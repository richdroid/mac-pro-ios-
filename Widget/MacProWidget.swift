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

// Black like the app, so the cylinder melts into it with the same soft glow.
struct GraphiteBackground: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color(white: 0.2), .clear], center: UnitPoint(x: 0.5, y: 0.35), startRadius: 4, endRadius: 190)
        }
    }
}
// The Mac Pro as the gauge: a drawn cylinder that fills from the base, with its rim, highlight and vents.
struct CylinderMeter: View {
    let value: Double
    var tint: Color = macBlue
    var flat = false        // one tone, for clear and tinted Home Screens
    @Environment(\.widgetRenderingMode) private var mode
    var body: some View {
        let mono = flat || mode != .fullColor
        Canvas { ctx, size in
            let h = min(size.height, size.width / 0.62), w = h * 0.62
            let o = CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2)
            let corner = w * 0.24
            let body = Path(roundedRect: CGRect(x: o.x, y: o.y, width: w, height: h), cornerRadius: corner, style: .continuous)
            let ink: Color = mono ? .white : tint
            ctx.fill(body, with: .color(mono ? .white.opacity(0.22) : Color(white: 0.17)))
            // The level.
            var level = ctx
            level.clip(to: body)
            let v = CGFloat(min(max(value, 0), 1))
            let fillTop = o.y + h * (1 - v)
            level.fill(Path(CGRect(x: o.x, y: fillTop, width: w, height: h * v)), with: mono ? .color(ink) : .linearGradient(Gradient(colors: [tint.opacity(0.75), tint]), startPoint: CGPoint(x: o.x, y: fillTop), endPoint: CGPoint(x: o.x, y: o.y + h)))
            // The rim and its opening.
            let rim = CGRect(x: o.x + w * 0.09, y: o.y + h * 0.035, width: w * 0.82, height: h * 0.13)
            ctx.stroke(Path(ellipseIn: rim), with: .color(mono ? .white : Color(white: 0.72)), lineWidth: max(1, h * 0.012))
            // The long reflection down the side.
            ctx.fill(Path(roundedRect: CGRect(x: o.x + w * 0.13, y: o.y + h * 0.24, width: w * 0.045, height: h * 0.6), cornerRadius: w * 0.02), with: .color(.white.opacity(mono ? 0.35 : 0.22)))
            // The vent slots around the base.
            for i in 0..<9 {
                let t = (CGFloat(i) - 4) / 4
                let slot = CGRect(x: o.x + w * (0.5 + t * 0.34) - w * 0.012, y: o.y + h * (0.905 + (1 - t * t) * 0.03), width: w * 0.024, height: h * 0.035)
                ctx.fill(Path(roundedRect: slot, cornerRadius: 1), with: .color(mono ? .white.opacity(0.5) : .black.opacity(0.55)))
            }
        }
        .aspectRatio(0.62, contentMode: .fit)
    }
}
struct Unreachable: View {
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            CylinderMeter(value: 0).frame(maxHeight: 70)
            Label(text, systemImage: "wifi.slash").font(.caption2.weight(.medium)).opacity(0.75)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
private func levelTint(_ v: Double) -> Color { v > 0.9 ? .red : v > 0.75 ? .orange : macBlue }
private func heatTint(_ c: Double) -> Color { c >= 90 ? .red : c >= 75 ? .orange : c >= 60 ? Color(red: 1, green: 0.8, blue: 0.1) : macBlue }

struct MeterColumn: View {
    let value: Double, text: String, icon: String
    var tint: Color = macBlue
    var flat = false
    var size: CGFloat = 16
    var body: some View {
        VStack(spacing: 5) {
            CylinderMeter(value: value, tint: tint, flat: flat)
            Text(text).font(.system(size: size, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Image(systemName: icon).font(.system(size: size - 5, weight: .medium)).opacity(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Status
struct StatusBody: View {
    let family: WidgetFamily
    let entry: MacEntry
    var flat = false
    func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    var body: some View {
        if let n = entry.snapshot {
            switch family {
            case .accessoryCircular:
                Gauge(value: n.cpu) { Image(systemName: "cpu") } currentValueLabel: { Text("\(Int(n.cpu * 100))") }.gaugeStyle(.accessoryCircular)
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    CylinderMeter(value: n.cpu); CylinderMeter(value: n.mem); CylinderMeter(value: n.disk)
                    Text(pct(n.cpu)).font(.headline).monospacedDigit()
                }
            case .systemSmall:
                HStack(spacing: 10) {
                    MeterColumn(value: n.cpu, text: "\(Int(n.cpu * 100))", icon: "cpu", tint: levelTint(n.cpu), flat: flat, size: 14)
                    MeterColumn(value: n.mem, text: "\(Int(n.mem * 100))", icon: "memorychip", tint: levelTint(n.mem), flat: flat, size: 14)
                    MeterColumn(value: n.disk, text: "\(Int(n.disk * 100))", icon: "internaldrive", tint: levelTint(n.disk), flat: flat, size: 14)
                }
            default:
                HStack(spacing: 24) {
                    MeterColumn(value: n.cpu, text: pct(n.cpu), icon: "cpu", tint: levelTint(n.cpu), flat: flat)
                    MeterColumn(value: n.mem, text: pct(n.mem), icon: "memorychip", tint: levelTint(n.mem), flat: flat)
                    MeterColumn(value: n.disk, text: pct(n.disk), icon: "internaldrive", tint: levelTint(n.disk), flat: flat)
                }
                .padding(.horizontal, 12)
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
    var flat = false
    var body: some View {
        if let n = entry.snapshot, let hot = n.hottest {
            switch family {
            case .accessoryCircular:
                Gauge(value: Heat.level(n.cpuTemp ?? hot.c)) { Image(systemName: "thermometer.medium") } currentValueLabel: { Text("\(Heat.f(n.cpuTemp ?? hot.c))") }.gaugeStyle(.accessoryCircular)
            case .accessoryInline:
                Label("\(Heat.f(n.cpuTemp ?? hot.c))°F", systemImage: "thermometer.medium")
            case .systemSmall:
                HStack(spacing: 12) {
                    CylinderMeter(value: Heat.level(hot.c), tint: heatTint(hot.c), flat: flat)
                    Text("\(Heat.f(hot.c))°").font(.system(size: 30, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                HStack(spacing: 16) {
                    ForEach(n.dials, id: \.icon) { d in
                        MeterColumn(value: Heat.level(d.c), text: "\(Heat.f(d.c))°", icon: d.icon, tint: heatTint(d.c), flat: flat)
                    }
                }
                .padding(.horizontal, 6)
            }
        } else if family == .accessoryCircular || family == .accessoryInline {
            Image(systemName: "thermometer.medium")
        } else { Unreachable(text: entry.problem) }
    }
}

// MARK: - Claude
struct ClaudeBody: View {
    let entry: MacEntry
    var flat = false
    static let clay = Color(red: 0.85, green: 0.47, blue: 0.34)
    var body: some View {
        if let n = entry.snapshot, let w = n.week {
            HStack(spacing: 14) {
                MeterColumn(value: (n.fiveHour ?? 0) / 100, text: "\(Int(n.fiveHour ?? 0))%", icon: "clock", tint: Self.clay, flat: flat, size: 15)
                MeterColumn(value: w / 100, text: "\(Int(w))%", icon: "calendar", tint: Self.clay, flat: flat, size: 15)
            }
        } else { Unreachable(text: entry.problem.isEmpty ? "No reading" : entry.problem) }
    }
}

// MARK: - Sideloaded apps
struct AppsBody: View {
    let entry: MacEntry
    func color(_ d: Int) -> Color { d > 2 ? macBlue : d > 0 ? .orange : .red }
    var body: some View {
        if let n = entry.snapshot, !n.apps.isEmpty {
            VStack(spacing: 12) {
                ForEach(Array(n.apps.prefix(4)), id: \.name) { a in
                    HStack(spacing: 10) {
                        Text(a.name).font(.footnote.weight(.medium)).lineLimit(1).frame(width: 78, alignment: .leading)
                        // One slot for each of the 7 days an app lasts.
                        HStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { i in
                                Capsule().fill(a.days == nil ? Color.white.opacity(0.28) : i < (a.days ?? 0) ? color(a.days ?? 0) : Color.white.opacity(0.14)).frame(height: 14)
                            }
                        }
                        Group {
                            if let d = a.days { Text("\(max(d, 0))d").monospacedDigit() } else { Image(systemName: "infinity") }
                        }.font(.footnote.weight(.semibold)).frame(width: 24, alignment: .trailing)
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
            .description("This week’s limit on the outside, the 5-hour limit inside.")
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
