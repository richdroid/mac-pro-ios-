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
    // "2.1 GB · Ready now · Torrentio"
    var details: String {
        var parts: [String] = []
        if let gb, gb > 0 { parts.append(gb < 1 ? "\(Int(gb * 1024)) MB" : String(format: "%.1f GB", gb)) }
        if instant == true { parts.append("Ready now") }
        if let lang, !lang.isEmpty { parts.append(lang) }
        if !addon.isEmpty { parts.append(addon) }
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
    // Follows the finger exactly, with nothing in between.
    @State private var drag = UserDefaults.standard.string(forKey: "pose") == "lift" ? CGSize(width: 18, height: -190) : .zero
    // Tells a touch the system took away from one that ended, so the card can't get stuck raised.
    @GestureState private var touching = false
    static let pose = UserDefaults.standard.string(forKey: "pose")

    init(target: FlickTarget) {
        self.target = target
        let ref = target.source == .stremio && target.send == nil ? target.item.stremioRef : nil
        let posed = ["lift", "flickdemo"].contains(Self.pose)
        // A card that already names its episode, from Continue watching or a re-flick, needs no episode picked.
        let ready = target.ready && (ref?.type == "movie" || ref?.video != nil)
        _step = State(initialValue: ref == nil || posed || ready ? .flick : ref?.type == "series" && ref?.video == nil ? .episodes : .streams)
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
    var progress: CGFloat { arrived && !flown ? min(1.2, max(0, -cardY) / reach) : 0 }
    var charge: CGFloat { flown || landed ? 1 : min(1, progress * 1.25) }
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
        // The system's own bar, so on the Duo back, next and close sit on the side like everywhere else.
        NavigationStack {
            GeometryReader { g in
                ZStack {
                    backdrop(g.size)
                    // The TV's screen, one view across the card's step and the controls', so it grows from one to the other.
                    // Under the steps, so the card flies over it on its way in.
                    if step == .flick || step == .control { screenLayer.opacity(arrived ? 1 : 0).transition(slide) }
                    Group {
                        switch step {
                        case .episodes: episodesStep.transition(slide)
                        case .streams: streamsStep.transition(slide)
                        case .flick: flickStep(g.size).transition(slide)
                        // Its screen grows out of the TV (the screen layer above), so the step itself only fades.
                        case .control: controlStep(g.size).transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // In and out with the backdrop: it opens over the app, not as a sheet sliding up.
                    .opacity(arrived ? 1 : 0)
                }
                .coordinateSpace(name: "flick")
            }
            // In with the backdrop, and out with it, rather than on the rail before anything else is there.
            .toolbar { if arrived { bar } }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .containerBackground(.clear, for: .navigation)
        }
        .preferredColorScheme(.dark)
        // The build's recording only: what the flick is doing, so a frame can be read against the code.
        .overlay(alignment: .bottomLeading) {
            if Self.pose == "flickdemo" {
                Text("step \(step.rawValue) flown \(flown ? 1 : 0) landed \(landed ? 1 : 0) sending \(sending ? 1 : 0) done \(done ? 1 : 0) ok \(successes)")
                    .font(.system(size: 11, design: .monospaced)).padding(6).background(.black.opacity(0.7)).foregroundStyle(.yellow)
            }
        }
        // Picked up, each quarter of the way, the hit on the TV.
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: lifted) { _, now in now }
        .sensoryFeedback(trigger: detent) { old, new in new > old && lifted ? .impact(flexibility: .rigid, intensity: 0.35 + 0.18 * Double(new)) : nil }
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: impacts)
        .task {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { arrived = true }
            // The app behind takes on the picked thing's colour too, and gets its own back after.
            if priorMood == nil { priorMood = .some(model.mood) }
            let art = item.art
            Task { if let u = URL(string: art), let c = await ImageStore.shared.band(u), !flown || step == .control { model.mood = c } }
            if Self.pose == "flickdemo" { Task { await demo() } }
            // Side by side, so a slow description doesn't hold up the streams.
            async let details: Void = loadMeta()
            if target.ready { await pickBest() }
            else if step == .streams && streams.isEmpty { await findStreams() }
            await details
        }
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
        }
        .ignoresSafeArea()
        .opacity(arrived ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: episode)
    }

    @ToolbarContentBuilder var bar: some ToolbarContent {
        if let previous {
            ToolbarItem(placement: .navigation) { Button { go(previous) } label: { Label("Back", systemImage: "chevron.left").opacity(arrived ? 1 : 0) } }
        }
        // Only back to an episode already chosen. On the streams, "Choose on the TV" is the way on without one.
        if let next, step == .episodes {
            ToolbarItem(placement: .primaryAction) { Button { go(next) } label: { Label("Next", systemImage: "chevron.right").opacity(arrived ? 1 : 0) } }
        }
        ToolbarItem(placement: .cancellationAction) {
            // While anything is still on its way to the TV, the X stops it, on the controls too. Once it's there, a tick.
            let stops = flown && (step != .control || sending)
            // Its label follows arrived's spring, so it fades in and out with the backdrop rather than popping on the rail.
            Button { stops ? callOff() : leave() } label: { Label(stops ? "Stop" : step == .control ? "Done" : "Close", systemImage: stops || step != .control ? "xmark" : "checkmark").opacity(arrived ? 1 : 0) }
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
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(selected ? AnyShapeStyle(TVLook.accent) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
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
                Button("No streams found. Try again") { Task { await findStreams() } }
                    .font(.subheadline.weight(.medium)).tint(TVLook.accent).frame(maxWidth: .infinity).padding(.top, 22)
            }
            let qualities = ["1080p", "4K", "720p", "480p"].filter { q in streams.contains { $0.quality == q } }
            if qualities.count > 1 {
                Chips(options: (["All"] + qualities).map { ($0, $0) }, selected: $streamFilter).padding(.top, 6)
            }
            let shown = streams.filter { streamFilter == "All" || $0.quality == streamFilter }
            // Best is the top one that hasn't already failed to start.
            let best = streamFilter == "All" ? streams.first { !failedTokens.contains($0.token) } : nil
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                streamRow(s, best: s == best, failed: failedTokens.contains(s.token)).transition(arriving(i))
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
    func streamRow(_ s: StremioStream, best: Bool, failed: Bool) -> some View {
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
                if !s.details.isEmpty { Text(s.details).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1) }
                // The file's own name tells versions apart, but one line of it is enough.
                if !s.description.isEmpty { Text(s.description).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
            }
            .multilineTextAlignment(.leading)
        }
        .disabled(failed)
        .opacity(failed ? 0.45 : 1)
    }
    func findStreams() async {
        guard let ref = item.stremioRef else { return }
        findingStreams = true; noStreams = false
        lookups += 1
        let mine = lookups
        // Only the newest lookup decides when the spinner stops.
        defer { if mine == lookups { findingStreams = false } }
        // The episode picked, else the one the card was already on, before its details have come.
        let video = episode?.id ?? ref.video ?? ref.imdb
        let term = video.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? video
        struct Answer: Decodable { let streams: [StremioStream] }
        let d = await TVBridge.data(TVBridge.url("/api/tv/streams?type=\(ref.type)&id=\(ref.imdb)&video=\(term)"), timeout: 25)
        // These tokens play the episode they were asked for, so an answer for another one is thrown away.
        guard (episode?.id ?? ref.video ?? ref.imdb) == video, mine == lookups else { return }
        guard let d, let a = try? JSONDecoder().decode(Answer.self, from: d), !a.streams.isEmpty else { noStreams = true; return }
        withAnimation { streams = a.streams }
    }

    // Last: nothing left to decide, just the TV and the card in your hand.
    @ViewBuilder func flickStep(_ size: CGSize) -> some View {
        let tall = min(size.height * 0.5, 420), width = source == .mint ? min(250, tall - 60) : min(210, (tall - 56) / 1.5)
        let column = VStack(spacing: 0) {
            tvSlot.padding(.top, 20)
            status.padding(.top, 16).padding(.horizontal, 30)
            Spacer(minLength: 14)
            hint.padding(.bottom, 12)
            card(width)
            .padding(.bottom, 22)
        }
        // Unfolded, the TV and the card keep to the middle of one side, clear of the fold, and the other side is left
        // empty: this screen is only ever the TV and the card.
        if panes { FoldSplit { column.frame(maxWidth: .infinity) } right: { Color.clear } } else { column }
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
        let locked = sending && handedOver
        let picture = VStack(spacing: 18) {
            // The screen's place. The screen itself is drawn over it, grown out of the TV the card landed in.
            Color.clear.frame(width: w, height: w * 9 / 16)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { f in
                    // The first time it's known, the screen grows to it; after that it just follows.
                    if controlSlot == .zero { withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { controlSlot = f } } else { controlSlot = f }
                }
            VStack(spacing: 4) {
                Text(isMusic ? (music?.title ?? shown.title) : (session?.description.first ?? shown.title)).font(.title2.weight(.bold)).lineLimit(2)
                Text(isMusic ? (music.map { "\($0.artist) · \($0.album)" } ?? shown.subtitle) : (session?.description.dropFirst().first ?? shown.subtitle))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .contentTransition(.opacity)
            .opacity(controlsIn ? 1 : 0)
            // Where it's got to, for a film or a song alike. Its place is kept until the TV says, so nothing below jumps.
            // Handed over before the film is going: what the TV is doing goes in the middle of the bar.
            let waiting = sending ? (phase ?? "Loading the stream") : nil
            Group {
                if onTV { EmptyView() }
                else if let session, !isMusic { VideoProgress(session: session, note: waiting, locked: locked).frame(maxWidth: w) }
                else if isMusic, let music, music.duration > 0 { MusicProgress(music: music).frame(maxWidth: w) }
                else { ProgressPlaceholder(note: waiting).frame(maxWidth: w) }
            }
            .opacity(controlsIn ? 1 : 0)
        }
        let remote = Button { model.tab = 0; leave() } label: { Label("Remote", systemImage: "av.remote").font(.subheadline.weight(.semibold)).padding(.horizontal, 18).frame(height: 44) }
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
                            PlayKey(playing: session?.playing, tint: .white, size: 74)
                            SeekButton(icon: "goforward.10", label: "Forward 10 seconds", step: 1)
                        }
                        .opacity(locked ? 0.4 : 1).allowsHitTesting(!locked)
                    } else {
                        GlassKey(icon: "backward.fill", label: "Previous", key: "previous", size: 56)
                        PlayKey(playing: isMusic ? music?.playing : session?.playing, tint: .white, size: 74)
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
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 44)
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
        else { Art(url: screenURL) { $0.resizable().aspectRatio(contentMode: fill ? .fill : .fit) } placeholder: { fill ? Color(white: 0.15) : Color.clear } }
    }
    // The TV's screen, small while the card is in the hand, grown on the control step. Its picture crossfades within the
    // one frame: the poster filling the small screen, then the whole poster on a blurred copy of itself.
    var screenLayer: some View {
        // Big only once the control step's place is known: until then, nothing changes on the small TV. Unfolded, the far
        // pane's place comes a few frames after the step does.
        let big = step == .control && controlSlot != .zero
        let slot = big ? controlSlot : tvFrame
        let radius: CGFloat = big ? 16 : 9
        let lean = big ? 0 : charge
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black.opacity(0.55))
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
                    Color.black
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
            TVFlash(trigger: successes)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: big)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .frame(width: slot.width, height: slot.height)
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(big ? 0.25 : 0.3 + 0.5 * charge), lineWidth: big ? 1 : 1.5) }
        .shadow(color: TVLook.accent.opacity(big ? 0.45 : 0.75 * charge), radius: big ? 26 : 10 + 18 * charge)
        .overlay { TVRipple(trigger: impacts, big: slot.width > 200) }
        .overlay { TVRipple(trigger: successes, big: slot.width > 200) }
        // It leans in to meet the card, then gives as the card hits.
        .scaleEffect(1 + 0.09 * lean)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: impacts) { c, s in c.scaleEffect(s) } keyframes: { _ in
            CubicKeyframe(0.92, duration: 0.08)
            SpringKeyframe(1, duration: 0.6, spring: Spring(response: 0.38, dampingRatio: 0.42))
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
    // What the TV is doing with it, under the TV.
    var status: some View {
        HStack(spacing: 7) {
            if sending || pickingBest { ProgressView().controlSize(.small).tint(.white).transition(.scale.combined(with: .opacity)) }
            else if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(TVLook.accent).transition(.scale(scale: 0.3).combined(with: .opacity)) }
            if let line = sending ? (phase ?? "Starting on the TV") : pickingBest ? "Finding the best stream" : note {
                Text(line).multilineTextAlignment(.center).lineLimit(2).contentTransition(.opacity).id(line).transition(.opacity)
            }
        }
        .font(.footnote.weight(.semibold))
        .frame(minHeight: 22)
        .animation(.spring(response: 0.38, dampingFraction: 0.7), value: sending || pickingBest)
        .animation(.spring(response: 0.38, dampingFraction: 0.6), value: done)
        .animation(.easeOut(duration: 0.25), value: note)
        .animation(.easeOut(duration: 0.25), value: phase)
    }
    var hint: some View {
        VStack(spacing: 4) {
            Image(systemName: "chevron.up").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                .phaseAnimator([CGFloat(0), -5]) { c, y in c.offset(y: y) } animation: { _ in .easeInOut(duration: 0.8) }
            Text("Flick up to play on the TV").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            if let stream { Text([stream.name, stream.details].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).lineLimit(1).padding(.horizontal, 30) }
        }
        // Gone as soon as the card leaves the hand, rather than showing through behind it.
        .opacity(lifted || progress > 0.02 || flown ? 0 : calm)
        .animation(.easeOut(duration: 0.15), value: lifted || progress > 0.02 || flown)
    }
    // Where the TV's screen sits on this step, and where the card aims: measured here, with nothing moving it, and drawn
    // by the screen layer above.
    var tvSlot: some View {
        VStack(spacing: 5) {
            Color.clear.frame(width: 168, height: 94.5)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { tvFrame = $0 }
            Capsule().fill(.white.opacity(0.3)).frame(width: 50, height: 3)
        }
        .accessibilityHidden(true)
    }
    func card(_ width: CGFloat) -> some View {
        // Closing on the TV it draws in, as anything does going away from you, and in flight it becomes the TV's picture.
        let near = min(1, progress)
        let size = flown ? tvFrame.height / max(cardFrame.height, 1) : (lifted ? 1.06 : 1) * (1 - 0.38 * near * near)
        let x = flown ? tvFrame.midX - cardFrame.midX : drag.width * 0.85
        let y = flown ? tvFrame.midY - cardFrame.midY : cardY
        return MediaCard(item: shown, source: source, width: width, image: target.image)
            .shadow(color: .black.opacity(lifted ? 0.55 : 0.45), radius: lifted ? 30 : 18, y: lifted ? 22 : 10)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lifted)
            .rotationEffect(.degrees(lean))
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.62), value: lean)
            .rotation3DEffect(.degrees(Double(flown ? 1 : near) * 18), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
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
                    guard !flown else { return }
                    drag = v.translation
                    lean = max(-12, min(12, Double(v.velocity.width) / 150 + Double(v.translation.width) / 45))
                    let d = min(3, Int(max(0, -v.translation.height) / reach * 4))
                    if d != detent { detent = d }
                }
                .onEnded { v in
                    if v.translation.height < -70 || v.predictedEndTranslation.height < -150 { send(flicked: v.velocity) }
                    else if v.translation.height > 110 { leave() }
                    else { settle() }
                })
            .onChange(of: touching) { _, on in if !on && !flown { settle() } }
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
    func demo() async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        demoHeld = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        for i in 1...45 {
            let t = CGFloat(i) / 45
            drag = CGSize(width: 36 * sin(t * .pi), height: -0.55 * reach * t * t)
            lean = Double(cos(t * .pi)) * 6
            detent = min(3, Int(t * t * 0.55 * 4))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        demoHeld = false
        send(flicked: CGSize(width: -60, height: -1900))
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
    func leave() {
        if let prior = priorMood { model.mood = prior }
        withAnimation(.easeOut(duration: 0.2)) { arrived = false }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            model.closeFlick()
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
            flown = false; landed = false; done = false; note = nil; drag = .zero; lean = 0; detent = 0
            step = .flick
        }
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
    // What the TV is doing while it gets going, for the line under it.
    static func phase(of s: TVStatus, video: Bool) -> String? {
        guard s.online else { return nil }
        if s.screen == "asleep" || s.screen == "screensaver" { return "Waking the TV" }
        guard video else { return nil }
        if let p = s.session, p.pkg == "com.stremio.one" { return p.playing ? nil : "Loading the stream" }
        if s.app == "com.stremio.one" { return "Opening Stremio" }
        return nil
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
        note = nil; detent = 0
        // Leaves at the speed it was thrown, so there's no seam between the finger and the flight.
        let from = cardY, to = tvFrame.midY - cardFrame.midY
        let speed = max(0, min(9, velocity.height / min(to - from, -1)))
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 300, damping: 30, initialVelocity: speed)) { flown = true; lean = 0 }
        phase = nil
        let video = source == .stremio && target.send == nil
        flight = Task {
            // The TV takes the card as it arrives.
            try? await Task.sleep(nanoseconds: 230_000_000)
            impacts += 1
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { landed = true; sending = true }
            // Thrown before the best stream was found: it goes as soon as it is.
            while pickingBest && !Task.isCancelled { try? await Task.sleep(nanoseconds: 150_000_000) }
            let order = order
            // No silent wait: the line under the TV follows what it's doing. Asked of the Mac directly, not through the
            // app's model, so the pages behind don't redraw under the flick each time. A stream takes the TV about ten
            // seconds, so once Stremio's player is up with this film, playing or not, the controls take over, and the
            // rest of the wait shows on the big screen.
            let early = order.0 == "play-stream"
            askedRestart = order.1["restart"] as? Bool == true
            let watch = Task {
                var cleared = false
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, let s = await TVBridge.status(timeout: 5), !Task.isCancelled else { continue }
                    let next = Self.phase(of: s, video: video)
                    if next != phase { phase = next }
                    let player = s.session.flatMap { $0.pkg == "com.stremio.one" ? $0 : nil }
                    // The Mac restarts Stremio first, so a player seen after none was is this one; before that, only by its title.
                    if player == nil { cleared = true }
                    guard early, !handedOver, let player, cleared || isThisFilm(player) else { continue }
                    // Long enough to read where it's got to, then on to the controls.
                    if phase == nil { phase = "Loading the stream" }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if !Task.isCancelled, sending, step == .flick { handOver() }
                }
            }
            do {
                // Longer than the bridge can take to wake the TV, restart Stremio and see the player start.
                let answer = try await TVBridge.post(order.0, order.1, timeout: 60)
                watch.cancel()
                target.sent?()
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                // Asked to start over and it couldn't: the control screen offers it.
                if (try? JSONSerialization.jsonObject(with: answer) as? [String: Any])?["restarted"] as? Bool == false { offerStartOver = true }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { sending = false; phase = nil; done = true; note = source == .mint || stream != nil || item.stremioRef == nil || target.send != nil ? "Playing on the TV" : "On the TV. Pick a stream with the remote." }
                successes += 1
                remember()
                // Already on the controls: the flash on the big screen is the yes.
                if handedOver { Task { try? await Task.sleep(nanoseconds: 400_000_000); await model.load() }; return }
                // Nothing else redraws while the TV says yes: the whole app catching up at that moment stalled the tick.
                try? await Task.sleep(nanoseconds: 950_000_000)
                handOver()
            } catch {
                watch.cancel()
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
    // Whether a Stremio player is the film just sent, by its title.
    func isThisFilm(_ p: TVStatus.Session) -> Bool {
        guard let now = p.description.first, !now.isEmpty else { return false }
        return now.localizedCaseInsensitiveContains(item.title) || item.title.localizedCaseInsensitiveContains(now)
    }
    // The hand-over: the TV the card landed in grows into the control screen, and its buttons settle in below.
    func handOver() {
        guard step == .flick, !handedOver else { return }
        handedOver = true
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
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
        drag = .zero
        let gone = error is TVBridge.Gone, stuck = error is TVBridge.DidNotStart
        withAnimation(.spring(response: 0.55, dampingFraction: 0.66)) {
            sending = false; phase = nil; landed = false; flown = false
            note = gone ? "That stream has gone. Pick again." : stuck ? "That stream didn’t start" : "The TV didn’t get that"
        }
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
                            CubicKeyframe(big ? 1.08 + CGFloat(i) * 0.04 : 1.6 + CGFloat(i) * 0.25, duration: 0.75)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(configuration.isPressed ? .easeOut(duration: 0.18).delay(0.06) : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
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
