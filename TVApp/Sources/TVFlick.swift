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
    let target: FlickTarget
    @State private var meta: StremioMeta?
    @State private var season = 0
    @State private var episode: StremioEpisode?
    @State private var streams: [StremioStream] = []
    @State private var stream: StremioStream?
    @State private var findingStreams = false
    @State private var noStreams = false
    @State private var tvFrame = CGRect.zero
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

    var item: MediaItem { target.item }
    var source: MediaSource { target.source }
    var armed: Bool { drag.height < -90 }
    var cardY: CGFloat {
        if flown { return -(cardFrame.maxY + cardFrame.height * 0.7) }
        if !arrived { return 420 }
        if hop { return -26 }
        return drag.height < 0 ? drag.height : drag.height * 0.22
    }
    // How far the card has come towards the top edge: 0 in the hand, 1 with its top at the edge.
    var nearEdge: CGFloat { arrived ? min(1.3, max(0, -cardY) / max(cardFrame.minY, 1)) : 0 }
    var charge: CGFloat { landed ? 1 : min(1, nearEdge * 1.3) }
    var cardWidth: CGFloat { source == .mint ? 176 : 148 }
    var shown: MediaItem {
        guard let e = episode else { return item }
        return MediaItem(title: item.title, subtitle: "S\(e.season) E\(e.episode) · \(e.name)", art: item.art, id: item.id, kind: item.kind)
    }
    var seasons: [Int] { Array(Set((meta?.episodes ?? []).map(\.season))).sorted() }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea().opacity(arrived ? 1 : 0)
                if g.size.width > g.size.height {
                    HStack(spacing: 24) {
                        details.frame(maxWidth: .infinity).opacity(calm)
                        VStack(spacing: 0) { tv.padding(.top, 20); Spacer(minLength: 16); hand }.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        tv.padding(.top, 14)
                        details.frame(maxHeight: .infinity).opacity(calm).zIndex(-1)
                        hand
                    }
                }
                Button { leave() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 40, height: 40).contentShape(Circle())
                }
                .buttonStyle(.plain).glassEffect(.regular, in: Circle()).padding(14).opacity(calm).accessibilityLabel("Close")
            }
            .coordinateSpace(name: "flick")
        }
        .preferredColorScheme(.dark)
        // Its own way in and out, so nothing slides over the card.
        .presentationBackground(.clear)
        .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, now in now }
        .task {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.66)) { arrived = true }
            await loadMeta()
        }
    }

    var tv: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.07))
                if landed, let image = target.image {
                    image.resizable().scaledToFill().transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if landed {
                    Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.15) }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 176, height: 99)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.28 + 0.5 * charge), lineWidth: 1.5) }
            .shadow(color: TVLook.accent.opacity(0.75 * charge), radius: 26)
            .scaleEffect(1 + 0.05 * charge)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { tvFrame = $0 }
            Capsule().fill(.white.opacity(0.28)).frame(width: 52, height: 3)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: charge)
        .accessibilityHidden(true)
    }

    // What there is to choose, between the TV and your hand.
    var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let about = meta?.about ?? item.about, !about.isEmpty {
                    Text(about).font(.subheadline).foregroundStyle(.secondary).lineLimit(5)
                }
                if !seasons.isEmpty { episodes }
                if source == .stremio, item.stremioRef != nil { streamPicker }
                if let slug = item.slug, !slug.isEmpty {
                    Button { model.tick(); model.post("film", ["slug": slug], say: "Opening in Letterboxd"); leave() } label: {
                        Label("Open in Letterboxd", systemImage: "film")
                    }.font(.subheadline.weight(.medium)).tint(TVLook.accent)
                }
            }
            .padding(20).padding(.top, 8)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
    var episodes: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons, id: \.self) { s in
                        Button { model.tick(); season = s } label: {
                            Text("Season \(s)").font(.footnote.weight(.semibold)).padding(.horizontal, 13).frame(height: 32)
                                .background(season == s ? TVLook.accent : Color(white: 0.14), in: Capsule())
                                .foregroundStyle(season == s ? .black : .white)
                        }.buttonStyle(.plain)
                    }
                }
            }
            ForEach((meta?.episodes ?? []).filter { $0.season == season }) { e in
                Button {
                    model.tick()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { episode = episode == e ? nil : e }
                    // Streams belong to one episode.
                    streams = []; stream = nil; noStreams = false
                } label: {
                    HStack(spacing: 11) {
                        Art(url: URL(string: e.thumb)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.14) }
                            .frame(width: 78, height: 44).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text("\(e.episode). \(e.name)").font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if episode == e { Image(systemName: "checkmark.circle.fill").foregroundStyle(TVLook.accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(episode == e ? .isSelected : [])
            }
        }
    }

    // Optional: left alone, the TV opens the title and its own list of streams.
    @ViewBuilder var streamPicker: some View {
        let isSeries = item.stremioRef?.type == "series"
        if streams.isEmpty {
            if !isSeries || episode != nil {
                Button { Task { await findStreams() } } label: {
                    HStack(spacing: 8) {
                        if findingStreams { ProgressView().controlSize(.small) } else { Image(systemName: "play.rectangle.on.rectangle") }
                        Text(findingStreams ? "Asking your addons…" : noStreams ? "No streams found. Try again" : "Choose a stream")
                    }
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 40).background(Color(white: 0.14), in: Capsule())
                }
                .buttonStyle(.plain).disabled(findingStreams)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Streams").font(.headline).padding(.bottom, 6)
                ForEach(streams) { s in
                    Button { model.tick(); withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { stream = stream == s ? nil : s } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name.isEmpty ? s.addon : s.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                if !s.description.isEmpty { Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            }
                            .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if stream == s { Image(systemName: "checkmark.circle.fill").foregroundStyle(TVLook.accent) }
                        }
                        .padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(stream == s ? .isSelected : [])
                }
            }
        }
    }
    func findStreams() async {
        guard let ref = item.stremioRef else { return }
        findingStreams = true; noStreams = false
        defer { findingStreams = false }
        let video = episode?.id ?? ref.imdb
        let term = video.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? video
        struct Answer: Decodable { let streams: [StremioStream] }
        guard let d = await TVBridge.data(TVBridge.url("/api/tv/streams?type=\(ref.type)&id=\(ref.imdb)&video=\(term)"), timeout: 25),
              let a = try? JSONDecoder().decode(Answer.self, from: d), !a.streams.isEmpty else { noStreams = true; return }
        withAnimation { streams = a.streams }
    }

    // The card, resting at the bottom until you throw it.
    var hand: some View {
        VStack(spacing: 10) {
            Text(note ?? "Flick up to play on the TV")
                .font(.footnote.weight(.medium)).foregroundStyle(note == nil ? .secondary : .primary)
                .contentTransition(.opacity)
                .opacity(note == nil ? calm : 1)
            card
        }
        .padding(.bottom, 16)
    }
    // Everything else steps back while the card is in the air.
    var calm: Double { arrived ? 1 - 0.8 * min(1, nearEdge * 1.4) : 0 }
    var card: some View {
        MediaCard(item: shown, source: source, width: cardWidth, image: target.image)
            // Measured before anything moves it, so it doesn't redraw the screen on every frame.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { if !flown { cardFrame = $0 } }
            .shadow(color: .black.opacity(0.6), radius: 18 + 26 * nearEdge, y: 10 + 22 * nearEdge)
            .phaseAnimator([CGFloat(0), -7]) { c, y in
                // A small bob while it waits, so it looks like something to pick up.
                c.offset(y: !touching && drag == .zero && !flown && note == nil ? y : 0)
            } animation: { _ in .easeInOut(duration: 1.3) }
            // It grows and leans as it nears the edge, on its way off the phone and towards the TV.
            .rotation3DEffect(.degrees(Double(nearEdge) * 16), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.5)
            .scaleEffect(1 + 0.55 * pow(nearEdge, 1.25))
            .rotationEffect(.degrees(Double(flown ? exitX : drag.width) / 18))
            .offset(x: flown ? exitX : drag.width * 0.6, y: cardY)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("flick"))
                .updating($touching) { _, on, _ in on = true }
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    if v.translation.height < -80 || v.predictedEndTranslation.height < -170 { send(flicked: v.velocity) }
                    else if v.translation.height > 110 { leave() }
                    else { settle() }
                })
            .onChange(of: touching) { _, on in if !on && !flown { settle() } }
            .onTapGesture {
                // A tap shows which way it wants to go.
                model.tick()
                withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { hop = true }
                Task {
                    try? await Task.sleep(nanoseconds: 170_000_000)
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
        withAnimation(.spring(response: 0.42, dampingFraction: 0.56)) { drag = .zero }
    }
    func leave() {
        withAnimation(.easeOut(duration: 0.2)) { arrived = false }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            model.closeFlick()
        }
    }

    func loadMeta() async {
        guard source == .stremio, let ref = item.stremioRef,
              let d = await TVBridge.data(TVBridge.url("/api/tv/stremio-meta?type=\(ref.type)&id=\(ref.imdb)"), timeout: 15),
              let m = try? JSONDecoder().decode(StremioMeta.self, from: d) else { return }
        meta = m
        // A card that's part way through a series starts on that episode.
        episode = m.episodes.first { $0.id == ref.video }
        season = episode?.season ?? m.episodes.first?.season ?? 0
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
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        note = nil
        // Leaves at the speed it was thrown, so there's no seam between the finger and the flight.
        let from = cardY, to = -(cardFrame.maxY + cardFrame.height * 0.7)
        let speed = min(0, velocity.height) / min(to - from, -1)
        exitX = max(-90, min(90, drag.width * 0.6 + velocity.width * 0.12))
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 150, damping: 22, initialVelocity: speed)) { flown = true }
        let order = order
        Task {
            // The TV lights as the card passes it.
            try? await Task.sleep(nanoseconds: 190_000_000)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.52)) { landed = true }
            do {
                try await TVBridge.post(order.0, order.1)
                target.sent?()
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                withAnimation { note = source == .mint || stream != nil ? "On the TV" : "On the TV. Pick a stream with the remote." }
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                leave()
            } catch {
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                #endif
                drag = .zero
                withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { landed = false; flown = false; note = stream != nil ? "That stream has gone. Pick again." : "The TV didn’t get that" }
                if stream != nil { stream = nil; streams = []; await findStreams() }
            }
        }
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
