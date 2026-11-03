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
    @Namespace private var screenSpace
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
        _step = State(initialValue: ref == nil || posed ? .flick : ref?.type == "series" ? .episodes : .streams)
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
        // At the card there's nothing left to go back to: the X is all it needs.
        case .flick, .control: return nil
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
                    Group {
                        switch step {
                        case .episodes: episodesStep.transition(slide)
                        case .streams: streamsStep.transition(slide)
                        case .flick: flickStep(g.size).transition(slide)
                        // Its screen grows out of the TV (matched below), so the step itself only fades.
                        case .control: controlStep(g.size).transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // In and out with the backdrop: it opens over the app, not as a sheet sliding up.
                    .opacity(arrived ? 1 : 0)
                }
                .coordinateSpace(name: "flick")
            }
            .toolbar { bar }
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
            if step == .streams && streams.isEmpty { await findStreams() }
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
            ToolbarItem(placement: .navigation) { Button { go(previous) } label: { Label("Back", systemImage: "chevron.left") } }
        }
        // Only back to an episode already chosen. On the streams, "Choose on the TV" is the way on without one.
        if let next, step == .episodes {
            ToolbarItem(placement: .primaryAction) { Button { go(next) } label: { Label("Next", systemImage: "chevron.right") } }
        }
        ToolbarItem(placement: .cancellationAction) {
            Button { flown && step != .control ? callOff() : leave() } label: { Label(step == .control ? "Done" : flown ? "Stop" : "Close", systemImage: step == .control ? "checkmark" : "xmark") }
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
                ForEach((meta?.episodes ?? []).filter { $0.season == season }) { e in
                    row(selected: episode == e) {
                        if episode != e { episode = e; stream = nil; streams = []; noStreams = false; streamFilter = "All" }
                        go(.streams)
                    } label: {
                        Art(url: URL(string: e.thumb)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                            .frame(width: 82, height: 46).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text("\(e.episode). \(e.name)").font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
        }
    }
    // Next: which stream, or leave that to the TV.
    var streamsStep: some View {
        page {
            if let e = episode { Text("Season \(e.season), episode \(e.episode): \(e.name)").font(.subheadline.weight(.semibold)).padding(.top, 4) }
            row(selected: false) { stream = nil; go(.flick) } label: {
                Image(systemName: "tv").foregroundStyle(TVLook.accent).frame(width: 28)
                Text("Choose on the TV").font(.subheadline.weight(.semibold))
            }
            .padding(.top, 4)
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
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                streamRow(s, best: i == 0 && streamFilter == "All").transition(arriving(i))
            }
        }
    }
    // Rows come in one after another, a beat apart.
    func arriving(_ i: Int) -> AnyTransition {
        let spring = Animation.spring(response: 0.45, dampingFraction: 0.85).delay(Double(min(i, 8)) * 0.035)
        return .asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(y: 14)).animation(spring), removal: .opacity)
    }
    func streamRow(_ s: StremioStream, best: Bool) -> some View {
        row(selected: stream == s) { stream = s; go(.flick) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.name.isEmpty ? s.addon : s.name).font(.subheadline.weight(.bold)).lineLimit(1)
                    // The list comes best first, for this box and what's being watched.
                    if best {
                        Text("Best").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(TVLook.accent, in: Capsule()).foregroundStyle(.black)
                    }
                }
                if !s.details.isEmpty { Text(s.details).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1) }
                // The file's own name tells versions apart, but one line of it is enough.
                if !s.description.isEmpty { Text(s.description).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
            }
            .multilineTextAlignment(.leading)
        }
    }
    func findStreams() async {
        guard let ref = item.stremioRef else { return }
        findingStreams = true; noStreams = false
        lookups += 1
        let mine = lookups
        // Only the newest lookup decides when the spinner stops.
        defer { if mine == lookups { findingStreams = false } }
        let chosen = episode
        let video = chosen?.id ?? ref.imdb
        let term = video.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? video
        struct Answer: Decodable { let streams: [StremioStream] }
        let d = await TVBridge.data(TVBridge.url("/api/tv/streams?type=\(ref.type)&id=\(ref.imdb)&video=\(term)"), timeout: 25)
        // These tokens play the episode they were asked for, so an answer for another one is thrown away.
        guard episode == chosen, mine == lookups else { return }
        guard let d, let a = try? JSONDecoder().decode(Answer.self, from: d), !a.streams.isEmpty else { noStreams = true; return }
        withAnimation { streams = a.streams }
    }

    // Last: nothing left to decide, just the TV and the card in your hand.
    @ViewBuilder func flickStep(_ size: CGSize) -> some View {
        let tall = min(size.height * 0.5, 420), width = source == .mint ? min(250, tall - 60) : min(210, (tall - 56) / 1.5)
        let column = VStack(spacing: 0) {
            tv.padding(.top, 20)
            status.padding(.top, 16).padding(.horizontal, 30)
            Spacer(minLength: 14)
            hint.padding(.bottom, 12)
            card(width)
            .padding(.bottom, 22)
        }
        // Unfolded, the TV and the card keep to one side, clear of the fold, and the other side is left empty:
        // this screen is only ever the TV and the card.
        if panes { FoldSplit { column } right: { Color.clear } } else { column }
    }
    // Sent with "Choose on the TV": Stremio is showing its streams, and only the remote can pick one.
    var choosingOnTV: Bool {
        source == .stremio && stream == nil && target.send == nil && item.stremioRef != nil && model.status?.session.map { $0.pkg == "com.stremio.one" && $0.position != nil } != true
    }
    // After the flick: the TV's screen, grown, with what's playing on it and the controls for it.
    @ViewBuilder func controlStep(_ size: CGSize) -> some View {
        let w = panes ? min(size.width / 2 - 48, 420) : min(size.width - 48, 520)
        // Until the TV reports what was just sent, what it reports is what played before, so the flicked thing stands in.
        let sentTo = source == .mint ? "com.codex.musicwebtv" : "com.stremio.one"
        let reported = model.status?.session
        let session = reported?.pkg == sentTo ? reported : nil
        let rawMusic = model.nowMusic
        let music = source == .mint && (target.send != nil || rawMusic?.title.caseInsensitiveCompare(item.title) == .orderedSame || reported?.pkg == sentTo) ? rawMusic : nil
        let isMusic = source == .mint
        let picture = VStack(spacing: 18) {
            controlScreen(w)
            VStack(spacing: 4) {
                Text(isMusic ? (music?.title ?? shown.title) : (session?.description.first ?? shown.title)).font(.title2.weight(.bold)).lineLimit(2)
                Text(isMusic ? (music.map { "\($0.artist) · \($0.album)" } ?? shown.subtitle) : (session?.description.dropFirst().first ?? shown.subtitle))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .contentTransition(.opacity)
            .opacity(controlsIn ? 1 : 0)
            // Where it's got to, for a film or a song alike, once the TV says.
            Group {
                if let session, !isMusic, session.position != nil { VideoProgress(session: session).frame(maxWidth: w) }
                else if isMusic, let music, music.duration > 0 { MusicProgress(music: music).frame(maxWidth: w) }
            }
            .opacity(controlsIn ? 1 : 0)
        }
        let controls = VStack(spacing: 18) {
            if choosingOnTV {
                // The TV is on Stremio's list of streams: what's needed now is the pad to pick one with.
                Text("Pick a stream with the remote").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                DPad().frame(width: 220, height: 220)
                GlassKey(icon: "chevron.left", label: "Back", key: "back", size: 50)
            } else {
                HStack(spacing: 22) {
                    if source == .stremio {
                        SeekButton(icon: "gobackward.10", label: "Back 10 seconds", forward: false)
                        PlayKey(playing: session?.playing, tint: .white, size: 74)
                        SeekButton(icon: "goforward.10", label: "Forward 10 seconds", forward: true)
                    } else {
                        GlassKey(icon: "backward.fill", label: "Previous", key: "previous", size: 56)
                        PlayKey(playing: isMusic ? music?.playing : session?.playing, tint: .white, size: 74)
                        GlassKey(icon: "forward.fill", label: "Next", key: "next", size: 56)
                    }
                }
            }
            Button { model.tab = 0; leave() } label: { Label("Remote", systemImage: "av.remote").font(.subheadline.weight(.semibold)).padding(.horizontal, 18).frame(height: 44) }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
        }
        .opacity(controlsIn ? 1 : 0)
        .offset(y: controlsIn ? 0 : 16)
        Group {
            // Unfolded, the screen one side of the fold and its controls the other.
            if panes {
                FoldSplit {
                    ScrollView { picture.padding(.horizontal, 24).padding(.vertical, 24).frame(maxWidth: .infinity) }
                } right: {
                    ScrollView { controls.padding(.horizontal, 24).padding(.vertical, 24).frame(maxWidth: .infinity) }.defaultScrollAnchor(.center)
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) { picture; controls }
                        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .environment(\.keysInScroll, true)
        // The buttons settle in from just below once the screen has grown into place.
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.88).delay(0.12)) { controlsIn = true } }
        // Kept current while it's open, so the bar and the buttons follow the TV.
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000); await model.load() } }
    }
    // The TV's screen, grown: the whole picture on a blurred copy of itself, as a poster sits on a TV's screen, never a
    // slice of it. It is the same screen the card flew into, grown into place.
    func controlScreen(_ w: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.6))
            Color.clear.overlay {
                if let image = target.image { image.resizable().scaledToFill() }
                else { Art(url: URL(string: episode?.thumb.isEmpty == false ? episode!.thumb : item.art)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.15) } }
            }
            .clipped()
            .blur(radius: 24).opacity(0.7)
            Group {
                if let image = target.image { image.resizable().scaledToFit() }
                else { Art(url: URL(string: episode?.thumb.isEmpty == false ? episode!.thumb : item.art)) { $0.resizable().scaledToFit() } placeholder: { Color.clear } }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1) }
        // Starts as the small TV the card landed in, and grows to here.
        .matchedGeometryEffect(id: "screen", in: screenSpace)
        .frame(width: w, height: w * 9 / 16)
        .shadow(color: TVLook.accent.opacity(0.45), radius: 26)
    }
    func controlButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button { model.tick(); action() } label: {
            Image(systemName: icon).font(.system(size: 22, weight: .medium)).frame(width: 56, height: 56).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel(label)
    }

    // What the TV is doing with it, under the TV.
    var status: some View {
        HStack(spacing: 7) {
            if sending { ProgressView().controlSize(.small).tint(.white).transition(.scale.combined(with: .opacity)) }
            else if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(TVLook.accent).transition(.scale(scale: 0.3).combined(with: .opacity)) }
            if let line = sending ? "Starting on the TV" : note {
                Text(line).multilineTextAlignment(.center).lineLimit(2).contentTransition(.opacity).id(line).transition(.opacity)
            }
        }
        .font(.footnote.weight(.semibold))
        .frame(minHeight: 22)
        .animation(.spring(response: 0.38, dampingFraction: 0.7), value: sending)
        .animation(.spring(response: 0.38, dampingFraction: 0.6), value: done)
        .animation(.easeOut(duration: 0.25), value: note)
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
    var tv: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.55))
                if landed {
                    // Filling exactly the screen it's given, never more, as that screen grows on the hand-over.
                    Color.clear.overlay {
                        if let image = target.image { image.resizable().scaledToFill() }
                        else { Art(url: URL(string: episode?.thumb.isEmpty == false ? episode!.thumb : item.art)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.15) } }
                    }
                    .clipped()
                    .transition(.scale(scale: 1.3).combined(with: .opacity))
                }
                if sending { TVWaiting().transition(.opacity) }
                if done { TVTick().transition(.scale(scale: 0.5).combined(with: .opacity)) }
                TVFlash(trigger: successes)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            // The same screen as the control step's, so on the hand-over this one grows into that one. Matched inside
            // the fixed frame, so the growing never changes this view's layout or the measure of where the card aims.
            .matchedGeometryEffect(id: "screen", in: screenSpace)
            .frame(width: 168, height: 94.5)
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.3 + 0.5 * charge), lineWidth: 1.5) }
            .shadow(color: TVLook.accent.opacity(0.75 * charge), radius: 10 + 18 * charge)
            .overlay { TVRipple(trigger: impacts) }
            .overlay { TVRipple(trigger: successes) }
            // It leans in to meet the card, then gives as the card hits.
            .scaleEffect(1 + 0.09 * charge)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: impacts) { c, s in c.scaleEffect(s) } keyframes: { _ in
                CubicKeyframe(0.92, duration: 0.08)
                SpringKeyframe(1, duration: 0.6, spring: Spring(response: 0.38, dampingRatio: 0.42))
            }
            Capsule().fill(.white.opacity(0.3)).frame(width: 50, height: 3)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: charge)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: landed)
        // Where the card aims: the screen, at the top of this, measured outside everything that moves it. Measured
        // inside, its own glow would move the target, which moves the glow, and so on without end.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { f in
            // Once it's handing over to the controls the card has landed, and nothing aims at it any more.
            guard !morphing else { return }
            tvFrame = CGRect(x: f.midX - 84, y: f.minY, width: 168, height: 94.5)
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
        guard let d = await TVBridge.data(TVBridge.url("/api/tv/stremio-meta?type=\(ref.type)&id=\(ref.imdb)"), timeout: 15),
              let m = try? JSONDecoder().decode(StremioMeta.self, from: d), !(ref.type == "series" && m.episodes.isEmpty) else { metaFailed = true; return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            meta = m
            // A card that's part way through a series starts on that episode.
            episode = m.episodes.first { $0.id == ref.video }
            season = episode?.season ?? m.episodes.first?.season ?? 0
        }
        // Picked from Continue watching, the episode is already known, so straight on to its streams.
        if episode != nil, step == .episodes { go(.streams) }
    }
    var order: (String, [String: Any]) {
        if let send = target.send { return send }
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
        let order = order
        flight = Task {
            // The TV takes the card as it arrives.
            try? await Task.sleep(nanoseconds: 230_000_000)
            impacts += 1
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { landed = true; sending = true }
            do {
                // Longer than the bridge can take to wake the TV, restart Stremio and see the player start.
                try await TVBridge.post(order.0, order.1, timeout: 60)
                target.sent?()
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { sending = false; done = true; note = source == .mint || stream != nil || item.stremioRef == nil || target.send != nil ? "Playing on the TV" : "On the TV. Pick a stream with the remote." }
                successes += 1
                // Nothing else redraws while the TV says yes: the whole app catching up at that moment stalled the tick.
                try? await Task.sleep(nanoseconds: 950_000_000)
                if !item.art.isEmpty { model.lastArt = item.art; model.lastArtTitle = item.title; model.lastArtPkg = source == .mint ? "com.codex.musicwebtv" : "com.stremio.one" }
                // The hand-over: the TV the card landed in grows into the control screen, and its buttons settle in below.
                morphing = true
                withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = .control }
                Task { try? await Task.sleep(nanoseconds: 500_000_000); await model.load() }
            } catch {
                // Called off with the X: it's already being stopped and closed.
                if Task.isCancelled || cancelled { return }
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                #endif
                drag = .zero
                let gone = error is TVBridge.Gone
                // Back out of the TV and into the hand, with a shake for no.
                withAnimation(.spring(response: 0.55, dampingFraction: 0.66)) { sending = false; landed = false; flown = false; note = gone ? "That stream has gone. Pick again." : "The TV didn’t get that" }
                try? await Task.sleep(nanoseconds: 380_000_000)
                shakes += 1
                // Only a stale stream needs a new list; the choice stands if the TV just didn't answer.
                if gone {
                    stream = nil; streams = []
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    note = nil
                    go(.streams)
                }
            }
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
    struct Wave { var scale: CGFloat = 1; var opacity: Double = 0 }
    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TVLook.accent, lineWidth: 2 - CGFloat(i) * 0.6)
                    .keyframeAnimator(initialValue: Wave(), trigger: trigger) { c, w in c.scaleEffect(w.scale).opacity(w.opacity) } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1, duration: 0.01 + Double(i) * 0.13)
                            CubicKeyframe(1.6 + CGFloat(i) * 0.25, duration: 0.75)
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
