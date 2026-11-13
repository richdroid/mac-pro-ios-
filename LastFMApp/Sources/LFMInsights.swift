import SwiftUI
import Charts

// The insights that need his whole history, on You: his staples as a river across the years, his eras with the months
// one artist owned as chapters, listening time, record days, the discoveries that stuck, each month against his median,
// and how much of each year's top 50 carried into the next. Each appears once the first read is done; none is a guess.

private func vivid(_ ref: ArtRef) -> Color { (ArtStore.shared.palette(ref) ?? Palette.from(name: ref.artist + ref.album)).vivid.color }

// Covers' colours, loaded once for a set of covers, so a chart drawn in them is drawn again when they arrive.
struct PaletteLoader: ViewModifier {
    let refs: [ArtRef]
    @Binding var tick: Int
    func body(content: Content) -> some View {
        content.task(id: refs.map(\.key).joined()) {
            var changed = false
            for r in refs where ArtStore.shared.palette(r) == nil { if await ArtStore.shared.palette(loading: r) != nil { changed = true } }
            if changed { withAnimation(.easeOut(duration: 0.35)) { tick += 1 } }
        }
    }
}

// MARK: - Always there: the canon's river

struct RiverCard: View {
    @State private var tick = 0
    private var store: Store { Store.shared }
    var body: some View {
        if let river = store.deep.river, river.layers.count >= 3, (river.layers.first?.values.count ?? 0) >= 6 {
            // Biggest in the middle, the rest out to the banks.
            let bySize = river.layers.sorted { $0.total > $1.total }
            let order: [RiverLayer] = bySize.enumerated().reduce(into: []) { acc, e in if e.offset % 2 == 0 { acc.append(e.element) } else { acc.insert(e.element, at: 0) } }
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "always there", trailing: "\(river.layers.count) artists")
                VStack(alignment: .leading, spacing: S.inner) {
                    stream(order, from: river.from).id(tick)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: S.figures)], alignment: .leading, spacing: S.pair * 2) {
                        ForEach(bySize) { l in
                            Opens(route: .artist(l.artist), zoom: nil) {
                                HStack(spacing: 8) {
                                    Circle().fill(vivid(ArtRef(artist: l.artist, album: l.album, url: l.image))).frame(width: 10, height: 10)
                                    Text(l.artist).font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(compact(l.total)).font(.subheadline).monospacedDigit().foregroundStyle(S.soft)
                                }
                                .frame(minHeight: 32)
                            }
                        }
                    }
                    .id(tick)
                }
                .card()
            }
            .padding(.horizontal, S.margin)
            .modifier(PaletteLoader(refs: river.layers.map { ArtRef(artist: $0.artist, album: $0.album, url: $0.image) }, tick: $tick))
        }
    }
    private func stream(_ layers: [RiverLayer], from: Int) -> some View {
        let n = layers.first?.values.count ?? 0
        let totals = (0..<n).map { i in layers.reduce(0) { $0 + $1.values[i] } }
        let peak = max(totals.max() ?? 1, 1)
        return VStack(spacing: S.pair * 2) {
            Canvas { ctx, size in
                let mid = size.height / 2
                let k = (size.height - 4) / CGFloat(peak)
                func x(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(max(n - 1, 1)) * size.width }
                var lower = totals.map { -CGFloat($0) * k / 2 }
                for (li, l) in layers.enumerated() {
                    let upper = (0..<n).map { lower[$0] + CGFloat(l.values[$0]) * k }
                    var p = Path()
                    smooth(&p, (0..<n).map { CGPoint(x: x($0), y: mid + upper[$0]) }, move: true)
                    smooth(&p, (0..<n).reversed().map { CGPoint(x: x($0), y: mid + lower[$0]) }, move: false)
                    p.closeSubpath()
                    ctx.fill(p, with: .color(vivid(ArtRef(artist: l.artist, album: l.album, url: l.image)).opacity(li % 2 == 0 ? 0.92 : 0.78)))
                    lower = upper
                }
                for i in 0..<n where (from + i) % 12 == 0 {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x(i), y: 0)); $0.addLine(to: CGPoint(x: x(i), y: size.height)) }, with: .color(.white.opacity(0.08)), lineWidth: 1)
                }
                // Each name where its stream runs widest, when it fits inside its stream there and clear of every name
                // already placed; else it's left to the legend.
                var lowerAgain = totals.map { -CGFloat($0) * k / 2 }
                var placed: [CGRect] = []
                for l in layers {
                    let thick = (0..<n).map { CGFloat(l.values[$0]) * k }
                    let label = ctx.resolve(Text(l.artist).font(.caption2.weight(.bold)).foregroundStyle(.black.opacity(0.78)))
                    let sz = label.measure(in: CGSize(width: 300, height: 40))
                    let order = thick.indices.sorted { thick[$0] > thick[$1] }.prefix(12)
                    let halfW: CGFloat = sz.width / 2, halfH: CGFloat = sz.height / 2
                    for i in order where thick[i] >= sz.height + 4 {
                        let lo: CGFloat = halfW + 4, hi: CGFloat = size.width - halfW - 4
                        let cx: CGFloat = min(max(x(i), lo), hi)
                        let cy: CGFloat = mid + lowerAgain[i] + thick[i] / 2
                        let r = CGRect(x: cx - halfW - 4, y: cy - halfH, width: sz.width + 8, height: sz.height)
                        guard !placed.contains(where: { $0.intersects(r) }) else { continue }
                        ctx.draw(label, at: CGPoint(x: cx, y: r.midY))
                        placed.append(r)
                        break
                    }
                    lowerAgain = (0..<n).map { lowerAgain[$0] + thick[$0] }
                }
            }
            .frame(height: 220)
            YearAxis(from: from, months: n)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your staples month by month since \(monthName(from)): " + layers.sorted { $0.total > $1.total }.map(\.artist).joined(separator: ", "))
    }
}

// A line through points, rounded between them.
func smooth(_ p: inout Path, _ pts: [CGPoint], move: Bool) {
    guard let first = pts.first else { return }
    if move { p.move(to: first) } else { p.addLine(to: first) }
    guard pts.count > 2 else { pts.dropFirst().forEach { p.addLine(to: $0) }; return }
    for i in 1..<pts.count - 1 {
        let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
        p.addQuadCurve(to: mid, control: pts[i])
    }
    p.addLine(to: pts[pts.count - 1])
}

// Years under a chart of months.
struct YearAxis: View {
    let from: Int
    let months: Int
    struct Mark { let year: Int; let label: String; let x: CGFloat }
    // Each year's January along the width, thinned so the labels never touch.
    static func marks(from: Int, months: Int, width: CGFloat) -> [Mark] {
        let first = from / 12, last = (from + months - 1) / 12
        let count = Double(last - first + 1)
        let step = max(1, Int((count * 34.0 / Double(max(width, 1))).rounded(.up)))
        let span = CGFloat(max(months - 1, 1))
        var out: [Mark] = []
        for y in first...last where (y - first) % step == 0 {
            let i = CGFloat(max(0, y * 12 - from))
            let x: CGFloat = min(max(12, i / span * width + 12), width - 12)
            out.append(Mark(year: y, label: "’" + String(String(y).suffix(2)), x: x))
        }
        return out
    }
    var body: some View {
        GeometryReader { g in
            ForEach(Self.marks(from: from, months: months, width: g.size.width), id: \.year) { m in
                Text(m.label).font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(S.soft).fixedSize().position(x: m.x, y: 7)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Eras and takeovers

struct ErasSection: View {
    @State private var all = false
    @State private var tick = 0
    private var store: Store { Store.shared }
    enum Chapter: Identifiable { case era(Era), takeover(Takeover)
        var id: String { switch self { case .era(let e): return "e\(e.from)"; case .takeover(let t): return "t\(t.month)" } }
        var start: Int { switch self { case .era(let e): return e.from; case .takeover(let t): return t.month } }
    }
    var body: some View {
        let d = store.deep
        if !d.eras.isEmpty || !d.takeovers.isEmpty, let first = d.months.keys.min() {
            let chapters = (d.eras.filter { $0.months >= 2 }.map(Chapter.era) + d.takeovers.map(Chapter.takeover)).sorted { $0.start > $1.start }
            let shown = all ? chapters : Array(chapters.prefix(5))
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "your eras", trailing: d.takeovers.isEmpty ? nil : "\(d.takeovers.count) taken over")
                VStack(alignment: .leading, spacing: S.inner) {
                    strip(d, first: first).id(tick)
                    ForEach(shown) { c in
                        switch c {
                        case .era(let e): eraRow(e)
                        case .takeover(let t): takeoverCard(t)
                        }
                    }
                    if chapters.count > 5 {
                        Button { withAnimation(.smooth) { all.toggle() } } label: {
                            Text(all ? "Show fewer" : "Show all \(chapters.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 44).glassEffect(.regular, in: Capsule())
                        }
                        .buttonStyle(Press())
                    }
                }
                .card()
            }
            .padding(.horizontal, S.margin)
            .modifier(PaletteLoader(refs: d.eras.map { ArtRef(artist: $0.artist, album: $0.album, url: $0.image) }, tick: $tick))
        }
    }
    // Every month since he began, coloured by the era it belongs to; the months taken over marked above.
    private func strip(_ d: Deep, first: Int) -> some View {
        let last = LocalDay.month(LocalDay.today)
        let n = max(last - first + 1, 1)
        return VStack(spacing: S.pair * 2) {
            Canvas { ctx, size in
                let w = size.width / CGFloat(n)
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 10, width: size.width, height: size.height - 10), cornerRadius: 4), with: .color(.white.opacity(0.07)))
                for e in d.eras {
                    let r = CGRect(x: CGFloat(e.from - first) * w, y: 10, width: CGFloat(e.months) * w, height: size.height - 10)
                    ctx.fill(Path(r), with: .color(vivid(ArtRef(artist: e.artist, album: e.album, url: e.image)).opacity(e.months >= 2 ? 0.9 : 0.5)))
                }
                for t in d.takeovers {
                    let x = (CGFloat(t.month - first) + 0.5) * w
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: 0, width: 6, height: 6)), with: .color(.white))
                }
            }
            .frame(height: 40)
            YearAxis(from: first, months: n)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(d.eras.filter { $0.months >= 2 }.count) eras since \(monthName(first))")
    }
    private func eraRow(_ e: Era) -> some View {
        let ref = ArtRef(artist: e.artist, album: e.album, url: e.image)
        return Opens(route: .artist(e.artist), zoom: "era|\(e.from)") {
            HStack(spacing: S.gap) {
                ArtView(ref, px: 156, corner: 6).frame(width: S.art).zoomSource("era|\(e.from)")
                VStack(alignment: .leading, spacing: S.pair / 2) {
                    Text(e.artist).font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(monthShort(e.from)) – \(monthShort(e.to))").font(.subheadline).foregroundStyle(S.soft).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: S.pair / 2) {
                    Text("\(e.months)").font(.body.weight(.medium)).monospacedDigit().foregroundStyle(.white)
                    Text("months").font(.caption).foregroundStyle(S.soft)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
    // A month one artist owned: a chapter, the month in huge thin type over the cover.
    private func takeoverCard(_ t: Takeover) -> some View {
        let ref = ArtRef(artist: t.artist, album: t.album, url: t.image)
        return Opens(route: .artist(t.artist), zoom: "takeover|\(t.month)") {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { g in ArtView(ref, px: 700, corner: 0).frame(width: g.size.width, height: g.size.width).position(x: g.size.width / 2, y: g.size.height / 2) }
                    .zoomSource("takeover|\(t.month)")
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.4), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: S.pair) {
                    Text(monthName(t.month)).font(.system(size: 44, weight: .thin)).tracking(-1).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    Text(t.artist).font(.title3.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: S.gap) {
                        Text("\(Int((t.share * 100).rounded()))%").font(.system(size: 24, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        Text("of the month, \(plays(t.plays))").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(S.inner)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Listening time

struct TimeCard: View {
    private var store: Store { Store.shared }
    var body: some View {
        if let t = store.deep.time, t.coverage >= 0.6 {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "listening time")
                VStack(alignment: .leading, spacing: S.inner) {
                    VStack(alignment: .leading, spacing: S.pair) {
                        Text(number(t.all / 3600)).font(.system(size: 64, weight: .thin)).monospacedDigit().foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                        Text("hours, about \(number(t.all / 86400)) days").font(.title3.weight(.light)).foregroundStyle(S.soft)
                    }
                    .accessibilityElement(children: .combine)
                    FigureGrid(items: [
                        (duration(t.year), "this year"),
                        (duration(t.month), "this month"),
                        (duration(t.perDay), "a day, on average"),
                    ])
                }
                .card()
            }
            .padding(.horizontal, S.margin)
        }
    }
}

// MARK: - Record days

struct RecordsSection: View {
    private var store: Store { Store.shared }
    var body: some View {
        let list = store.deep.records
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "record days").padding(.horizontal, S.margin)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: S.gap) { ForEach(list) { card($0) } }
                        .scrollTargetLayout()
                        .padding(.horizontal, S.margin)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .clipped()
            }
        }
    }
    private func card(_ r: Record) -> some View {
        let ref = ArtRef(artist: r.artist, album: r.album, url: r.image)
        let route: Route = r.what == .track ? .track(Scrobble.song(artist: r.artist, title: r.track, album: r.album, image: r.image))
            : r.what == .artist ? .artist(r.artist) : .album(r.artist, r.album)
        let what: String = r.what == .day ? "plays in one day" : r.what == .track ? "plays of one song in a day" : "plays of one artist in a day"
        let name: String = r.what == .day ? "Mostly \(r.artist)" : r.what == .track ? r.track : r.artist
        return Opens(route: route, zoom: "record|\(r.id)") {
            ZStack(alignment: .bottomLeading) {
                ArtView(ref, px: 700, corner: 0).frame(width: 250, height: 250).zoomSource("record|\(r.id)")
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.45), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: S.pair) {
                    Text(number(r.plays)).font(.system(size: 64, weight: .thin)).monospacedDigit().foregroundStyle(.white)
                    Text(what).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(name).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    Text(LocalDay.date(r.day).formatted(.dateTime.month(.wide).day().year())).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                .padding(S.inner)
            }
            .frame(width: 250, height: 250)
            .clipShape(RoundedRectangle(cornerRadius: S.corner, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: S.corner, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Discoveries that stuck

struct DiscoveriesSection: View {
    private var store: Store { Store.shared }
    var body: some View {
        let years = store.deep.discoveries
        if years.count >= 2 {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "discoveries that stuck")
                VStack(alignment: .leading, spacing: S.inner) {
                    Chart {
                        ForEach(years) { y in
                            BarMark(x: .value("Year", String(y.year)), y: .value("New artists", y.found))
                                .foregroundStyle(.white.opacity(0.18)).cornerRadius(4)
                            BarMark(x: .value("Year", String(y.year)), y: .value("Stuck", y.stuck), width: .ratio(0.45))
                                .foregroundStyle(S.accent).cornerRadius(3)
                        }
                    }
                    .chartXAxis { AxisMarks { v in AxisValueLabel { Text("’" + String((v.as(String.self) ?? "").suffix(2))).font(.caption2.weight(.medium)).foregroundStyle(S.soft) } } }
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel().foregroundStyle(S.soft).font(.caption2) } }
                    .frame(height: 130)
                    .accessibilityLabel("New artists each year, and how many stuck")
                    HStack(spacing: 16) {
                        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.25)).frame(width: 12, height: 10); Text("new artists") }
                        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(S.accent).frame(width: 12, height: 10); Text("still played a year on") }
                    }
                    .font(.caption).foregroundStyle(S.soft)
                    ForEach(years.reversed().filter { !$0.top.isEmpty }) { y in row(y) }
                }
                .card()
            }
            .padding(.horizontal, S.margin)
        }
    }
    private func row(_ y: DiscoveryYear) -> some View {
        VStack(alignment: .leading, spacing: S.pair * 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(y.year)).font(.title3.weight(.bold)).foregroundStyle(.white)
                Spacer()
                Text("\(y.stuck) of \(number(y.found)) stuck").font(.subheadline).monospacedDigit().foregroundStyle(S.soft)
            }
            ScrollView(.horizontal) {
                HStack(spacing: S.gap) {
                    ForEach(y.top) { a in
                        Opens(route: .artist(a.name), zoom: "found|\(y.year)|\(a.name)") {
                            VStack(alignment: .leading, spacing: S.pair) {
                                ArtView(ArtRef(artist: a.name, album: a.album, url: a.image), px: 220, corner: 8).frame(width: 76).zoomSource("found|\(y.year)|\(a.name)")
                                Text(a.name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(2, reservesSpace: true)
                                Text(compact(a.plays)).font(.caption2).monospacedDigit().foregroundStyle(S.soft)
                            }
                            .frame(width: 76, alignment: .leading)
                        }
                        .accessibilityLabel("\(a.name), \(a.plays) plays")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Month by month, against his median

struct VolumeCard: View {
    private var store: Store { Store.shared }
    var body: some View {
        let d = store.deep
        if d.months.count >= 6, d.median > 0, let first = d.months.keys.min() {
            let last = LocalDay.month(LocalDay.today)
            let all = (first...last).map { (m: $0, n: d.months[$0] ?? 0) }
            let busiest = all.max { $0.n < $1.n }
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "month by month")
                VStack(alignment: .leading, spacing: S.inner) {
                    HStack(alignment: .top, spacing: S.figures) {
                        Figure(value: number(d.median), label: "your usual month", size: 30)
                        if let b = busiest { Figure(value: String(format: "%.1f×", Double(b.n) / Double(d.median)), label: "busiest, \(monthShort(b.m))", size: 30) }
                        Spacer(minLength: 0)
                    }
                    Chart {
                        ForEach(all, id: \.m) { x in
                            BarMark(x: .value("Month", x.m - first), y: .value("Plays", x.n), width: .ratio(0.7))
                                .foregroundStyle(x.n >= d.median ? S.accent : S.accent.opacity(0.45)).cornerRadius(2)
                        }
                        RuleMark(y: .value("Usual", d.median)).foregroundStyle(.white.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
                    }
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: min(36, all.count))
                    .chartScrollPosition(initialX: max(0, all.count - 36))
                    .chartXAxis {
                        AxisMarks(values: all.filter { $0.m % 12 == 0 }.map { $0.m - first }) { v in
                            AxisValueLabel { Text(String((first + (v.as(Int.self) ?? 0)) / 12)).font(.caption2.weight(.medium)).foregroundStyle(S.soft) }
                        }
                    }
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel().foregroundStyle(S.soft).font(.caption2) } }
                    .frame(height: 160)
                    .accessibilityLabel("Plays each month. Your usual month is \(d.median) plays.")
                    HStack(spacing: 16) {
                        HStack(spacing: 6) { Rectangle().fill(.white.opacity(0.7)).frame(width: 14, height: 1.5); Text("your usual month") }
                        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(S.accent).frame(width: 10, height: 10); Text("above it") }
                    }
                    .font(.caption).foregroundStyle(S.soft)
                }
                .card()
            }
            .padding(.horizontal, S.margin)
        }
    }
}

// MARK: - Carried over

struct CarryCard: View {
    private var store: Store { Store.shared }
    var body: some View {
        let list = store.deep.carry
        if list.count >= 2 {
            let done = list.filter { !$0.soFar }
            let mean = done.isEmpty ? 0 : done.reduce(0.0) { $0 + Double($1.carried) / Double($1.of) } / Double(done.count)
            let shift = done.min { Double($0.carried) / Double($0.of) < Double($1.carried) / Double($1.of) }
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "carried over")
                VStack(alignment: .leading, spacing: S.inner) {
                    HStack(alignment: .top, spacing: S.figures) {
                        Figure(value: "\(Int((mean * 100).rounded()))%", label: "of a year's top 50 stays the next", size: 30)
                        Spacer(minLength: 0)
                    }
                    Chart {
                        ForEach(list) { c in
                            BarMark(x: .value("Year", String(c.year)), y: .value("Carried", c.carried)).foregroundStyle(S.accent.opacity(c.soFar ? 0.5 : 1)).cornerRadius(3)
                            BarMark(x: .value("Year", String(c.year)), y: .value("New", c.of - c.carried)).foregroundStyle(.white.opacity(0.14)).cornerRadius(3)
                                .annotation(position: .top, spacing: 4) {
                                    Text(c.id == shift?.id ? "biggest change" : "\(Int((Double(c.carried) / Double(c.of) * 100).rounded()))%")
                                        .font(.caption2.weight(c.id == shift?.id ? .bold : .medium)).foregroundStyle(c.id == shift?.id ? .white : S.soft).fixedSize()
                                }
                        }
                    }
                    .chartYScale(domain: 0...62)
                    .chartYAxis(.hidden)
                    .chartXAxis { AxisMarks { v in AxisValueLabel { Text("’" + String((v.as(String.self) ?? "").suffix(2))).font(.caption2.weight(.medium)).foregroundStyle(S.soft) } } }
                    .frame(height: 150)
                    .accessibilityLabel("How much of each year's top 50 artists was in the year before's")
                    HStack(spacing: 16) {
                        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(S.accent).frame(width: 12, height: 10); Text("from the year before") }
                        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.25)).frame(width: 12, height: 10); Text("new to the top 50") }
                    }
                    .font(.caption).foregroundStyle(S.soft)
                }
                .card()
            }
            .padding(.horizontal, S.margin)
        }
    }
}
