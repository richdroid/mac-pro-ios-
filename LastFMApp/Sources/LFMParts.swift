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
            case .up(let n): HStack(spacing: 1) { Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7)); Text("\(n)") }.accessibilityLabel("Up \(n)")
            case .down(let n): HStack(spacing: 1) { Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)); Text("\(n)") }.foregroundStyle(S.soft).accessibilityLabel("Down \(n)")
            case .new: Text("new").font(.caption2.weight(.bold)).foregroundStyle(.black).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.white)).accessibilityLabel("New")
            case .same: Image(systemName: "minus").font(.system(size: 8, weight: .bold)).foregroundStyle(S.soft.opacity(0.7)).accessibilityLabel("Same place")
            case nil: EmptyView()
            }
        }
        .font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
    }
}

// One line of a chart or the library: rank and movement, the cover, its names, and his plays (and time).
struct EntryRow: View {
    let e: Entry
    var showRank = true
    var context = "row"
    var trailing: String? = nil       // replaces the plays on the right (a date, when sorted by one)
    var body: some View {
        Opens(route: e.route, zoom: "\(context)|\(e.id)") {
            HStack(spacing: S.gap) {
                if showRank {
                    VStack(spacing: S.pair) {
                        Text("\(e.rank)").font(.system(size: e.rank < 100 ? 22 : 17, weight: .light)).monospacedDigit().foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        MoveMark(move: e.move)
                    }
                    .frame(width: 36)
                }
                ArtView(e.art, px: 156, corner: 6).frame(width: S.art).zoomSource("\(context)|\(e.id)")
                VStack(alignment: .leading, spacing: S.pair / 2) {
                    Text(e.title).font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    if e.kind != .artists { Text(e.artist).font(.subheadline).foregroundStyle(S.soft).lineLimit(1) }
                    else if let s = e.secs { Text(duration(s)).font(.subheadline).monospacedDigit().foregroundStyle(S.soft).lineLimit(1) }
                }
                Spacer(minLength: 8)
                // His plays, the number alone (the list says what it counts); sorted by a date, the date leads.
                VStack(alignment: .trailing, spacing: S.pair / 2) {
                    Text(trailing ?? number(e.plays)).font(.body.weight(.medium)).monospacedDigit().foregroundStyle(.white)
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
                        Text("\(k + 1)").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 8)
                            .offset(x: -2, y: 18)
                    }
                }
                .padding(.bottom, ranks ? S.gap : S.pair)
                Text(e.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Text(caption(e)).font(.footnote).monospacedDigit().foregroundStyle(S.soft).lineLimit(1)
            }
            .frame(width: S.tile, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// A row of choices as glass capsules, the chosen one filled.
struct Chips<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: S.gap / 1.5) {
                ForEach(items, id: \.self) { t in
                    let on = t == selection
                    Button { withAnimation(.snappy(duration: 0.25)) { selection = t } } label: {
                        Text(label(t)).font(.subheadline.weight(.semibold)).foregroundStyle(on ? .black : .white)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background { if on { Capsule().fill(.white) } }
                            .glassEffect(.regular, in: Capsule())
                    }
                    .buttonStyle(Press())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, S.margin)
        }
        .scrollIndicators(.hidden)
        .clipped()
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
    @State private var width: CGFloat = 360
    var body: some View {
        let room: CGFloat = (width + S.figures) / (104 + S.figures)
        let fit: Int = max(1, Int(room))
        let n: Int = items.count
        let cols: Int = n <= fit ? max(n, 1) : Self.even(n, fit)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: S.figures, alignment: .topLeading), count: cols), alignment: .leading, spacing: S.inner) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, f in Figure(value: f.0, label: f.1, size: size) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
    // The most columns that fit and leave no row short, else as many as fit.
    static func even(_ n: Int, _ fit: Int) -> Int {
        var c = fit
        while c >= 2 { if n % c == 0 { return c }; c -= 1 }
        return fit
    }
}

// A page's scroll: content, the bottom air, and back to the top when its tab is tapped again.
struct Page<C: View>: View {
    var top = 0
    @ViewBuilder let content: () -> C
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("top")
                content().padding(.bottom, S.section)
            }
            .scrollIndicators(.hidden)
            .onChange(of: top) { _, _ in withAnimation(.smooth) { proxy.scrollTo("top", anchor: .top) } }
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
