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
        GeometryReader { g in
            let room = max(g.size.width - S.margin * 2 + 8, 1)
            let natural = max(textWidth(name, size: size, tracking: -2), 1)
            // Always whole: set smaller until it fits the band, and left out when even half size wouldn't fit. A word
            // cut at the display's edge or at the fold read as broken ("ard li", run 32).
            // At most 80 % of the band, so there's always room to sway: fitted to the full width it had none and stood
            // still (run 33).
            let fit = min(size, size * room * 0.8 / natural)
            let slack = max(0, room - natural * fit / size)
            if fit >= size * 0.5 {
                // A slow sway across the room it has, about 10 pt a second: a layer behind, not a ticker. One repeating
                // animation of an offset, not a 30-a-second timeline that worked the view out again every tick.
                let on = moving && !still && slack >= 2
                // The drift is the render server's (a layer animation), not a SwiftUI one: a forever animation here was
                // worked out on the main thread every frame, on every page of the tab, for as long as a song was on
                // (run 40's hitch log: today, his page and his story all lost frames while playing; idle they didn't).
                #if canImport(UIKit)
                if on {
                    DriftName(text: name, size: fit, tracking: -2 * fit / size, lead: S.margin - 4, slack: slack)
                        .frame(width: g.size.width, height: g.size.height)
                } else { still(name, fit) .frame(width: g.size.width, height: g.size.height, alignment: .leading) }
                #else
                still(name, fit).frame(width: g.size.width, height: g.size.height, alignment: .leading)
                #endif
            }
        }
        .frame(height: ceil(size * 1.2))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    private func still(_ name: String, _ fit: CGFloat) -> some View {
        Text(name).font(.system(size: fit, weight: .thin)).tracking(-2 * fit / size).lineLimit(1).fixedSize()
            .foregroundStyle(.white.opacity(0.13))
            .offset(x: S.margin - 4)
    }
}

#if canImport(UIKit)
// The name as a label whose layer sways from side to side: Core Animation moves it, so no frame of it costs the app
// anything. The animation is put back whenever the view returns to a window or the app comes forward (the system
// drops layer animations then).
private struct DriftName: UIViewRepresentable {
    let text: String, size: CGFloat, tracking: CGFloat, lead: CGFloat, slack: CGFloat
    func makeUIView(context: Context) -> Drifter { Drifter() }
    func updateUIView(_ v: Drifter, context: Context) { v.set(text, size, tracking, lead, slack) }
    final class Drifter: UIView {
        private let label = UILabel()
        private var lead: CGFloat = 0, slack: CGFloat = 0
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false; isAccessibilityElement = false
            label.textColor = UIColor.white.withAlphaComponent(0.13)
            label.lineBreakMode = .byClipping
            addSubview(label)
            NotificationCenter.default.addObserver(self, selector: #selector(sway), name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
        func set(_ text: String, _ size: CGFloat, _ tracking: CGFloat, _ lead: CGFloat, _ slack: CGFloat) {
            label.attributedText = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: size, weight: .thin), .kern: tracking])
            label.sizeToFit()
            let moved = abs(slack - self.slack) > 0.5 || lead != self.lead
            self.lead = lead; self.slack = slack
            setNeedsLayout()
            if moved { sway() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            let s = label.bounds.size
            label.layer.removeAnimation(forKey: "sway")
            label.frame = CGRect(x: lead, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            sway()
        }
        override func didMoveToWindow() { super.didMoveToWindow(); sway() }
        // About 10 pt a second across the room it has, there and back, for ever.
        @objc private func sway() {
            guard window != nil, slack >= 2, label.layer.animation(forKey: "sway") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = 0; a.toValue = slack
            a.duration = max(Double(slack) / 10, 1)
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.isRemovedOnCompletion = false
            label.layer.add(a, forKey: "sway")
        }
    }
}
#endif

// MARK: - Quickplay: heavy rotation

// His week's albums as a mosaic: the most played a large tile with its name and plays, the next ones small tiles beside
// it, each opening its album. Worked out from his history once it reaches back a week; until then, nothing (never a
// guess from part of the week).
struct RotationMosaic: View {
    // Seeded from the list kept last time, so the mosaic is in its place in the first frame and never slides in above
    // cards already on screen (run 39: "heavy rotation" faded in and pushed the page down 0.6 s after opening).
    @State private var albums: [Entry] = RotationMosaic.first
    // Read from the disk once a launch (as a state's first value it was read again every time his page was made).
    private static let first: [Entry] = kept()
    private var store: Store { Store.shared }
    private var sync: HistorySync { HistorySync.shared }
    var body: some View {
        Group {
            if let top = albums.first, albums.count >= 3 {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "heavy rotation", trailing: "7 days")
                    // Laid out from the width it's given, in the same pass: it used to measure its own width, which
                    // could only grow, and after a turn of the phone the whole page stayed cut off at the left (run 39).
                    MosaicLayout(gap: S.mosaic) {
                        bigTile(top)
                        ForEach(1..<9, id: \.self) { k in
                            if k < albums.count { smallTile(albums[k], rank: k + 1) } else { Color.clear }
                        }
                    }
                    .clipped()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(store.recent.first?.id ?? "")|\(sync.complete)|\(sync.coveredFrom / 3600)") { await load() }
    }
    private func load() async {
        let to = Int(Clock.now.timeIntervalSince1970) + 1, from = to - 7 * 86400
        guard sync.complete || sync.coveredFrom <= from else { return }
        let list = await HistoryDB.reader.top(.albums, from: from, to: to, limit: 9, median: LengthFill.shared.median)
        // In place, no animation of its own: the tiles keep their places and only what changed changes.
        guard list.map(\.id) != albums.map(\.id) || list.map(\.plays) != albums.map(\.plays) else { return }
        albums = list
        Self.keep(list)
    }
    // The last list on the disk: artist, album, cover and plays are all a tile needs.
    private static var file: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(LastFM.shared.mock ? "rotation-mock.json" : "rotation.json") }
    private struct Kept: Codable { let artist: String; let album: String; let image: String?; let plays: Int }
    static func kept() -> [Entry] {
        if UserDefaults.standard.bool(forKey: "fresh") { return [] }
        guard let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Kept].self, from: d) else { return [] }
        let out = list.map { Entry(kind: .albums, artist: $0.artist, album: $0.album, track: "", plays: $0.plays, image: $0.image) }
        // Its covers at the sizes the tiles draw, before the first frame.
        for (i, e) in out.prefix(9).enumerated() { ArtStore.shared.warm(e.art, px: [i == 0 ? 600 : 300], backdrop: false) }
        return out
    }
    private static func keep(_ list: [Entry]) {
        let k = list.map { Kept(artist: $0.artist, album: $0.album, image: $0.image, plays: $0.plays) }
        if let d = try? JSONEncoder().encode(k) { try? d.write(to: file, options: .atomic) }
    }
    private func bigTile(_ e: Entry) -> some View {
        Opens(route: e.route, zoom: "rotation|\(e.id)") {
            ZStack(alignment: .bottomLeading) {
                ArtView(e.art, px: 600, corner: 12).zoomSource("rotation|\(e.id)")
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.72), location: 1)], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: S.square, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(number(e.plays)).font(.system(size: 34, weight: .thin)).monospacedDigit().foregroundStyle(.white)
                    Text(e.album).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                    Text(e.artist).font(.footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                }
                .padding(10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Most played this week: \(e.album) by \(e.artist), \(plays(e.plays))")
        .accessibilityAddTraits(.isButton)
    }
    private func smallTile(_ e: Entry, rank: Int) -> some View {
        Opens(route: e.route, zoom: "rotation|\(e.id)") {
            ZStack(alignment: .bottomLeading) {
                ArtView(e.art, px: 300, corner: 8).zoomSource("rotation|\(e.id)")
                RankShade(corner: 8)
                Text(number(e.plays)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 3).padding(6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank). \(e.album) by \(e.artist), \(plays(e.plays))")
        .accessibilityAddTraits(.isButton)
    }
}

// The mosaic's shape from the width offered, worked out in one layout pass: the first view a double tile, then small
// square tiles two rows deep beside it; four columns folded (a 2×2 beside it), six with room (two rows of four). Small
// tiles past what the columns hold are put outside its bounds.
struct MosaicLayout: Layout {
    let gap: CGFloat
    private func metrics(_ w: CGFloat) -> (cols: Int, u: CGFloat) {
        let cols = w >= 560 ? 6 : 4
        return (cols, max(1, ((w - gap * CGFloat(cols - 1)) / CGFloat(cols)).rounded(.down)))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 360
        let m = metrics(w)
        return CGSize(width: w, height: m.u * 2 + gap)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(bounds.width)
        let big = m.u * 2 + gap
        let per = m.cols - 2
        for (i, v) in subviews.enumerated() {
            if i == 0 {
                v.place(at: bounds.origin, proposal: ProposedViewSize(width: big, height: big))
                continue
            }
            let k = i - 1
            if k < per * 2 {
                let x = bounds.minX + big + gap + CGFloat(k % per) * (m.u + gap)
                let y = bounds.minY + CGFloat(k / per) * (m.u + gap)
                v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: m.u, height: m.u))
            } else {
                // Out of the frame (the mosaic is clipped to its bounds), at its own size, never squashed to nothing.
                v.place(at: CGPoint(x: bounds.maxX + 4000, y: bounds.minY), proposal: ProposedViewSize(width: m.u, height: m.u))
            }
        }
    }
}

// MARK: - Mixview

// The artist on now in the middle, the artists like them around, a line to each as heavy as his own plays of them. A
// neighbour he's never played is drawn lighter, on a dashed line, and says so. Every one opens its page. Covers square,
// like every artist in the app (an artist is drawn with their most played album).
// The ring only where it has the room to stay clean (open upright). Narrower (folded, a pane open flat) eight covers
// and their names around one cover piled into each other (run 32), so there it is a plain grid: four across, each name
// whole on two lines, his plays under it.
struct MixView: View {
    let artist: String
    let center: ArtRef
    @State private var ring: [Node] = []
    @State private var shown = false
    // The room it has, from the page's width (it sits inside the page's margins): known as it's laid out, where it
    // used to measure itself and lay out a frame late.
    @Environment(\.pageWidth) private var pageWidth
    private var width: CGFloat { max(200, pageWidth - S.margin * 2) }
    @Environment(\.accessibilityReduceMotion) private var still
    // Room under or over a satellite's cover for its name on two lines and his plays.
    @ScaledMetric(relativeTo: .caption) private var label: CGFloat = 48
    struct Node: Identifiable, Equatable {
        var id: String { name.lowercased() }
        let name: String
        let match: Double
        let plays: Int
        var art: ArtRef
    }
    static let most = 8
    static let ringWidth: CGFloat = 600
    var body: some View {
        let nodes = Array(ring.prefix(Self.most))
        Group {
            if nodes.count >= 3 {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "mix", trailing: "like \(artist)")
                    if width >= Self.ringWidth { ringView(nodes) } else { grid(nodes) }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: artist) { await load() }
    }

    private func grid(_ nodes: [Node]) -> some View {
        let cols = min(width < 330 ? 3 : 4, max(nodes.count, 1))
        // Only full rows: eight in three columns left a hole (3, 3, 2; run 33).
        let cells = Array(nodes.prefix(max(cols, nodes.count / cols * cols)))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: S.gap, alignment: .top), count: cols), alignment: .leading, spacing: S.inner) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { k, n in
                Opens(route: .artist(n.name), zoom: "mix|\(n.id)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ArtView(n.art, px: 300, corner: 8).aspectRatio(1, contentMode: .fit).zoomSource("mix|\(n.id)")
                            .opacity(n.plays > 0 ? 1 : 0.72)
                        words(n, align: .leading, reserve: true)
                    }
                }
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)
                .animation(still ? nil : .smooth(duration: 0.4).delay(0.04 * Double(k)), value: shown)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(n.name), " + (n.plays > 0 ? plays(n.plays) : "new to you"))
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    // In the grid every name keeps two lines, so the plays under them sit on one line across a row (run 33).
    private func words(_ n: Node, align: HorizontalAlignment, reserve: Bool = false) -> some View {
        VStack(alignment: align, spacing: 0) {
            Text(n.name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(2, reservesSpace: reserve)
                .multilineTextAlignment(align == .leading ? .leading : .center)
            Text(n.plays > 0 ? plays(n.plays) : "new to you").font(.caption2).monospacedDigit().foregroundStyle(S.soft).lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func ringView(_ nodes: [Node]) -> some View {
        let height = min(max(width * 0.62, 300), 420) + label * 2
        let layout = place(nodes, in: CGSize(width: width, height: height))
        return ZStack {
            // The lines first, under the covers, from the edge of the cover in the middle to the edge of each
            // satellite's cover: his plays as weight, faint where he has none. A name always sits on the far side of its
            // cover from the middle, so no line runs through a word.
            Canvas { ctx, _ in
                let peak = max(1, nodes.map(\.plays).max() ?? 1)
                for (n, q) in zip(nodes, layout.points) {
                    let dx = q.x - layout.center.x, dy = q.y - layout.center.y
                    let m = max(abs(dx), abs(dy), 1)
                    let t0 = (layout.core / 2 + 4) / m, t1 = 1 - (layout.side(n.match) / 2 + 4) / m
                    guard t1 > t0 else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: layout.center.x + dx * t0, y: layout.center.y + dy * t0))
                    path.addLine(to: CGPoint(x: layout.center.x + dx * t1, y: layout.center.y + dy * t1))
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
                let q = k < layout.points.count ? layout.points[k] : layout.center
                let above = q.y < layout.center.y - 1
                let side = layout.side(n.match)
                // The stack's middle, so its cover's middle lands on the ring.
                let p = CGPoint(x: q.x, y: q.y + (above ? -1 : 1) * (label + 4) / 2)
                satellite(n, side: side, above: above)
                    .position(shown ? p : layout.center)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.4)
                    .animation(still ? nil : .spring(response: 0.55, dampingFraction: 0.78).delay(0.04 * Double(k)), value: shown)
            }
        }
        .frame(height: height)
    }

    private func satellite(_ n: Node, side: CGFloat, above: Bool) -> some View {
        Opens(route: .artist(n.name), zoom: "mix|\(n.id)") {
            VStack(spacing: 4) {
                if above { words(n, align: .center).frame(width: Self.wordsWidth, height: label, alignment: .bottom) }
                ArtView(n.art, px: 200, corner: 8).frame(width: side, height: side).zoomSource("mix|\(n.id)")
                    .opacity(n.plays > 0 ? 1 : 0.72)
                if !above { words(n, align: .center).frame(width: Self.wordsWidth, height: label, alignment: .top) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n.name), " + (n.plays > 0 ? plays(n.plays) : "new to you"))
        .accessibilityAddTraits(.isButton)
    }
    static let wordsWidth: CGFloat = 120
    private struct Layout {
        let center: CGPoint
        let points: [CGPoint]
        let core: CGFloat
        let small: CGFloat
        let large: CGFloat
        func side(_ match: Double) -> CGFloat { small + (large - small) * CGFloat(min(max(match, 0), 1)) }
    }
    // The cover in the middle; the satellites' covers on an ellipse that fills the room, each with its words on the
    // outside kept inside the frame.
    private func place(_ nodes: [Node], in size: CGSize) -> Layout {
        let core = min(112, size.height * 0.26)
        let small: CGFloat = 50, large: CGFloat = 72
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let rx = max(60, size.width / 2 - Self.wordsWidth / 2 - 2)
        let ry = max(60, size.height / 2 - large / 2 - label - 6)
        let pts = nodes.indices.map { i -> CGPoint in
            let a = -Double.pi / 2 + Double(i) / Double(nodes.count) * 2 * .pi + (nodes.count % 2 == 0 ? .pi / Double(nodes.count) : 0)
            return CGPoint(x: c.x + rx * CGFloat(cos(a)), y: c.y + ry * CGFloat(sin(a)))
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

// MARK: - The wall

// Zune's desktop Now Playing: a wall of covers from his own listening, small square tiles edge to edge, dimmed to one
// tint (the colour of the cover on now), the song over it. It lies behind the top of today's page and scrolls away with
// it. Drawn once into one picture (it is still: nothing here moves by the frame), from covers already on the phone.
struct ArtWall: View {
    let tint: Color
    @Environment(\.pageWidth) private var width
    // His week's albums, then what he's played lately: gathered once a launch, there in the first frame.
    private static let covers: [ArtRef] = gather(Store.shared.recent)
    static func gather(_ recent: [Scrobble]) -> [ArtRef] {
        var seen = Set<String>(), out: [ArtRef] = []
        for r in recent.prefix(200).map(\.art) where !r.album.isEmpty && seen.insert(r.key).inserted {
            out.append(r)
            if out.count == 24 { break }
        }
        return out
    }
    var body: some View {
        let refs = Self.covers
        if refs.count >= 6 {
            let cols = width >= 560 ? 8 : 5
            let side = (width / CGFloat(cols)).rounded(.up)
            // As deep as what's on: the cover and the song's words under it folded; the cover beside its words with room.
            let depth: CGFloat = width >= 560 ? 440 : min(width - S.margin * 2, 440) + 300
            let rows = Int((depth / side).rounded(.up))
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 0) {
                        // Each row starts further along the list, so a short list doesn't stack the same cover in a column.
                        ForEach(0..<cols, id: \.self) { c in ArtView(refs[(r * (cols + 2) + c) % refs.count], px: 156, corner: 0).frame(width: side, height: side) }
                    }
                }
            }
            .saturation(0)
            .colorMultiply(tint)
            .opacity(0.42)
            // Darker toward its foot, where the song's words lie over it, and gone into the ground at the end.
            .overlay { LinearGradient(stops: [.init(color: S.ground.opacity(0.3), location: 0), .init(color: S.ground.opacity(0.62), location: 0.55), .init(color: S.ground, location: 1)], startPoint: .top, endPoint: .bottom) }
            .drawingGroup()
            .frame(width: width, height: side * CGFloat(rows), alignment: .topLeading)
            .clipped()
            // From where the pivot's names fade the page out.
            .offset(y: -S.head - 26)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
