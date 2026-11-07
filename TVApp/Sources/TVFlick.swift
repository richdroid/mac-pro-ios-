import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// One way to send anything to the TV: a black screen, the TV up top, and the card in your hand at the bottom.
struct FlickTarget: Identifiable {
    let id = UUID()
    let item: MediaItem
    let source: MediaSource
    // A song on this phone: its own cover, its own way to the TV, and what to do once it's there.
    var image: Image?
    var send: (String, [String: Any])?
    var sent: (() -> Void)?
    // Straight to the card in the hand, with the best stream found for it: a re-flick, or the next episode.
    var ready = false
    // And thrown by itself once it's found, for the next episode, which is one tap.
    var autoplay = false
    // The tile it was picked from, on the screen, so a card put back goes back onto it.
    var origin: CGRect? = nil
    // "Choose another" after a start that failed: straight to the streams, with the ones that didn't start set apart.
    var streamsFirst = false
    var avoid: Set<String> = []
}
struct StremioEpisode: Decodable, Identifiable, Hashable {
    let id: String, season: Int, episode: Int, name: String, thumb: String
    // From the Mac when Stremio's meta has them; Cinemeta's (SeriesInfo) win where both exist.
    var runtime: Int?
    var overview: String?
    // "3. The One…", but never "2. Episode 2: …", which says the number twice (r26).
    var title: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Episode \(episode)" }
        if n.lowercased().hasPrefix("episode \(episode)") { return n }
        return "\(episode). \(n)"
    }
}
struct StremioStream: Decodable, Identifiable, Hashable {
    let token: String, addon: String, name: String, description: String
    var quality: String?
    var hdr: String?
    var gb: Double?
    var instant: Bool?
    var lang: String?
    var id: String { token }
    // "2.1 GB · Ready now". Where it came from is added only to tell apart two rows that would otherwise read the same.
    var size: String? { gb.flatMap { $0 > 0 ? ($0 < 1 ? "\(Int($0 * 1024)) MB" : String(format: "%.1f GB", $0)) : nil } }
    func details(withSource: Bool = false, size withSize: Bool = true) -> String {
        var parts: [String] = []
        if withSize, let size { parts.append(size) }
        if instant == true { parts.append("Ready now") }
        if let lang, !lang.isEmpty { parts.append(lang) }
        if withSource, !addon.isEmpty { parts.append(addon) }
        return parts.joined(separator: " · ")
    }
    // What the row reads as, without its source.
    var look: String { (name.isEmpty ? addon : name) + "\u{1}" + details() }
    // Under the card in the hand: which stream it is, and nothing about where it came from. "1080p · 2.1 GB · Ready now"
    var brief: String {
        var parts: [String] = []
        if let q = quality ?? (name.isEmpty ? nil : name), !q.isEmpty { parts.append(q + (hdr.map { $0.isEmpty ? "" : " " + $0 } ?? "")) }
        if let gb, gb > 0 { parts.append(gb < 1 ? "\(Int(gb * 1024)) MB" : String(format: "%.1f GB", gb)) }
        if instant == true { parts.append("Ready now") }
        return parts.joined(separator: " · ")
    }
}
struct StremioMeta: Decodable {
    let about: String
    let episodes: [StremioEpisode]
}
extension MediaItem {
    // Cards hold either a plain title id or a whole link, and a link can already point at an episode.
    var stremioRef: (type: String, imdb: String, video: String?)? {
        if id.hasPrefix("stremio:///detail/") {
            let parts = id.dropFirst(18).split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            return (parts[0], parts[1], parts.count > 2 ? parts[2].removingPercentEncoding : nil)
        }
        return id.hasPrefix("tt") ? (kind == "series" ? "series" : "movie", id, nil) : nil
    }
}

struct FlickScreen: View {
    // Its entry in the side bar's Back, while choosing.
    @State private var railBackID = UUID()
    @State private var showInfo = false
    // The stream whose full description is open under its row.
    @State private var streamOpen: String?
    @Environment(TVModel.self) var model
    enum Step: Int { case episodes, streams, flick }
    let target: FlickTarget
    @State private var step: Step
    @State private var forward = true
    @State private var meta: StremioMeta?
    @State private var metaFailed = false
    @State private var lookups = 0
    @State private var season = 0
    @State private var episode: StremioEpisode?
    @State private var streams: [StremioStream] = []
    @State private var stream: StremioStream?
    @State private var findingStreams = false
    @State private var streamFilter = "All"
    @State private var noStreams = false
    @State private var cardFrame = CGRect.zero
    @State private var arrived = false
    // The bar's buttons come a beat after the backdrop starts in, as the bar itself can't fade.
    @State private var barShown = false
    @State private var flown = false
    @State private var landed = false
    @State private var note: String?
    @State private var hop = false
    @State private var sending = false
    @State private var done = false
    @State private var tvFrame = CGRect.zero
    // Each one is a moment: the card hitting the TV, and the card refused.
    @State private var impacts = 0
    @State private var shakes = 0
    // How the card swings in the hand, from how fast it's moving sideways.
    @State private var lean = 0.0
    // Quarter steps of the way to the TV, each felt as a tick.
    @State private var detent = 0
    @State private var demoHeld = false
    // The TV's answer: a flash and a tick on its screen, then the screen grows into its controls.
    @State private var successes = 0
    // The throw's own clock and flags: the tilt's trigger, the card turning into the TV's picture, when it left the hand,
    // and whether the Mac has said anything yet.
    @State private var thrown = 0
    @State private var morph = false
    @State private var releasedAt = Date.distantPast
    @StateObject private var pageBar = PageBarState()
    @State private var answered = false
    // The request has gone out to the Mac. From then on it's never called off for being slow: a written start runs.
    @State private var written = false
    // The card's picture, decoded, taken at the throw so the landed TV never waits on a fetch.
    @State private var heldImage: TVImage?
    // Its 16 px version, the landed picture's soft background, made when the picture is first in hand.
    @State private var softImage: TVImage?
    @State private var flight: Task<Void, Never>?
    @State private var cancelled = false
    @State private var morphing = false
    // The control screen's buttons settle in just after its screen has grown out of the TV.
    // Where the TV's screen sits on the control step. The one screen moves between that and tvFrame, growing as it goes.
    // Streams the TV took but couldn't get going: kept apart in the list, and never picked again.
    @State private var failedTokens: Set<String> = []
    // What the TV is doing while it gets going, read off its status.
    @State private var phase: String?
    // The best stream being found, and whether the one in hand was picked here rather than by him.
    @State private var pickingBest = false
    @State private var picked = false
    @State private var autoplay: Bool
    // The episode Stremio's Continue watching is on, and how far into it.
    @State private var upNext: String?
    @State private var upNextProgress: Double?
    // True once the episode he's on is known (what's playing, the card, or Continue watching), so nothing is prepared for a
    // guess like S1 E1 before then.
    @State private var resumeKnown = false
    // Each episode's own description and running time, from Stremio's catalogue.
    @State private var info: SeriesInfo.Info?
    // Handed to the controls while the TV is still getting the film going, once its player is up.
    @State private var handedOver = false
    // Near the end of something, whether to start it over rather than resume at the credits, and how long it runs.
    // Start over or carry on, as chosen; unchosen, a nearly-finished one starts over and anything else carries on.
    @State private var startOverChoice: Bool?
    var startOver: Bool { startOverChoice ?? nearEnd }
    @State private var runtime: Double?
    @State private var choseOnTV = false
    // On the control screen, a way back to the start, for when it's still near the end.
    @State private var askedRestart = false
    @Environment(\.paneLayout) private var panes
    @State private var priorMood: Color??
    // Thrown sideways too, the card's way across settles on its own spring, so the flight bends.
    @State private var flownX = false
    // Past seven tenths of the way: the TV lights up for it, and the hand feels it.
    @State private var charged = false
    // The Mac said the film is playing: the controls are his.
    @State private var playingSeen = false
    // The start is being followed line by line, so the TV's status needn't be asked.
    @State private var streamed = false
    // On the way out: nothing started now may change the app behind.
    @State private var leaving = false
    // Put back: the card goes down onto the tile it came from as everything else fades.
    @State private var returning = false
    @State private var returnSlot = CGRect.zero
    // Into the Remote: the screen moves onto the Remote's own picture of the TV.
    @State private var toRemote = false
    // The tab he threw from, while the Remote comes up under the stage; put back if the throw is called off or bounced.
    @State private var tabBefore: Int?
    @State private var restoredTab: Int?
    // The catch has settled: the TV's glow eased off and its picture the Remote's own look.
    @State private var caught = false
    // The ‹ goes the moment the card is lifted, with no animation: removed inside the throw's spring, its glass morphed with
    // the throw's speed into a blob over the card (r20).
    @State private var backHidden = false
    // Set the moment the screen lands on the Remote's picture: the bar's tick turns into the Remote's eye right then.
    @State private var onRemote = false
    @State private var remoteSlot = CGRect.zero
    @State private var screenOut = false
    // The last of it fading, so nothing over the Remote is gone in one frame when the screen closes.
    @State private var fadingOut = false
    // Where this screen sits on the display, to place things measured elsewhere.
    @State private var flickFrame = CGRect.zero
    // Held where it was as the Remote's tab comes up under it, so the tab changing can't lay it out again mid-move.
    @State private var held: CGRect?
    var flickOrigin: CGPoint { (held ?? flickFrame).origin }
    // The picked thing's own colour, which floods in a little while the card is held.
    @State private var tint: Color?
    // The catch's sparks: the card's own colour beside the accent.
    var sparkTint: Color { tint ?? .white }
    // The TV taking a breath as its player comes up.
    // When the Mac said the film is playing: the play key says so at once, before the TV's own status catches up.
    @State private var playedAt: Date?
    // Follows the finger exactly, with nothing in between.
    @State private var drag = UserDefaults.standard.string(forKey: "pose") == "lift" ? CGSize(width: 18, height: -190) : .zero
    // Tells a touch the system took away from one that ended, so the card can't get stuck raised.
    @GestureState private var touching = false
    static let pose = UserDefaults.standard.string(forKey: "pose")

    init(target: FlickTarget) {
        self.target = target
        let ref = target.source == .stremio && target.send == nil ? target.item.stremioRef : nil
        let posed = ["lift", "flickdemo", "flickdemo-stream"].contains(Self.pose) || Self.pose?.hasPrefix("flick-") == true
        // A card that already names its episode, from Continue watching or a re-flick, needs no episode picked.
        let ready = target.ready && (ref?.type == "movie" || ref?.video != nil)
        // A show always opens on its own page, its episodes there to pick from with where he is in view, even from
        // Continue watching: going straight to one episode's streams was "so static" (Richard, 2026-11-05).
        _step = State(initialValue: ref == nil || posed || ready ? .flick : ref?.type == "series" ? .episodes : .streams)
        // After a start that failed, "Choose another" comes straight to the streams, the ones that didn't start set apart.
        if target.streamsFirst && ref != nil { _step = State(initialValue: .streams) }
        _failedTokens = State(initialValue: target.avoid)
        _autoplay = State(initialValue: target.autoplay)
    }
    var item: MediaItem { target.item }
    var source: MediaSource { target.source }
    var isSeries: Bool { item.stremioRef?.type == "series" }
    var lifted: Bool { (touching || demoHeld) && !flown }
    // Picking an episode or a stream, before the card is in the hand.
    var choosing: Bool { step == .episodes || step == .streams }
    var cardY: CGFloat {
        if !arrived { return 420 }
        if hop { return -22 }
        // Up is free; down gives less and less, like pulling against a band.
        return drag.height < 0 ? drag.height : 90 * (1 - 1 / (drag.height / 150 + 1))
    }
    // From the hand to the TV it's going into.
    var reach: CGFloat { max(cardFrame.midY - tvFrame.midY, 1) }
    // How far the card has come: 0 in the hand, 1 over the TV.
    var progress: CGFloat { arrived && !flown && !returning ? min(1.2, max(0, -cardY) / reach) : 0 }
    // The TV's answer to the card coming: full by seven tenths of the way, when it's charged.
    var charge: CGFloat { returning ? 0 : flown || landed ? 1 : min(1, progress / 0.7) }
    // What the Mac is told is coming, so it can do more than wake the TV.
    var prepareBody: [String: Any] { prepareBody(for: nil) }
    func prepareBody(for video: String?) -> [String: Any] {
        guard let ref = item.stremioRef else { return [:] }
        var b: [String: Any] = ["type": ref.type, "imdb": ref.imdb]
        if let v = video ?? episode?.id ?? ref.video { b["video"] = v }
        if video == nil, let t = stream?.token { b["token"] = t }
        return b
    }
    // A Stremio stream or title: the kind of send the TV can be made ready for.
    var video: Bool { source == .stremio && target.send == nil && item.stremioRef != nil }
    var onTV: Bool { model.isOnTV(shown, source) || model.isOnTV(item, source) }
    // Everything else steps back while the card is in the air.
    var calm: Double { !arrived ? 0 : flown ? 0.15 : 1 - 0.85 * min(1, Double(progress) * 1.6) }
    var shown: MediaItem {
        guard let e = episode else { return item }
        return MediaItem(title: item.title, subtitle: "S\(e.season) E\(e.episode) · \(e.name)", art: item.art, id: item.id, kind: item.kind)
    }
    var seasons: [Int] { Array(Set((meta?.episodes ?? []).map(\.season))).sorted() }
    var previous: Step? {
        switch step {
        case .episodes: return nil
        case .streams: return isSeries ? .episodes : nil
        // At the card there's nothing left to go back to, unless the stream was picked here: then back to choose another.
        case .flick: return picked && !flown && !backHidden ? .streams : nil
        }
    }
    var next: Step? {
        switch step {
        case .episodes: return episode == nil ? nil : .streams
        case .streams: return .flick
        case .flick: return nil
        }
    }
    func go(_ to: Step) {
        model.tick()
        forward = to.rawValue > step.rawValue
        if !flown { note = nil }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = to }
        if to == .streams && streams.isEmpty { Task { await findStreams() } }
    }

    var body: some View {
        felt
            .opacity(fadingOut ? 0 : 1)
            // Charged at seven tenths; falling back below six tenths un-charges, silently.
            .onChange(of: progress >= 0.7) { _, now in if now && lifted { charged = true } }
            .onChange(of: progress < 0.6) { _, below in if below && !flown { charged = false } }
            .onChange(of: lifted) { _, up in
                guard up, !backHidden else { return }
                var quiet = Transaction(); quiet.disablesAnimations = true
                withTransaction(quiet) { backHidden = true }
            }
            // The TV made ready, with what's coming, at each point he shows he means it: the show's page with its Resume,
            // the streams opening, the card in the hand with its stream, and the card lifted (§2.5a C6).
            // Nothing is prepared for what's already on the TV (r18: a prepare went out for the film already playing).
            .onChange(of: lifted) { _, now in if now && video && !onTV { Prepare.arm(prepareBody) } }
            .onChange(of: step == .flick && stream != nil) { _, now in if now && video && !flown && !onTV { Prepare.arm(prepareBody) } }
            .onChange(of: step) { _, now in if now == .streams && video && !onTV { Prepare.arm(prepareBody) } }
            .onChange(of: resumeKnown && !onTVUnsettled ? resumeTarget?.episode.id : nil) { _, id in
                if let id, video, step == .episodes, let t = resumeTarget, !isOn(t.episode) { Prepare.arm(prepareBody(for: id)) }
            }
            .task { await opened() }
    }
    // Picked up, a third of the way, charged, and the hit on the TV: the whole set while the card is in the hand. The
    // caught tick follows the impact by 120 ms (in `arrivedAtTV`).
    var felt: some View {
        screen
            .onChange(of: lifted) { _, now in if now { FlickHaptic.lift(); FlickClock.touched() } }
            .onChange(of: detent) { old, new in if new == 1 && old == 0 && lifted { FlickHaptic.detent() } }
            .onChange(of: charged) { _, now in if now && lifted { FlickHaptic.charged() } }
            .onChange(of: impacts) { _, _ in FlickHaptic.impact() }
            .onAppear { FlickHaptic.warm() }
    }
    var screen: some View {
        // The system's own bar, so on the Duo back, next and close sit on the side like everywhere else.
        NavigationStack {
            GeometryReader { g in
                // Once held, laid out at the size it had and put back where it was, whatever the space around it does.
                let live = g.frame(in: .global)
                let box = held ?? live
                ZStack {
                    backdrop(box.size)
                    // The TV's screen, one view across the card's step and the controls', so it grows from one to the other.
                    // Under the steps, so the card flies over it on its way in.
                    if step == .flick { screenLayer.opacity((arrived || toRemote) && !screenOut ? 1 : 0).transition(slide) }
                    Group {
                        switch step {
                        case .episodes: episodesStep.transition(slide)
                        case .streams: streamsStep.transition(slide)
                        case .flick: flickStep(g).transition(slide)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // In and out with the backdrop: it opens over the app, not as a sheet sliding up. A card being put
                    // back stays to the end, landing on its tile.
                    .opacity(arrived || returning ? 1 : 0)
                }
                .frame(width: box.width, height: box.height)
                .coordinateSpace(name: "flick")
                .offset(x: box.minX - live.minX, y: box.minY - live.minY)
            }
            // On the reader, outside the hold's offset, so measuring it moves nothing.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { flickFrame = $0 }
            // In with the backdrop, and out with it, rather than on the rail before anything else is there.
            // On the card and after it, the X in the bar. While choosing (the show's page, the streams), back is in a
            // glass bar at the foot by the side bar, like every other page's, never loose circles over the side bar.
            // Open, the bar's buttons go as the move starts, but the bar itself stays: hiding it there re-laid the whole
            // screen out under the moving picture, in the move's first frame, and the open hand-off stalled ~160 ms, its
            // light dropping out for a frame and the picture then leaping to the Remote (r27, r28). Folded keeps the tick
            // becoming the Remote's eye, and hides the bar as before.
            .toolbar { if barShown && !choosing && !(panes && toRemote) { bar } }
            // The X goes with the stage, folded and open: left over the side bar it swapped to the Remote's eye in one frame (r19).
            .navBarHidden(toRemote && !panes)
            // While choosing, back is the same glass bar every page has, at the foot by the side bar, stepping away as he
            // scrolls down and back as he scrolls up; never a loose circle (r17).
            .environment(\.pageBar, pageBar)
            .overlay(alignment: .bottom) {
                // With a side bar beside the page, Back is the side bar's (Richard, 2026-11-07: "back should be on side
                // bar"). Open in portrait the page covers the tab bar, so there it keeps its own bar at the foot.
                if choosing && model.railWidth < 1 {
                    // One glass bar across the page's foot, back at its start: summoned by scrolling up, gone on the way
                    // down, and the page's foot inset (84 pt) keeps its last row clear of it at rest (r26: a lone "Back"
                    // capsule sat over episode 4's title).
                    PageBar(back: { if let previous { go(previous) } else { leave() } }, full: true) { EmptyView() }
                        .padding(.horizontal, panes ? 20 : 16).padding(.bottom, panes ? 16 : 10)
                        // Open, the choices' pane only, never across the fold (r27).
                        .containerRelativeFrame(.horizontal) { w, _ in panes ? w / 2 : w }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(barShown && pageBar.shown ? 1 : 0)
                        .offset(y: pageBar.shown ? 0 : 18)
                        .allowsHitTesting(pageBar.shown)
                }
            }
            // Open, the show's one big key sits at the left pane's foot, level with Back at the right's: the same height,
            // the same baseline. Flowing under the blurb it landed 34 pt above Back, two bars that didn't line up (r29).
            .overlay(alignment: .bottomLeading) {
                if choosing && panes && step == .episodes {
                    resumeButton(height: 50)
                        .padding(.horizontal, 20).padding(.bottom, 16)
                        .containerRelativeFrame(.horizontal) { w, _ in w / 2 }
                        .opacity(barShown ? 1 : 0)
                }
            }
            .onChange(of: choosing && !leaving, initial: true) { _, c in model.flickChoosing = c }
            // The side bar's Back steps back through the choosing (streams → episodes → out), as the page's own bar did.
            .onChange(of: choosing && !leaving && model.railWidth >= 1, initial: true) { _, on in
                if on { model.pushBack(railBackID) { if let previous { go(previous) } else { leave() } } } else { model.popBack(railBackID) }
            }
            .onChange(of: !choosing && !toRemote && !leaving, initial: true) { _, c in model.flickCovering = c }
            .onDisappear { model.flickChoosing = false; model.flickCovering = false; model.popBack(railBackID) }
            // The card in the hand, the stage black over everything: the Remote comes up underneath now, so its first
            // layout (0.3 s folded, about 0.9 s open) is paid for while nothing moves, never during the throw (r21: switched
            // at the release, it froze the card mid-air). Back off the card's step, the page he came from comes back.
            .onChange(of: step == .flick && arrived && !leaving && !returning, initial: true) { _, on in
                if on { Task { try? await Task.sleep(nanoseconds: 600_000_000); prepareRemote() } }
                else if !flown && !toRemote { backToThrownFrom() }
            }
            // Another tab, from the side bar while choosing, leaves the page for it.
            .onChange(of: model.tab) { _, t in
                // Its own putting back of the page he came from isn't him picking a tab.
                if t == restoredTab { restoredTab = nil; return }
                if choosing && !leaving { leave() }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .containerBackground(.clear, for: .navigation)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .preferredColorScheme(.dark)
        // The build's recording only: what the flick is doing, so a frame can be read against the code. Top left, clear of
        // the card at rest.
        .overlay(alignment: .topLeading) {
            // Only on the flick's own timing poses; the plain show-page shots stay clean so the page itself can be judged.
            if Self.pose?.hasPrefix("flick-") == true || Self.pose?.hasPrefix("flickdemo") == true {
                // Milliseconds since the release, so a frame can be read against §2.5a C4's timings.
                // Ten times a second, not every frame: redrawn per frame it cost the hand-off its own frames (r27).
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    let t = releasedAt == .distantPast ? -1 : Int(ctx.date.timeIntervalSince(releasedAt) * 1000)
                    Text("t=\(t) step \(step.rawValue) flown \(flown ? 1 : 0) landed \(landed ? 1 : 0) sending \(sending ? 1 : 0) phase \(phase ?? "-") answered \(answered ? 1 : 0)")
                        .font(.system(size: 11, design: .monospaced)).padding(6).background(.black.opacity(0.7)).foregroundStyle(.yellow)
                }
            }
        }
    }
    // As the screen opens: in it comes, the colours change, and whatever the card needs is asked for.
    func opened() async {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { arrived = true }
        Task { try? await Task.sleep(nanoseconds: 250_000_000); withAnimation(.easeOut(duration: 0.2)) { barShown = true } }
        // The app behind takes on the picked thing's colour too, and gets its own back after: never once this has
        // started to close, or the colour would stay behind it.
        if priorMood == nil { priorMood = .some(model.mood) }
        let art = item.art
        Task {
            guard let u = URL(string: art), let c = await ImageStore.shared.band(u) else { return }
            withAnimation(.easeOut(duration: 0.3)) { tint = c }
            if !leaving, !flown { model.mood = c }
        }
        if step == .flick && stream != nil && video && !onTV { Prepare.arm(prepareBody) }
        if ["flickdemo", "flickdemo-stream"].contains(Self.pose) || Self.pose?.hasPrefix("flick-") == true { Task { await demo() } }
        // Side by side, so a slow description doesn't hold up the streams.
        async let details: Void = loadMeta()
        if isSeries, let ref = item.stremioRef {
            info = SeriesInfo.cached(ref.imdb)
            if info == nil { Task { let i = await SeriesInfo.load(ref.imdb); withAnimation(.easeOut(duration: 0.2)) { info = i } } }
        }
        if target.ready { await pickBest() }
        else if step == .streams && streams.isEmpty { await findStreams() }
        await details
    }
    var slide: AnyTransition {
        // Into the controls, the flick just fades away.
        if morphing { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    // Black, as he asked: the page behind never shows through as shapes. While choosing, the picked thing's art shows
    // softly through the dark; on the card's step the art's colour lives only as a glow behind the TV, brightening as
    // the card charges (§2.5a C2).
    func backdrop(_ size: CGSize) -> some View {
        ZStack {
            // Opaque under everything: nothing of the page behind can read through, so that page needn't hide its own bar
            // to stay out of sight, which took the tab rail with it (r20–r26: no rail beside a show's page).
            // No material over it: a full-screen blur of plain black drew nothing but cost a blur pass every frame, twice
            // the area open, where the throw ran at about 20 fps and the backdrop's fade at the move blurred the Remote
            // coming up under it (r28).
            Color.black
            if step != .flick {
                Color.clear
                    .overlay {
                        Group {
                            if let image = target.image { image.resizable().scaledToFill() }
                            else {
                                Art(url: URL(string: episode?.thumb.isEmpty == false ? episode!.thumb : item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                                    .id(episode?.id ?? item.art)
                                    .transition(.opacity)
                            }
                        }
                        // A fixed blur: animating its radius redraws the whole screen's blur every frame.
                        .blur(radius: 32)
                        .scaleEffect(1.1)
                    }
                    .clipped()
                    // Beside the side bar the strip under it is plain black, so the art's tint dies away before the page's
                    // trailing edge rather than meeting the strip as a band of a different background (r30).
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .opacity(0.4)
                    .transition(.opacity)
            }
            Color.black.opacity(step == .flick ? 0.88 : 0.6)
        }
        // Edge to edge, except past the page's trailing edge beside the side bar while choosing: run on under the bar's
        // room, it covered the rail (r20–r28). It was cut there with a clip over the whole flick screen (r29), which
        // rendered every frame of the throw and the move offscreen: the folded stalls rose from ~60 to ~120 ms, and the
        // open hand-off from 166 to 202 ms.
        .ignoresSafeArea(edges: model.flickChoosing ? [.top, .bottom, .leading] : .all)
        .opacity(arrived ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: episode)
        .animation(.easeOut(duration: 0.3), value: step)
    }
    // The art's colour, only behind the TV: brightest at its centre, gone by 1.6 times its width.
    func glow(_ s: Stage) -> some View {
        RadialGradient(colors: [(tint ?? TVLook.accent).opacity(0.35 + 0.25 * Double(charge)), .clear], center: .center, startRadius: 0, endRadius: s.tv.width * 0.8)
            .frame(width: s.tv.width * 1.6, height: s.tv.width * 1.6)
            .position(s.centre)
            .allowsHitTesting(false)
            .opacity(arrived && !toRemote ? 1 : 0)
    }

    @ToolbarContentBuilder var bar: some ToolbarContent {
        if let previous {
            ToolbarItem(placement: .navigation) { Button { go(previous) } label: { Label("Back", systemImage: "chevron.left") } }
        }
        // Only back to an episode already chosen. On the streams, "Choose on the TV" is the way on without one.
        if let next, step == .episodes {
            ToolbarItem(placement: .primaryAction) { Button { go(next) } label: { Label("Next", systemImage: "chevron.right") } }
        }
        ToolbarItem(placement: .cancellationAction) {
            // While the card is on its way or held in the TV, the X calls it off.
            let stops = flown
            // Going to the Remote folded, the tick becomes the Remote's own eye in the same place, so the bar never swaps in
            // a frame. Unfolded the Remote has no bar button, and the tick just fades with the screen.
            let eye = onRemote && !stops && !panes ? (model.mirrorLive ? "eye.slash" : "eye") : nil
            Button { stops ? callOff() : leave() } label: {
                // Both glyphs always drawn, one crossfading into the other: a symbol swap here cut in one frame, as the bar
                // rebuilds its item rather than animating it.
                Label {
                    Text(stops ? "Stop" : "Close")
                } icon: {
                    ZStack {
                        Image(systemName: "xmark")
                            .opacity(eye == nil ? 1 : 0).scaleEffect(eye == nil ? 1 : 0.6)
                        Image(systemName: eye ?? (model.mirrorLive ? "eye.slash" : "eye"))
                            .opacity(eye == nil ? 0 : 1).scaleEffect(eye == nil ? 0.6 : 1)
                    }
                    .animation(.easeInOut(duration: 0.2), value: eye == nil)
                }
            }
        }
    }

    var poster: some View {
        Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
            .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
    }
    // The show's name leads; under it, once an episode's chosen, that episode, else how many seasons there are.
    func titles(big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(big ? .title.weight(.bold) : .title2.weight(.bold)).lineLimit(3)
            if step == .streams, let e = episode {
                Text("S\(e.season) E\(e.episode) · \(e.name)").font(.headline).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            } else if isSeries, case let n = seasons.filter({ $0 > 0 }).count, n > 0 {
                Text(n == 1 ? "1 season" : "\(n) seasons").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .contentTransition(.opacity)
    }
    // What it's about: on the streams, the episode's own words, else the show's or the film's (Richard, 2026-11-05: "make
    // the description an episode description unless not available").
    var blurbText: String? {
        if step == .streams, let e = episode, let o = info?.about[e.id], !o.isEmpty { return o }
        let a = meta?.about ?? item.about
        return a?.isEmpty == false ? a : nil
    }
    func blurb(_ lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = blurbText { Text(t).font(.subheadline).foregroundStyle(.secondary).lineLimit(lines).fixedSize(horizontal: false, vertical: true).contentTransition(.opacity) }
            HStack(spacing: 18) {
                // Everything about it, before choosing (Richard, 2026-11-07: "an i to see full details of each before i flick").
                if item.stremioRef != nil {
                    Button { model.tick(); showInfo = true } label: { Label("Details", systemImage: "info.circle") }
                        .font(.footnote.weight(.semibold)).tint(TVLook.accent)
                }
                if let slug = item.slug, !slug.isEmpty {
                    Button { model.tick(); model.post("film", ["slug": slug]); leave() } label: {
                        Label("Letterboxd", systemImage: "film")
                    }.font(.footnote.weight(.medium)).tint(TVLook.accent)
                }
            }
        }
        .sheet(isPresented: $showInfo) { TitleInfoSheet(item: item, source: source, fromFlick: true) }
        .animation(.easeOut(duration: 0.2), value: blurbText)
    }
    var heading: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                poster.frame(width: 74, height: 111).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 8) { titles(big: false); blurb(4) }
                Spacer(minLength: 0)
            }
            if step == .episodes { resumeButton() }
        }
    }
    // Unfolded, the show has the left side to itself: poster and name side by side, what it's about under them, and the
    // one big way to carry on, so the side reads full rather than a small poster over empty space.
    var bigHeading: some View {
        // The name leads, at the top line shared with the other pane; under it the poster, big enough to be the pane's
        // picture (60 % of it, at most 300 pt), and what it's about under that at the pane's full width. Beside a small
        // poster, the blurb ran in a sliver and the lower half of the pane stood empty, which read as a panel (r28).
        VStack(alignment: .leading, spacing: 16) {
            titles(big: true)
            poster.aspectRatio(2 / 3, contentMode: .fit)
                .containerRelativeFrame(.horizontal) { w, _ in min(w * 0.6, 300) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            blurb(6)
            // On the streams, the episode being chosen for: its number, name, length and what happens, so the side
            // under the poster is the episode's page, not half empty (r27).
            if step == .streams, let e = episode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Season \(e.season) · Episode \(e.episode)" + (e.runtime.map { " · \($0) min" } ?? ""))
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Text(e.title).font(.title3.weight(.semibold)).lineLimit(2)
                    if let o = e.overview, !o.isEmpty { Text(o).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Where to carry on: the episode he's on (or the one after it if that's all but done, or the first), as one big key.
    var resumeTarget: (episode: StremioEpisode, verb: String)? {
        guard let all = meta?.episodes, !all.isEmpty else { return nil }
        if let id = upNext, let e = all.first(where: { $0.id == id }) {
            let p = upNextProgress ?? 0
            if p > 0.9, let n = NextUp.after(e, in: all) { return (n, "Play next") }
            return (e, p > 0 ? "Resume" : "Play")
        }
        return (all.first { $0.season > 0 } ?? all[0], "Play")
    }
    // The episode the big key would play is already what's on the TV: the key says so, and takes him to the Remote.
    func isOn(_ e: StremioEpisode) -> Bool {
        guard let ref = item.stremioRef else { return false }
        return model.isOn(imdb: ref.imdb, title: item.title, episode: e.id)
    }
    // This show is what the TV's playing, but which episode isn't known yet: no key and no prepare until it is.
    var onTVUnsettled: Bool {
        guard item.stremioRef?.type == "series", model.videoIsCurrent, let s = model.status?.session, s.pkg == "com.stremio.one" else { return false }
        // Not settled until a fresh reading is in.
        if model.staleStatus { return true }
        if let on = NextUp.shared.series, on.imdb == item.stremioRef?.imdb { return false }
        return (s.isShow(item.title)) && s.seasonEpisode == nil
    }
    // Straight to the Remote with nothing sent; if it's paused there, asked to play (MEDIA_PLAY, never the toggle).
    func toRemoteNow() {
        model.tick()
        // Held as playing, as from a card, so the key shows the play it asked for at once.
        if model.status?.session?.playing == false { model.holdPlay(true); model.key("resume") }
        if let prior = priorMood { model.mood = prior }
        model.tab = 0
        leave(restoreMood: false)
    }
    @ViewBuilder func resumeButton(height: CGFloat = 58) -> some View {
        if let t = resumeTarget, isOn(t.episode) {
            Button(action: toRemoteNow) {
                HStack(spacing: 12) {
                    Circle().fill(TVLook.accent).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("On the TV").font(.headline)
                        Text("S\(t.episode.season) E\(t.episode.episode) · \(t.episode.name)").font(.caption.weight(.medium)).opacity(0.7).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "av.remote").font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 20).frame(height: height)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressCard())
            .transition(.opacity)
        } else if let t = resumeTarget, resumeKnown, !onTVUnsettled {
            // Only once it's known where he is: until then it said "Play S1 E1" for a show he's halfway through (r18).
            let p = t.episode.id == upNext ? (upNextProgress ?? 0) : 0
            let mins = info?.minutes[t.episode.id] ?? info?.show
            let left = t.verb == "Resume" ? mins.map { "\(max(1, Int(Double($0) * (1 - p)))) min left" } : mins.map { "\($0) min" }
            Button { choose(t.episode) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill").font(.system(size: 17, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(t.verb) S\(t.episode.season) E\(t.episode.episode)").font(.headline)
                        Text(([t.episode.name] + (left.map { [$0] } ?? [])).joined(separator: " · ")).font(.caption.weight(.medium)).opacity(0.7).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.black).padding(.horizontal, 20).frame(height: height)
                .background(TVLook.accent, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressCard())
            .transition(.opacity)
        }
    }
    // An episode picked, from its row or the big key: its streams next.
    func choose(_ e: StremioEpisode) {
        if episode != e { episode = e; stream = nil; streams = []; noStreams = false; streamFilter = "All"; picked = false; runtime = nil; startOverChoice = nil; choseOnTV = false }
        go(.streams)
    }
    func row<L: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                label()
                Spacer(minLength: 0)
                // The whole row is the button, so no arrow; only the one chosen says so.
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(TVLook.accent).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            // One row height for every plain choice on these pages, with the same corners as the episode rows.
            .frame(minHeight: 40)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(selected ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressCard())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    // The film at the top, then the choices. Unfolded, the film one side of the fold and the choices the other.
    @ViewBuilder func page<C: View>(@ViewBuilder content: () -> C) -> some View {
        // Both sides start at the same line, and fade under the top edge rather than run under the clock.
        // Air under the top on both sides, the same on each so their first lines (the poster's top, the "Season" heading)
        // sit level; room at the foot for the bar, so the last row can always be scrolled clear of it.
        if panes {
            FoldSplit {
                // On the page's own black, no panel behind it: a tinted card behind one side read as a block of different
                // background, half of it empty (r28). The poster fills the side instead.
                ScrollView { bigHeading.padding(.horizontal, 20).padding(.top, 36).padding(.bottom, 84) }.topFade().summonsBar()
            } right: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { content() }
                        .padding(.horizontal, 20).padding(.top, 36).padding(.bottom, 84)
                }
                .topFade().summonsBar()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { heading.padding(.bottom, 8); content() }
                    // Clear of the top edge and the clock, never jammed under it (r21).
                    .padding(.horizontal, 20).padding(.top, 32).padding(.bottom, 84)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .topFade().summonsBar()
        }
    }

    // First step of a series: which episode. The same list as over the Remote and on Playing.
    var episodesStep: some View {
        page {
            if seasons.isEmpty && !metaFailed {
                ForEach(0..<4, id: \.self) { i in PlaceholderRow(delay: Double(i) * 0.12, thumb: true) }
            } else if seasons.isEmpty {
                // No episode list is no reason to be stuck: the TV can still open the series.
                Text("Couldn’t load the episodes.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                Button("Try again") { metaFailed = false; Task { await loadMeta() } }.font(.subheadline.weight(.medium)).tint(TVLook.accent)
                row(selected: false) { go(.flick) } label: {
                    Image(systemName: "tv").foregroundStyle(TVLook.accent).frame(width: 28)
                    Text("Open the series on the TV").font(.subheadline.weight(.semibold))
                }
            } else {
                ScrollViewReader { proxy in
                    let target = resumeTarget?.episode
                    EpisodePicker(episodes: meta?.episodes ?? [], season: $season, current: target?.id,
                                  // The episode that's on the TV says so, never "Up next" (r18).
                                  currentLabel: target.map(isOn) == true ? "Playing" : resumeTarget?.verb == "Resume" ? "Resume" : "Up next",
                                  progress: target?.id == upNext ? upNextProgress : nil, info: info) { choose($0) }
                    // To where he is, as soon as that's known, and again on coming back from the streams.
                    .onChange(of: target?.id, initial: true) { _, id in
                        guard let id else { return }
                        Task { try? await Task.sleep(nanoseconds: 60_000_000); withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onAppear { if let id = episode?.id ?? target?.id { Task { proxy.scrollTo(id, anchor: .center) } } }
                }
            }
        }
    }
    func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(TVLook.accent, in: Capsule()).foregroundStyle(.black)
    }
    // Next: which stream, or leave that to the TV.
    var streamsStep: some View {
        page {
            // The episode is named on the left, over its own description; here, the choice, under its heading.
            let qualities = ["1080p", "4K", "720p", "480p"].filter { q in streams.contains { $0.quality == q } }
            HStack(spacing: 12) {
                Text("Streams").font(.title3.weight(.bold))
                if qualities.count > 1 { Chips(options: (["All"] + qualities).map { ($0, $0) }, selected: $streamFilter).rowEdge() }
            }
            .frame(height: 36, alignment: .leading)
            .padding(.bottom, 2)
            row(selected: choseOnTV) { stream = nil; picked = false; choseOnTV = true; go(.flick) } label: {
                Image(systemName: "tv").font(.system(size: 17, weight: .semibold)).foregroundStyle(TVLook.accent).frame(width: 28)
                Text("Choose on the TV").font(.subheadline.weight(.semibold))
            }
            // Nearly finished: resuming would land on the credits, so starting over is offered, and chosen to begin with.
            // Not for Choose on the TV, where Stremio's own screen asks.
            // Where it'll start, and the other way, whenever he's been in it before: from the card, else from Stremio's own
            // Continue watching (Richard, 2026-11-07: "obv when i flick it should start from where i was").
            if hasResume && !choseOnTV {
                Chips(options: [(false, resumeLabel), (true, "Start over")], selected: Binding(get: { startOver }, set: { startOverChoice = $0 })).padding(.top, 6)
            }
            if findingStreams && streams.isEmpty {
                Text("Asking your addons…").font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(0..<4, id: \.self) { i in PlaceholderRow(delay: Double(i) * 0.12) }
            } else if noStreams {
                Button("No streams found. Try again") { Task { await findStreams(again: true) } }
                    .font(.subheadline.weight(.medium)).tint(TVLook.accent).frame(maxWidth: .infinity).padding(.top, 22)
            }
            let shown = streams.filter { streamFilter == "All" || $0.quality == streamFilter }
            // Best is the top one that hasn't already failed to start.
            let best = streamFilter == "All" ? streams.first { !failedTokens.contains($0.token) } : nil
            // Rows that would read exactly the same say where each came from.
            let looks = Dictionary(shown.map { ($0.look, 1) }, uniquingKeysWith: +)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                streamRow(s, best: s == best, failed: failedTokens.contains(s.token), twin: (looks[s.look] ?? 0) > 1).transition(arriving(i))
            }
        }
        .task(id: episode?.id) { await loadRuntime() }
    }
    // Rows come in one after another, a beat apart.
    func arriving(_ i: Int) -> AnyTransition {
        let spring = Animation.spring(response: 0.45, dampingFraction: 0.85).delay(Double(min(i, 8)) * 0.035)
        return .asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(y: 14)).animation(spring), removal: .opacity)
    }
    // How far into it the card says he is, for the episode it's about.
    var savedProgress: Double? {
        guard let ref = item.stremioRef else { return nil }
        if ref.type == "series", let e = episode {
            if e.id == ref.video, let p = item.progress { return p }
            if e.id == upNext, let p = upNextProgress { return p }
            return continuing(ref.imdb, e.id)
        }
        return item.progress ?? continuing(ref.imdb, nil)
    }
    // Where Stremio's own Continue watching has him in this film, or this episode of this show.
    func continuing(_ imdb: String, _ video: String?) -> Double? {
        let row = BrowseStore.shared(.stremio).rows.first { $0.title == "Continue watching" }
        for i in row?.items ?? [] {
            guard let r = i.stremioRef, r.imdb == imdb, let p = i.progress else { continue }
            if video == nil || r.video == video { return p }
        }
        return nil
    }
    var hasResume: Bool { (savedProgress ?? 0) > 0.01 && (savedProgress ?? 0) < 0.99 }
    var nearEnd: Bool { (savedProgress ?? 0) > 0.9 }
    var resumeLabel: String {
        guard let runtime, let p = savedProgress else { return "Resume" }
        // Running time times progress: "Resumes at 42:10", "Resumes at 1:12:05".
        let s = Int(runtime * p / 1000)
        return "Resumes at " + (s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
    }
    // The running time, for the Resume chip's time: from Stremio's own catalogue, the episode's if it has one.
    func loadRuntime() async {
        guard runtime == nil, hasResume, let ref = item.stremioRef,
              let d = await TVBridge.data(URL(string: "https://v3-cinemeta.strem.io/meta/\(ref.type)/\(ref.imdb).json"), timeout: 10, cached: true),
              let meta = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["meta"] as? [String: Any] else { return }
        let video = episode?.id ?? ref.video
        let ep = (meta["videos"] as? [[String: Any]])?.first { ($0["id"] as? String) == video }
        func minutes(_ t: Any?) -> Double? {
            guard let t = t as? String else { return nil }
            // "2h 3min", "123 min" and the like: the number before each unit.
            func number(before unit: String) -> Double {
                guard let r = t.range(of: "\\d+\\s*" + unit, options: .regularExpression) else { return 0 }
                return Double(t[r].prefix { $0.isNumber }) ?? 0
            }
            let h = number(before: "h"), m = number(before: "min")
            return h + m > 0 ? (h * 60 + m) * 60000 : nil
        }
        if let ms = minutes(ep?["runtime"]) ?? minutes(meta["runtime"]) { withAnimation(.easeOut(duration: 0.2)) { runtime = ms } }
    }
    func streamRow(_ s: StremioStream, best: Bool, failed: Bool, twin: Bool) -> some View {
        row(selected: stream == s) { stream = s; picked = false; choseOnTV = false; go(.flick) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.name.isEmpty ? s.addon : s.name).font(.subheadline.weight(.bold)).lineLimit(1)
                    // The list comes best first, for this box and what's being watched.
                    if best { badge("Best") }
                    // Tried, and the TV couldn't get it going, twice: left in place so the list doesn't jump, but out of reach.
                    if failed {
                        Text("Didn’t start").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(.white.opacity(0.14), in: Capsule()).foregroundStyle(.secondary)
                    }
                }
                let details = s.details(withSource: twin, size: false)
                if !details.isEmpty { Text(details).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1) }
                // Everything the addon says about it (the file, the source, the size, the codec), when its "i" is open.
                if streamOpen == s.id {
                    Text([s.addon, s.name, s.description].filter { !$0.isEmpty }.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .multilineTextAlignment(.leading)
            // How big it is, at the row's end where the eye runs to, rather than empty space, right-aligned so the sizes
            // line up down the list. It takes the whole rest of the row: with a spacer here as well as the row's own, the
            // two split the room and each size sat midway, at a different place on every row (r27, r28).
            Text(s.size ?? "").font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                .frame(minWidth: 64, maxWidth: .infinity, alignment: .trailing).padding(.leading, 8)
        }
        .disabled(failed)
        .opacity(failed ? 0.45 : 1)
        // Its details, opened in place: the row's own tap still picks it.
        .overlay(alignment: .topTrailing) {
            Button { model.tick(); withAnimation(.snappy) { streamOpen = streamOpen == s.id ? nil : s.id } } label: {
                Image(systemName: streamOpen == s.id ? "info.circle.fill" : "info.circle").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TVLook.accent).frame(width: 36, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Stream details")
            .offset(x: 4, y: -6)
        }
    }
    func findStreams(again: Bool = false) async {
        guard let ref = item.stremioRef else { return }
        findingStreams = true; noStreams = false
        lookups += 1
        let mine = lookups
        // Only the newest lookup decides when the spinner stops.
        defer { if mine == lookups { findingStreams = false } }
        // The episode picked, else the one the card was already on, before its details have come. Usually already asked
        // for when the card was pressed.
        let video = episode?.id ?? ref.video ?? ref.imdb
        let found = await StreamCache.shared.streams(type: ref.type, imdb: ref.imdb, video: video, again: again)
        // These tokens play the episode they were asked for, so an answer for another one is thrown away.
        guard (episode?.id ?? ref.video ?? ref.imdb) == video, mine == lookups else { return }
        guard let found, !found.isEmpty else { noStreams = true; return }
        withAnimation { streams = found }
    }

    // Where everything on the card's step goes. The TV sits at the true centre of the screen, worked out from the whole
    // display rather than the space left by the bars, so a side bar or the time never pushes it aside, folded, open or
    // flat. Partly folded, it's the centre of the half being looked at, and the card sits at the foot of the half in the
    // hand. Nothing here depends on the two-pane layout, which can change under the flick.
    struct Stage {
        var centre: CGPoint, tv: CGSize, cardX: CGFloat, cardTop: CGFloat, cardWidth: CGFloat, floor: CGFloat, wide: Bool
        var tvTop: CGFloat { centre.y - tv.height / 2 }
        var tvBottom: CGFloat { centre.y + tv.height / 2 }
    }
    func stage(_ g: GeometryProxy) -> Stage {
        let ins = g.safeAreaInsets
        let screen = CGRect(x: -ins.leading, y: -ins.top, width: g.size.width + ins.leading + ins.trailing, height: g.size.height + ins.top + ins.bottom)
        var look = screen, hand = screen
        #if os(iOS)
        if #available(iOS 27.1, *), let crease = g.reservedRegions(kind: .division).first?.frame, crease.width > 0 || crease.height > 0 {
            if crease.height >= crease.width {
                // Stood like a book: the wider side, or the left if they're even, has the TV and the card.
                let left = CGRect(x: screen.minX, y: screen.minY, width: max(0, crease.minX - screen.minX), height: screen.height)
                let right = CGRect(x: crease.maxX, y: screen.minY, width: max(0, screen.maxX - crease.maxX), height: screen.height)
                look = left.width + 1 >= right.width ? left : right; hand = look
            } else {
                // Stood like a laptop: the TV on the upper half, the card at the foot of the lower one.
                look = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: max(0, crease.minY - screen.minY))
                hand = CGRect(x: screen.minX, y: crease.maxY, width: screen.width, height: max(0, screen.maxY - crease.maxY))
            }
        }
        #endif
        let wide = look.width > look.height
        // 220 pt folded, 320 open (§2.5a C2), never more than the half it sits in leaves room for.
        let tvWidth = wide ? min(320, look.width * 0.42) : min(220, look.width * 0.56)
        let tv = CGSize(width: tvWidth, height: (tvWidth * 9 / 16).rounded())
        let centre = CGPoint(x: look.midX, y: look.midY)
        // The card is held low in the hand, well clear of the TV's stand so a throw has a real way to travel, with its
        // title strip (at its foot) always at least 12 pt above the edge: a quarter past the edge hid the title (r17).
        var width: CGFloat = wide ? 136 : 124
        var height = MediaCard.height(width, source)
        // Never over the TV: on a short screen (open, flat) the card is made smaller until it clears the TV by 24 pt, rather
        // than sit on its stand (r19: the card's top was over the TV's bottom bezel).
        if hand.intersects(CGRect(x: look.minX, y: centre.y, width: look.width, height: 1)) {
            let room = hand.maxY - 12 - (centre.y + tv.height / 2 + 24)
            if height > room, room > 0 {
                let smaller = max(96, (width * room / height).rounded(.down))
                width = smaller; height = MediaCard.height(width, source)
            }
        }
        let top = max(hand.maxY - height - 12, min(centre.y + tv.height / 2 + 24, hand.maxY - height * 0.75))
        return Stage(centre: centre, tv: tv, cardX: hand.midX, cardTop: top, cardWidth: width, floor: hand.maxY - 4, wide: wide)
    }
    // Last: nothing left to decide, just the TV and the card in your hand.
    func flickStep(_ g: GeometryProxy) -> some View {
        let s = stage(g)
        let cardHeight = MediaCard.height(s.cardWidth, source)
        return ZStack {
            glow(s)
            // Above the TV while the card is in the hand: what to do, which stream it is, and anything gone wrong.
            above.frame(width: max(220, s.tv.width + 120), height: 48, alignment: .bottom).position(x: s.centre.x, y: s.tvTop - 40)
                .opacity(arrived ? 1 : 0)
            tvSlot(s.tv).position(s.centre).opacity(arrived ? 1 : 0)
            // The card's shadow on the floor, at the screen's edge where the hand is: it stays as the card goes, and fades.
            Ellipse().fill(.black)
                .frame(width: s.cardWidth * 0.86, height: 16).blur(radius: 9)
                .opacity(flown || returning || !arrived ? 0 : lifted ? 0.42 * Double(1 - min(1, progress)) : 0.3)
                .animation(.easeOut(duration: flown ? 0.5 : 0.2), value: flown)
                .position(x: s.cardX, y: min(s.cardTop + cardHeight, s.floor))
            card(s.cardWidth)
                .position(x: s.cardX, y: s.cardTop + cardHeight / 2)
        }
    }
    var screenURL: URL? { URL(string: episode?.thumb.isEmpty == false ? episode!.thumb : item.art) }
    // What the TV's screen shows from 200 ms into the flight to the Remote: the Remote's own poster sat on a blur of
    // itself, the same picture StartingPicture shows there, so it never changes look on the way (r18).
    @ViewBuilder var landedPicture: some View {
        // Always a picture already in hand: the card's own, or the one decoded when it was thrown. A fetch by address
        // here blanked the TV for a moment after the impact (r24).
        if let image = target.image ?? heldImage.map({ Image(tv: $0) }) {
            ZStack {
                Color.black.opacity(0.35)
                // Soft, edge to edge: the picture shrunk to 16 px and stretched, made off the main thread, as the Remote's
                // own picture does. A live blur here (radius 24, the whole TV) was first drawn in the impact's frame and
                // redrawn every frame of the move as the picture grew: the ~200 ms stall after the impact, and the leap.
                if let soft = softImage {
                    Color.clear.overlay { Image(tv: soft).resizable().interpolation(.high).scaledToFill() }.clipped().opacity(0.7)
                } else {
                    Color.clear.overlay { image.resizable().scaledToFill() }.clipped().blur(radius: 24, opaque: true).opacity(0.7)
                }
                image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6).padding(14)
            }
        } else {
            PosterOnBlur(url: URL(string: screenURL?.absoluteString ?? item.art))
        }
    }
    @ViewBuilder func artwork(fill: Bool) -> some View {
        if let image = target.image { image.resizable().aspectRatio(contentMode: fill ? .fill : .fit) }
        else { Art(url: screenURL) { $0.resizable().aspectRatio(contentMode: fill ? .fill : .fit) } placeholder: { fill ? (tint ?? Color(white: 0.15)) : Color.clear } }
    }
    // The TV's screen on the stage. Once the card lands it *is* the card's picture, full bleed, with the light lapping its
    // edge while the TV starts it; then, going to the Remote, one number runs from here to the Remote's own picture of
    // the TV, which shows the same poster and the same light, so the one picture carries on there (§2.5a C4).
    var screenLayer: some View { Moving(t: toRemote ? 1 : 0) { screenLayer(move: $0) } }
    func screenLayer(move t: CGFloat) -> some View {
        let slot = toRemote || t > 0 ? between(tvFrame, remoteSlot, t) : tvFrame
        // The Remote's picture's own corners by the end of the move, so landing on it changes nothing but place and size.
        let radius = 9 + (TVLook.card - 9) * t
        // Leaning in stays leant in through the landing and eases off only with the move, so the TV never drops a size in
        // one frame (r19: a 10 % snap at the impact); the squash keyframes are its only other change of size.
        let lean = charge * (1 - t)
        // The rim and glow go at the landing: from then the light round the picture is its only frame (r19: the rim and the
        // light drew two frames on one picture, and the rim lagged beside it on the move).
        // Eased off over 0.2 s from the impact (`caught`), never dropped in a frame (r21: a look-swap at the catch).
        let glow = toRemote || caught ? 0 : Double(1 - t)
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black.opacity(0.55 - 0.2 * Double(t)))
            // What the TV is showing now, so it reads as his TV rather than an empty slab. It gives way as the card comes.
            if !landed {
                TVNowPicture(store: model.mirrorStore)
                    .opacity(0.85 * Double(1 - charge))
                    .transition(.opacity)
            }
            // The TV answering the card on its way: the poster rising dimly from the bottom of its screen.
            if !landed && charge > 0.01 {
                Color.clear.overlay { artwork(fill: true) }.clipped()
                    .opacity(0.42 * Double(charge))
                    .offset(y: (1 - charge) * slot.height * 0.75)
                    .allowsHitTesting(false)
            }
            // Landed: the card's own picture, in the same place at the same size, so the hand-over from the flying card is
            // invisible. No transition: a second poster scaling in, or a fade, read as two pictures.
            // The card's full-bleed poster becomes the Remote's poster-on-blur over the same 0.2 s, as one picture changing.
            // One look from the catch to the Remote: the framed poster on its blur, never a full-bleed poster between two
            // framed ones (r27, open: framed → full → framed).
            if landed { landedPicture }
            // The TV starting it: the light round the picture's edge, carried across into the Remote.
            if landed && sending { LoadingRing(radius: radius).transition(.opacity) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .frame(width: slot.width, height: slot.height)
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(glow * (0.3 + 0.5 * charge)), lineWidth: 1.5) }
        // It brightens as the card comes, and glows hard once the card is charged.
        .shadow(color: TVLook.accent.opacity(glow * (charged ? 0.95 : 0.7 * charge)), radius: glow > 0 ? (charged ? 34 : 10 + 18 * charge) : 0)
        // One ripple from its edge at the impact.
        .overlay { TVRipple(trigger: impacts, big: false) }
        // And a burst of light off its edges, the card's colours and the accent, flung out and falling away: the catch
        // should feel like a catch (Richard, 2026-11-07: "flick screen isnt superfluous enough and whimsical enough not
        // enough flair").
        .overlay { TVSparks(trigger: impacts, tint: sparkTint) }
        // It leans in to meet the card, then gives as the card hits: squashed, over, and settled.
        .scaleEffect(1 + 0.09 * lean)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: impacts) { c, s in c.scaleEffect(s) } keyframes: { _ in
            CubicKeyframe(0.95, duration: 0.07)
            CubicKeyframe(1.03, duration: 0.12)
            SpringKeyframe(1, duration: 0.45, spring: Spring(response: 0.35, dampingRatio: 0.55))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: charge)
        .offset(x: slot.minX, y: slot.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Nothing until its place is known, so it never starts from a corner.
        .opacity(slot == .zero ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    // Above the TV: only what's worth reading. The hint for his first three flicks, then nothing; a note when a throw
    // came back. No stream size, no "Ready now", no "Finding the best stream" (the light round the card says it).
    @AppStorage("flicksDone") private var flicksDone = 0
    @ViewBuilder var above: some View {
        if !flown || note != nil {
            VStack(spacing: 3) {
                if let note {
                    Text(note).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2).id(note).transition(.opacity)
                } else if flicksDone < 3 && !pickingBest {
                    Text("Flick up to play on the TV").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).transition(.opacity)
                }
            }
            .opacity(arrived ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: arrived)
            .animation(.easeOut(duration: 0.25), value: note)
            .transition(.opacity)
        }
    }
    // The start, step by step, as the Mac tells it: "awake", "opening", "player", "playing". A Mac too old to say is
    // read off the TV's status instead, in the same words.
    static func dots(for phase: String?) -> Int {
        switch phase { case "awake", "opening": return 1; case "player": return 2; case "playing": return 3; default: return 0 }
    }
    // Before the Mac's first word: waking, said at once, if the box was last seen asleep.
    static func word(for phase: String?, asleep: Bool = true) -> String {
        switch phase { case "awake", "opening": return "Opening"; case "player": return "Starting"; case "playing": return "Playing"; default: return asleep ? "Waking" : "Opening" }
    }
    // A film's year, from whatever its card said under it.
    static func year(in s: String) -> String? {
        s.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression).map { String(s[$0]) }
    }
    // Where the TV's screen sits on this step, and where the card aims: measured here, with nothing moving it, and drawn
    // by the screen layer above.
    func tvSlot(_ size: CGSize) -> some View {
        Color.clear.frame(width: size.width, height: size.height)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { tvFrame = $0 }
            // Its stand, hung under it, so the screen itself is what's centred.
            .overlay(alignment: .bottom) { Capsule().fill(.white.opacity(0.3)).frame(width: 56, height: 3).offset(y: 9) }
            .accessibilityHidden(true)
    }
    func card(_ width: CGFloat) -> some View {
        // Rising toward the TV it swells, to 1.31 times by seven tenths of the way, lit round its edge more and more.
        // Let go, it flies into the TV and becomes its picture: from 200 ms its own picture grows to exactly the TV's
        // screen while the title strip fades, so at the impact the TV's screen is the poster, one view (§2.5a C3, C4).
        let near = min(1, progress)
        let rise = min(1, near / 0.7), eased = rise * rise * (3 - 2 * rise)
        let grow = (lifted ? 1.05 : 1) * (1 + 0.25 * eased)
        // In the air it grows to the TV's own height, so at the impact it's the size of what it lands in, never bigger
        // than the TV and sat over it (r17).
        let fit = min(tvFrame.width / max(cardFrame.width, 1), tvFrame.height / max(cardFrame.height, 1))
        let size = returning ? returnSlot.width / max(cardFrame.width, 1) : flown ? max(0.2, fit) : grow
        let x = returning ? returnSlot.midX - cardFrame.midX : flownX ? tvFrame.midX - cardFrame.midX : drag.width
        let y = returning ? returnSlot.midY - cardFrame.midY : flown ? tvFrame.midY - cardFrame.midY : cardY
        let rim = flown || returning ? 0 : Double(near)
        let glow = (tint ?? TVLook.accent).mix(with: .white, by: 0.35)
        let radius: CGFloat = width > 200 ? 8 : 6
        return MediaCard(item: shown, source: source, width: width, image: target.image)
            .overlay(alignment: .topTrailing) {
                // Which stream it is, as one small chip, and nothing else about it.
                if let q = stream?.quality ?? stream.map({ $0.name }), !q.isEmpty, !flown {
                    Text(q).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule()).padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(TVLook.accent.opacity(0.8 * rim), lineWidth: 1.5)
            }
            // The light round the card while its stream is still being found: it can't go until it has one.
            .overlay { if pickingBest && !flown { LoadingRing(radius: radius).transition(.opacity) } }
            // The card's own picture, growing into the TV's screen in the last part of the flight. It covers the card
            // whole from its first frame (no fade of either, so never two translucent pictures at once), and its size is
            // given before the card's scale, so it ends exactly on the TV's screen.
            .overlay {
                landedPicture.background(.black)
                    .opacity(morph ? 1 : 0).animation(nil, value: morph)
                    .frame(width: (morph ? tvFrame.width : cardFrame.width) / max(size, 0.01),
                           height: (morph ? tvFrame.height : cardFrame.height) / max(size, 0.01))
                    .clipShape(RoundedRectangle(cornerRadius: (morph ? 9 : radius) / max(size, 0.01), style: .continuous))
                    .allowsHitTesting(false)
            }
            // The card is opaque and exactly this shape, so its shadows come from the shape. Lifted, it rises off the
            // table: a bigger, lower shadow. In the air the shadow is gone by 200 ms.
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black)
                    .shadow(color: glow.opacity(0.65 * rim), radius: 4 + 14 * rim)
                    .shadow(color: .black.opacity(flown ? 0 : lifted ? 0.55 : 0.45), radius: lifted ? 30 : 18, y: lifted ? 22 : 10)
                    .opacity(morph ? 0 : 1)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lifted)
            .rotationEffect(.degrees(returning || flown ? 0 : lean))
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.62), value: lean)
            // Tipped into the throw and flat again as it lands in the screen.
            .keyframeAnimator(initialValue: 0.0, trigger: thrown) { c, a in
                c.rotation3DEffect(.degrees(a), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            } keyframes: { _ in
                CubicKeyframe(12, duration: 0.16)
                CubicKeyframe(0, duration: 0.16)
            }
            .scaleEffect(size)
            // At the impact the TV's own screen takes over in the same place: no fade.
            .opacity(landed ? 0 : 1)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { c, dx in c.offset(x: dx) } keyframes: { _ in
                CubicKeyframe(-16, duration: 0.06)
                CubicKeyframe(13, duration: 0.08)
                CubicKeyframe(-8, duration: 0.08)
                CubicKeyframe(4, duration: 0.07)
                CubicKeyframe(0, duration: 0.08)
            }
            .offset(x: x, y: y)
            // Where it rests, measured outside everything that moves it. Inside, its own movement would change the
            // measure that drives the movement, and the two would chase each other until the app locked up.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { cardFrame = $0 }
            // From the first touch: lifted on the same frame, then exactly under the finger.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("flick"))
                .updating($touching) { _, on, _ in on = true }
                .onChanged { v in
                    guard !flown, !returning else { return }
                    drag = v.translation
                    lean = max(-10, min(10, Double(v.velocity.width) / 150 + Double(v.translation.width) / 45))
                    let d = progress >= 0.7 ? 2 : progress >= 0.35 ? 1 : 0
                    if d != detent { detent = d }
                }
                .onEnded { v in
                    guard !returning, !flown else { return }
                    let rise = -v.translation.height, vy = v.velocity.height
                    // A touch that hardly moved is a tap: the hop that shows which way it goes.
                    if abs(v.translation.width) < 6 && abs(v.translation.height) < 6 && abs(vy) < 200 { hopCard(); settle(); return }
                    if (vy <= -550 && rise >= 30) || progress >= 0.5 { send(flicked: v.velocity) }
                    else if v.translation.height >= 110 || vy >= 900 { putBack() }
                    else { settle() }
                })
            .onChange(of: touching) { _, on in if !on && !flown && !returning { settle() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Sends this to the TV")
            .accessibilityAction { send() }
    }
    // A tap shows which way it wants to go.
    func hopCard() {
        model.tick()
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { hop = true }
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.42)) { hop = false }
        }
    }
    // Let go short of a throw: back to rest, with one soft touch.
    func settle() {
        detent = 0
        if backHidden { var quiet = Transaction(); quiet.disablesAnimations = true; withTransaction(quiet) { backHidden = false } }
        guard drag != .zero || lean != 0 else { return }
        FlickHaptic.settle()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.6)) { drag = .zero; lean = 0 }
    }
    // For the build's recording: the moves a finger makes, pick up, a slow pull with a sway, and a throw.
    // Far enough up that the card charges and the TV lights for it. With a stream to be found first, it waits for that,
    // as he would.
    func demo() async {
        // §2.5a E's poses. flick-stage is the stage at rest; flick-putback pulls the card down and lets go; flick-cancel
        // throws and calls it off at 200 ms; the rest throw as he does and are judged on what the mock's scene answers
        // (starting, slow, failed, offline, already on).
        let pose = Self.pose ?? ""
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if pose == "flick-stage" { return }
        if pose != "flickdemo" {
            for _ in 0..<100 where stream == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        demoHeld = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        if pose == "flick-putback" {
            for i in 1...30 { drag = CGSize(width: 0, height: 5 * CGFloat(i)); try? await Task.sleep(nanoseconds: 16_000_000) }
            demoHeld = false
            putBack()
            return
        }
        for i in 1...50 {
            let t = CGFloat(i) / 50
            drag = CGSize(width: 36 * sin(t * .pi), height: -0.8 * reach * t * t)
            lean = Double(cos(t * .pi)) * 6
            detent = t * 0.8 >= 0.7 ? 2 : t * 0.8 >= 0.35 ? 1 : 0
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        demoHeld = false
        send(flicked: CGSize(width: -260, height: -1900))
        if pose == "flick-cancel" { try? await Task.sleep(nanoseconds: 200_000_000); callOff() }
    }
    // The X while it's on its way: whatever started on the TV stops, and this closes.
    func callOff() {
        cancelled = true
        backToThrownFrom()
        flight?.cancel()
        model.clearStart()
        model.tick()
        // Stop only what this throw put on the TV (r24: a cancel before the request had left sent stop-playing and would
        // have closed a film he already had on). Never sent: nothing to stop. Sent but not on yet: stop it only if it turns
        // up there in the next 20 s.
        let pkg = source == .mint || target.send != nil ? "com.codex.musicwebtv" : "com.stremio.one"
        if written {
            let mine = target.send != nil || source == .mint ? true : alreadyOn
            if mine { model.post("stop-playing", ["pkg": pkg]) }
            else if let ref = item.stremioRef {
                let m = model, title = item.title, ep = ref.type == "series" ? (episode?.id ?? ref.video) : nil
                Task { @MainActor in
                    for _ in 0..<20 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if m.isOn(imdb: ref.imdb, title: title, episode: ep) { m.post("stop-playing", ["pkg": pkg]); return }
                    }
                }
            }
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { sending = false }
        leave()
    }
    // The Remote's tab up under the black stage, the Remote's picture kept hidden until the TV's screen lands on it.
    func prepareRemote() {
        guard step == .flick, arrived, !leaving, !returning, !cancelled, !flown, model.tab != 0 || tabBefore == nil else { return }
        if model.tab == 0 && tabBefore == nil && model.flickHandoff { return }
        tabBefore = tabBefore ?? model.tab
        var quiet = Transaction(); quiet.disablesAnimations = true
        // The film's colour goes behind the Remote now too, under the black stage, with the Remote's own first layout:
        // done at 600 ms with the move, its redraw of the whole background hitched it (r26); left until after, the app's
        // colour (Stremio's purple) showed beside the Remote as it came (r19).
        withTransaction(quiet) { model.flickHandoff = true; model.tab = 0; model.keepMood(until: item.art); model.mood = tint }
    }
    // A throw that didn't go on to the Remote puts the page he threw from back under the stage.
    func backToThrownFrom() {
        guard let b = tabBefore else { return }
        restoredTab = b
        var quiet = Transaction(); quiet.disablesAnimations = true
        withTransaction(quiet) { model.flickHandoff = false; model.tab = b; model.moodArt = nil; if let prior = priorMood { model.mood = prior } }
        tabBefore = nil
    }
    // Everything fades back to the page underneath. From here on nothing started by this screen changes the app behind.
    func leave(restoreMood: Bool = true) {
        if !toRemote { backToThrownFrom() }
        leaving = true
        if restoreMood, let prior = priorMood { model.mood = prior }
        withAnimation(.easeOut(duration: 0.2)) { arrived = false; barShown = false }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            model.closeFlick()
        }
    }
    // Pulled down and let go: the card goes back down onto the tile it was picked from, as the rest fades to the page
    // that tile is on. Without a tile on screen to go to, it just fades with the rest.
    func putBack() {
        // The tile, in this screen's own terms, and only if some of it is still on the display.
        guard let o = target.origin, o.width > 10, cardFrame.width > 0,
              o.maxY > 40, o.minY < cardFrame.maxY + flickOrigin.y + 200 else { leave(); return }
        let slot = o.offsetBy(dx: -flickOrigin.x, dy: -flickOrigin.y)
        backToThrownFrom()
        leaving = true
        detent = 0
        if let prior = priorMood { model.mood = prior }
        FlickHaptic.putBack()
        returnSlot = slot
        withAnimation(.spring(response: 0.46, dampingFraction: 0.88)) { returning = true; drag = .zero; lean = 0 }
        withAnimation(.easeOut(duration: 0.32)) { arrived = false; barShown = false }
        Task {
            try? await Task.sleep(nanoseconds: 480_000_000)
            model.closeFlick()
        }
    }
    // Into the Remote, in one move: its tab comes up under this screen, the TV's screen moves onto the Remote's own
    // picture of the TV, which shows the same poster, and only then does everything else fade. The film's colour stays,
    // as it's the same film.
    func goRemote() {
        #if os(iOS)
        // The Remote must come up with the start already its own (r21: some launches showed no transport, light or title).
        if Self.pose?.hasPrefix("flick") == true, model.starting == nil, !alreadyOn { HitchLog.shared.assertFailed("model.starting was nil at the hand-over") }
        #endif
        model.tick()
        leaving = true
        // The stand-in was set at the impact; the live mirror waits until the start has cleared (startPlayed), so no stale
        // launcher capture shows behind a starting film (r24).
        if model.starting == nil, !model.mirrorLive { model.setMirror(true) }
        // Held where it is first: the tab changing under it lays the space around it out again.
        if flickFrame.width > 0 { held = flickFrame }
        // Under the screen, so the Remote is laid out, and its picture's place known, by the time the screen moves.
        // No animation starts in this tick: laying the Remote out hitches the main thread, and swallowed the fades.
        // Normally already up since the release; a hand-over by another path brings it up here.
        if model.tab != 0 || !model.flickHandoff { model.remoteArrival = Date(); model.flickHandoff = true; model.tab = 0 }
        tabBefore = nil
        Task {
            // The same place on two reads in a row, so the move aims at where the picture settles, not at its first layout.
            // Known already from the last visit to the Remote, the move starts at once; the loop below follows any late change.
            var slot: CGRect? = model.mirrorSlot.flatMap { $0.width > 20 ? $0 : nil }, seen: CGRect?
            for _ in 0..<(slot == nil ? 40 : 0) {
                if let s = model.mirrorSlot, s.width > 20 {
                    if let p = seen, abs(p.minX - s.minX) + abs(p.minY - s.minY) + abs(p.width - s.width) < 0.5 { slot = s; break }
                    seen = s
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            if slot == nil { slot = seen }
            guard let s = slot else {
                model.flickHandoff = false; model.keepMood(until: item.art); model.mood = tint; handOverArt()
                leave(restoreMood: false); Task { await model.load() }; return
            }
            remoteSlot = s.offsetBy(dx: -flickOrigin.x, dy: -flickOrigin.y)
            // A frame, so the Remote's first layout is done before anything moves.
            try? await Task.sleep(nanoseconds: 17_000_000)
            // The fade, the move and the Remote coming up through the backdrop start together, so there's never a lone
            // screen on an empty backdrop. The backdrop is gone quickly, before the keys arrive, so they never read grey
            // through it.
            // One update, so the controls can't be gone a frame before the screen starts to move. The bar's ✓ stays to the
            // end and fades with the rest of this screen: taken off now, it left an empty glass circle behind.
            model.remoteMoveAt = Date()
            // Settled by 1.2 s from the release (§2.5a): the move starts by about 0.5 s and runs about 0.6 s.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                toRemote = true
                // The stage gone in 0.12 s, before the keys come, so the two never overlap.
                withAnimation(.easeOut(duration: 0.12)) { arrived = false }
            }
            // The Remote's picture can still settle as its page lays out, so the move keeps aiming at where it is now,
            // place and size, until the spring has run its course and the picture has stopped moving. Once the screen
            // is on it, a late change eases across rather than stepping.
            // Every change of aim is animated, never a jump mid-spring (r21: an unanimated retarget stepped the picture 25 pt),
            // and the landing is over by 1.1 s from the release whatever happens.
            let start = Date()
            let deadline = max(releasedAt == .distantPast ? start.addingTimeInterval(0.5) : releasedAt.addingTimeInterval(1.1), start.addingTimeInterval(0.4))
            var still = 0
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 16_000_000)
                if let s = model.mirrorSlot, s.width > 20 {
                    let next = s.offsetBy(dx: -flickOrigin.x, dy: -flickOrigin.y)
                    let moved = abs(next.minX - remoteSlot.minX) + abs(next.minY - remoteSlot.minY)
                        + abs(next.width - remoteSlot.width) + abs(next.height - remoteSlot.height) > 0.5
                    if moved {
                        still = 0
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { remoteSlot = next }
                    } else { still += 1 }
                }
                if Date().timeIntervalSince(start) > 0.4 && still >= 4 { break }
            }
            // Landed on it: the screen gives way to the same picture underneath, and whatever of this screen is still
            // over the keys fades with it before it's taken away.
            // The picture underneath back first, unanimated, so the screen fades onto it, not onto the backdrop.
            model.flickHandoff = false
            FlickClock.current.remoteLanded()
            withAnimation(.easeOut(duration: 0.2)) { onRemote = true; screenOut = true; fadingOut = true }
            try? await Task.sleep(nanoseconds: 230_000_000)
            // Only now, with nothing moving: the picture he last threw, which redraws the app's pages (r26).
            handOverArt()
            model.closeFlick()
            // Only once the move is over, so its fetch and redraw can't hitch it.
            await model.load()
        }
    }

    func loadMeta() async {
        guard source == .stremio, target.send == nil, let ref = item.stremioRef else { return }
        // A show opened from anywhere but Continue watching still starts where he is in it, if Stremio's row knows.
        let home = BrowseStore.shared(.stremio)
        let homeLoad = Task { if ref.type == "series" && ref.video == nil && home.rows.isEmpty { await home.load() } }
        guard let d = await TVBridge.data(TVBridge.url("/api/tv/stremio-meta?type=\(ref.type)&id=\(ref.imdb)"), timeout: 15),
              let m = try? JSONDecoder().decode(StremioMeta.self, from: d), !(ref.type == "series" && m.episodes.isEmpty) else { metaFailed = true; return }
        if ref.type == "series" { NextUp.remember(m, for: ref.imdb) }
        defer {
            // The episode the big key would play, its streams fetched now, so tapping it never waits on them (§2.5a C7).
            if ref.type == "series", let e = resumeTarget?.episode, !isOn(e) { Task { _ = await StreamCache.shared.streams(type: "series", imdb: ref.imdb, video: e.id) } }
        }
        // The episode he's on, best source first: what the TV is playing now, the card's own episode, then "S2 E3" on the card.
        let on = upNext == nil ? onEpisode(in: m, ref: ref) : nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            meta = m
            // A card that's part way through a series starts on that episode, unless one's been picked meanwhile.
            if episode == nil { episode = m.episodes.first { $0.id == ref.video } }
            if let on { upNext = on.id; upNextProgress = on.progress }
            season = resumeTarget?.episode.season ?? episode?.season ?? m.episodes.first?.season ?? 0
        }
        if upNext != nil || ref.type != "series" { resumeKnown = true; return }
        // Otherwise Continue watching may know, once it's in.
        await homeLoad.value
        let rowItem = home.rows.first { $0.title == "Continue watching" }?.items.first { $0.stremioRef?.imdb == ref.imdb }
        let e = rowItem.flatMap { r in m.episodes.first { $0.id == r.stremioRef?.video } ?? Self.episode(named: r.subtitle, in: m.episodes) }
        if let e, upNext == nil {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { upNextProgress = rowItem?.progress; upNext = e.id; season = resumeTarget?.episode.season ?? e.season }
        }
        resumeKnown = true
    }
    // The episode he's on for this show, without asking anyone: the TV's own session, then the card.
    func onEpisode(in m: StremioMeta, ref: (type: String, imdb: String, video: String?)) -> (id: String, progress: Double?)? {
        if let s = NextUp.shared.series, s.imdb == ref.imdb, m.episodes.contains(where: { $0.id == s.current }) {
            let sess = model.status?.session
            let p = sess.flatMap { x in x.duration.flatMap { d in d > 0 ? x.position.map { $0 / d } : nil } }
            return (s.current, p)
        }
        // The TV's session names the show and episode itself, before the series lookup has caught up.
        if let sess = model.status?.session, sess.pkg == "com.stremio.one", model.videoIsCurrent, sess.isShow(item.title),
           let se = sess.seasonEpisode, let e = m.episodes.first(where: { $0.season == se.season && $0.episode == se.episode }) {
            let p = sess.duration.flatMap { d in d > 0 ? sess.position.map { $0 / d } : nil }
            return (e.id, p)
        }
        if let v = ref.video, m.episodes.contains(where: { $0.id == v }) { return (v, item.progress) }
        if let e = Self.episode(named: item.subtitle, in: m.episodes) { return (e.id, item.progress) }
        return nil
    }
    // "S2 E3", "S02E03" or "S2 · E3" in a card's line, as the episode it names.
    static func episode(named text: String, in all: [StremioEpisode]) -> StremioEpisode? {
        guard let r = try? NSRegularExpression(pattern: #"S(\d+)\s*[·.]?\s*E(\d+)"#, options: .caseInsensitive),
              let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let sr = Range(m.range(at: 1), in: text), let er = Range(m.range(at: 2), in: text),
              let se = Int(text[sr]), let ep = Int(text[er]) else { return nil }
        return all.first { $0.season == se && $0.episode == ep }
    }
    // The best stream, found for him: straight to the card with it in hand, and for the next episode, thrown too.
    func pickBest() async {
        guard source == .stremio, target.send == nil, item.stremioRef != nil else { return }
        pickingBest = true
        await findStreams()
        pickingBest = false
        guard let best = streams.first(where: { !failedTokens.contains($0.token) }) else {
            // Nothing to play it with: the list says so, with a way to try again.
            autoplay = false
            if !flown { go(.streams) }
            return
        }
        if stream == nil { stream = best; picked = true }
        guard autoplay, !flown else { return }
        autoplay = false
        try? await Task.sleep(nanoseconds: 450_000_000)
        if step == .flick, !flown, !cancelled { send(flicked: CGSize(width: 0, height: -1500)) }
    }
    // Where the TV has got to, read off its status, for a Mac too old to say: in the words the Mac would use.
    static func phase(of s: TVStatus, video: Bool) -> String? {
        guard s.online else { return nil }
        if s.screen == "asleep" || s.screen == "screensaver" { return nil }
        guard video else { return "awake" }
        if let p = s.session, p.pkg == "com.stremio.one" { return p.playing ? "playing" : "player" }
        if s.app == "com.stremio.one" { return "opening" }
        return "awake"
    }
    var order: (String, [String: Any]) {
        if let send = target.send { return send }
        if let stream, let ref = item.stremioRef {
            // What it is, so the Mac can fetch its running time and poster while it starts, and the next two best streams,
            // so one that won't start is replaced on the Mac without coming back to the phone (§2.5a C8).
            var body: [String: Any] = ["token": stream.token, "imdb": ref.imdb]
            if ref.type == "series", let video = episode?.id ?? ref.video { body["video"] = video }
            if hasResume && startOver { body["restart"] = true }
            // Where he was in it, as a share of its length, so the Mac can make sure it opens there and not at 0:00 (r24:
            // "85 min left" opened at 0:08). Not for a start over.
            else {
                // From the card, else from Stremio's own Continue watching, so a pick from search, Recently flicked or a
                // rec carries on where he was too.
                if let p = savedProgress, p > 0.01, p < 0.97 { body["resume"] = (p * 1000).rounded() / 1000 }
            }
            let spare = streams.filter { $0.token != stream.token && !failedTokens.contains($0.token) }.prefix(2).map(\.token)
            if !spare.isEmpty { body["fallbacks"] = Array(spare) }
            return ("play-stream", body)
        }
        if let stream { return ("play-stream", ["token": stream.token]) }
        if source == .mint { return ("mint-open", ["link": item.id, "title": item.title, "subtitle": item.subtitle, "art": item.art, "kind": item.kind, "play": true]) }
        if let ref = item.stremioRef {
            if let e = episode { return ("stremio-open", ["id": "stremio:///detail/series/\(ref.imdb)/" + e.id.replacingOccurrences(of: ":", with: "%3A")]) }
            return ("stremio-open", item.id.hasPrefix("stremio:") ? ["id": item.id] : ["type": ref.type, "id": ref.imdb])
        }
        return ("film", ["slug": item.slug ?? ""])
    }
    // What's being started, for "Choose another" from the Remote: this title, at this episode.
    var again: FlickTarget {
        var item = self.item
        if let ref = item.stremioRef, ref.type == "series", let v = episode?.id ?? ref.video {
            item = MediaItem(title: item.title, subtitle: item.subtitle, art: item.art, id: "stremio:///detail/series/\(ref.imdb)/" + (v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v), kind: item.kind)
        }
        return FlickTarget(item: item, source: source)
    }
    // The throw (§2.5a C4). t = 0 at release: the request leaves now; the card flies for 320 ms, tipping in and flat
    // again as it lands, and from 200 ms it becomes the TV's picture; the impact is the end of that flight, not a clock;
    // the caught tick 120 ms later; at 600 ms the TV's screen moves onto the Remote's picture, where the start is shown
    // until it plays. A Mac slow to answer never brings the card back once the request has gone; only one that couldn't be
    // reached at all does.
    func send(flicked velocity: CGSize = .zero) {
        guard !flown else { return }
        FlickClock.begin()
        releasedAt = Date()
        note = nil; detent = 0
        let from = cardY, to = tvFrame.midY - cardFrame.midY
        let vy = max(0, min(6, velocity.height / min(to - from, -1)))
        let across = tvFrame.midX - cardFrame.midX - drag.width
        let vx = abs(across) > 8 ? max(-5, min(5, velocity.width / across)) : 0
        thrown += 1
        answered = false; written = false; caught = false
        if target.image == nil, let u = screenURL ?? URL(string: item.art) {
            heldImage = ImageStore.shared.cached(u)
            softImage = ImageStore.shared.small(u, 16)
            if softImage == nil, let h = heldImage { Task { softImage = await ImageStore.shrunk(h, 16) } }
        }
        withAnimation(.interpolatingSpring(duration: 0.32, bounce: 0, initialVelocity: vy), completionCriteria: .logicallyComplete) {
            flown = true; lean = 0
        } completion: { arrivedAtTV() }
        withAnimation(.interpolatingSpring(duration: 0.40, bounce: 0, initialVelocity: vx)) { flownX = true }
        // The Remote comes up under the black stage now, so the flight pays for laying it out (r20: switching at 600 ms
        // froze the main thread for 0.3 s folded and 0.9 s open, and the move was late or a cut). Its picture stays hidden
        // until the screen lands on it.
        if model.tab != 0 || tabBefore == nil {
            tabBefore = tabBefore ?? model.tab
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { model.remoteArrival = Date(); model.flickHandoff = true; model.tab = 0 }
        }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard flown, !cancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { morph = true }
        }
        phase = nil; streamed = false
        // The start becomes the model's a frame after the impact (arrivedAtTV), not on the release frame: the Remote laid out
        // under the stage redrew for it there and the card stalled 80–275 ms as it left his finger (r24).
        flight = Task { await start() }
    }
    // The card reaches the TV: the hit, felt and seen, then the second tick; and at 600 ms on into the Remote.
    func arrivedAtTV() {
        guard flown, !cancelled, !returning else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { landed = true }
        FlickClock.current.mark("impact")
        Task {
            // The hit's look and the light round the picture a frame after the swap, so the impact frame carries only the
            // swap itself (r17: a ~140 ms stall at the impact).
            await Task.yield()
            // The start is the model's from here, well before the hand-over, so the Remote comes up with it (r21), and the
            // stand-in picture is set now rather than at 600 ms with everything else.
            if !alreadyOn {
                if model.starting == nil { beginStarting() } else if let t = stream?.token { model.starting?.token = t }
                if let art = screenURL?.absoluteString { model.standIn(art) }
            }
            impacts += 1
            withAnimation(.easeOut(duration: 0.2)) { sending = true; caught = true }
            try? await Task.sleep(nanoseconds: 110_000_000)
            guard !cancelled else { return }
            FlickHaptic.caught()
            // Held a moment, the light starting round the picture, then on into the Remote. A request already on its way is
            // never called off for being slow (r17: "It said the TV isn't answering, then the film started anyway"): no
            // word by 1.5 s goes on to the Remote all the same, as starting. Only a request that couldn't be sent at all
            // brings the card back (failedOnStage, from start()).
            // On the Remote by 1.2 s on every throw: the move starts at 600 ms from the release whatever the request is doing
            // (r19: it waited on the request and started at about 1 s). The start is the model's, so it carries on there.
            let hold = 0.6 - Date().timeIntervalSince(releasedAt)
            if hold > 0 { try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) }
            guard !cancelled, step == .flick else { return }
            handOver()
        }
    }
    func beginStarting() {
        let art = screenURL?.absoluteString ?? item.art
        model.beginStart(.init(title: item.title, art: art, line: episode.map { "S\($0.season) E\($0.episode) · \($0.name)" }, token: stream?.token), target: again)
    }
    // The request, from release to the answer. It runs on after the flick screen has closed: the start is the model's.
    func start() async {
        // Thrown before the best stream was found: it goes as soon as it is.
        while pickingBest && !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
        if Task.isCancelled { return }
        // What's already on the TV is never sent again; if it's paused there, it's asked to play, nothing else
        // (Richard, 2026-11-05: "the episode restarted i think because of the app").
        if alreadyOn {
            if model.status?.session?.playing == false { model.key("resume") }
            FlickClock.current.mark("already-on"); FlickClock.current.finished()
            answered = true
            sending = false
            return
        }
        let order = order
        let early = order.0 == "play-stream"
        askedRestart = order.1["restart"] as? Bool == true
        // Normally begun at the release already (so the Remote's picture is the poster from the hand-over on); this only
        // fills in the stream it went with.
        if model.starting != nil { model.starting?.token = stream?.token }
        FlickClock.current.mark("request")
        written = true
        var resent = false
        while true {
            do {
                let answer: Data
                if early {
                    answer = try await TVBridge.playStream(order.1, opened: { _ in
                        answered = true; FlickClock.current.mark("first-byte")
                    }, phase: { p in took(p) })
                } else {
                    answer = try await TVBridge.post(order.0, order.1, timeout: 60)
                    answered = true
                }
                // The Mac found it already on, or joined a start of the same thing already under way: a success like any
                // other, with nothing more to do (real-TV test, 2026-11-05).
                if let j = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] {
                    if j["alreadyOn"] as? Bool == true { FlickClock.current.mark("already-on") }
                    if j["joined"] as? Bool == true { FlickClock.current.mark("joined") }
                }
                target.sent?()
                remember()
                flicksDone += 1
                // An answer with no "playing" line (an old Mac, or a send that isn't a stream) is the yes.
                model.startPlayed()
                FlickClock.current.mark("answer"); FlickClock.current.finished()
                return
            } catch {
                if Task.isCancelled || cancelled { return }
                // Gone: the list is fetched afresh and the same file (or the next best) sent once more, silently.
                if error is TVBridge.Gone, !resent, early, let ref = item.stremioRef {
                    resent = true
                    let was = stream
                    StreamCache.shared.forget(type: ref.type, imdb: ref.imdb, video: episode?.id ?? ref.video ?? ref.imdb)
                    await findStreams(again: true)
                    stream = streams.first { $0.description == was?.description && !failedTokens.contains($0.token) } ?? streams.first { !failedTokens.contains($0.token) }
                    if stream != nil { continue }
                }
                FlickClock.current.mark("failed"); FlickClock.current.finished(onStage: !handedOver)
                if let s = stream { failedTokens.insert(s.token) }
                // Still on the stage (no answer at all): the card comes back. On the Remote: the poster dims, with one
                // way on.
                if !handedOver { answered = true; await failedOnStage(error); return }
                model.startFailed(tokens: Array(failedTokens))
                return
            }
        }
    }
    // A step of the start, as the Mac reports it: the model's, so the Remote follows it after this screen has closed.
    func took(_ p: String) {
        FlickClock.current.mark("phase-" + p)
        phase = p
        model.startPhase(p)
        if p == "playing" {
            FlickClock.current.mark("playing")
            playedAt = Date()
            model.startPlayed()
        }
    }
    // The very thing in the hand is what the TV is playing now: the same show and episode, or the same film, and not
    // asked to start over.
    var alreadyOn: Bool {
        guard source == .stremio, target.send == nil, let ref = item.stremioRef, model.videoIsCurrent,
              let s = model.status?.session, s.pkg == "com.stremio.one", !(nearEnd && startOver && stream != nil) else { return false }
        if ref.type == "series" {
            guard let v = episode?.id ?? ref.video else { return false }
            return model.isOn(imdb: ref.imdb, title: item.title, episode: v)
        }
        return model.isOn(imdb: ref.imdb, title: item.title, episode: nil) && isThisFilm(s)
    }
    // Whether a Stremio player is the film just sent, by its title.
    func isThisFilm(_ p: TVStatus.Session) -> Bool {
        guard let now = p.description.first, !now.isEmpty else { return false }
        return TVStatus.Session.sameName(now, item.title)
    }
    // Caught, and straight on into the Remote: the TV's screen moves onto the Remote's own picture, where the start is
    // shown until it plays. A control screen of its own was a second, worse remote (Richard, 2026-11-05: "awful").
    func handOver() {
        guard step == .flick, !handedOver else { return }
        handedOver = true
        FlickClock.current.mark("handover")
        goRemote()
    }
    // The picture he last threw, for the app's pages: set once the move is over (goRemote), never during it.
    func handOverArt() {
        if !item.art.isEmpty { model.lastArt = item.art; model.lastArtTitle = item.title; model.lastArtPkg = source == .mint ? "com.codex.musicwebtv" : "com.stremio.one" }
    }
    func remember() {
        let video = source == .stremio && target.send == nil
        // Kept on the phone for the Watch tab's Recently flicked, and for knowing the next episode.
        if video, let ref = item.stremioRef {
            RecentFlicks.shared.add(RecentFlick(title: item.title, art: item.art, imdb: ref.imdb, type: ref.type, video: ref.type == "series" ? episode?.id ?? ref.video : nil,
                                                episode: episode.map { "S\($0.season) E\($0.episode)" }, at: Date()))
            NextUp.shared.forget()
        }
    }
    // The TV said no before the hand-over: out of it and back into the hand, with a shake, and the next best stream
    // ready in the card. Never bounced into a list.
    func failedOnStage(_ error: Error) async {
        FlickHaptic.error()
        backToThrownFrom()
        backHidden = false
        model.clearStart()
        drag = .zero
        let gone = error is TVBridge.Gone, stuck = error is TVBridge.DidNotStart
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { landed = false }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.66)) {
            sending = false; phase = nil; flown = false; flownX = false; morph = false; playingSeen = false
            note = gone ? "That stream has gone" : stuck ? "That stream didn’t start" : "The TV didn’t get that"
        }
        try? await Task.sleep(nanoseconds: 380_000_000)
        shakes += 1
        if stuck || gone { stream = streams.first { !failedTokens.contains($0.token) } }
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        withAnimation(.easeOut(duration: 0.25)) { note = nil }
    }
}

// The small TV's own picture before anything is thrown at it: a film's poster while one plays (a capture of it would be
// black), else the latest still of its screen, else the cover of what's on. Nothing while it's asleep.
private struct TVNowPicture: View {
    @Environment(TVModel.self) var model
    @ObservedObject var store: MirrorStore
    var asleep: Bool { model.status?.screen == "asleep" }
    var poster: URL? {
        if model.filmOnScreen, let s = model.status?.session { return model.picture(for: s).flatMap(URL.init(string:)) }
        return nil
    }
    var body: some View {
        Color.clear.overlay {
            if asleep { EmptyView() }
            else if let poster { Art(url: poster) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
            // Never a capture older than five seconds: the TV as it was a while ago isn't his TV now (§2.5a C2).
            else if let m = store.image, Date().timeIntervalSince(store.at) < 5 { Image(tv: m).resizable().scaledToFill() }
            else { Art(url: model.nowArt.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
        }
        .clipped()
        .animation(.easeOut(duration: 0.25), value: store.at)
        // A still more than a few seconds old is asked for again once, so it's the screen as it is now.
        .task {
            guard !asleep, poster == nil, Date().timeIntervalSince(store.at) > 5 else { return }
            await model.loadMirror()
        }
    }
}

// The TV's screen while it gets going: the light running round its whole edge, as on any card that's loading.

// How far the TV has got with a start: woken, opened, playing. The dot being worked on breathes; one word says where.
struct TVPhaseDots: View {
    let filled: Int
    let word: String
    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(i < filled ? TVLook.accent : .white.opacity(0.24)).frame(width: 7, height: 7)
                        .shadow(color: TVLook.accent.opacity(i < filled ? 0.7 : 0), radius: 4)
                        .scaleEffect(i < filled ? 1 : 0.85)
                        .phaseAnimator(i == filled ? [0.45, 1.0] : [1.0]) { c, o in c.opacity(o) } animation: { _ in .easeInOut(duration: 0.7) }
                }
            }
            Text(word).font(.caption.weight(.semibold)).foregroundStyle(.secondary).contentTransition(.opacity)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: filled)
        .animation(.easeOut(duration: 0.2), value: word)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word)
    }
}

// The TV saying yes: a tick on its screen.
// A flash across the TV's screen as it takes something on.

// Hands its content how far along a move it is, every frame, so what's drawn can be worked out from that one number.
private struct Moving<C: View>: View, Animatable {
    var t: CGFloat
    @ViewBuilder let content: (CGFloat) -> C
    var animatableData: CGFloat { get { t } set { t = newValue } }
    var body: some View { content(t) }
}
private func between(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
           width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

// Rings going out from the TV each time something lands on it.
// Sparks thrown off the TV's edge at the catch: a ring of small lights flying out on their own curves, spinning a little,
// shrinking and fading as they fall. Laid out once from a fixed pattern, so every catch looks alike and nothing is
// measured while it moves.
private struct TVSparks: View {
    let trigger: Int
    var tint: Color
    static let count = 18
    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<Self.count, id: \.self) { i in
                    OneSpark(i: i, count: Self.count, box: g.size, trigger: trigger, tint: tint)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
private struct OneSpark: View {
    let i: Int, count: Int
    let box: CGSize
    let trigger: Int
    let tint: Color
    struct Spark { var t: CGFloat = 0 }
    var angle: Double { Double(i) / Double(count) * 2 * .pi + (i.isMultiple(of: 2) ? 0.12 : -0.08) }
    var reach: CGFloat { CGFloat(0.62 + 0.22 * Double((i * 7) % 5) / 4) }
    var start: CGPoint { CGPoint(x: box.width / 2 + CGFloat(cos(angle)) * box.width / 2, y: box.height / 2 + CGFloat(sin(angle)) * box.height / 2) }
    var end: CGPoint {
        let dx = CGFloat(cos(angle)) * box.width / 2 * (1 + reach * 0.55)
        let dy = CGFloat(sin(angle)) * box.height / 2 * (1 + reach)
        return CGPoint(x: box.width / 2 + dx, y: box.height / 2 + dy + 26)
    }
    var colour: Color { i % 2 == 0 ? TVLook.accent : tint }
    @ViewBuilder var mark: some View {
        if i % 3 == 0 { Image(systemName: "sparkle").font(.system(size: 12, weight: .bold)) }
        else { Circle().frame(width: 4.5, height: 4.5) }
    }
    func placed(_ c: some View, _ t: CGFloat) -> some View {
        let p0 = start, p1 = end
        let x: CGFloat = p0.x + (p1.x - p0.x) * t
        let y: CGFloat = p0.y + (p1.y - p0.y) * t + 18 * t * t
        let live = t > 0 && t < 1
        let scale: CGFloat = live ? 1.2 - 0.9 * t : 0.01
        let fade: Double = live ? Double(1 - t * t) : 0
        return c.position(x: x, y: y).scaleEffect(scale).rotationEffect(.degrees(Double(t) * 160)).opacity(fade)
    }
    var body: some View {
        let delay: Double = 0.02 + Double(i % 4) * 0.025
        mark
            .foregroundStyle(colour)
            .shadow(color: colour.opacity(0.9), radius: 4)
            .keyframeAnimator(initialValue: Spark(), trigger: trigger) { c, s in placed(c, s.t) } keyframes: { _ in
                KeyframeTrack(\.t) {
                    LinearKeyframe(0, duration: 0.001)
                    LinearKeyframe(0.001, duration: delay)
                    CubicKeyframe(0.75, duration: 0.32)
                    CubicKeyframe(1, duration: 0.38)
                }
            }
    }
}
private struct TVRipple: View {
    let trigger: Int
    // On the grown screen the same rings would reach far past it, so they stay close.
    var big = false
    struct Wave { var scale: CGFloat = 1; var opacity: Double = 0 }
    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TVLook.accent, lineWidth: 2 - CGFloat(i) * 0.6)
                    .keyframeAnimator(initialValue: Wave(), trigger: trigger) { c, w in c.scaleEffect(w.scale).opacity(w.opacity) } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1, duration: 0.01 + Double(i) * 0.13)
                            // Never past a quarter again the TV's size, so they stay clear of the line under it.
                            CubicKeyframe(big ? 1.08 + CGFloat(i) * 0.04 : 1.16 + CGFloat(i) * 0.09, duration: 0.75)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: 0.01 + Double(i) * 0.13)
                            LinearKeyframe(0.9 - Double(i) * 0.3, duration: 0.02)
                            CubicKeyframe(0, duration: 0.74)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}

// A row of choices whose highlight slides to the one picked.
struct Chips<T: Hashable>: View {
    @Environment(TVModel.self) var model
    let options: [(T, String)]
    @Binding var selected: T
    // Space before the first chip and after the last, inside the row, so a row that runs to the edge scrolls to it.
    var inset: CGFloat = 0
    @Namespace private var pill
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { value, label in
                    Button { model.tick(); withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { selected = value } } label: {
                        Text(label).font(.footnote.weight(.semibold)).padding(.horizontal, 13).frame(height: 32)
                            .foregroundStyle(selected == value ? .black : .white)
                            .background {
                                if selected == value { Capsule().fill(TVLook.accent).matchedGeometryEffect(id: "pill", in: pill) }
                                else { Capsule().fill(.white.opacity(0.1)) }
                            }
                    }
                    .buttonStyle(PressCard())
                    .accessibilityAddTraits(selected == value ? .isSelected : [])
                }
            }
            .padding(.horizontal, inset)
        }
    }
}

// The shape of a row still on its way, breathing until it arrives.
struct PlaceholderRow: View {
    var delay = 0.0
    var thumb = false
    var body: some View {
        HStack(spacing: 11) {
            if thumb { RoundedRectangle(cornerRadius: 6, style: .continuous).frame(width: 82, height: 46) }
            VStack(alignment: .leading, spacing: 7) {
                Capsule().frame(width: 120, height: 11)
                Capsule().frame(width: 190, height: 8)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.12))
        .padding(.horizontal, 12).frame(height: thumb ? 66 : 64)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .phaseAnimator([0.45, 1.0]) { c, o in c.opacity(o) } animation: { _ in .easeInOut(duration: 0.9).delay(delay) }
        .accessibilityHidden(true)
    }
}

// Cards give under the finger, as anything you can pick up should. Gently, and easing in, because every scroll starts
// with a touch on some card, and a sharp squeeze there makes the whole row twitch.
struct PressCard: ButtonStyle {
    // The moment a finger lands, before it's a tap: time enough to start asking for what the tap will need.
    var onPress: (() -> Void)? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(configuration.isPressed ? .easeOut(duration: 0.18).delay(0.06) : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in if down { onPress?() } }
    }
}

// A button inside a bar: only the icon gives, so the bar itself stays put.
struct PressIcon: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

// An app's own things, reached from its banner.
struct AppBrowse: View {
    @Environment(TVModel.self) var model
    @Environment(\.paneLayout) private var panes
    let source: MediaSource
    // A row opened from its heading on this page. This page is itself pushed by an item (model.browsing), and a row pushed
    // by value on the same stack re-pushed this page instead: "Continue watching" opened Stremio again (Richard,
    // 2026-11-06: "it shouldnt open the same menu as the one i first accessed"). So its rows open by an item too.
    @State private var row: RowRoute?
    var body: some View {
        Group {
            if panes {
                FoldSplit { BrowseColumn(store: .shared(source), part: .left) } right: { BrowseColumn(store: .shared(source), part: .right) }
            } else {
                BrowseColumn(store: .shared(source))
            }
        }
        .topShade().topFade()
        .environment(\.openRow, { row = $0 })
        .navigationDestination(item: $row) { $0.page.underFlick(barHidden: true) }
        .background { Ambience() }
        .onAppear { model.mood = source.mood }
        .onDisappear { if model.mood == source.mood { model.mood = nil } }
        // The build's shot of Stremio's first row opened from its heading ("-pose stremiorow"): its own list, not Stremio again.
        .task {
            guard UserDefaults.standard.string(forKey: "pose") == "stremiorow", row == nil else { return }
            let store = BrowseStore.shared(source)
            for _ in 0..<60 where store.rows.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let first = store.rows.first { row = .media(first, source) }
        }
        .navigationTitle(source.name)
        // Back, and the app itself on the TV, in the page's bar; not offered when it's already the app on the TV.
        .barPage {
            if model.status?.app != source.pkg {
                PageBarAction(title: "Open on TV", icon: "tv") { model.post("open", ["pkg": source.pkg]) }
            }
        }
    }
}

extension View {
    @ViewBuilder func navBarHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
        toolbarVisibility(hidden ? .hidden : .automatic, for: .navigationBar)
        #else
        self
        #endif
    }
}
