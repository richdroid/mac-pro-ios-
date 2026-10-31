import AppIntents
import SwiftUI
import WidgetKit

struct WidgetAddress: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Mac Pro"
    static var description = IntentDescription("Shows your Mac Pro.")
    @Parameter(title: "Different address (optional)") var address: String?
}

struct WidgetStatus: Decodable {
    struct CPU: Decodable { let total: Int }
    struct Memory: Decodable { let used: Double; let total: Double }
    struct Disk: Decodable { let free: Double; let total: Double }
    struct Plan: Decodable { let fiveHour: Double?; let sevenDay: Double? }
    struct Usage: Decodable { let plan: Plan? }
    struct Temp: Decodable { let name: String; let c: Double }
    struct History: Decodable { let cpu: [Double] }
    struct SeedApp: Decodable { let name: String; let expires: Double; let state: String; let own: Bool }
    struct Seed: Decodable { let reachable: Bool; let apps: [SeedApp] }
    let uptime: Double
    let cpu: CPU; let mem: Memory; let disk: Disk; let usage: Usage; let temps: [Temp]?; let iosApps: Seed?; let hist: History
}

// What the widgets draw, whether it came from the Mac or is a sample in the widget gallery.
struct MacSnapshot {
    var cpu = 0.0, mem = 0.0, disk = 0.0
    var fiveHour: Double?, week: Double?
    var uptime = ""
    var temps: [(name: String, c: Double)] = []
    var history: [Double] = []
    var apps: [(name: String, days: Int?)] = []
    static let sample = MacSnapshot(cpu: 0.34, mem: 0.52, disk: 0.58, fiveHour: 6, week: 47, uptime: "2d 4h",
        temps: [("CPU", 54), ("GPU A", 44), ("GPU B", 47), ("Memory", 42), ("Chipset", 52), ("Drive", 38)],
        history: [20, 24, 30, 18, 26, 44, 38, 30, 52, 40, 33, 28, 36, 34],
        apps: [("Mac Pro", 6), ("Chumby", 2), ("SideStore", nil)])
    init(cpu: Double, mem: Double, disk: Double, fiveHour: Double?, week: Double?, uptime: String, temps: [(name: String, c: Double)], history: [Double], apps: [(name: String, days: Int?)]) {
        self.cpu = cpu; self.mem = mem; self.disk = disk; self.fiveHour = fiveHour; self.week = week; self.uptime = uptime; self.temps = temps; self.history = history; self.apps = apps
    }
    init(_ s: WidgetStatus, now: Date) {
        cpu = Double(s.cpu.total) / 100
        mem = s.mem.total > 0 ? s.mem.used / s.mem.total : 0
        disk = s.disk.total > 0 ? 1 - s.disk.free / s.disk.total : 0
        fiveHour = s.usage.plan?.fiveHour; week = s.usage.plan?.sevenDay
        let u = Int(s.uptime), d = u / 86400, h = u / 3600 % 24, m = u / 60 % 60
        uptime = d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
        temps = (s.temps ?? []).map { ($0.name, $0.c) }
        history = Array(s.hist.cpu.suffix(40))
        apps = (s.iosApps?.apps ?? []).map { a in
            (a.name, a.expires > 0 ? Int(ceil((a.expires / 1000 - now.timeIntervalSince1970) / 86400)) : nil)
        }
    }
    var hottest: (name: String, c: Double)? { temps.max { $0.c < $1.c } }
    var cpuTemp: Double? { temps.first { $0.name == "CPU" }?.c ?? hottest?.c }
    // One dial per part: the hotter GPU stands for both.
    var dials: [(icon: String, c: Double)] {
        var out: [(String, Double)] = []
        if let c = temps.first(where: { $0.name == "CPU" })?.c { out.append(("cpu", c)) }
        if let g = temps.filter({ $0.name.hasPrefix("GPU") }).map(\.c).max() { out.append(("display", g)) }
        if let c = temps.first(where: { $0.name == "Memory" })?.c { out.append(("memorychip", c)) }
        if let c = temps.first(where: { $0.name == "Drive" })?.c { out.append(("internaldrive", c)) }
        return out
    }
}

struct MacEntry: TimelineEntry {
    let date: Date
    var snapshot: MacSnapshot?
    var problem = ""
}

struct MacProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MacEntry { MacEntry(date: Date(), snapshot: .sample) }
    func snapshot(for c: WidgetAddress, in context: Context) async -> MacEntry { context.isPreview ? MacEntry(date: Date(), snapshot: .sample) : await load(c) }
    func timeline(for c: WidgetAddress, in context: Context) async -> Timeline<MacEntry> {
        Timeline(entries: [await load(c)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
    private func load(_ c: WidgetAddress) async -> MacEntry {
        var text = (c.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "" }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text + "/api/status") else { return MacEntry(date: Date(), problem: "No address") }
        var r = URLRequest(url: url); r.timeoutInterval = 15; r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(WidgetStatus.self, from: d) else { return MacEntry(date: Date(), problem: "Tailscale off?") }
        return MacEntry(date: Date(), snapshot: MacSnapshot(s, now: Date()))
    }
}

// The cylinder's own look: graphite, with a cool glow.
struct GraphiteBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.18), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.74).opacity(0.28), .clear], center: .center, startRadius: 10, endRadius: 170)
        }
    }
}
struct Unreachable: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image("MacPro").resizable().scaledToFit().opacity(0.45).frame(maxHeight: 64)
            Label(text, systemImage: "wifi.slash").font(.caption2.weight(.medium)).opacity(0.75)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
private let cpuBlue = Color(red: 0.35, green: 0.72, blue: 1), memPink = Color(red: 0.98, green: 0.42, blue: 0.66), diskGold = Color(red: 1, green: 0.76, blue: 0.3)

// MARK: - Status
struct StatusBody: View {
    let family: WidgetFamily
    let entry: MacEntry
    func dial(_ v: Double, _ c: Color, _ icon: String) -> some View {
        ArcGauge(v, style: c, width: 6) {
            VStack(spacing: 0) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(c)
                Text("\(Int((v * 100).rounded()))").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
    }
    var body: some View {
        if let n = entry.snapshot {
            switch family {
            case .accessoryCircular:
                Gauge(value: n.cpu) { Image(systemName: "cpu") } currentValueLabel: { Text("\(Int(n.cpu * 100))") }.gaugeStyle(.accessoryCircular)
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Gauge(value: n.cpu) { Image(systemName: "cpu") }.gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.8)
                    Gauge(value: n.mem) { Image(systemName: "memorychip") }.gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.8)
                    Gauge(value: n.disk) { Image(systemName: "internaldrive") }.gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.8)
                }
            case .systemSmall:
                ZStack {
                    Ring(value: n.cpu, color: cpuBlue, width: 10)
                    Ring(value: n.mem, color: memPink, width: 10).padding(13)
                    Ring(value: n.disk, color: diskGold, width: 10).padding(26)
                    Image("MacPro").resizable().scaledToFit().frame(height: 36)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                HStack(spacing: 12) {
                    Image("MacPro").resizable().scaledToFit().frame(maxHeight: 112)
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            dial(n.cpu, cpuBlue, "cpu")
                            dial(n.mem, memPink, "memorychip")
                            dial(n.disk, diskGold, "internaldrive")
                        }
                        SparkLine(values: n.history, top: 100, color: cpuBlue).frame(height: 24)
                    }
                }
            }
        } else if family == .accessoryCircular || family == .accessoryRectangular {
            Image(systemName: "wifi.slash")
        } else { Unreachable(text: entry.problem) }
    }
}

// MARK: - Temperatures
struct TempBody: View {
    let family: WidgetFamily
    let entry: MacEntry
    var body: some View {
        if let n = entry.snapshot, let hot = n.hottest {
            switch family {
            case .accessoryCircular:
                Gauge(value: Heat.level(n.cpuTemp ?? hot.c)) { Image(systemName: "thermometer.medium") } currentValueLabel: { Text("\(Heat.f(n.cpuTemp ?? hot.c))") }.gaugeStyle(.accessoryCircular)
            case .accessoryInline:
                Label("\(Heat.f(n.cpuTemp ?? hot.c))°F", systemImage: "thermometer.medium")
            case .systemSmall:
                ArcGauge(Heat.level(hot.c), style: Heat.gradient, width: 12) {
                    VStack(spacing: 0) {
                        Text("\(Heat.f(hot.c))°").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Image(systemName: "thermometer.medium").font(.system(size: 13)).foregroundStyle(Heat.color(hot.c))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                HStack(spacing: 10) {
                    ForEach(n.dials, id: \.icon) { d in
                        VStack(spacing: 6) {
                            ArcGauge(Heat.level(d.c), style: Heat.gradient, width: 7) {
                                Text("\(Heat.f(d.c))°").font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                            Image(systemName: d.icon).font(.system(size: 15)).foregroundStyle(Heat.color(d.c))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if family == .accessoryCircular || family == .accessoryInline {
            Image(systemName: "thermometer.medium")
        } else { Unreachable(text: entry.problem) }
    }
}

// MARK: - Claude
struct ClaudeBody: View {
    let entry: MacEntry
    static let clay = Color(red: 0.85, green: 0.5, blue: 0.36)
    var body: some View {
        if let n = entry.snapshot, let w = n.week {
            ZStack {
                Ring(value: w / 100, color: Self.clay, width: 12)
                Ring(value: (n.fiveHour ?? 0) / 100, color: Color(red: 0.98, green: 0.8, blue: 0.62), width: 12).padding(16)
                VStack(spacing: 0) {
                    Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(Self.clay)
                    Text("\(Int(w))%").font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { Unreachable(text: entry.problem.isEmpty ? "No reading" : entry.problem) }
    }
}

// MARK: - Sideloaded apps
struct AppsBody: View {
    let entry: MacEntry
    func color(_ d: Int) -> Color { d > 2 ? .green : d > 0 ? .orange : .red }
    var body: some View {
        if let n = entry.snapshot, !n.apps.isEmpty {
            VStack(spacing: 11) {
                ForEach(Array(n.apps.prefix(4)), id: \.name) { a in
                    HStack(spacing: 10) {
                        Text(a.name).font(.footnote.weight(.medium)).lineLimit(1).frame(width: 84, alignment: .leading)
                        if let d = a.days {
                            ProgressView(value: Double(min(max(d, 0), 7)), total: 7).tint(color(d))
                            Text("\(max(d, 0))d").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(color(d)).frame(width: 26, alignment: .trailing)
                        } else {
                            ProgressView(value: 1, total: 1).tint(.white.opacity(0.25))
                            Image(systemName: "infinity").font(.footnote).opacity(0.6).frame(width: 26, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { Unreachable(text: entry.problem.isEmpty ? "No apps" : entry.problem) }
    }
}

// MARK: - The widgets
struct InWidget<C: View>: View {
    @Environment(\.widgetFamily) private var family
    let content: (WidgetFamily) -> C
    var body: some View {
        content(family).foregroundStyle(.white).containerBackground(for: .widget) { GraphiteBackground() }
    }
}

struct MacProWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProStatus", intent: WidgetAddress.self, provider: MacProvider()) { e in InWidget { StatusBody(family: $0, entry: e) } }
            .configurationDisplayName("Mac Pro Status")
            .description("CPU, memory and disk at a glance.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}
struct MacTempWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProTemps", intent: WidgetAddress.self, provider: MacProvider()) { e in InWidget { TempBody(family: $0, entry: e) } }
            .configurationDisplayName("Mac Pro Temperatures")
            .description("How hot the trash can is running.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
    }
}
struct MacClaudeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProClaude", intent: WidgetAddress.self, provider: MacProvider()) { e in InWidget { _ in ClaudeBody(entry: e) } }
            .configurationDisplayName("Claude Usage")
            .description("This week’s limit outside, the 5-hour limit inside.")
            .supportedFamilies([.systemSmall])
    }
}
struct MacAppsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProApps", intent: WidgetAddress.self, provider: MacProvider()) { e in InWidget { _ in AppsBody(entry: e) } }
            .configurationDisplayName("Sideloaded Apps")
            .description("Days left before your apps need renewing.")
            .supportedFamilies([.systemMedium])
    }
}

#if !GALLERY
@main
struct MacProWidgets: WidgetBundle {
    var body: some Widget {
        MacProWidget()
        MacTempWidget()
        MacClaudeWidget()
        MacAppsWidget()
    }
}
#endif
