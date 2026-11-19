import SwiftUI

// Three ideas taken from the real Zune software (Zune HD and the Zune 4 desktop), each doing a job here rather than
// dressing the app up (Richard, 2026-11-18: "really go to my design tenets and pull from real zune software while
// remaining functional and grounded in ios be smart"):
// - Now Playing's giant artist name: on the Zune HD the artist's name ran across the screen in huge light type behind
//   the music, drifting slowly. Here it drifts behind the song on now, only while it plays.
// - Quickplay: the desktop's home was a mosaic of covers, one large tile and smaller ones beside it. Here the mosaic is
//   his week's albums, the tile for the one he's played most twice the size of the rest: what's in heavy rotation, as
//   pictures, readable at a glance.
// - Mixview: tapping an artist in Zune showed them in the middle and related artists around them, joined by lines. Here
//   the artists Last.fm calls like the one on now ring its cover, each line as heavy as his own plays of that artist, so
//   which neighbours he already loves and which are new to him reads as a picture.
// All of it in Apple's grammar: system navigation, Dynamic Type for every word, VoiceOver labels, Reduce Motion stills
// the drift and the fly-in, haptics only on his touch.

// MARK: - The giant name

struct MixName: View {
    let text: String
    var size: CGFloat = 120
    var moving: Bool
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        let name = text.lowercased()
        // One copy and the air after it; enough copies to cover the width, so the line never runs out as it drifts.
        let unit = max(textWidth(name, size: size, tracking: -2) + size * 0.5, 1)
        GeometryReader { g in
            let copies = Int((g.size.width / unit).rounded(.up)) + 1
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving || still)) { tl in
                // About 14 pt a second: slower than anything he does, so it reads as a layer behind, not a ticker.
                let t = moving && !still ? tl.date.timeIntervalSinceReferenceDate : 0
                let x = -CGFloat((t * 14).truncatingRemainder(dividingBy: Double(unit)))
                HStack(spacing: 0) {
                    ForEach(0..<copies, id: \.self) { _ in
                        Text(name).font(.system(size: size, weight: .thin)).tracking(-2).lineLimit(1).fixedSize()
                            .frame(width: unit, alignment: .leading)
                    }
                }
                .offset(x: x + S.margin - 8)
                .foregroundStyle(.white.opacity(0.13))
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
            .clipped()
        }
        .frame(height: ceil(size * 1.22))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Quickplay: heavy rotation

// His week's albums as a mosaic: the most played a large tile with its name and plays, the next ones small tiles beside
// it, each opening its album. Worked out from his history once it reaches back a week; until then, nothing (never a
// guess from part of the week).
struct RotationMosaic: View {
    @State private var albums: [Entry] = []
    @State private var width: CGFloat = 360
    private var store: Store { Store.shared }
    private var sync: HistorySync { HistorySync.shared }
    var body: some View {
        // Four columns folded (the big tile and a 2×2 beside it), six with room (the big tile and two rows of four).
        let cols = width >= 560 ? 6 : 4
        let g = S.gap / 2
        let u = max(1, ((width - g * CGFloat(cols - 1)) / CGFloat(cols)).rounded(.down))
        let smalls = (cols - 2) * 2
        let big = u * 2 + g
        Group {
            if let top = albums.first, albums.count >= 3 {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "heavy rotation", trailing: "7 days")
                    HStack(alignment: .top, spacing: g) {
                        bigTile(top, side: big)
                        VStack(alignment: .leading, spacing: g) {
                            ForEach(0..<2, id: \.self) { row in
                                HStack(spacing: g) {
                                    ForEach(0..<(cols - 2), id: \.self) { c in
                                        let k = 1 + row * (cols - 2) + c
                                        if k < albums.count, k <= smalls { smallTile(albums[k], rank: k + 1, side: u) }
                                        else { Color.clear.frame(width: u, height: u) }
                                    }
                                }
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: "\(store.recent.first?.id ?? "")|\(sync.complete)|\(sync.coveredFrom / 3600)") { await load() }
    }
    private func load() async {
        let to = Int(Clock.now.timeIntervalSince1970) + 1, from = to - 7 * 86400
        guard sync.complete || sync.coveredFrom <= from else { albums = []; return }
        let list = await HistoryDB.reader.top(.albums, from: from, to: to, limit: 9, median: LengthFill.shared.median)
        withAnimation(.smooth(duration: 0.35)) { albums = list }
    }
    private func bigTile(_ e: Entry, side: CGFloat) -> some View {
        Opens(route: e.route, zoom: "rotation|\(e.id)") {
            ZStack(alignment: .bottomLeading) {
                ArtView(e.art, px: 600, corner: 12).frame(width: side, height: side).zoomSource("rotation|\(e.id)")
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.72), location: 1)], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(number(e.plays)).font(.system(size: 34, weight: .thin)).monospacedDigit().foregroundStyle(.white)
                    Text(e.album).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                    Text(e.artist).font(.footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                .padding(10)
            }
            .frame(width: side, height: side)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Most played this week: \(e.album) by \(e.artist), \(plays(e.plays))")
        .accessibilityAddTraits(.isButton)
    }
    private func smallTile(_ e: Entry, rank: Int, side: CGFloat) -> some View {
        Opens(route: e.route, zoom: "rotation|\(e.id)") {
            ZStack(alignment: .bottomLeading) {
                ArtView(e.art, px: 300, corner: 8).frame(width: side, height: side).zoomSource("rotation|\(e.id)")
                RankShade(corner: 8).frame(width: side, height: side)
                Text(number(e.plays)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 3).padding(6)
            }
            .frame(width: side, height: side)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank). \(e.album) by \(e.artist), \(plays(e.plays))")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Mixview

// The artist on now in the middle, the artists like them around, a line to each as heavy as his own plays of them. A
// neighbour he's never played is drawn lighter, on a dashed line, and says so. Every one opens its page. Covers square,
// like every artist in the app (an artist is drawn with their most played album).
struct MixView: View {
    let artist: String
    let center: ArtRef
    @State private var ring: [Node] = []
    @State private var shown = false
    @State private var width: CGFloat = 360
    @Environment(\.accessibilityReduceMotion) private var still
    @ScaledMetric(relativeTo: .caption) private var label: CGFloat = 32
    struct Node: Identifiable, Equatable {
        var id: String { name.lowercased() }
        let name: String
        let match: Double
        let plays: Int
        var art: ArtRef
    }
    static let most = 8
    var body: some View {
        let nodes = Array(ring.prefix(Self.most))
        let height = min(max(width * 0.82, 300), 400) + label
        Group {
            if nodes.count >= 3 {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "mix", trailing: "like \(artist)")
                    ZStack {
                        let layout = place(nodes, in: CGSize(width: width, height: height))
                        // The lines first, under the covers: his plays as weight, faint where he has none.
                        Canvas { ctx, _ in
                            let peak = max(1, nodes.map(\.plays).max() ?? 1)
                            for (n, p) in zip(nodes, layout.points) {
                                var path = Path(); path.move(to: layout.center); path.addLine(to: p)
                                let w = n.plays > 0 ? 1 + 4 * CGFloat(log(Double(n.plays) + 1) / log(Double(peak) + 1)) : 0.75
                                ctx.stroke(path, with: .color(.white.opacity(n.plays > 0 ? 0.42 : 0.14)), style: StrokeStyle(lineWidth: w, lineCap: .round, dash: n.plays > 0 ? [] : [3, 4]))
                            }
                        }
                        .opacity(shown ? 1 : 0)
                        Opens(route: .artist(artist)) {
                            ArtView(center, px: 400, corner: 14).frame(width: layout.core, height: layout.core)
                                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                        }
                        .position(layout.center)
                        .accessibilityLabel(artist)
                        .accessibilityHint("Shows the artist")
                        ForEach(Array(nodes.enumerated()), id: \.element.id) { k, n in
                            let p = k < layout.points.count ? layout.points[k] : layout.center
                            satellite(n, side: layout.side(n.match))
                                .position(shown ? p : layout.center)
                                .opacity(shown ? 1 : 0)
                                .scaleEffect(shown ? 1 : 0.4)
                                .animation(still ? nil : .spring(response: 0.55, dampingFraction: 0.78).delay(0.04 * Double(k)), value: shown)
                        }
                    }
                    .frame(height: height)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: artist) { await load() }
    }
    private func satellite(_ n: Node, side: CGFloat) -> some View {
        Opens(route: .artist(n.name), zoom: "mix|\(n.id)") {
            VStack(spacing: 4) {
                ArtView(n.art, px: 200, corner: 8).frame(width: side, height: side).zoomSource("mix|\(n.id)")
                    .opacity(n.plays > 0 ? 1 : 0.72)
                VStack(spacing: 0) {
                    Text(n.name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(n.plays > 0 ? plays(n.plays) : "new to you").font(.caption2).monospacedDigit().foregroundStyle(S.soft).lineLimit(1)
                }
                .frame(width: max(side + 28, 84))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n.name), " + (n.plays > 0 ? plays(n.plays) : "new to you"))
        .accessibilityAddTraits(.isButton)
    }
    private struct Layout {
        let center: CGPoint
        let points: [CGPoint]
        let core: CGFloat
        let small: CGFloat
        let large: CGFloat
        func side(_ match: Double) -> CGFloat { small + (large - small) * CGFloat(min(max(match, 0), 1)) }
    }
    // The cover in the middle; the ring on an ellipse that fills the room, starting at the top, each satellite's centre
    // placed so its cover and its two lines of words stay inside.
    private func place(_ nodes: [Node], in size: CGSize) -> Layout {
        let core = min(112, size.height * 0.3)
        let small: CGFloat = 46, large: CGFloat = size.width >= 560 ? 76 : 64
        // The cover sits a little above the satellite's point and its words below; centre on the cover.
        let c = CGPoint(x: size.width / 2, y: (size.height - label) / 2 + 6)
        let rx = max(60, size.width / 2 - max(large + 28, 84) / 2 - 2)
        let ry = max(60, (size.height - label) / 2 - large / 2 - 4)
        let pts = nodes.indices.map { i -> CGPoint in
            let a = -Double.pi / 2 + Double(i) / Double(nodes.count) * 2 * .pi + (nodes.count % 2 == 0 ? .pi / Double(nodes.count) : 0)
            // Offset by half the words so the cover, not the whole stack, sits on the ring.
            return CGPoint(x: c.x + rx * CGFloat(cos(a)), y: c.y + ry * CGFloat(sin(a)) + label / 2)
        }
        return Layout(center: c, points: pts, core: core, small: small, large: large)
    }
    private func load() async {
        shown = false
        ring = []
        guard let j = try? await LastFM.shared.call("artist.getsimilar", ["artist": artist, "limit": "16", "autocorrect": "1"], fresh: 86400) else { return }
        let similar = j["similarartists"]["artist"].array.map { (name: $0["name"].text, match: Double($0["match"].text) ?? 0) }.filter { !$0.name.isEmpty }.prefix(Self.most)
        guard similar.count >= 3 else { return }
        let counts = await HistoryDB.reader.playsOf(artists: similar.map(\.name))
        var list: [Node] = []
        for s in similar {
            let r = await ArtistArt.ref(s.name)
            if Task.isCancelled { return }
            list.append(Node(name: s.name, match: s.match, plays: counts[s.name.lowercased()] ?? 0, art: r))
        }
        ring = list
        try? await Task.sleep(nanoseconds: 120_000_000)
        withAnimation(still ? nil : .easeOut(duration: 0.3)) { shown = true }
    }
}
