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
}
struct StremioEpisode: Decodable, Identifiable, Hashable {
    let id: String, season: Int, episode: Int, name: String, thumb: String
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
    func details(withSource: Bool = false) -> String {
        var parts: [String] = []
        if let gb, gb > 0 { parts.append(gb < 1 ? "\(Int(gb * 1024)) MB" : String(format: "%.1f GB", gb)) }
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
    @EnvironmentObject var model: TVModel
    enum Step: Int { case episodes, streams, flick, control }
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
    @State private var flight: Task<Void, Never>?
    @State private var cancelled = false
    @State private var morphing = false
    // The control screen's buttons settle in just after its screen has grown out of the TV.
    @State private var controlsIn = false
    // Where the TV's screen sits on the control step. The one screen moves between that and tvFrame, growing as it goes.
    @State private var controlSlot = CGRect.zero
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
    // Handed to the controls while the TV is still getting the film going, once its player is up.
    @State private var handedOver = false
    // Near the end of something, whether to start it over rather than resume at the credits, and how long it runs.
    @State private var startOver = true
    @State private var runtime: Double?
    @State private var choseOnTV = false
    // On the control screen, a way back to the start, for when it's still near the end.
    @State private var offerStartOver = false
    @State private var checkedEnd = false
    @State private var restarting = false
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
    // The TV taking a breath as its player comes up.
    @State private var breaths = 0
    @State private var timing = FlickTiming()
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
        let posed = ["lift", "flickdemo", "flickdemo-stream"].contains(Self.pose)
        // A card that already names its episode, from Continue watching or a re-flick, needs no episode picked.
        let ready = target.ready && (ref?.type == "movie" || ref?.video != nil)
        _step = State(initialValue: ref == nil || posed || ready ? .flick : ref?.type == "series" && ref?.video == nil ? .episodes : .streams)
        // The build's shot of the controls after a flick, on a film near its end: already there, the card landed. And
        // its recording of the way from there into the Remote.
        if Self.pose == "startover" || Self.pose == "toremote" {
            _step = State(initialValue: .control); _flown = State(initialValue: true); _landed = State(initialValue: true); _done = State(initialValue: true)
            _handedOver = State(initialValue: true); _stream = State(initialValue: StremioStream(token: "s0", addon: "Sample addon", name: "1080p", description: ""))
        }
        _autoplay = State(initialValue: target.autoplay)
    }
    var item: MediaItem { target.item }
    var source: MediaSource { target.source }
    var isSeries: Bool { item.stremioRef?.type == "series" }
    var lifted: Bool { (touching || demoHeld) && !flown }
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
    // A Stremio stream or title: the kind of send the TV can be made ready for.
    var video: Bool { source == .stremio && target.send == nil && item.stremioRef != nil }
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
        case .flick: return picked && !flown ? .streams : nil
        case .control: return nil
        }
    }
    var next: Step? {
        switch step {
        case .episodes: return episode == nil ? nil : .streams
        case .streams: return .flick
        case .flick, .control: return nil
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
            .onChange(of: progress >= 0.7) { _, now in if lifted || !now { charged = now } }
            // The TV made ready while the card is in the hand, or as soon as the card has its stream.
            .onChange(of: lifted) { _, now in if now && video { Prepare.arm() } }
            .onChange(of: step == .flick && stream != nil) { _, now in if now && video && !flown { Prepare.arm() } }
            .task { await opened() }
    }
    // Picked up, each quarter of the way, charged, the hit on the TV.
    var felt: some View {
        let held = lifted
        return screen
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: held) { (_: Bool, now: Bool) -> Bool in now }
            .sensoryFeedback(trigger: detent) { (old: Int, new: Int) -> SensoryFeedback? in new > old && held ? .impact(flexibility: .rigid, intensity: 0.35 + 0.18 * Double(new)) : nil }
            .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: charged) { (_: Bool, now: Bool) -> Bool in now }
            .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: impacts)
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
                    if step == .flick || step == .control { screenLayer.opacity((arrived || toRemote) && !screenOut ? 1 : 0).transition(slide) }
                    Group {
                        switch step {
                        case .episodes: episodesStep.transition(slide)
                        case .streams: streamsStep.transition(slide)
                        case .flick: flickStep(g).transition(slide)
                        // Its screen grows out of the TV (the screen layer above), so the step itself only fades.
                        case .control: controlStep(box.size).transition(.opacity)
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
            .toolbar { if barShown { bar } }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .containerBackground(.clear, for: .navigation)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .preferredColorScheme(.dark)
        // The build's recording only: what the flick is doing, so a frame can be read against the code.
        .overlay(alignment: .bottomLeading) {
            if ["flickdemo", "flickdemo-stream", "toremote"].contains(Self.pose) {
                Text("step \(step.rawValue) flown \(flown ? 1 : 0) landed \(landed ? 1 : 0) sending \(sending ? 1 : 0) done \(done ? 1 : 0) ok \(successes) phase \(phase ?? "-") lines \(streamed ? 1 : 0)")
                    .font(.system(size: 11, design: .monospaced)).padding(6).background(.black.opacity(0.7)).foregroundStyle(.yellow)
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
            if !leaving, !flown || step == .control { model.mood = c }
        }
        if step == .flick && stream != nil && video { Prepare.arm() }
        if ["flickdemo", "flickdemo-stream"].contains(Self.pose) { Task { await demo() } }
        if Self.pose == "toremote" { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); goRemote() } }
        // Side by side, so a slow description doesn't hold up the streams.
        async let details: Void = loadMeta()
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

    // See-through, tinted by whatever is chosen, and it comes up clear as the card goes.
    func backdrop(_ size: CGSize) -> some View {
        // Edge to edge, under the side bar too, and always fully blurred: what's behind never shows through.
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
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
                    // A fixed blur: animating its radius redraws the whole screen's blur every frame of the flight.
                    .blur(radius: 32)
                    .scaleEffect(landed ? 1.16 : 1.1)
                }
                .clipped()
                .opacity(0.55 + 0.4 * charge)
            Color.black.opacity(0.4 - 0.15 * charge)
            // While the card is held the whole screen leans into the throw: the picked thing's colour floods in a little.
            (tint ?? .clear).opacity(lifted ? 0.1 + 0.12 * Double(min(1, progress)) : 0)
                .animation(.easeOut(duration: 0.25), value: lifted)
        }
        .ignoresSafeArea()
        .opacity(arrived ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: episode)
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
            // While anything is still on its way to the TV, the X stops it, on the controls too. Once it's there, a tick.
            let stops = flown && (step != .control || sending)
            Button { stops ? callOff() : leave() } label: { Label(stops ? "Stop" : step == .control ? "Done" : "Close", systemImage: stops || step != .control ? "xmark" : "checkmark") }
        }
    }

    var poster: some View {
        Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
            .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
    }
    func about(_ lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.title3.weight(.bold)).lineLimit(2)
            if let about = meta?.about ?? item.about, !about.isEmpty {
                Text(about).font(.footnote).foregroundStyle(.secondary).lineLimit(lines)
            }
            if let slug = item.slug, !slug.isEmpty {
                Button { model.tick(); model.post("film", ["slug": slug]); leave() } label: {
                    Label("Letterboxd", systemImage: "film")
                }.font(.footnote.weight(.medium)).tint(TVLook.accent).padding(.top, 2)
            }
        }
    }
    var heading: some View {
        HStack(alignment: .top, spacing: 14) {
            poster.frame(width: 74, height: 111).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            about(4)
            Spacer(minLength: 0)
        }
    }
    // Unfolded, the film has the left side to itself: a real poster, and room for what it's about.
    var bigHeading: some View {
        VStack(alignment: .leading, spacing: 14) {
            poster.frame(width: 180, height: 270).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            about(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.white.opacity(selected ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressCard())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    // The film at the top, then the choices. Unfolded, the film one side of the fold and the choices the other.
    @ViewBuilder func page<C: View>(@ViewBuilder content: () -> C) -> some View {
        if panes {
            FoldSplit {
                ScrollView { bigHeading.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24) }
            } right: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { content() }
                        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { heading; content() }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // First step of a series: which episode.
    var episodesStep: some View {
        page {
            if seasons.isEmpty && !metaFailed {
                ForEach(0..<4, id: \.self) { i in PlaceholderRow(delay: Double(i) * 0.12, thumb: true) }.padding(.top, 6)
            } else if seasons.isEmpty {
                // No episode list is no reason to be stuck: the TV can still open the series.
                Text("Couldn’t load the episodes.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                Button("Try again") { metaFailed = false; Task { await loadMeta() } }.font(.subheadline.weight(.medium)).tint(TVLook.accent)
                row(selected: false) { go(.flick) } label: {
                    Image(systemName: "tv").foregroundStyle(TVLook.accent).frame(width: 28)
                    Text("Open the series on the TV").font(.subheadline.weight(.semibold))
                }
            } else {
                Chips(options: seasons.map { ($0, "Season \($0)") }, selected: $season).padding(.top, 6)
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach((meta?.episodes ?? []).filter { $0.season == season }) { e in
                            episodeRow(e).id(e.id).transition(.opacity.combined(with: .offset(y: 10)))
                        }
                    }
                    // To where he is, when that's found, and again on coming back from the streams.
                    .onChange(of: upNext) { _, id in if let id { withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { proxy.scrollTo(id, anchor: .center) } } }
                    .onAppear { if let id = episode?.id { Task { proxy.scrollTo(id, anchor: .center) } } }
                }
            }
        }
    }
    func episodeRow(_ e: StremioEpisode) -> some View {
        row(selected: episode == e) {
            if episode != e { episode = e; stream = nil; streams = []; noStreams = false; streamFilter = "All"; picked = false; runtime = nil; startOver = true; choseOnTV = false }
            go(.streams)
        } label: {
            Art(url: URL(string: e.thumb)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                .frame(width: 82, height: 46)
                .overlay(alignment: .bottom) {
                    // How far into it he is, as on Stremio's own cards.
                    if e.id == upNext, let p = upNextProgress, p > 0 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) { Color.white.opacity(0.25); TVLook.accent.frame(width: g.size.width * min(p, 1)) }
                        }.frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(e.episode). \(e.name)").font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                if e.id == upNext { badge("Up next") }
            }
        }
    }
    func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(TVLook.accent, in: Capsule()).foregroundStyle(.black)
    }
    // Next: which stream, or leave that to the TV.
    var streamsStep: some View {
        page {
            if let e = episode { Text("Season \(e.season), episode \(e.episode): \(e.name)").font(.subheadline.weight(.semibold)).padding(.top, 4) }
            row(selected: choseOnTV) { stream = nil; picked = false; choseOnTV = true; go(.flick) } label: {
                Image(systemName: "tv").foregroundStyle(TVLook.accent).frame(width: 28)
                Text("Choose on the TV").font(.subheadline.weight(.semibold))
            }
            .padding(.top, 4)
            // Nearly finished: resuming would land on the credits, so starting over is offered, and chosen to begin with.
            // Not for Choose on the TV, where Stremio's own screen asks.
            if nearEnd && !choseOnTV {
                Chips(options: [(false, resumeLabel), (true, "Start over")], selected: $startOver).padding(.top, 6)
            }
            if findingStreams && streams.isEmpty {
                Text("Asking your addons…").font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(0..<4, id: \.self) { i in PlaceholderRow(delay: Double(i) * 0.12) }
            } else if noStreams {
                Button("No streams found. Try again") { Task { await findStreams(again: true) } }
                    .font(.subheadline.weight(.medium)).tint(TVLook.accent).frame(maxWidth: .infinity).padding(.top, 22)
            }
            let qualities = ["1080p", "4K", "720p", "480p"].filter { q in streams.contains { $0.quality == q } }
            if qualities.count > 1 {
                Chips(options: (["All"] + qualities).map { ($0, $0) }, selected: $streamFilter).padding(.top, 6)
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
            if e.id == ref.video { return item.progress }
            return e.id == upNext ? upNextProgress : nil
        }
        return item.progress
    }
    var nearEnd: Bool { (savedProgress ?? 0) > 0.9 }
    var resumeLabel: String {
        guard let runtime, let p = savedProgress else { return "Resume" }
        // Running time times progress is only an estimate, so to the minute.
        let m = Int(runtime * p / 60000)
        return "Resume at " + (m >= 60 ? String(format: "%d:%02d", m / 60, m % 60) : "\(m) min")
    }
    // The running time, for the Resume chip's time: from Stremio's own catalogue, the episode's if it has one.
    func loadRuntime() async {
        guard runtime == nil, nearEnd, let ref = item.stremioRef,
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
                let details = s.details(withSource: twin)
                if !details.isEmpty { Text(details).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .multilineTextAlignment(.leading)
        }
        .disabled(failed)
        .opacity(failed ? 0.45 : 1)
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
        let tvWidth = wide ? min(320, look.width * 0.36) : min(208, look.width * 0.5)
        let tv = CGSize(width: tvWidth, height: (tvWidth * 9 / 16).rounded())
        let centre = CGPoint(x: look.midX, y: look.midY)
        // The card is held, not laid down: small, its lower third past the bottom edge like a card in the hand, and
        // well clear of the TV's stand, so a throw has a real way to travel.
        // Open, a little smaller and nearer the stand, so well over two thirds of it, title and all, shows over the edge.
        let width: CGFloat = wide ? 104 : 92
        let height = MediaCard.height(width, source)
        let stand = centre.y + tv.height / 2 + 12
        let held = hand.maxY - height * (wide ? 3 / 4 : 2 / 3)
        let top = hand == look ? max(held, stand + (wide ? 50 : 110)) : max(held, hand.minY + 12)
        return Stage(centre: centre, tv: tv, cardX: hand.midX, cardTop: top, cardWidth: width, floor: hand.maxY - 4, wide: wide)
    }
    // Last: nothing left to decide, just the TV and the card in your hand.
    func flickStep(_ g: GeometryProxy) -> some View {
        let s = stage(g)
        let cardHeight = MediaCard.height(s.cardWidth, source)
        return ZStack {
            // Above the TV while the card is in the hand: what to do, which stream it is, and anything gone wrong.
            above.frame(width: max(220, s.tv.width + 120), height: 48, alignment: .bottom).position(x: s.centre.x, y: s.tvTop - 40)
                .opacity(arrived ? 1 : 0)
            tvSlot(s.tv).position(s.centre).opacity(arrived ? 1 : 0)
            // Under it once the card has landed: how far the TV has got.
            below.frame(width: max(220, s.tv.width + 80), height: 40, alignment: .top).position(x: s.centre.x, y: s.tvBottom + (s.wide ? 22 : 16) + 20)
                .opacity(arrived ? 1 : 0)
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
    // Sent with "Choose on the TV": Stremio is showing its streams, and only the remote can pick one.
    var choosingOnTV: Bool {
        source == .stremio && stream == nil && target.send == nil && item.stremioRef != nil && model.status?.session.map { $0.pkg == "com.stremio.one" && $0.position != nil } != true
    }
    // The episode after this one, from the episode list already loaded.
    var nextEpisode: StremioEpisode? {
        guard isSeries, let e = episode, let all = meta?.episodes else { return nil }
        return NextUp.after(e, in: all)
    }
    // After the flick: the TV's screen, grown, with what's playing on it and the controls for it. Nothing here scrolls,
    // so the screen's place stays put while it grows into it.
    @ViewBuilder func controlStep(_ size: CGSize) -> some View {
        let w = panes ? min(size.width / 2 - 48, 420) : min(size.width - 48, 520)
        // Until the TV reports what was just sent, what it reports is what played before, so the flicked thing stands in.
        let sentTo = source == .mint ? "com.codex.musicwebtv" : "com.stremio.one"
        let reported = model.status?.session
        let session = reported?.pkg == sentTo ? reported : nil
        let rawMusic = model.nowMusic
        let music = source == .mint && (target.send != nil || rawMusic?.title.caseInsensitiveCompare(item.title) == .orderedSame || reported?.pkg == sentTo) ? rawMusic : nil
        let isMusic = source == .mint
        let onTV = choosingOnTV
        // Until the TV says it's playing, a pause would be undone by its own start check and a jump would hit a player
        // that isn't ready, so those wait, dimmed, and come in once it answers.
        let locked = sending && handedOver && !playingSeen
        // Under the title: the episode for a series, the year for a film, and never the service or the app.
        let under = isMusic ? (music.map { "\($0.artist) · \($0.album)" } ?? shown.subtitle)
            : session?.description.dropFirst().first.map(Wording.episode) ?? (isSeries && episode != nil ? shown.subtitle : Self.year(in: item.subtitle) ?? "")
        let picture = VStack(spacing: 18) {
            // The screen's place. The screen itself is drawn over it, grown out of the TV the card landed in.
            Color.clear.frame(width: w, height: w * 9 / 16)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { f in
                    // The first time it's known, the screen grows to it; after that it just follows.
                    if controlSlot == .zero { withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { controlSlot = f } } else { controlSlot = f }
                }
            VStack(spacing: 4) {
                Text(isMusic ? (music?.title ?? shown.title) : (session?.description.first ?? shown.title)).font(.title2.weight(.bold)).lineLimit(2)
                // Its line is kept even when there's nothing to say, so nothing moves when there is.
                Text(under.isEmpty ? " " : under)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .contentTransition(.opacity)
            .opacity(controlsIn ? 1 : 0)
            // Where it's got to, for a film or a song alike. Its place is kept until the TV says, so nothing below jumps.
            // Handed over before the film is going: what the TV is doing goes in the middle of the bar.
            // The same word as above the TV: "Waking" only when the TV really is asleep.
            let waiting = sending ? Self.word(for: phase, asleep: model.status.map { $0.screen == "asleep" || $0.screen == "screensaver" } ?? true) : nil
            Group {
                if onTV { EmptyView() }
                else if let session, !isMusic { VideoProgress(session: session, note: waiting, locked: locked).frame(maxWidth: w) }
                else if isMusic, let music, music.duration > 0 { MusicProgress(music: music).frame(maxWidth: w) }
                else { ProgressPlaceholder(note: waiting).frame(maxWidth: w) }
            }
            .opacity(controlsIn ? 1 : 0)
        }
        let remote = Button { goRemote() } label: { Label("Remote", systemImage: "av.remote").font(.subheadline.weight(.semibold)).padding(.horizontal, 18).frame(height: 44) }
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
        let controls = VStack(spacing: 18) {
            if onTV {
                // The TV is on Stremio's list of streams: what's needed now is the pad to pick one with.
                Text("Pick a stream with the remote").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                DPad().frame(width: 180, height: 180)
                HStack(spacing: 14) { GlassKey(icon: "chevron.left", label: "Back", key: "back", size: 44); remote }
            } else {
                HStack(spacing: 22) {
                    if source == .stremio {
                        Group {
                            SeekButton(icon: "gobackward.10", label: "Back 10 seconds", step: -1)
                            // Pause from the hand-over on, dimmed while it's starting, so the key never flickers
                            // through play on the way.
                            PlayKey(playing: locked || playedAt.map({ Date().timeIntervalSince($0) < 4 }) == true ? true : session?.playing, size: 74)
                            SeekButton(icon: "goforward.10", label: "Forward 10 seconds", step: 1)
                        }
                        .opacity(locked ? 0.4 : 1).allowsHitTesting(!locked)
                    } else {
                        GlassKey(icon: "backward.fill", label: "Previous", key: "previous", size: 56)
                        PlayKey(playing: isMusic ? music?.playing : session?.playing, size: 74)
                        GlassKey(icon: "forward.fill", label: "Next", key: "next", size: 56)
                    }
                }
                if source == .stremio {
                    // Stop only while the player is open; the row keeps its place either way.
                    HStack(spacing: 18) {
                        // While it's still starting, Stop calls the whole start off, as the X does.
                        if session != nil { GlassButton(icon: "stop.fill", label: "Stop", size: 50) { if sending { callOff() } else { stop() } } }
                        if !locked, let n = nextEpisode { GlassButton(icon: "forward.end.fill", label: "Next episode, \(n.episode). \(n.name)", size: 50) { playNext(n) }.transition(.opacity) }
                    }
                    .frame(height: 50)
                }
                HStack(spacing: 12) {
                    remote
                    // Still near the end, or the TV couldn't go back to the start by itself: one quiet way back to it.
                    if offerStartOver && source == .stremio && !locked {
                        Button(action: startOverNow) {
                            HStack(spacing: 7) {
                                if restarting { ProgressView().controlSize(.small) } else { Image(systemName: "backward.end") }
                                Text("Start over")
                            }
                            // As strong as Remote beside it: it's a real choice, not a disabled one.
                            .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).frame(height: 44)
                        }
                        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule()).disabled(restarting)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: offerStartOver)
            }
        }
        // In the way the buttons first settle in, once the TV says it's playing.
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: locked)
        .opacity(controlsIn ? 1 : 0)
        .offset(y: controlsIn ? 0 : 16)
        Group {
            // Unfolded, the screen one side of the fold and its controls the other.
            if panes {
                FoldSplit {
                    picture.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } right: {
                    controls.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 18) { picture; controls; Spacer(minLength: 0) }
                    .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .environment(\.keysInScroll, true)
        // The buttons settle in from just below once the screen has grown into place.
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.88).delay(0.12)) { controlsIn = true } }
        // Kept current while it's open, so the bar and the buttons follow the TV.
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000); await model.load() } }
        // Opened in the last tenth, Start over is offered; it goes once the film is back in its first tenth. Not while a
        // start-over asked for is still being done, when the player is briefly where he left off.
        .onChange(of: Self.through(session), initial: true) { _, f in
            guard let f, source == .stremio else { return }
            if !checkedEnd && !(askedRestart && sending) { checkedEnd = true; if f > 0.9 { offerStartOver = true } }
            if offerStartOver && f < 0.1 { offerStartOver = false }
        }
    }
    // How far through the film the TV says it is.
    static func through(_ s: TVStatus.Session?) -> Double? {
        guard let s, let p = s.position, let d = s.duration, d > 0 else { return nil }
        let ran = s.playing ? max(0, Date().timeIntervalSince1970 * 1000 - (s.sampledAt ?? Date().timeIntervalSince1970 * 1000)) : 0
        return min(1, (p + ran) / d)
    }
    func startOverNow() {
        model.tick()
        restarting = true
        let session = model.status?.session
        Task {
            do {
                // Played and moved by Android's own seek, which reaches the start from the credits; the seek bar's keys
                // run out about an hour back.
                let d = try await TVBridge.post("player-seek-to", ["ms": 0, "play": true], timeout: 60)
                if let ms = ((try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["position"] as? NSNumber)?.doubleValue {
                    SeekQueue.shared.adopt(ms, for: session)
                    if let dur = session?.duration, dur > 0, ms / dur < 0.1 { offerStartOver = false }
                }
                await model.load()
            } catch {
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                #endif
                model.say("Couldn’t go back to the start")
            }
            restarting = false
        }
    }
    var screenURL: URL? { URL(string: episode?.thumb.isEmpty == false ? episode!.thumb : item.art) }
    @ViewBuilder func artwork(fill: Bool) -> some View {
        if let image = target.image { image.resizable().aspectRatio(contentMode: fill ? .fill : .fit) }
        else { Art(url: screenURL) { $0.resizable().aspectRatio(contentMode: fill ? .fill : .fit) } placeholder: { fill ? (tint ?? Color(white: 0.15)) : Color.clear } }
    }
    // The TV's screen, small while the card is in the hand, grown on the control step. Its picture crossfades within the
    // one frame: the poster filling the small screen, then the whole poster on a blurred copy of itself.
    // Going to the Remote, one number runs from the controls' place to the Remote's picture, so every frame of the move
    // is drawn in between, wherever that picture has settled by then, and the glow goes with it rather than at once.
    var screenLayer: some View { Moving(t: toRemote ? 1 : 0) { screenLayer(move: $0) } }
    func screenLayer(move t: CGFloat) -> some View {
        // Big only once the control step's place is known: until then, nothing changes on the small TV. Unfolded, the far
        // pane's place comes a few frames after the step does. Going to the Remote, it moves onto the Remote's own
        // picture of the TV, which shows the same thing, so the one picture carries on there.
        let big = (step == .control && controlSlot != .zero) || toRemote
        let start = controlSlot == .zero ? tvFrame : controlSlot
        let slot = toRemote || t > 0 ? between(start, remoteSlot, t) : big ? controlSlot : tvFrame
        // The grown screen has the Remote's picture's own corners, so moving onto it changes nothing but place and size.
        let radius: CGFloat = big ? TVLook.card : 9
        let lean = big ? 0 : charge
        let glow = Double(1 - t)
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black.opacity(0.55))
            // What the TV is showing now, so it reads as his TV rather than an empty slab. It gives way as the card comes.
            if !landed && !big {
                TVNowPicture(store: model.mirrorStore)
                    .opacity(0.85 * Double(1 - charge))
                    .transition(.opacity)
            }
            // The TV answering the card on its way: the poster rising dimly from the bottom of its screen, like a
            // reflection of what's coming.
            if !landed && !big && charge > 0.01 {
                Color.clear.overlay { artwork(fill: true) }.clipped()
                    .opacity(0.42 * Double(charge))
                    .offset(y: (1 - charge) * slot.height * 0.75)
                    .allowsHitTesting(false)
            }
            // The poster filling the screen stays put underneath through the growing, so there's never a frame without it.
            if landed || big {
                Color.clear.overlay { artwork(fill: true) }.clipped()
                    .transition(.asymmetric(insertion: .scale(scale: 1.3).combined(with: .opacity), removal: .opacity))
            }
            // The tick fades out as the screen grows, rather than going the moment the step changes.
            if done { TVTick().opacity(big ? 0 : 1).transition(.scale(scale: 0.5).combined(with: .opacity)) }
            // On top, the grown screen's picture fades in: the whole poster on a blurred copy of itself. Only from the
            // control step on, so its blur costs nothing while the card is in flight or the tick plays.
            if step == .control {
                ZStack {
                    // As the Remote draws its own picture of the TV, so the move into it ends on the same thing.
                    // Never solid black before the poster's in: its own colour, which the blurred poster then covers.
                    (tint ?? Color(white: 0.12)).opacity(1 - 0.65 * Double(t))
                    Color.clear.overlay { artwork(fill: true) }.clipped().blur(radius: 24).opacity(0.7)
                    artwork(fill: false)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                        .padding(14)
                }
                .opacity(big ? 1 : 0)
                .transition(.opacity)
            }
            if sending { TVWaiting().transition(.opacity) }
            // Grown over the poster, only a breath of the flash: the ripple round it says it landed, without a white frame.
            TVFlash(trigger: successes).opacity(big ? 0.2 : 1)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: big)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .frame(width: slot.width, height: slot.height)
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(glow * (big ? 0.25 : 0.3 + 0.5 * charge)), lineWidth: big ? 1 : 1.5) }
        // It brightens as the card comes, and glows hard once the card is charged.
        .shadow(color: TVLook.accent.opacity(glow * (big ? 0.45 : charged ? 0.95 : 0.7 * charge)), radius: big ? 26 : charged ? 34 : 10 + 18 * charge)
        .overlay { TVRipple(trigger: impacts, big: big) }
        .overlay { TVRipple(trigger: successes, big: big) }
        // It leans in to meet the card, then gives as the card hits: squashed, over, and settled.
        .scaleEffect(1 + 0.09 * lean)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: impacts) { c, s in c.scaleEffect(s) } keyframes: { _ in
            CubicKeyframe(0.94, duration: 0.07)
            CubicKeyframe(1.03, duration: 0.12)
            SpringKeyframe(1, duration: 0.45, spring: Spring(response: 0.35, dampingRatio: 0.55))
        }
        // One soft breath as its player comes up, just before it grows into the controls.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: breaths) { c, s in c.scaleEffect(s) } keyframes: { _ in
            CubicKeyframe(1.035, duration: 0.22)
            CubicKeyframe(1, duration: 0.3)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: charge)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: landed)
        .offset(x: slot.minX, y: slot.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Nothing until its place is known, so it never starts from a corner.
        .opacity(slot == .zero ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    // Above the TV while the card is in the hand: what to do and which stream is in it, or the one thing worth knowing
    // instead (the best stream being found, or why the last throw came back). Out of the hierarchy once the card has
    // gone, so nothing ghosts behind the TV's own answer.
    @ViewBuilder var above: some View {
        if !flown {
            VStack(spacing: 3) {
                if pickingBest {
                    HStack(spacing: 7) { ProgressView().controlSize(.small).tint(.white); Text("Finding the best stream") }
                        .font(.footnote.weight(.semibold)).transition(.opacity)
                } else if let note {
                    Text(note).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2).id(note).transition(.opacity)
                } else {
                    Text("Flick up to play on the TV").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).transition(.opacity)
                    if let stream, !stream.brief.isEmpty { Text(stream.brief).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                }
            }
            // Readable for as long as the card is in the hand, raised or not; it goes with the card once thrown.
            .opacity(arrived ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: arrived)
            .animation(.easeOut(duration: 0.25), value: note)
            .animation(.easeOut(duration: 0.25), value: pickingBest)
            .transition(.opacity)
        }
    }
    // Under the TV once the card is in it: three dots that fill as the TV wakes, opens the film and plays it, with one
    // word for where it's got to. The tick on the TV says the rest.
    @ViewBuilder var below: some View {
        if landed && sending {
            TVPhaseDots(filled: Self.dots(for: phase), word: Self.word(for: phase, asleep: model.status.map { $0.screen == "asleep" || $0.screen == "screensaver" } ?? true)).transition(.opacity)
        } else if flown, let note, !note.isEmpty {
            Text(note).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2).transition(.opacity)
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
        // Rising toward the TV it grows, by up to 15 % at seven tenths of the way, lit round its edge more and more.
        // Let go, it tips into the TV and becomes its picture. Put back, it goes down onto its own tile.
        let near = min(1, progress)
        let rise = min(1, near / 0.7), eased = rise * rise * (3 - 2 * rise)
        let grow = (lifted ? 1.03 : 1) * (1 + 0.15 * eased)
        let size = returning ? returnSlot.width / max(cardFrame.width, 1) : flown ? tvFrame.height / max(cardFrame.height, 1) : grow
        let x = returning ? returnSlot.midX - cardFrame.midX : flownX ? tvFrame.midX - cardFrame.midX : drag.width * 0.85
        let y = returning ? returnSlot.midY - cardFrame.midY : flown ? tvFrame.midY - cardFrame.midY : cardY
        let rim = flown || returning ? 0 : Double(near)
        let glow = (tint ?? TVLook.accent).mix(with: .white, by: 0.35)
        return MediaCard(item: shown, source: source, width: width, image: target.image)
            .overlay {
                RoundedRectangle(cornerRadius: width > 200 ? 8 : 6, style: .continuous)
                    .strokeBorder(TVLook.accent.opacity(0.8 * rim), lineWidth: 1.5)
            }
            .shadow(color: glow.opacity(0.65 * rim), radius: 4 + 14 * rim)
            .shadow(color: .black.opacity(lifted ? 0.55 : 0.45), radius: lifted ? 30 : 18, y: lifted ? 22 : 10)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lifted)
            .rotationEffect(.degrees(returning ? 0 : lean))
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.62), value: lean)
            // Tipped toward the TV only once it's thrown, so in the hand it never reads as going away.
            .rotation3DEffect(.degrees(flown && !returning ? 14 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .scaleEffect(size)
            .opacity(landed ? 0 : 1)
            .animation(.easeOut(duration: 0.14), value: landed)
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
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("flick"))
                .updating($touching) { _, on, _ in on = true }
                .onChanged { v in
                    guard !flown, !returning else { return }
                    drag = v.translation
                    lean = max(-12, min(12, Double(v.velocity.width) / 150 + Double(v.translation.width) / 45))
                    let d = min(3, Int(max(0, -v.translation.height) / reach * 4))
                    if d != detent { detent = d }
                }
                .onEnded { v in
                    guard !returning else { return }
                    if v.translation.height < -70 || v.predictedEndTranslation.height < -150 { send(flicked: v.velocity) }
                    else if v.translation.height > 110 { putBack() }
                    else { settle() }
                })
            .onChange(of: touching) { _, on in if !on && !flown && !returning { settle() } }
            .onTapGesture {
                // A tap shows which way it wants to go.
                model.tick()
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { hop = true }
                Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.42)) { hop = false }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Sends this to the TV")
            .accessibilityAction { send() }
    }
    func settle() {
        detent = 0
        guard drag != .zero || lean != 0 else { return }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        #endif
        withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) { drag = .zero; lean = 0 }
    }
    // For the build's recording: the moves a finger makes, pick up, a slow pull with a sway, and a throw.
    // Far enough up that the card charges and the TV lights for it. With a stream to be found first, it waits for that,
    // as he would.
    func demo() async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if Self.pose == "flickdemo-stream" {
            for _ in 0..<100 where stream == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        demoHeld = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        for i in 1...50 {
            let t = CGFloat(i) / 50
            drag = CGSize(width: 36 * sin(t * .pi), height: -0.8 * reach * t * t)
            lean = Double(cos(t * .pi)) * 6
            detent = min(3, Int(t * t * 0.8 * 4))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        demoHeld = false
        send(flicked: CGSize(width: -260, height: -1900))
    }
    // The X while it's on its way: whatever started on the TV stops, and this closes.
    func callOff() {
        cancelled = true
        flight?.cancel()
        model.tick()
        model.post("stop-playing", ["pkg": source == .mint || target.send != nil ? "com.codex.musicwebtv" : "com.stremio.one"])
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { sending = false }
        leave()
    }
    // Everything fades back to the page underneath. From here on nothing started by this screen changes the app behind.
    func leave(restoreMood: Bool = true) {
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
        leaving = true
        detent = 0
        if let prior = priorMood { model.mood = prior }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
        #endif
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
        model.tick()
        leaving = true
        model.keepMood(until: item.art)
        if let art = screenURL?.absoluteString { model.standIn(art) }
        if !model.mirrorLive { model.setMirror(true) }
        // Held where it is first: the tab changing under it lays the space around it out again.
        if flickFrame.width > 0 { held = flickFrame }
        // Under the screen, so the Remote is laid out, and its picture's place known, by the time the screen moves.
        // No animation starts in this tick: laying the Remote out hitches the main thread, and swallowed the fades.
        model.remoteArrival = Date()
        model.tab = 0
        Task {
            var slot: CGRect?
            for _ in 0..<30 {
                if let s = model.mirrorSlot, s.width > 20 { slot = s; break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard let s = slot else { leave(restoreMood: false); Task { await model.load() }; return }
            remoteSlot = s.offsetBy(dx: -flickOrigin.x, dy: -flickOrigin.y)
            // Two more frames, so the Remote's first layout is done before anything moves.
            try? await Task.sleep(nanoseconds: 33_000_000)
            // The fade, the move and the Remote coming up through the backdrop start together, so there's never a lone
            // screen on an empty backdrop. The backdrop is gone quickly, before the keys arrive, so they never read grey
            // through it.
            withAnimation(.easeOut(duration: 0.2)) { controlsIn = false }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { toRemote = true }
            withAnimation(.easeOut(duration: 0.15)) { arrived = false; barShown = false }
            // The Remote's picture can still settle as its page lays out, so the move keeps aiming at where it is now,
            // place and size, until the spring has run its course and the picture has stopped moving. Once the screen
            // is on it, a late change eases across rather than stepping.
            let start = Date()
            var still = 0
            while Date().timeIntervalSince(start) < 1.5 {
                try? await Task.sleep(nanoseconds: 16_000_000)
                let gone = Date().timeIntervalSince(start)
                if let s = model.mirrorSlot, s.width > 20 {
                    let next = s.offsetBy(dx: -flickOrigin.x, dy: -flickOrigin.y)
                    let moved = abs(next.minX - remoteSlot.minX) + abs(next.minY - remoteSlot.minY)
                        + abs(next.width - remoteSlot.width) + abs(next.height - remoteSlot.height) > 0.5
                    if moved {
                        still = 0
                        if gone > 0.6 { withAnimation(.easeOut(duration: 0.15)) { remoteSlot = next } } else { remoteSlot = next }
                    } else { still += 1 }
                }
                if gone > 0.65 && still >= 6 { break }
            }
            // Landed on it: the screen gives way to the same picture underneath, and whatever of this screen is still
            // over the keys fades with it before it's taken away.
            withAnimation(.easeOut(duration: 0.2)) { screenOut = true; fadingOut = true }
            try? await Task.sleep(nanoseconds: 230_000_000)
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
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            meta = m
            // A card that's part way through a series starts on that episode, unless one's been picked meanwhile.
            if episode == nil { episode = m.episodes.first { $0.id == ref.video } }
            season = episode?.season ?? m.episodes.first?.season ?? 0
        }
        guard ref.type == "series", ref.video == nil else { return }
        await homeLoad.value
        let watching = home.rows.first { $0.title == "Continue watching" }?.items.first { $0.stremioRef?.imdb == ref.imdb && $0.stremioRef?.video != nil }
        guard episode == nil, step == .episodes, let watching, let e = m.episodes.first(where: { $0.id == watching.stremioRef?.video }) else { return }
        // Chosen and shown, but not gone on from: he may want another.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { episode = e; season = e.season; upNextProgress = watching.progress; upNext = e.id }
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
    // The next episode, from the control screen: the screen shrinks back into the TV, the card comes to the hand with
    // that episode, and goes up by itself once its best stream is found.
    func playNext(_ n: StremioEpisode) {
        controlsIn = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            episode = n; season = n.season; stream = nil; streams = []; noStreams = false; streamFilter = "All"; picked = false
            flown = false; flownX = false; landed = false; done = false; note = nil; drag = .zero; lean = 0; detent = 0
            step = .flick
        }
        playingSeen = false; streamed = false
        autoplay = true
        handedOver = false; offerStartOver = false; checkedEnd = false; askedRestart = false
        Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            morphing = false
            await pickBest()
        }
    }
    // Back closes Stremio's player, and it keeps his place. Then there's nothing left here to control.
    func stop() {
        model.key("back")
        leave()
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
            // What it is, so the Mac can fetch its running time and poster while it starts.
            var body: [String: Any] = ["token": stream.token, "imdb": ref.imdb]
            if ref.type == "series", let video = episode?.id ?? ref.video { body["video"] = video }
            if nearEnd && startOver { body["restart"] = true }
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
    func send(flicked velocity: CGSize = .zero) {
        guard !flown else { return }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
        #endif
        timing = FlickTiming(); timing.mark("release")
        note = nil; detent = 0; charged = false
        // Leaves at the speed it was thrown, so there's no seam between the finger and the flight. Up and across settle on
        // their own springs, the way across carrying the sideways throw, so the flight bends into the TV.
        let from = cardY, to = tvFrame.midY - cardFrame.midY
        let speed = max(0, min(9, velocity.height / min(to - from, -1)))
        let across = tvFrame.midX - cardFrame.midX - drag.width * 0.85
        let speedX = abs(across) > 8 ? max(-5, min(5, velocity.width / across)) : 0
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 300, damping: 30, initialVelocity: speed)) { flown = true; lean = 0 }
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 170, damping: 22, initialVelocity: speedX)) { flownX = true }
        phase = nil; playingSeen = false; streamed = false
        let video = source == .stremio && target.send == nil
        flight = Task {
            // The TV takes the card as it arrives, while the request is already on its way: the landing plays over it.
            let landing = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 230_000_000)
                guard !cancelled else { return }
                impacts += 1
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { landed = true; sending = true }
                // A Mac quicker than the card: its player was already up before the card got there.
                if phase == "player" || phase == "playing" { playerUp() }
                // A second, lighter knock just after the hit: the TV has it.
                try? await Task.sleep(nanoseconds: 90_000_000)
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
                #endif
            }
            // Thrown before the best stream was found: it goes as soon as it is.
            while pickingBest && !Task.isCancelled { try? await Task.sleep(nanoseconds: 150_000_000) }
            let order = order
            let early = order.0 == "play-stream"
            askedRestart = order.1["restart"] as? Bool == true
            // A Mac too old to report the start line by line: what the TV is doing is read off its status instead,
            // and once Stremio's player is up with this film, the controls take over. Stopped as soon as the Mac
            // turns out to be reporting.
            let watch = Task {
                var cleared = false
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, let s = await TVBridge.status(timeout: 5), !Task.isCancelled, !streamed else { continue }
                    let next = Self.phase(of: s, video: video)
                    if next != phase { withAnimation(.easeOut(duration: 0.25)) { phase = next } }
                    let player = s.session.flatMap { $0.pkg == "com.stremio.one" ? $0 : nil }
                    // The Mac restarts Stremio first, so a player seen after none was is this one; before that, only by its title.
                    if player == nil { cleared = true }
                    guard early, !handedOver, let player, cleared || isThisFilm(player) else { continue }
                    if player.playing { playingSeen = true }
                    playerUp()
                }
            }
            do {
                let answer: Data
                if early {
                    // Followed as it happens: the controls come at "player", and are his at "playing".
                    answer = try await TVBridge.playStream(order.1, opened: { lines in
                        timing.mark("first-byte")
                        if lines { streamed = true; watch.cancel() }
                    }, phase: { p in took(p) })
                } else {
                    // Longer than the bridge can take to wake the TV and open what was sent.
                    answer = try await TVBridge.post(order.0, order.1, timeout: 60)
                }
                watch.cancel()
                // Never ahead of the card reaching the TV.
                await landing.value
                timing.mark("answer")
                target.sent?()
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                // Asked to start over and it couldn't: the control screen offers it.
                if (try? JSONSerialization.jsonObject(with: answer) as? [String: Any])?["restarted"] as? Bool == false { offerStartOver = true }
                // No words for a yes: the tick on the TV says it. Only Choose on the TV needs saying what's next.
                withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) {
                    sending = false; phase = nil; done = true; playingSeen = true
                    note = source == .mint || stream != nil || item.stremioRef == nil || target.send != nil ? nil : "Pick a stream with the remote"
                }
                successes += 1
                // From now the card's step leaves by fading, set before the hand-over so its last frames have it.
                morphing = true
                remember()
                timing.send()
                // Already on the controls: the flash on the big screen is the yes.
                if handedOver { Task { try? await Task.sleep(nanoseconds: 400_000_000); await model.load() }; return }
                // Straight on: the flash and the tick play as the screen grows.
                handOver()
            } catch {
                watch.cancel()
                await landing.value
                timing.mark("failed"); timing.send()
                // Called off with the X: it's already being stopped and closed.
                if Task.isCancelled || cancelled { return }
                // Handed over too soon: back down into the small TV, then the no as usual.
                if handedOver {
                    controlsIn = false
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = .flick; done = false }
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    morphing = false; handedOver = false
                }
                await failed(error)
            }
        }
    }
    // A step of the start, as the Mac reports it.
    func took(_ p: String) {
        timing.mark("phase-" + p)
        withAnimation(.easeOut(duration: 0.25)) { phase = p }
        switch p {
        case "player": playerUp()
        case "playing":
            playingSeen = true
            playedAt = Date()
            Task { await model.load() }
            // Straight to the controls if the player and the film came together.
            playerUp()
        default: break
        }
    }
    // Stremio's player is up with the film: one breath of the TV, and it grows into the controls, the rest of the wait
    // shown there.
    func playerUp() {
        guard !handedOver, !morphing, sending, step == .flick else { return }
        morphing = true
        breaths += 1
        Task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            if sending, step == .flick, !cancelled { handOver() }
        }
    }
    // Whether a Stremio player is the film just sent, by its title.
    func isThisFilm(_ p: TVStatus.Session) -> Bool {
        guard let now = p.description.first, !now.isEmpty else { return false }
        return now.localizedCaseInsensitiveContains(item.title) || item.title.localizedCaseInsensitiveContains(now)
    }
    // The hand-over: the TV the card landed in grows into the control screen, and its buttons settle in below.
    func handOver() {
        guard step == .flick, !handedOver else { return }
        handedOver = true
        timing.mark("handover")
        if !item.art.isEmpty { model.lastArt = item.art; model.lastArtTitle = item.title; model.lastArtPkg = source == .mint ? "com.codex.musicwebtv" : "com.stremio.one" }
        morphing = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = .control }
        Task { try? await Task.sleep(nanoseconds: 500_000_000); await model.load() }
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
    // The TV said no: back out of it and into the hand, with a shake.
    func failed(_ error: Error) async {
        // Back to sliding between steps, for the way back to the streams.
        morphing = false
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
        drag = .zero
        let gone = error is TVBridge.Gone, stuck = error is TVBridge.DidNotStart
        withAnimation(.spring(response: 0.55, dampingFraction: 0.66)) {
            sending = false; phase = nil; landed = false; flown = false; flownX = false; playingSeen = false
            note = gone ? "That stream has gone. Pick again." : stuck ? "That stream didn’t start" : "The TV didn’t get that"
        }
        // A list with a stream that's gone is stale: the next look asks afresh.
        if gone, let ref = item.stremioRef { StreamCache.shared.forget(type: ref.type, imdb: ref.imdb, video: episode?.id ?? ref.video ?? ref.imdb) }
        try? await Task.sleep(nanoseconds: 380_000_000)
        shakes += 1
        // A stale stream needs a new list. One that didn't start is set aside, with the next best ready to try.
        // The choice stands if the TV just didn't answer.
        guard gone || stuck else { return }
        if gone { stream = nil; streams = [] }
        else {
            if let s = stream { failedTokens.insert(s.token) }
            stream = streams.first { !failedTokens.contains($0.token) }
        }
        picked = false
        try? await Task.sleep(nanoseconds: 700_000_000)
        note = nil
        go(.streams)
    }
}

// The small TV's own picture before anything is thrown at it: a film's poster while one plays (a capture of it would be
// black), else the latest still of its screen, else the cover of what's on. Nothing while it's asleep.
private struct TVNowPicture: View {
    @EnvironmentObject var model: TVModel
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
            else if let m = store.image { Image(tv: m).resizable().scaledToFill() }
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

// The TV's screen while it gets going: a light running along the bottom edge.
private struct TVWaiting: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.3)
            GeometryReader { g in
                Capsule()
                    .fill(LinearGradient(colors: [.clear, TVLook.accent, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * 0.5, height: 3)
                    .phaseAnimator([false, true]) { c, on in c.offset(x: on ? g.size.width * 0.5 : 0) } animation: { _ in .easeInOut(duration: 0.9) }
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

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
private struct TVTick: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 36, weight: .semibold))
                .symbolRenderingMode(.palette).foregroundStyle(.black, TVLook.accent)
                .symbolEffect(.bounce, value: on)
        }
        .onAppear { on = true }
    }
}
// A flash across the TV's screen as it takes something on.
private struct TVFlash: View {
    let trigger: Int
    var body: some View {
        Color.white
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { c, o in c.opacity(o) } keyframes: { _ in
                LinearKeyframe(0.4, duration: 0.06)
                CubicKeyframe(0, duration: 0.4)
            }
            .allowsHitTesting(false)
    }
}

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
    @EnvironmentObject var model: TVModel
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
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    let source: MediaSource
    var body: some View {
        Group {
            if panes {
                FoldSplit { BrowseColumn(store: .shared(source), part: .left) } right: { BrowseColumn(store: .shared(source), part: .right) }
            } else {
                BrowseColumn(store: .shared(source))
            }
        }
        .topShade().topFade()
        .background { Ambience() }
        .onAppear { model.mood = source.mood }
        .onDisappear { if model.mood == source.mood { model.mood = nil } }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.tick(); model.post("open", ["pkg": source.pkg]) } label: { Label("Open on TV", systemImage: "tv") }
            }
        }
    }
}
