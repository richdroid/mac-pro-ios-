import SwiftUI
import Charts

// The pieces every tab and page shares: how a tap opens a page, the rows and panoramas of covers, movement marks,
// chips, a tide of plays over the years, and the ways out (Apple Music, Last.fm).

private struct OpenRouteKey: EnvironmentKey { static let defaultValue: (Go) -> Void = { _ in } }
extension EnvironmentValues {
    var openRoute: (Go) -> Void { get { self[OpenRouteKey.self] } set { self[OpenRouteKey.self] = newValue } }
}

// Anything that opens a page: an artist, album or track, from anywhere. With a cover to grow out of, the page zooms
// from it; else it slides in like any page.
struct Opens<C: View>: View {
    let route: Route
    var zoom: String? = nil
    @ViewBuilder let label: () -> C
    @Environment(\.openRoute) private var open
    var body: some View {
        Button { open(Go(route: route, zoom: zoom)) } label: { label().contentShape(Rectangle()) }
            .buttonStyle(Press())
    }
}

// A cover that opens its page, the page growing out of it.
struct CoverButton: View {
    let route: Route
    let ref: ArtRef
    let source: String
    var px = 300
    var corner: CGFloat = 8
    var body: some View {
        Opens(route: route, zoom: source) { ArtView(ref, px: px, corner: corner).zoomSource(source) }
            .accessibilityLabel(label)
    }
    private var label: String {
        switch route {
        case .artist(let a): return a
        case .album(let a, let l): return "\(l) by \(a)"
        case .track(let s): return "\(s.title) by \(s.artist)"
        }
    }
}

// Up or down against the stretch before, or new to the chart. White, never coloured to mean good or bad.
struct MoveMark: View {
    let move: Move?
    var body: some View {
        Group {
            switch move {
            case .up(let n): HStack(spacing: 2) { Image(systemName: "arrowtriangle.up.fill").font(.system(size: 10)); Text("\(n)") }.accessibilityLabel("Up \(n)")
            case .down(let n): HStack(spacing: 2) { Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)); Text("\(n)") }.foregroundStyle(S.soft).accessibilityLabel("Down \(n)")
            case .new: NewMark()
            case .same: Image(systemName: "minus").font(.system(size: 10, weight: .bold)).foregroundStyle(S.soft.opacity(0.7)).accessibilityLabel("Same place")
            case nil: EmptyView()
            }
        }
        .font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
    }
}

// New to a chart or to him: small bold capitals in white, as Zune marks a thing (never a solid white block).
struct NewMark: View {
    var body: some View {
        Text("New").textCase(.uppercase).font(.caption2.weight(.heavy)).tracking(0.8).foregroundStyle(.white).fixedSize()
            .accessibilityLabel("New")
    }
}

// A rank on a cover: the corner under it darkened, so the numeral reads on any picture (review 2026-11-14, item 8).
struct RankShade: View {
    var corner: CGFloat = 10
    var body: some View {
        RadialGradient(colors: [.black.opacity(0.62), .black.opacity(0.3), .clear], center: .bottomLeading, startRadius: 0, endRadius: 96)
            .clipShape(RoundedRectangle(cornerRadius: min(corner, S.square), style: .continuous))
            .allowsHitTesting(false)
    }
}

// One line of a chart or the library: rank and movement, the cover, its names, and his plays (and time).
struct EntryRow: View {
    let e: Entry
    var showRank = true
    var context = "row"
    var trailing: String? = nil       // replaces the plays on the right (a date, when sorted by one)
    var peak: Int? = nil              // the list's most played: with it, each row draws its plays as a bar against that
    var body: some View {
        Opens(route: e.route, zoom: "\(context)|\(e.id)") {
            HStack(spacing: S.gap) {
                if showRank {
                    VStack(spacing: S.pair) {
                        Text("\(e.rank)").font(.system(size: e.rank < 100 ? 28 : 19, weight: .thin)).monospacedDigit().foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        MoveMark(move: e.move)
                    }
                    .frame(width: 40)
                }
                ArtView(e.art, px: 156, corner: 6).frame(width: S.art).zoomSource("\(context)|\(e.id)")
                VStack(alignment: .leading, spacing: S.pair / 2) {
                    // Two lines before a name is ever cut short (review 2026-11-14, item 6).
                    Text(e.title).font(.system(.title3)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                    if e.kind != .artists { Text(e.artist).font(.subheadline).foregroundStyle(S.soft).lineLimit(2) }
                    else if let s = e.secs { Text(duration(s)).font(.subheadline).monospacedDigit().foregroundStyle(S.soft).lineLimit(1) }
                    if let peak, peak > 0, e.plays > 0 {
                        // His plays as a bar in the cover's colour against the list's most played: the row's width shows
                        // something (review 2026-11-14, item 17).
                        let tint = (ArtStore.shared.palette(e.art) ?? Palette.from(name: e.artist + e.album)).vivid.color
                        GeometryReader { g in
                            Capsule().fill(tint).frame(width: max(4, g.size.width * CGFloat(e.plays) / CGFloat(peak)), height: 4)
                        }
                        .frame(height: 4).padding(.top, S.pair)
                        .accessibilityHidden(true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                // His plays, the number alone (the list says what it counts); sorted by a date, the date leads.
                VStack(alignment: .trailing, spacing: S.pair / 2) {
                    Text(trailing ?? number(e.plays)).font(.system(.title3, weight: .light)).monospacedDigit().foregroundStyle(.white)
                    if trailing != nil, e.plays > 0 { Text(plays(e.plays)).font(.caption).monospacedDigit().foregroundStyle(S.soft) }
                }
                .fixedSize()
                .accessibilityLabel(trailing.map { "\($0), \(plays(e.plays))" } ?? plays(e.plays))
            }
            .padding(.vertical, S.row / 2)
        }
        .accessibilityElement(children: .combine)
    }
}

// A panorama: big covers in a row that runs off the edge, Zune's way.
struct Panorama: View {
    let title: String
    var trailing: String? = nil
    let items: [Entry]
    var ranks = false
    var caption: (Entry) -> String = { "\(number($0.plays)) \($0.plays == 1 ? "play" : "plays")" }
    var body: some View {
        if !items.isEmpty && items.count < 3 {
            // One or two: rows, never a sparse panorama.
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: title, trailing: trailing)
                VStack(spacing: 0) { ForEach(items) { e in EntryRow(e: e, showRank: false, context: title) } }
            }
            .padding(.horizontal, S.margin)
        } else if !items.isEmpty {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: title, trailing: trailing).padding(.horizontal, S.margin)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: S.gap) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { k, e in tile(k, e) }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, S.margin)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .clipped()
            }
        }
    }
    private func tile(_ k: Int, _ e: Entry) -> some View {
        Opens(route: e.route, zoom: "\(title)|\(e.id)") {
            VStack(alignment: .leading, spacing: S.pair) {
                ZStack(alignment: .bottomLeading) {
                    ArtView(e.art, px: 400, corner: 10).frame(width: S.tile).zoomSource("\(title)|\(e.id)")
                    if ranks {
                        RankShade().frame(width: S.tile, height: S.tile)
                        Text("\(k + 1)").font(.system(size: 72, weight: .thin)).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 6)
                            .offset(x: -2, y: 18)
                    }
                }
                .padding(.bottom, ranks ? S.gap : S.pair)
                Text(e.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2, reservesSpace: true)
                Text(caption(e)).font(.footnote).monospacedDigit().foregroundStyle(S.soft).lineLimit(1)
            }
            .frame(width: S.tile, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// A row of choices: one glass bar, the chosen one lit inside it (white type on a brighter pill, never a solid white
// block). One control for every such choice in the app (review 2026-11-14, items 15 and 25). It scrolls sideways when
// its choices outrun the room, fading at the far edge; with room, `fill` spreads them evenly across the width.
struct Segments<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    var fill = false
    let label: (T) -> String
    @Namespace private var lit
    var body: some View {
        if fill {
            bar.frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) { bar.padding(.horizontal, S.margin) }
                    .scrollIndicators(.hidden)
                    .mask { HStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: S.margin) } }
                    .onChange(of: selection) { _, t in withAnimation(.snappy) { proxy.scrollTo(t, anchor: .center) } }
            }
        }
    }
    private var bar: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { t in
                let on = t == selection
                Button { withAnimation(.snappy(duration: 0.25)) { selection = t } } label: {
                    Text(label(t)).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(on ? 1 : 0.7))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 14).frame(height: 36).frame(maxWidth: fill ? .infinity : nil)
                        .background { if on { Capsule().fill(.white.opacity(0.24)).matchedGeometryEffect(id: "lit", in: lit) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .id(t)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .sensoryFeedback(.tick, trigger: selection)
    }
}

// His plays of one thing, month by month since he first heard it, as a tide: a band that swells and ebbs round its
// middle line, in the cover's colour, the years marked under it.
struct Tide: View {
    let months: [Int: Int]
    let tint: Color
    var height: CGFloat = 110
    var body: some View {
        if let first = months.keys.min() {
            let last = LocalDay.month(LocalDay.today)
            let span = max(last - first + 1, 2)
            let vals = (0..<span).map { Double(months[first + $0] ?? 0) }
            let peak = max(vals.max() ?? 1, 1)
            let busiest = vals.indices.max { vals[$0] < vals[$1] } ?? 0
            VStack(alignment: .leading, spacing: S.pair * 2) {
                Canvas { ctx, size in
                    let mid = size.height / 2
                    func x(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(span - 1) * size.width }
                    func h(_ v: Double) -> CGFloat { max(0.6, CGFloat(sqrt(v / peak)) * (size.height / 2 - 2)) }
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: mid - h(vals[0])))
                    for i in 1..<span { p.addLine(to: CGPoint(x: x(i), y: mid - h(vals[i]))) }
                    for i in stride(from: span - 1, through: 0, by: -1) { p.addLine(to: CGPoint(x: x(i), y: mid + h(vals[i]))) }
                    p.closeSubpath()
                    ctx.fill(p, with: .linearGradient(Gradient(colors: [tint.opacity(0.95), tint.opacity(0.55)]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0)))
                    // Year lines, faint.
                    for i in 0..<span where (first + i) % 12 == 0 {
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x(i), y: 0)); $0.addLine(to: CGPoint(x: x(i), y: size.height)) }, with: .color(.white.opacity(0.09)), lineWidth: 1)
                    }
                }
                .frame(height: height)
                YearAxis(from: first, months: span)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your plays by month since \(monthName(first)). Busiest: \(monthName(first + busiest)), \(Int(vals[busiest])) plays.")
        }
    }
}

// The ways out: Apple Music, then Last.fm.
struct WaysOut: View {
    let apple: URL?
    let lastfm: URL?
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: S.gap) {
            if let apple {
                Button { openURL(apple) } label: { Label("Open in Apple Music", systemImage: "music.note").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).tint(S.accent).controlSize(.large)
            }
            if let lastfm {
                Button { openURL(lastfm) } label: { Label("Open on Last.fm", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass).controlSize(.large)
            }
        }
    }
}

// A row of figures that wraps as the width allows, each the same width, so a grid of them stays even.
// Columns are chosen so every row is full where the count allows (three figures are three across, four are four or two
// and two), never two and a stray one.
struct FigureGrid: View {
    let items: [(String, String)]
    var size: CGFloat = 30
    var body: some View {
        // A column is as wide as the longest figure needs, allowing it to shrink to 72 % (Figure's own limit is 70 %),
        // so no figure is ever cut short ("Mar 14, 20…" open flat, run 12).
        let longest: Int = items.map { $0.0.count }.max() ?? 3
        let label: Int = items.map { $0.1.count }.max() ?? 5
        // Room for the longest label too ("of your 1,077 artists" was cut open flat, run 16).
        let need: CGFloat = max(84, (CGFloat(longest) * size * 0.46 + 4) * 0.72, CGFloat(label) * 7.4 + 4)
        // The columns chosen from the width offered, in the same layout pass: the grid measured its own width and laid
        // out one frame late, at 360 pt first whatever the room (run 39 review, fault 1).
        FigureLayout(need: need) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, f in Figure(value: f.0, label: f.1, size: size) }
        }
    }
    // The most columns that fit and leave no row short, else as many as fit.
    static func even(_ n: Int, _ fit: Int) -> Int {
        var c = fit
        while c >= 2 { if n % c == 0 { return c }; c -= 1 }
        return fit
    }
}

struct FigureLayout: Layout {
    let need: CGFloat
    private func cols(_ n: Int, _ width: CGFloat) -> Int {
        let fit: Int = max(1, Int((width + S.figures) / (need + S.figures)))
        // Three that almost fit go three across (their digits shrink a little) rather than two and a stray one.
        let across: CGFloat = (width - S.figures * CGFloat(max(n - 1, 0))) / CGFloat(max(n, 1))
        return n <= fit ? max(n, 1) : (n <= 3 && across >= need * 0.95 ? n : FigureGrid.even(n, fit))
    }
    private func rows(_ subviews: Subviews, _ width: CGFloat) -> (cols: Int, cell: CGFloat, heights: [CGFloat]) {
        let c = cols(subviews.count, width)
        let cell = max(1, (width - S.figures * CGFloat(c - 1)) / CGFloat(c))
        var heights: [CGFloat] = []
        for (i, v) in subviews.enumerated() {
            let h = v.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height
            if i % c == 0 { heights.append(h) } else { heights[heights.count - 1] = max(heights[heights.count - 1], h) }
        }
        return (c, cell, heights)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let n = CGFloat(max(subviews.count, 1))
        var w = proposal.width ?? (need * n + S.figures * (n - 1))
        if !w.isFinite { w = need * n + S.figures * (n - 1) }
        let r = rows(subviews, w)
        return CGSize(width: w, height: r.heights.reduce(0, +) + S.inner * CGFloat(max(r.heights.count - 1, 0)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(subviews, bounds.width)
        var y = bounds.minY
        for (i, v) in subviews.enumerated() {
            let c = i % r.cols
            if c == 0, i > 0 { y += r.heights[i / r.cols - 1] + S.inner }
            v.place(at: CGPoint(x: bounds.minX + CGFloat(c) * (r.cell + S.figures), y: y), anchor: .topLeading, proposal: ProposedViewSize(width: r.cell, height: nil))
        }
    }
}

// The width of the page a view is on (a tab's page, one section of a pager, one pane open flat), known in the layout
// pass that draws it. Views that choose a shape by width read it here instead of measuring themselves a frame late.
private struct PageWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 390 }
extension EnvironmentValues {
    var pageWidth: CGFloat { get { self[PageWidthKey.self] } set { self[PageWidthKey.self] = newValue } }
}

// A page's scroll: content, the bottom air, and back to the top when its tab is tapped again.
struct Page<C: View>: View {
    var top = 0
    @ViewBuilder let content: () -> C
    var body: some View {
        GeometryReader { g in
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("top")
                    content().padding(.bottom, S.section)
                }
                .scrollIndicators(.hidden)
                .onScrollPhaseChange { _, new in Store.shared.scrolling = new != .idle }
                .onChange(of: top) { _, _ in withAnimation(.smooth) { proxy.scrollTo("top", anchor: .top) } }
            }
            .environment(\.pageWidth, g.size.width)
        }
    }
}

func plays(_ n: Int) -> String { "\(number(n)) \(n == 1 ? "play" : "plays")" }
func ago(_ uts: Int) -> String {
    let d = Date(timeIntervalSince1970: TimeInterval(uts))
    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d), to: Calendar.current.startOfDay(for: Clock.now)).day ?? 0
    if days == 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    return dateShort(uts)
}
