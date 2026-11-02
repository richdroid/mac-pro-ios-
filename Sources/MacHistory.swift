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
        case .temperature: return "\(Heat.f(v))°"
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
}

struct TrendPoint: Decodable, Hashable {
    let t: Double, v: Double
    var peak: Double?
    var date: Date { Date(timeIntervalSince1970: t / 1000) }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LiveStore
    @Environment(\.paneLayout) private var panes
    let metric: HistoryMetric
    @State private var points: [TrendPoint] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var hours = 24
    @State private var picked: Date?

    struct Mark: Identifiable { let date: Date; let value: Double; let run: Int; var peak: Double?; var id: Date { date } }

    var shown: [TrendPoint] {
        let from = Date().addingTimeInterval(-Double(hours) * 3600).timeIntervalSince1970 * 1000
        return points.filter { $0.t >= from }
    }
    // Averaged to what the screen can show, and broken wherever the Mac wasn't recording, rather than joined across the gap.
    var marks: [Mark] {
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
    var current: Double? { metric.now(store.live) ?? points.last?.v }

    var readout: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(pickedMark.map { metric.text($0.value) } ?? current.map(metric.text) ?? "–")
                .font(.system(size: 34, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
            Text(pickedMark.map { $0.date.formatted(date: .omitted, time: .shortened) } ?? "Now").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                AreaMark(x: .value("Time", m.date), y: .value(metric.title, m.value), series: .value("Run", "\(m.run)"))
                    .foregroundStyle(LinearGradient(colors: [macBlue.opacity(0.32), macBlue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", m.date), y: .value(metric.title, m.value), series: .value("Run", "\(m.run)"))
                    .foregroundStyle(macBlue).lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                // Each minute's short spikes, so the highest figure below can be seen on the chart too.
                if let peak = m.peak {
                    LineMark(x: .value("Time", m.date), y: .value(metric.title, peak), series: .value("Run", "peak \(m.run)"))
                        .foregroundStyle(macBlue.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                }
            }
            if let p = pickedMark {
                RuleMark(x: .value("Time", p.date)).foregroundStyle(.white.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", p.date), y: .value(metric.title, p.value)).foregroundStyle(.white).symbolSize(36)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: .automatic(includesZero: metric.kind != .temperature))
        .chartXSelection(value: $picked)
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
                if failed { ContentUnavailableView("Can’t reach the Mac", systemImage: "wifi.exclamationmark") }
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
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        Group {
            if panes {
                FoldSplit {
                    VStack(spacing: 14) { readout; chart.frame(maxHeight: .infinity) }.padding(20)
                } right: {
                    ScrollView { VStack(spacing: 14) { range; stats; processes; coverage }.padding(20) }
                }
            } else {
                ScrollView {
                    VStack(spacing: 14) { readout; range; chart.frame(height: 260); stats; processes; coverage }.padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
        .background(groupedBackground.ignoresSafeArea())
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeOut(duration: 0.25), value: hours)
        .navigationDestination(item: $model.processes) { ProcessesView(first: $0) }
        .task {
            // A new reading arrives once a minute.
            while !Task.isCancelled {
                do { points = try await model.api.trend(metric.key); failed = false }
                catch is CancellationError { return }
                catch { failed = points.isEmpty }
                loaded = true
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
}

// Held down like the lock screen's flashlight: it swells under the finger, clicks and switches.
struct DisplayHoldButton: View {
    @EnvironmentObject var model: AppModel
    let say: (String) -> Void
    @State private var pressing = false
    @State private var wanted: Bool?    // what was asked for, until the Mac agrees
    var isOn: Bool { wanted ?? model.status?.displayOn ?? (model.status?.screen != "display off") }
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: isOn ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 20))
                .foregroundStyle(isOn ? Color.black : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 52)
                .background(isOn ? Color.white : Color(white: 0.16), in: Circle())
                .scaleEffect(pressing ? 1.22 : 1)
                .animation(.spring(duration: 0.3, bounce: 0.4), value: pressing)
                .animation(.easeOut(duration: 0.18), value: isOn)
            Text(isOn ? "Display on" : "Display off").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { say("Hold to turn the display \(isOn ? "off" : "on")") }
        .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 40, perform: toggle, onPressingChanged: { p in
            pressing = p
            if p { click(.light) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac display")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }
    #if canImport(UIKit)
    func click(_ style: UIImpactFeedbackGenerator.FeedbackStyle) { UIImpactFeedbackGenerator(style: style).impactOccurred() }
    #else
    enum Style { case light, heavy }
    func click(_ style: Style) {}
    #endif
    func toggle() {
        guard wanted == nil else { return }
        let next = !isOn
        click(.heavy)
        wanted = next
        Task {
            if let problem = await model.run(next ? "display-on" : "display-off") {
                wanted = nil
                say(problem)
                return
            }
            // The Mac takes a moment to change and to report it.
            for _ in 0..<4 where model.status?.displayOn != next {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await model.refresh()
            }
            wanted = nil
        }
    }
}
