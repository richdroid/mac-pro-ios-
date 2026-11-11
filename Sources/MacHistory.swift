import Charts
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// One thing the Mac measures, as the history screen shows it.
struct HistoryMetric: Identifiable, Hashable {
    enum Kind: Hashable { case percent, rate, bytes, temperature }
    let key: String, title: String, kind: Kind
    var id: String { key }
    static let cpu = HistoryMetric(key: "cpu", title: "CPU", kind: .percent)
    static let memory = HistoryMetric(key: "mem", title: "Memory", kind: .percent)
    static let download = HistoryMetric(key: "rx", title: "Download", kind: .rate)
    static let upload = HistoryMetric(key: "tx", title: "Upload", kind: .rate)
    static let disk = HistoryMetric(key: "disk", title: "Disk free", kind: .bytes)
    static func temperature(_ name: String) -> HistoryMetric { HistoryMetric(key: "temp:\(name)", title: "\(name) temperature", kind: .temperature) }
    static func named(_ key: String) -> HistoryMetric? {
        if key.hasPrefix("temp:") { return temperature(String(key.dropFirst(5))) }
        return [cpu, memory, download, upload, disk].first { $0.key == key }
    }
    func text(_ v: Double) -> String {
        switch kind {
        case .percent: return "\(Int(v.rounded()))%"
        case .rate: return Format.rate(v)
        case .bytes: return Format.bytes(v)
        case .temperature: return "\(Heat.shown(v))°"
        }
    }
    func now(_ live: LiveStatus?) -> Double? {
        guard let live else { return nil }
        switch key {
        case "cpu": return Double(live.cpu.total)
        case "mem": return 100 * live.mem.used / max(live.mem.total, 1)
        case "rx": return live.net.rxRate
        case "tx": return live.net.txRate
        default: return live.temps?.first { "temp:\($0.name)" == key }?.c
        }
    }
    func now(_ s: Status?) -> Double? {
        guard let s else { return nil }
        switch key {
        case "cpu": return Double(s.cpu.total)
        case "mem": return 100 * s.mem.used / max(s.mem.total, 1)
        case "rx": return s.net.rxRate
        case "tx": return s.net.txRate
        case "disk": return s.disk.free
        default: return s.temps?.first { "temp:\($0.name)" == key }?.c
        }
    }
}

struct TrendPoint: Decodable, Hashable {
    let t: Double, v: Double
    var peak: Double?
    var date: Date { Date(timeIntervalSince1970: t / 1000) }
}

// Each figure's last day, read ahead while Status is up, so its page slides in already drawn. A spinner only shows
// when nothing has been read yet this launch.
@MainActor
enum TrendCache {
    static var points: [String: [TrendPoint]] = [:]
    private static var readAt = Date.distantPast
    // Every figure Status opens a history for. At most once every few minutes; each page tops up its own as it reads.
    static func prefetch(_ api: API, _ s: Status) async {
        guard Date().timeIntervalSince(readAt) > 300 else { return }
        readAt = Date()
        let keys = [HistoryMetric.cpu, .memory, .download, .upload, .disk].map(\.key) + (s.temps ?? []).map { HistoryMetric.temperature($0.name).key }
        for k in keys where !Task.isCancelled {
            if let p = try? await api.trend(k), !p.isEmpty { points[k] = p }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.paneLayout) private var panes
    let metric: HistoryMetric
    @State private var points: [TrendPoint]
    @State private var loaded: Bool
    @State private var failed = false
    @State private var missed = false
    @State private var misses = MissClock()
    // The Mac has stopped answering (the app's own readings, or this page's): the figure under "Now" and the chart are
    // the last it sent, said so with their age and dimmed.
    var stale: Bool { !points.isEmpty && (missed || model.problem != nil || model.pose == "stale") }
    @ViewBuilder var staleLine: some View { if stale { StaleLine(lastRead: model.pose == "stale" ? Date().addingTimeInterval(-190) : model.pulse.lastFresh) } }
    init(metric: HistoryMetric) {
        self.metric = metric
        let kept = TrendCache.points[metric.key] ?? []
        _points = State(initialValue: kept)
        _loaded = State(initialValue: !kept.isEmpty)
    }
    @State private var hours = 24
    @State private var picked: Date?

    struct Mark: Identifiable { let date: Date; let value: Double; let run: Int; var peak: Double?; var id: Date { date } }

    var shown: [TrendPoint] {
        let from = Date().addingTimeInterval(-Double(hours) * 3600).timeIntervalSince1970 * 1000
        return points.filter { $0.t >= from }
    }
    // Averaged to what the screen can show, and broken wherever the Mac wasn't recording, rather than joined across the gap.
    // Worked out once per load or change of period, not on every redraw: the chart redraws as a finger slides along it.
    @State private var marksCache: (key: Int, marks: [Mark]) = (0, [])
    var marksKey: Int { hours &* 1_000_003 &+ points.count &+ Int(points.last?.t ?? 0) }
    var marks: [Mark] { marksCache.key == marksKey && marksKey != 0 ? marksCache.marks : computeMarks() }
    func computeMarks() -> [Mark] {
        let bucket = Double(hours) * 3600 / 240
        var out: [Mark] = [], run = 0
        let groups = Dictionary(grouping: shown) { floor($0.t / 1000 / bucket) }
        for key in groups.keys.sorted() {
            let g = groups[key]!, date = Date(timeIntervalSince1970: key * bucket + bucket / 2)
            if let last = out.last, date.timeIntervalSince(last.date) > max(240, bucket * 2.5) { run += 1 }
            out.append(Mark(date: date, value: g.map(\.v).reduce(0, +) / Double(g.count), run: run, peak: g.compactMap(\.peak).max()))
        }
        return out
    }
    var pickedMark: Mark? {
        guard let picked else { return nil }
        return marks.min { abs($0.date.timeIntervalSince(picked)) < abs($1.date.timeIntervalSince(picked)) }
    }
    // The figure under the name is its own view, the only part of the page that watches the live readings: the whole page
    // (its chart included) was worked out again with every reading, a 100 to 200 ms frame each second (gate 3).
    var readout: some View {
        HistoryReadout(metric: metric, picked: pickedMark.map { ($0.value, $0.date) }, last: points.last?.v, stale: stale)
    }
    var range: some View {
        Picker("Period", selection: $hours) {
            Text("1 hour").tag(1); Text("6 hours").tag(6); Text("24 hours").tag(24)
        }
        .pickerStyle(.segmented).labelsHidden()
    }
    var chart: some View {
        let list = marks, domain = Date().addingTimeInterval(-Double(hours) * 3600)...Date()
        return Chart {
            ForEach(list) { m in
                AreaMark(x: .value("Time", m.date), y: .value(metric.title, m.value), series: .value("Run", "\(m.run)"), stacking: .unstacked)
                    .foregroundStyle(LinearGradient(colors: [macBlue.opacity(0.32), macBlue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", m.date), y: .value(metric.title, m.value), series: .value("Run", "\(m.run)"))
                    .foregroundStyle(macBlue).lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                // Each minute's short spikes, as a soft band above the line, so the highest figure below shows on the chart too.
                if let peak = m.peak {
                    AreaMark(x: .value("Time", m.date), yStart: .value(metric.title, m.value), yEnd: .value(metric.title, peak), series: .value("Run", "peak \(m.run)"))
                        .foregroundStyle(macBlue.opacity(0.15))
                }
            }
            if let p = pickedMark {
                RuleMark(x: .value("Time", p.date)).foregroundStyle(.white.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", p.date), y: .value(metric.title, p.value)).foregroundStyle(.white).symbolSize(36)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: .automatic(includesZero: metric.kind != .temperature))
        // Not the system's chart selection, which takes every touch and stops the page scrolling.
        .chartOverlay { proxy in
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    Color.clear.holdToScrub { p in
                        guard let p, let plot = proxy.plotFrame else { picked = nil; return }
                        picked = proxy.value(atX: p.x - g[plot].minX, as: Date.self)
                    }
                    // Where the line is now, beating softly, while nothing is being read off it.
                    if pickedMark == nil, let last = list.last, Date().timeIntervalSince(last.date) < 600, let plot = proxy.plotFrame,
                       let at = proxy.position(for: (x: last.date, y: last.value)) {
                        NowDot().position(x: g[plot].minX + at.x, y: g[plot].minY + at.y).allowsHitTesting(false)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.1))
                AxisValueLabel { if let d = v.as(Double.self) { Text(metric.text(d)).font(.caption2).monospacedDigit() } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel(format: hours == 1 ? Date.FormatStyle.dateTime.hour().minute() : Date.FormatStyle.dateTime.hour())
            }
        }
        .overlay {
            if points.isEmpty {
                if failed {
                    ContentUnavailableView {
                        Label(Phrase.macAway, systemImage: "wifi.exclamationmark")
                    } actions: {
                        Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                    }
                }
                else if loaded { ContentUnavailableView("Collecting", systemImage: "chart.xyaxis.line", description: Text("The first reading arrives within a minute.")) }
                else { ProgressView() }
            }
        }
    }
    func stat(_ title: String, _ value: Double?, at: Date? = nil) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 0) {
                Text(value.map(metric.text) ?? "–").monospacedDigit()
                if let at { Text(at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
            }
        } label: { Text(title) }
    }
    var stats: some View {
        let list = shown, top = list.max { ($0.peak ?? $0.v) < ($1.peak ?? $1.v) }, low = list.min { $0.v < $1.v }
        return VStack(spacing: 0) {
            stat("Average", list.isEmpty ? nil : list.map(\.v).reduce(0, +) / Double(list.count)).padding(14)
            Divider()
            stat("Highest", top.map { $0.peak ?? $0.v }, at: top?.date).padding(14)
            Divider()
            stat("Lowest", low?.v, at: low?.date).padding(14)
        }
        .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
    // Said plainly until there's a whole day to show.
    @ViewBuilder var coverage: some View {
        if let first = points.first?.date, Date().timeIntervalSince(first) < 23.5 * 3600 {
            Text("Recording since \(first.formatted(date: Calendar.current.isDateInToday(first) ? .omitted : .abbreviated, time: .shortened)). The full 24 hours fills in from there.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder var processes: some View {
        if let sort = ProcessSort(metric: metric) { ProcessesLink(sort: sort) }
    }
    var body: some View {
        let _ = SwipeLog.mark("history body")
        // Opened, turned or closed, the page comes back where he was: the figures scroll to what was at the top.
        ScrollViewReader { proxy in
        Group {
            if panes {
                // The name first in the left pane, carried unseen in the right so both start level (PaneHeading).
                FoldSplit {
                    VStack(spacing: 14) { PaneHeading(title: metric.title); staleLine; readout; chart.frame(maxHeight: .infinity).opacity(stale ? staleDim : 1) }
                        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
                } right: {
                    ScrollView {
                        VStack(spacing: 14) { PaneHeading(title: metric.title, shown: false); range.place("range"); stats.place("stats"); processes.place("procs"); coverage.place("coverage") }
                            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
                    }
                    .scrollsUnder()
                    .keepsPlace("history-\(metric.key)", proxy)
                }
            } else {
                ScrollView {
                    VStack(spacing: 14) { PaneHeading(title: metric.title).place("title"); staleLine; readout.place("readout"); range.place("range"); chart.frame(height: 260).opacity(stale ? staleDim : 1).place("chart"); stats.place("stats"); processes.place("procs"); coverage.place("coverage") }
                        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
                }
                .scrollsUnder()
                .keepsPlace("history-\(metric.key)", proxy)
            }
        }
        }
        .holdsWhileMoving("history")
        .background(groupedBackground.ignoresSafeArea())
        .topEdge()
        // The system's own Back: on the Duo it lays out at the top of the side strip, along the top open in portrait, and
        // the edge swipe goes with it (Apple's HIG for iPhone Duo, "Vertical controls"; Richard, 2026-11-08: "the back
        // button is retarded and not iphone duo standard"). The name is placed as every pushed page's is.
        .pushedTitle()
        .animation(.easeOut(duration: 0.2), value: hours)
        .animation(Motion.quick, value: stale)
        .onChange(of: marksKey, initial: true) { _, k in marksCache = (k, computeMarks()) }
        .modifier(ProcessesOverHistory(model: model, nav: model.nav))
        .task {
            // A new reading arrives once a minute. Until the first one gets through, it keeps trying every few seconds.
            while !Task.isCancelled {
                if !model.screenOpen { await load() }
                // Sooner again after a miss, so the page is back the moment the Mac is.
                try? await Task.sleep(nanoseconds: points.isEmpty || missed ? 5_000_000_000 : 60_000_000_000)
            }
        }
    }
    func load() async {
        do { points = try await model.api.trend(metric.key); misses.hit(); failed = false; missed = false; TrendCache.points[metric.key] = points }
        catch is CancellationError { return }
        catch {
            // Said only after 8 s without an answer; until then the wait shows as waiting, not as "Collecting".
            guard misses.miss() else { return }
            failed = points.isEmpty; missed = true
        }
        loaded = true
    }
}

// The newest reading's dot, with a ring that swells and fades from it.
struct NowDot: View {
    var body: some View {
        ZStack {
            Circle().fill(macBlue.opacity(0.35)).frame(width: 8, height: 8)
                .phaseAnimator([0.0, 1.0]) { ring, t in ring.scaleEffect(1 + 1.6 * t).opacity(1 - t) } animation: { t in t == 1 ? .easeOut(duration: 1.4) : .linear(duration: 0) }
            Circle().fill(macBlue).frame(width: 7, height: 7).overlay { Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1) }
        }
        .frame(width: 24, height: 24)
    }
}

// Held down like the lock screen's flashlight: a ring fills around it under the finger, it clicks and switches. The
// glyph and its fill say which way it is; a tap on its own only wiggles it and says "Hold" in place.
struct DisplayHoldButton: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LiveStore
    @State private var pressing = false
    @State private var fill: CGFloat = 0
    @State private var wanted: Bool?    // what was asked for, until the Mac agrees
    @State private var settling: Task<Void, Never>?
    @State private var hint = false
    @State private var wiggles = 0
    @State private var failure: String?
    // What was just asked for, briefly; otherwise the Mac's own state, read every second, then every 10 seconds.
    // From the page that holds it: the status isn't watched through the model (StatusStore).
    var statusOn: Bool?
    var statusOff = false
    var reported: Bool? { store.live?.displayOn ?? statusOn }
    var isOn: Bool { wanted ?? reported ?? !statusOff }
    static let hold = 0.4, settle = 0.12
    var body: some View {
        // Dimmed in its own colours while the Mac can't be reached: an opacity laid over it from outside didn't reach
        // the glyph, which draws in its own layer for the symbol swap. Offline it takes exactly the other three's colours,
        // white circle or not, so it doesn't look as if it still works.
        let dim = model.stale ? offlineDim : 1, lit = isOn && !model.stale
        VStack(spacing: 6) {
            Image(systemName: isOn ? "sun.max.fill" : "moon")
                .font(.system(size: 20))
                .foregroundStyle(lit ? Color.black : Color.white.opacity(dim))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 52)
                .background(lit ? Color.white : Color(white: 0.16).opacity(dim), in: Circle())
                .overlay {
                    Circle().trim(from: 0, to: fill)
                        .stroke(macBlue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-5)
                }
                .scaleEffect(pressing ? 1.12 : 1)
                .animation(.spring(duration: 0.24, bounce: 0.35), value: pressing)
                .animation(.easeOut(duration: 0.14), value: isOn)
                .keyframeAnimator(initialValue: 0.0, trigger: wiggles) { v, x in v.offset(x: x) } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(-4, duration: 0.05)
                        LinearKeyframe(4, duration: 0.08)
                        LinearKeyframe(-3, duration: 0.08)
                        LinearKeyframe(0, duration: 0.06)
                    }
                }
            Text(hint ? "Hold" : "Display").font(.caption2).foregroundStyle(hint ? AnyShapeStyle(macBlue) : AnyShapeStyle(.secondary.opacity(dim))).lineLimit(1).minimumScaleFactor(0.8)
                .contentTransition(.opacity)
            if let failure {
                Text(failure).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            wiggles += 1
            withAnimation(Motion.fade) { hint = true }
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); withAnimation(Motion.fade) { hint = false } }
        }
        .onLongPressGesture(minimumDuration: Self.hold, maximumDistance: 12, perform: toggle, onPressingChanged: { p in
            // Only a finger that stays: one passing through on a scroll shouldn't make it react.
            settling?.cancel()
            if p {
                settling = Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.settle * 1e9))
                    if Task.isCancelled { return }
                    pressing = true
                    click(.light)
                    withAnimation(.linear(duration: Self.hold - Self.settle)) { fill = 1 }
                }
            } else {
                pressing = false
                if wanted == nil { withAnimation(.easeOut(duration: 0.12)) { fill = 0 } }
            }
        })
        // For the build's shot: the key held 0.3 s into its 0.4 s hold and frozen there, so the ring and the swell can be
        // checked for clipping (pose "displayhold"). Nothing is sent.
        .task {
            guard model.pose == "displayhold" else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            pressing = true
            withAnimation(.linear(duration: 0.3)) { fill = 0.3 / Self.hold }
        }
        // Nothing to switch while the Mac can't be reached.
        .allowsHitTesting(!model.stale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac display")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint("Hold to switch")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }
    #if canImport(UIKit)
    func click(_ style: UIImpactFeedbackGenerator.FeedbackStyle) { if MacPrefs.haptics { UIImpactFeedbackGenerator(style: style).impactOccurred() } }
    #else
    enum Style { case light, heavy }
    func click(_ style: Style) {}
    #endif
    func toggle() {
        guard wanted == nil else { return }
        let next = !isOn
        click(.heavy)
        wanted = next
        failure = nil
        fill = 1
        Task {
            // The ring lets go once it has clicked.
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeOut(duration: 0.22)) { fill = 0 }
        }
        Task {
            if let problem = await model.run(next ? "display-on" : "display-off") {
                wanted = nil
                withAnimation(Motion.quick) { failure = problem }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if failure == problem { withAnimation(Motion.quick) { failure = nil } }
                return
            }
            // The Mac takes a moment to change and to report it: held for at most 6 s, then the Mac's word stands, whatever
            // it is, so the key never keeps a wish that didn't happen.
            for _ in 0..<12 where reported != next { try? await Task.sleep(nanoseconds: 500_000_000) }
            wanted = nil
        }
    }
}

// A history's figure: the picked point's, or else the live reading, the day's last point, or what Status last showed; never a
// dash while a figure is known.
struct HistoryReadout: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LiveStore
    let metric: HistoryMetric
    let picked: (value: Double, date: Date)?
    let last: Double?
    let stale: Bool
    var current: Double? { metric.now(store.live) ?? last ?? metric.now(model.status) }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(picked.map { metric.text($0.value) } ?? current.map(metric.text) ?? "–")
                .font(.system(size: 34, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
            Text(picked.map { $0.date.formatted(date: .omitted, time: .shortened) } ?? (stale ? "Last reading" : "Now")).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(stale ? staleDim : 1)
    }
}
