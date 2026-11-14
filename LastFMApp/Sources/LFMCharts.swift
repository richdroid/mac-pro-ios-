import SwiftUI
import CoreGraphics
import ImageIO

// Charts: his top artists, albums and tracks for the last week, month, 3 months, 6 months, year or all time, or any past
// week; how each moved against the stretch before; plays and listening time; a collage of the covers to share; and the
// top ten's ranks over the last twelve weeks as a bump chart. Worked out from his own plays on the phone (Last.fm's own
// charts stand in only for a stretch the first read hasn't reached yet).
enum Period: Hashable, Sendable {
    case days(Int)
    case all
    case week(ChartWeek)
    var name: String {
        switch self {
        case .days(7): return "Week"
        case .days(30): return "Month"
        case .days(365): return "Year"
        case .days(let n): return "\(n / 30) months"
        case .all: return "All time"
        case .week(let w): return w.label
        }
    }
    var lastfm: String? {
        switch self {
        case .days(7): return "7day"
        case .days(30): return "1month"
        case .days(90): return "3month"
        case .days(180): return "6month"
        case .days(365): return "12month"
        case .all: return "overall"
        default: return nil
        }
    }
    var before: String {
        switch self {
        case .days(7): return "the week before"
        case .days(30): return "the month before"
        case .days(365): return "the year before"
        case .days(let n): return "the \(n / 30) months before"
        case .all: return "a week ago"
        case .week: return "the week before"
        }
    }
    static let rolling: [Period] = [.days(7), .days(30), .days(90), .days(180), .days(365), .all]
}

struct ChartSummary: Sendable {
    let plays: Int
    let secs: Int?
    let artists: Int, albums: Int, tracks: Int
    let change: Double?        // plays against the stretch before
}

@MainActor @Observable final class ChartsModel {
    static let shared = ChartsModel()
    var period: Period = .days(7) { didSet { reload() } }
    var kind: Kind = .albums { didSet { reload(); reloadBump() } }
    var size = 4
    var entries: [Entry] = []
    var summary: ChartSummary?
    var weeks: [ChartWeek] = []
    var bump: [Entry] = []
    var bumpRanks: [[String: Int]] = []
    var bumpWeeks: [(Int, Int)] = []
    var shareImage: Image?
    @ObservationIgnored private var cache: [String: ([Entry], ChartSummary?)] = [:]
    @ObservationIgnored private var bumpCache: [Kind: ([Entry], [[String: Int]], [(Int, Int)])] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stamp = 0       // the history's size when the cache was made

    private func key(_ p: Period, _ k: Kind) -> String { "\(p)|\(k.rawValue)" }

    func appear() {
        // Kept for a while: worked out again only when the history has grown by a song or two.
        let read = HistorySync.shared.read
        if abs(read - stamp) > 3 { cache = [:]; bumpCache = [:]; stamp = read }
        reload(); reloadBump()
        if weeks.isEmpty { Task { weeks = await ChartWeek.load() } }
    }

    func window(_ p: Period) -> (from: Int, to: Int, prevFrom: Int, prevTo: Int) {
        let now = Int(Clock.now.timeIntervalSince1970) + 1
        switch p {
        case .days(let n): return (now - n * 86400, now, now - 2 * n * 86400, now - n * 86400)
        case .all: return (0, now, 0, now - 7 * 86400)
        case .week(let w): return (w.from, w.to, w.from - 7 * 86400, w.from)
        }
    }

    func reload() {
        let p = period, k = kind, ck = key(p, k)
        if let hit = cache[ck] { entries = hit.0; summary = hit.1; render(); return }
        task?.cancel()
        task = Task {
            let sync = HistorySync.shared
            let w = window(p)
            let db = HistoryDB.reader
            var list: [Entry] = []
            var sum: ChartSummary?
            if sync.complete || sync.coveredFrom <= w.from {
                let median = await db.medianLength()
                list = await db.top(k, from: w.from, to: w.to, limit: 100, median: median)
                let withPrev = sync.complete || sync.coveredFrom <= w.prevFrom
                if withPrev {
                    let prev = await db.ranks(k, from: w.prevFrom, to: w.prevTo, limit: 1000)
                    for i in list.indices {
                        if let r = prev[list[i].rankKey] { list[i].move = r > list[i].rank ? .up(r - list[i].rank) : r < list[i].rank ? .down(list[i].rank - r) : .same }
                        else { list[i].move = .new }
                    }
                }
                let t = await db.time(from: w.from, to: w.to)
                let d = await db.distinct(from: w.from, to: w.to)
                var change: Double?
                if withPrev, case .all = p {} else if withPrev {
                    let before = await db.between(w.prevFrom, w.prevTo)
                    if before > 0 { change = Double(t.plays - before) / Double(before) }
                }
                sum = ChartSummary(plays: t.plays, secs: HistoryDB.listening(plays: t.plays, secs: t.secs, known: t.known, median: median),
                                   artists: d.artists, albums: d.albums, tracks: d.tracks, change: change)
            } else {
                var week: ChartWeek?
                if case .week(let x) = p { week = x }
                list = await RemoteChart.top(k, period: p.lastfm, week: week)
            }
            guard !Task.isCancelled else { return }
            cache[ck] = (list, sum)
            if period == p && kind == k {
                withAnimation(.smooth(duration: 0.3)) { entries = list; summary = sum }
                render()
            }
        }
    }

    // The last twelve weeks (his calendar's weeks, this one so far), and how the ten most played across them ranked in each.
    func reloadBump() {
        let k = kind
        if let hit = bumpCache[k] { bump = hit.0; bumpRanks = hit.1; bumpWeeks = hit.2; return }
        guard HistorySync.shared.complete || HistorySync.shared.coveredFrom < Int(Clock.now.timeIntervalSince1970) - 90 * 86400 else { return }
        Task {
            let cal = Calendar.current
            guard let ws = cal.dateInterval(of: .weekOfYear, for: Clock.now)?.start else { return }
            let now = Int(Clock.now.timeIntervalSince1970) + 1
            let weeks: [(Int, Int)] = (0..<12).reversed().compactMap { k in
                guard let s = cal.date(byAdding: .weekOfYear, value: -k, to: ws), let e = cal.date(byAdding: .weekOfYear, value: 1, to: s) else { return nil }
                return (Int(s.timeIntervalSince1970), min(Int(e.timeIntervalSince1970), now))
            }
            guard let first = weeks.first else { return }
            let db = HistoryDB.reader
            let top = await db.top(k, from: first.0, to: now, limit: 10, median: 215)
            let ranks = await db.weekly(k, weeks: weeks, depth: 20)
            bumpCache[k] = (top, ranks, weeks)
            if kind == k { bump = top; bumpRanks = ranks; bumpWeeks = weeks }
        }
    }

    // The collage as one picture to share: the covers drawn edge to edge at 2,000 px, made whenever the grid changes.
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    func render() {
        let n = size
        let list = Array(entries.prefix(n * n))
        renderTask?.cancel()
        shareImage = nil
        guard !list.isEmpty else { return }
        renderTask = Task {
            let side = 2000, cell = side / n
            var images: [CGImage?] = []
            for e in list { images.append(await ArtStore.shared.image(e.art, px: 700)) }
            guard !Task.isCancelled,
                  let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(red: 0.035, green: 0.035, blue: 0.045, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.interpolationQuality = .high
            for (i, img) in images.enumerated() {
                let r = CGRect(x: (i % n) * cell, y: side - (i / n + 1) * cell, width: cell, height: cell)
                if let img { ctx.draw(img, in: r) }
                else {
                    let p = Palette.from(name: list[i].artist + list[i].album)
                    ctx.setFillColor(CGColor(red: p.vivid.r, green: p.vivid.g, blue: p.vivid.b, alpha: 1))
                    ctx.fill(r)
                }
            }
            guard let out = ctx.makeImage(), !Task.isCancelled else { return }
            shareImage = Image(decorative: out, scale: 1)
        }
    }
}

struct ChartsTab: View {
    let top: Int
    @Environment(\.paneLayout) private var pane
    @State private var picking = false
    @State private var all = false
    private var m: ChartsModel { ChartsModel.shared }
    var body: some View {
        Group {
            if pane {
                FoldSplit {
                    Page(top: top) { VStack(alignment: .leading, spacing: S.section) { head; waiting; figures; collage }.padding(.top, S.head) }
                } right: {
                    Page(top: top) { VStack(alignment: .leading, spacing: S.section) { list; BumpSection() }.padding(.top, S.section) }
                }
            } else {
                Page(top: top) {
                    VStack(alignment: .leading, spacing: S.section) { head; waiting; figures; collage; list; BumpSection() }.padding(.top, S.head)
                }
            }
        }
        .onAppear { m.appear() }
        .onChange(of: m.period) { _, _ in all = false }
        .onChange(of: m.kind) { _, _ in all = false }
        .cover(isPresented: $picking) { WeekPicker() }
        .task {
            guard Pose.name == "weeks" else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            picking = true
        }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: S.head) {
            HubTitle(text: "charts", size: 80)
            periods
            Picker("Show", selection: Binding(get: { m.kind }, set: { m.kind = $0 })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, S.margin)
        }
    }

    // The stretches as glass capsules, a past week among them once chosen, and the way to choose one.
    private var periods: some View {
        let list: [Period] = { if case .week = m.period { return Period.rolling + [m.period] }; return Period.rolling }()
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: S.gap / 1.5) {
                    ForEach(list, id: \.self) { p in
                        let on = p == m.period
                        Button { withAnimation(.snappy(duration: 0.25)) { m.period = p } } label: {
                            Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(on ? .black : .white)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background { if on { Capsule().fill(.white) } }
                                .glassEffect(.regular, in: Capsule())
                        }
                        .buttonStyle(Press())
                        .id(p)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    Button { picking = true } label: {
                        Label("Any week", systemImage: "calendar").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 36)
                            .glassEffect(.regular, in: Capsule())
                    }
                    .buttonStyle(Press())
                }
                .padding(.horizontal, S.margin)
            }
            .scrollIndicators(.hidden)
            .clipped()
            .onChange(of: m.period) { _, p in withAnimation(.smooth) { proxy.scrollTo(p, anchor: .center) } }
        }
    }

    // Only the very first time a chart is worked out (a later one keeps the last on screen until the new one is ready).
    @ViewBuilder private var waiting: some View {
        if m.entries.isEmpty { ProgressView().tint(.white).controlSize(.large).frame(maxWidth: .infinity).padding(.vertical, S.section) }
    }

    @ViewBuilder private var figures: some View {
        if let s = m.summary {
            VStack(alignment: .leading, spacing: S.inner) {
                HStack(alignment: .lastTextBaseline, spacing: S.figures) {
                    VStack(alignment: .leading, spacing: S.pair) {
                        Text(number(s.plays)).font(.system(size: 64, weight: .thin)).monospacedDigit().foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                        Text("plays").font(.title3.weight(.light)).foregroundStyle(S.soft)
                    }
                    if let c = s.change {
                        VStack(alignment: .leading, spacing: S.pair) {
                            HStack(spacing: 4) {
                                Image(systemName: c >= 0 ? "arrow.up.right" : "arrow.down.right").font(.title3.weight(.semibold))
                                Text("\(Int((abs(c) * 100).rounded()))%").font(.system(size: 30, weight: .light)).monospacedDigit()
                            }
                            .foregroundStyle(.white)
                            Text("against \(m.period.before)").font(.subheadline).foregroundStyle(S.soft)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Spacer(minLength: 0)
                }
                FigureGrid(items: [
                    s.secs.map { (duration($0), "listening") },
                    (number(s.artists), "artists"),
                    (number(s.albums), "albums"),
                    (number(s.tracks), "tracks"),
                ].compactMap { $0 })
            }
            .padding(.horizontal, S.margin)
        }
    }

    // The covers edge to edge, a hairline apart, in the grid chosen; shared as one picture.
    @ViewBuilder private var collage: some View {
        if !m.entries.isEmpty {
            let n = m.size
            let cells = Array(m.entries.prefix(n * n))
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "collage")
                HStack(spacing: S.gap) {
                    Picker("Grid", selection: Binding(get: { m.size }, set: { m.size = $0; m.render() })) {
                        ForEach([3, 4, 5], id: \.self) { Text("\($0)×\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let img = m.shareImage {
                        ShareLink(item: img, preview: SharePreview("Your \(m.period.name.lowercased()) in \(m.kind.noun)", image: img)) {
                            Label("Share", systemImage: "square.and.arrow.up").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).frame(height: 32)
                        }
                        .buttonStyle(.glass)
                    } else {
                        Label("Share", systemImage: "square.and.arrow.up").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 32).foregroundStyle(S.soft)
                            .glassEffect(.regular, in: Capsule())
                            .accessibilityLabel("Share, getting the picture ready")
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: n), spacing: 1) {
                    ForEach(cells) { e in
                        Opens(route: e.route, zoom: "collage|\(e.id)") {
                            ArtView(e.art, px: n >= 5 ? 300 : 500, corner: 0).zoomSource("collage|\(e.id)")
                        }
                        .accessibilityLabel("\(e.rank). \(e.title)")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.smooth(duration: 0.35), value: n)
            }
            .padding(.horizontal, S.margin)
        }
    }

    @ViewBuilder private var list: some View {
        if !m.entries.isEmpty {
            let shown = all ? m.entries : Array(m.entries.prefix(10))
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "top \(m.kind.noun)")
                VStack(spacing: 0) {
                    ForEach(shown) { e in EntryRow(e: e, context: "chart") }
                }
                if m.entries.count > 10 {
                    Button { withAnimation(.smooth) { all.toggle() } } label: {
                        Text(all ? "Show the top 10" : "Show all \(m.entries.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .glassEffect(.regular, in: Capsule())
                    }
                    .buttonStyle(Press())
                    .padding(.top, S.pair)
                }
            }
            .padding(.horizontal, S.margin)
        }
    }
}

// The ten most played across the last twelve weeks, their rank each week as lines in their covers' colours (rank 1 at
// the top), falling off the foot when out of the top 20. Tap a name to follow its line.
struct BumpSection: View {
    @State private var follow: String?
    private var m: ChartsModel { ChartsModel.shared }
    var body: some View {
        if !m.bump.isEmpty, m.bumpRanks.count >= 2 {
            let depth = 15
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "the last 12 weeks")
                VStack(alignment: .leading, spacing: S.inner) {
                    chart(depth)
                    legend
                }
                .card()
            }
            .padding(.horizontal, S.margin)
        }
    }
    private func colour(_ e: Entry) -> Color { (ArtStore.shared.palette(e.art) ?? Palette.from(name: e.artist + e.album)).vivid.color }
    private func chart(_ depth: Int) -> some View {
        let weeks = m.bumpRanks.count
        return VStack(spacing: S.pair * 2) {
            Canvas { ctx, size in
                let left: CGFloat = 22, right: CGFloat = 8
                let w = size.width - left - right, h = size.height - 8
                func x(_ i: Int) -> CGFloat { left + CGFloat(i) / CGFloat(weeks - 1) * w }
                func y(_ r: Int) -> CGFloat { 4 + CGFloat(r - 1) / CGFloat(depth - 1) * h }
                for r in [1, 5, 10, 15] {
                    ctx.draw(Text("\(r)").font(.caption2.weight(.medium)).foregroundStyle(S.soft), at: CGPoint(x: 8, y: y(r)))
                    ctx.stroke(Path { $0.move(to: CGPoint(x: left, y: y(r))); $0.addLine(to: CGPoint(x: size.width - right, y: y(r))) }, with: .color(.white.opacity(0.05)), lineWidth: 1)
                }
                // The line followed is drawn last, bright and thick; the rest stay as a faint weave behind it.
                let lead = followed
                for e in m.bump.sorted(by: { a, _ in a.id != lead }) {
                    let on = e.id == lead
                    let c = colour(e).opacity(on ? 1 : 0.28)
                    var runs: [[CGPoint]] = [], run: [CGPoint] = []
                    for i in 0..<weeks {
                        if let r = m.bumpRanks[i][e.rankKey], r <= depth { run.append(CGPoint(x: x(i), y: y(r))) }
                        else if !run.isEmpty { runs.append(run); run = [] }
                    }
                    if !run.isEmpty { runs.append(run) }
                    for pts in runs {
                        var path = Path()
                        smooth(&path, pts, move: true)
                        ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: on ? 4 : 1.8, lineCap: .round, lineJoin: .round))
                        for p in pts {
                            let d: CGFloat = on ? 9 : 4
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)), with: .color(c))
                        }
                    }
                }
            }
            .frame(height: 260)
            HStack {
                if let f = m.bumpWeeks.first { Text(dateShort(f.0)) }
                Spacer()
                Text("This week")
            }
            .font(.caption2.weight(.medium)).foregroundStyle(S.soft)
            .padding(.leading, 22)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ranks over the last twelve weeks: " + m.bump.map { e in "\(e.title), now \(m.bumpRanks.last?[e.rankKey].map { "number \($0)" } ?? "out of the top 20")" }.joined(separator: "; "))
    }
    // Followed: the one tapped, else the most played across the twelve weeks (the longest line to follow).
    private var followed: String? { follow ?? m.bump.first?.id }
    private var byNow: [Entry] { m.bump }
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: S.figures)], alignment: .leading, spacing: S.pair * 2) {
            ForEach(byNow) { e in
                let on = followed == e.id
                Button { withAnimation(.snappy) { follow = e.id } } label: {
                    HStack(spacing: 8) {
                        Capsule().fill(colour(e)).frame(width: 14, height: 4)
                        Text(e.title).font(.subheadline.weight(on ? .bold : .medium)).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(m.bumpRanks.last?[e.rankKey].map { "\($0)" } ?? "–").font(.subheadline).monospacedDigit().foregroundStyle(S.soft)
                    }
                    .frame(minHeight: 32)
                    .opacity(on ? 1 : 0.6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Press())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// Any of his weeks, newest first, a year at a time, each with its most played cover and its plays.
struct WeekPicker: View {
    @Environment(\.dismiss) private var dismiss
    private var m: ChartsModel { ChartsModel.shared }
    var body: some View {
        let byYear = Dictionary(grouping: m.weeks, by: \.year)
        let years = byYear.keys.sorted(by: >)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    HubTitle(text: "any week", size: 72).padding(.bottom, S.head)
                    ForEach(years, id: \.self) { y in
                        SectionHead(text: String(y)).padding(.horizontal, S.margin).padding(.top, y == years.first ? 0 : S.section).padding(.bottom, S.head)
                        ForEach(byYear[y] ?? []) { w in WeekRow(w: w) { m.period = .week(w); dismiss() } .padding(.horizontal, S.margin) }
                    }
                    if m.weeks.isEmpty { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, S.section) }
                }
                .padding(.bottom, S.section)
            }
            .scrollIndicators(.hidden)
            .modifier(BarFade())
            .background { Backdrop(ref: Store.shared.hero?.art, moving: false, dim: 0.2) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label("Close", systemImage: "xmark") } }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task { if m.weeks.isEmpty { m.weeks = await ChartWeek.load() } }
    }
}

struct WeekRow: View {
    let w: ChartWeek
    let pick: () -> Void
    @State private var top: (plays: Int, artist: String, album: String, url: String?)?
    var body: some View {
        Button(action: pick) {
            HStack(spacing: S.gap) {
                ZStack {
                    if let t = top, !t.album.isEmpty { ArtView(ArtRef(artist: t.artist, album: t.album, url: t.url), px: 156, corner: 6) }
                    else { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.06)) }
                }
                .frame(width: S.art, height: S.art)
                VStack(alignment: .leading, spacing: S.pair / 2) {
                    Text(w.label).font(.body.weight(.semibold)).foregroundStyle(.white)
                    Text(top.map { $0.artist.isEmpty ? " " : $0.artist } ?? " ").font(.subheadline).foregroundStyle(S.soft).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(top.map { number($0.plays) } ?? "").font(.body.weight(.medium)).monospacedDigit().foregroundStyle(.white)
            }
            .padding(.vertical, S.row / 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .task(id: w.from) { top = await HistoryDB.reader.weekTop(from: w.from, to: w.to) }
    }
}
