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
    var id: String { token }
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
    enum Step: Int { case episodes, streams, flick }
    let target: FlickTarget
    @State private var step: Step
    @State private var forward = true
    @State private var meta: StremioMeta?
    @State private var season = 0
    @State private var episode: StremioEpisode?
    @State private var streams: [StremioStream] = []
    @State private var stream: StremioStream?
    @State private var findingStreams = false
    @State private var noStreams = false
    @State private var cardFrame = CGRect.zero
    @State private var arrived = false
    @State private var flown = false
    @State private var landed = false
    @State private var note: String?
    @State private var hop = false
    @State private var exitX: CGFloat = 0
    // Follows the finger exactly, with nothing in between.
    @State private var drag = UserDefaults.standard.string(forKey: "pose") == "lift" ? CGSize(width: 18, height: -300) : .zero
    // Tells a touch the system took away from one that ended, so the card can't get stuck raised.
    @GestureState private var touching = false

    init(target: FlickTarget) {
        self.target = target
        let ref = target.source == .stremio && target.send == nil ? target.item.stremioRef : nil
        let posed = UserDefaults.standard.string(forKey: "pose") == "lift"
        _step = State(initialValue: ref == nil || posed ? .flick : ref?.type == "series" ? .episodes : .streams)
    }
    var item: MediaItem { target.item }
    var source: MediaSource { target.source }
    var isSeries: Bool { item.stremioRef?.type == "series" }
    var armed: Bool { drag.height < -80 }
    var cardY: CGFloat {
        if flown { return -(cardFrame.maxY + cardFrame.height * 0.7) }
        if !arrived { return 420 }
        if hop { return -22 }
        return drag.height < 0 ? drag.height : drag.height * 0.22
    }
    // How far the card has come towards the top edge: 0 in the hand, 1 with its top at the edge.
    var nearEdge: CGFloat { arrived ? min(1.3, max(0, -cardY) / max(cardFrame.minY, 1)) : 0 }
    var charge: CGFloat { landed ? 1 : min(1, nearEdge * 1.3) }
    // Everything else steps back while the card is in the air.
    var calm: Double { arrived ? 1 - 0.85 * min(1, nearEdge * 1.4) : 0 }
    var shown: MediaItem {
        guard let e = episode else { return item }
        return MediaItem(title: item.title, subtitle: "S\(e.season) E\(e.episode) · \(e.name)", art: item.art, id: item.id, kind: item.kind)
    }
    var seasons: [Int] { Array(Set((meta?.episodes ?? []).map(\.season))).sorted() }
    var previous: Step? {
        switch step {
        case .episodes: return nil
        case .streams: return isSeries ? .episodes : nil
        case .flick: return target.send != nil || source != .stremio || item.stremioRef == nil || flown ? nil : .streams
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
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = to }
        if to == .streams && streams.isEmpty { Task { await findStreams() } }
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                backdrop(g.size)
                Group {
                    switch step {
                    case .episodes: episodesStep.transition(slide)
                    case .streams: streamsStep.transition(slide)
                    case .flick: flickStep(g.size).transition(slide)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                bar
            }
            .coordinateSpace(name: "flick")
        }
        .preferredColorScheme(.dark)
        // Its own way in and out, so nothing slides over the card, and the app stays faintly there behind it.
        .presentationBackground(.clear)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: touching) { _, now in now }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: armed) { _, now in now && touching }
        .task {
            withAnimation(.easeOut(duration: 0.22)) { arrived = true }
            await loadMeta()
            if step == .streams && streams.isEmpty { await findStreams() }
        }
    }
    var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    // See-through, tinted by whatever is chosen, and it comes up clear as the card goes.
    func backdrop(_ size: CGSize) -> some View {
        ZStack {
            Group {
                if let image = target.image { image.resizable().scaledToFill() }
                else {
                    Art(url: URL(string: episode?.thumb.isEmpty == false ? episode!.thumb : item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .id(episode?.id ?? item.art)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .blur(radius: landed ? 18 : 34)
            .scaleEffect(landed ? 1.14 : 1.05)
            .opacity(0.5 + 0.45 * charge)
            Rectangle().fill(.ultraThinMaterial).opacity(1 - 0.75 * charge)
            Color.black.opacity(0.38 - 0.2 * charge)
        }
        .ignoresSafeArea()
        .opacity(arrived ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: episode)
    }

    var bar: some View {
        VStack {
            HStack(spacing: 8) {
                if let previous { barButton("chevron.left", "Back") { go(previous) } }
                if let next, step != .flick { barButton("chevron.right", "Next") { go(next) } }
                Spacer()
                barButton("xmark", "Close") { leave() }.disabled(flown)
            }
            .padding(14)
            Spacer()
        }
        .opacity(calm)
    }
    func barButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 42, height: 42).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel(label)
    }

    var heading: some View {
        HStack(alignment: .top, spacing: 14) {
            Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                .frame(width: 74, height: 111).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.title3.weight(.bold)).lineLimit(2)
                if let about = meta?.about ?? item.about, !about.isEmpty {
                    Text(about).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                }
                if let slug = item.slug, !slug.isEmpty {
                    Button { model.tick(); model.post("film", ["slug": slug], say: "Opening in Letterboxd"); leave() } label: {
                        Label("Letterboxd", systemImage: "film")
                    }.font(.footnote.weight(.medium)).tint(TVLook.accent).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }
    func row<L: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                label()
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(selected ? AnyShapeStyle(TVLook.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.white.opacity(selected ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressCard())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    func page<C: View>(@ViewBuilder content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(.horizontal, 20).padding(.top, 70).padding(.bottom, 24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }

    // First step of a series: which episode.
    var episodesStep: some View {
        page {
            heading
            if seasons.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { s in
                            Button { model.tick(); withAnimation(.snappy) { season = s } } label: {
                                Text("Season \(s)").font(.footnote.weight(.semibold)).padding(.horizontal, 13).frame(height: 32)
                                    .background(season == s ? AnyShapeStyle(TVLook.accent) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
                                    .foregroundStyle(season == s ? .black : .white)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 6)
                ForEach((meta?.episodes ?? []).filter { $0.season == season }) { e in
                    row(selected: episode == e) {
                        if episode != e { episode = e; stream = nil; streams = []; noStreams = false }
                        go(.streams)
                    } label: {
                        Art(url: URL(string: e.thumb)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                            .frame(width: 82, height: 46).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text("\(e.episode). \(e.name)").font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
            }
        }
    }
    // Next: which stream, or leave that to the TV.
    var streamsStep: some View {
        page {
            heading
            if let e = episode { Text("Season \(e.season), episode \(e.episode): \(e.name)").font(.subheadline.weight(.semibold)).padding(.top, 4) }
            row(selected: false) { stream = nil; go(.flick) } label: {
                Image(systemName: "tv").foregroundStyle(TVLook.accent).frame(width: 28)
                Text("Choose on the TV").font(.subheadline.weight(.semibold))
            }
            .padding(.top, 4)
            if findingStreams {
                HStack(spacing: 10) { ProgressView(); Text("Asking your addons…").font(.subheadline).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity).padding(.top, 22)
            } else if noStreams {
                Button("No streams found. Try again") { Task { await findStreams() } }
                    .font(.subheadline.weight(.medium)).tint(TVLook.accent).frame(maxWidth: .infinity).padding(.top, 22)
            }
            ForEach(streams) { s in
                row(selected: stream == s) { stream = s; go(.flick) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name.isEmpty ? s.addon : s.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if !s.description.isEmpty { Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        if !s.name.isEmpty { Text(s.addon).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                    .multilineTextAlignment(.leading)
                }
            }
        }
    }
    func findStreams() async {
        guard let ref = item.stremioRef else { return }
        findingStreams = true; noStreams = false
        defer { findingStreams = false }
        let chosen = episode
        let video = chosen?.id ?? ref.imdb
        let term = video.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? video
        struct Answer: Decodable { let streams: [StremioStream] }
        let d = await TVBridge.data(TVBridge.url("/api/tv/streams?type=\(ref.type)&id=\(ref.imdb)&video=\(term)"), timeout: 25)
        // These tokens play the episode they were asked for, so an answer for another one is thrown away.
        guard episode == chosen else { return }
        guard let d, let a = try? JSONDecoder().decode(Answer.self, from: d), !a.streams.isEmpty else { noStreams = true; return }
        withAnimation { streams = a.streams }
    }

    // Last: nothing left to decide, just the TV and the card in your hand.
    func flickStep(_ size: CGSize) -> some View {
        let tall = min(size.height * 0.5, 420), width = source == .mint ? min(250, tall - 60) : min(210, (tall - 56) / 1.5)
        return VStack(spacing: 0) {
            tv.padding(.top, 56)
            Spacer(minLength: 14)
            VStack(spacing: 4) {
                Image(systemName: "chevron.up").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    .phaseAnimator([CGFloat(0), -5]) { c, y in c.offset(y: y) } animation: { _ in .easeInOut(duration: 0.8) }
                Text(note ?? "Flick up to play on the TV").font(.footnote.weight(.medium)).foregroundStyle(note == nil ? .secondary : .primary).contentTransition(.opacity)
                if let stream, note == nil { Text(stream.name.isEmpty ? stream.addon : stream.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).padding(.horizontal, 30) }
            }
            .opacity(note == nil ? calm : 1)
            .padding(.bottom, 12)
            card(width)
            .padding(.bottom, 22)
        }
    }
    var tv: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.55))
                if landed, let image = target.image {
                    image.resizable().scaledToFill().transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if landed {
                    Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.15) }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 168, height: 94.5)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.3 + 0.5 * charge), lineWidth: 1.5) }
            .shadow(color: TVLook.accent.opacity(0.7 * charge), radius: 24)
            // A ring goes out from the screen as the card arrives.
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TVLook.accent, lineWidth: 2)
                    .scaleEffect(landed ? 1.55 : 1).opacity(landed ? 0 : (flown ? 0.9 : 0))
                    .animation(.easeOut(duration: 0.65), value: landed)
            }
            .scaleEffect(1 + 0.05 * charge)
            Capsule().fill(.white.opacity(0.3)).frame(width: 50, height: 3)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: landed)
        .accessibilityHidden(true)
    }
    func card(_ width: CGFloat) -> some View {
        MediaCard(item: shown, source: source, width: width, image: target.image)
            .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
            // It grows and leans as it nears the edge, on its way off the phone and towards the TV.
            .rotation3DEffect(.degrees(Double(nearEdge) * 11), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.45)
            .scaleEffect(1 + 0.55 * pow(nearEdge, 1.25))
            .rotationEffect(.degrees(Double(flown ? exitX : drag.width) / 22))
            .offset(x: flown ? exitX : drag.width * 0.6, y: cardY)
            // Where it rests, whatever is moving it: an offset doesn't change this, so it isn't rewritten every frame.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { cardFrame = $0 }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("flick"))
                .updating($touching) { _, on, _ in on = true }
                .onChanged { v in if !flown { drag = v.translation } }
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
        guard drag != .zero else { return }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        #endif
        withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) { drag = .zero }
    }
    func leave() {
        withAnimation(.easeOut(duration: 0.2)) { arrived = false }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            model.closeFlick()
        }
    }

    func loadMeta() async {
        guard source == .stremio, target.send == nil, let ref = item.stremioRef,
              let d = await TVBridge.data(TVBridge.url("/api/tv/stremio-meta?type=\(ref.type)&id=\(ref.imdb)"), timeout: 15),
              let m = try? JSONDecoder().decode(StremioMeta.self, from: d) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            meta = m
            // A card that's part way through a series starts on that episode.
            episode = m.episodes.first { $0.id == ref.video }
            season = episode?.season ?? m.episodes.first?.season ?? 0
        }
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
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        #endif
        note = nil
        // Leaves at the speed it was thrown, so there's no seam between the finger and the flight.
        let from = cardY, to = -(cardFrame.maxY + cardFrame.height * 0.7)
        let speed = min(0, velocity.height) / min(to - from, -1)
        exitX = max(-90, min(90, drag.width * 0.6 + velocity.width * 0.12))
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 170, damping: 24, initialVelocity: speed)) { flown = true }
        let order = order
        Task {
            // The TV lights as the card passes it.
            try? await Task.sleep(nanoseconds: 170_000_000)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { landed = true }
            do {
                // Longer than the bridge gives a sleeping TV to wake.
                try await TVBridge.post(order.0, order.1, timeout: 30)
                target.sent?()
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                withAnimation { note = source == .mint || stream != nil || item.stremioRef == nil || target.send != nil ? "On the TV" : "On the TV. Pick a stream with the remote." }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                leave()
            } catch {
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                #endif
                drag = .zero
                let gone = error is TVBridge.Gone
                withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { landed = false; flown = false; note = gone ? "That stream has gone. Pick again." : "The TV didn’t get that" }
                // Only a stale stream needs a new list; the choice stands if the TV just didn't answer.
                if gone {
                    stream = nil; streams = []
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    note = nil
                    go(.streams)
                }
            }
        }
    }
}

// Cards give under the finger, as anything you can pick up should.
struct PressCard: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.55), value: configuration.isPressed)
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
        .background { Wall(art: model.status?.music?.art) }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.tick(); model.post("open", ["pkg": source.pkg], say: "Opening \(source.name)") } label: { Label("Open on TV", systemImage: "tv") }
            }
        }
    }
}
