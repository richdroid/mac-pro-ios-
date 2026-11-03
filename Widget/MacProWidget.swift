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
    struct Plan: Decodable { let fiveHour: Double?; let sevenDay: Double?; let fiveHourResets: Double?; let sevenDayResets: Double? }
    struct Usage: Decodable { let plan: Plan? }
    struct Claude: Decodable { let remoteControl: Bool }
    struct Temp: Decodable { let name: String; let c: Double }
    struct SeedApp: Decodable { let name: String; let expires: Double; let state: String; let own: Bool }
    struct Seed: Decodable { let reachable: Bool; let apps: [SeedApp] }
    let macos: String; let uptime: Double
    let cpu: CPU; let mem: Memory; let disk: Disk; let usage: Usage; let claude: Claude; let temps: [Temp]?; let iosApps: Seed?
}

struct MacEntry: TimelineEntry {
    enum State { case ok(WidgetStatus), noAddress, unreachable, sample }
    let date: Date
    let state: State
    var status: WidgetStatus? { if case .ok(let s) = state { return s }; return nil }
    var isSample: Bool { if case .sample = state { return true }; return false }
    var problem: String? {
        switch state {
        case .noAddress: return "No address set."
        case .unreachable: return "Can’t reach it. Is Tailscale on?"
        default: return nil
        }
    }
    var temps: [WidgetStatus.Temp] { isSample ? [.init(name: "CPU", c: 54), .init(name: "GPU A", c: 44), .init(name: "GPU B", c: 45), .init(name: "Memory", c: 42)] : status?.temps ?? [] }
    var uptime: String {
        let u = Int(status?.uptime ?? 187200), d = u / 86400, h = u / 3600 % 24, m = u / 60 % 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

struct MacProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MacEntry { MacEntry(date: Date(), state: .sample) }
    func snapshot(for c: WidgetAddress, in context: Context) async -> MacEntry { context.isPreview ? MacEntry(date: Date(), state: .sample) : await load(c) }
    func timeline(for c: WidgetAddress, in context: Context) async -> Timeline<MacEntry> {
        Timeline(entries: [await load(c)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
    private func load(_ c: WidgetAddress) async -> MacEntry {
        var text = (c.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "" }
        if text.isEmpty { return MacEntry(date: Date(), state: .noAddress) }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text + "/api/status") else { return MacEntry(date: Date(), state: .noAddress) }
        var r = URLRequest(url: url); r.timeoutInterval = 15; r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(WidgetStatus.self, from: d) else { return MacEntry(date: Date(), state: .unreachable) }
        return MacEntry(date: Date(), state: .ok(s))
    }
}

// The cylinder's own look: dark graphite with a cool glow.
struct Graphite: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(.white).containerBackground(for: .widget) {
            ZStack {
                LinearGradient(colors: [Color(white: 0.17), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.74).opacity(0.28), .clear], center: .center, startRadius: 10, endRadius: 170)
            }
        }
    }
}
func fahrenheit(_ c: Double) -> Int { Int((c * 9 / 5 + 32).rounded()) }
// In the app's unit when it shares its settings with the widgets, Fahrenheit otherwise.
func shownTemp(_ c: Double) -> Int { MacPrefs.widgetCelsius ? Int(c.rounded()) : fahrenheit(c) }
var tempUnit: String { MacPrefs.widgetCelsius ? "°C" : "°F" }
// The meters' blue, or the app's colour when it shares it.
var meterTint: Color {
    guard let a = MacPrefs.widgetAccent, a != .blue else { return Color(red: 0.45, green: 0.75, blue: 1) }
    return a.color
}
let claudeTint = Color(red: 0.85, green: 0.55, blue: 0.4)
func heatColor(_ c: Double) -> Color { c >= 90 ? .red : c >= 75 ? .orange : c >= 60 ? .yellow : Color(red: 0.45, green: 0.85, blue: 0.95) }
func heatLine(_ c: Double) -> String { c >= 90 ? "Fans, please!" : c >= 75 ? "Getting toasty" : c >= 60 ? "Warming up" : "Cool as a trash can" }
func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// Thick enough to read at arm's length.
struct Bar: View {
    let value: Double, color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(color).frame(width: max(5, g.size.width * min(max(value, 0), 1))).widgetAccentable()
            }
        }
        .frame(height: 6)
    }
}
// Each bar sits right under its own label, and well apart from the next meter's.
struct Meter: View {
    let label: String, value: Double, text: String
    var tint = meterTint
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer(minLength: 4)
                Text(text).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Bar(value: value, color: value > 0.85 ? .red : value > 0.65 ? .orange : tint)
        }
    }
}
struct Problem: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image("MacPro").resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit().frame(height: 44)
            Text("Mac Pro").font(.caption.weight(.semibold))
            Text(text).font(.caption2).opacity(0.7)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Status
struct StatusView: View {
    @Environment(\.widgetFamily) private var systemFamily
    var forced: WidgetFamily?
    var family: WidgetFamily { forced ?? systemFamily }
    let entry: MacEntry
    var n: (cpu: Double, mem: Double, disk: Double, week: Double?)? {
        if entry.isSample { return (0.12, 0.41, 0.58, 47) }
        guard let s = entry.status else { return nil }
        return (Double(s.cpu.total) / 100, s.mem.total > 0 ? s.mem.used / s.mem.total : 0, s.disk.total > 0 ? 1 - s.disk.free / s.disk.total : 0, s.usage.plan?.sevenDay)
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                if let n { Gauge(value: n.cpu) { Text("CPU") } currentValueLabel: { Text("\(Int(n.cpu * 100))") }.gaugeStyle(.accessoryCircular) }
                else { Image(systemName: "exclamationmark.triangle") }
            case .accessoryRectangular:
                if let n {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Mac Pro").font(.headline)
                        Text("CPU \(pct(n.cpu)) · Mem \(pct(n.mem))")
                        Text("Up \(entry.uptime)").opacity(0.7)
                    }.font(.caption)
                } else { Text("Mac Pro unreachable").font(.caption) }
            case .systemSmall:
                if let n {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 8) {
                            Image("MacPro").resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit().frame(width: 34, height: 46)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Mac Pro").font(.system(size: 16, weight: .semibold))
                                Text("Up \(entry.uptime)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        Spacer(minLength: 6)
                        VStack(spacing: 10) {
                            Meter(label: "CPU", value: n.cpu, text: pct(n.cpu))
                            Meter(label: "Memory", value: n.mem, text: pct(n.mem))
                        }
                    }
                } else { Problem(text: entry.problem ?? "") }
            default:
                if let n {
                    HStack(spacing: 16) {
                        VStack(spacing: 6) {
                            Image("MacPro").resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit().frame(height: 100)
                            Text("Up \(entry.uptime)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        }
                        // The meters share the height evenly, the space falling between them rather than inside them.
                        VStack(alignment: .leading, spacing: 0) {
                            Meter(label: "CPU", value: n.cpu, text: pct(n.cpu))
                            Spacer(minLength: 6)
                            Meter(label: "Memory", value: n.mem, text: pct(n.mem))
                            Spacer(minLength: 6)
                            Meter(label: "Disk", value: n.disk, text: pct(n.disk))
                            if let w = n.week {
                                Spacer(minLength: 6)
                                Meter(label: "Claude week", value: w / 100, text: "\(Int(w))%", tint: claudeTint)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                } else { Problem(text: entry.problem ?? "") }
            }
        }
        .modifier(Graphite())
    }
}
struct MacProWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProStatus", intent: WidgetAddress.self, provider: MacProvider()) { StatusView(entry: $0).widgetURL(URL(string: "macproapp://tab/0")) }
            .configurationDisplayName("Mac Pro Status")
            .description("CPU, memory, disk, uptime and Claude.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

// MARK: - Temperatures
struct TempView: View {
    @Environment(\.widgetFamily) private var systemFamily
    var forced: WidgetFamily?
    var family: WidgetFamily { forced ?? systemFamily }
    let entry: MacEntry
    var hottest: WidgetStatus.Temp? { entry.temps.max { $0.c < $1.c } }
    var cpu: Double? { entry.temps.first { $0.name == "CPU" }?.c ?? hottest?.c }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                if let c = cpu { Gauge(value: min(c, 100), in: 20...100) { Text(tempUnit) } currentValueLabel: { Text("\(shownTemp(c))") }.gaugeStyle(.accessoryCircular) }
                else { Image(systemName: "thermometer.medium") }
            case .accessoryInline:
                Label(cpu.map { "CPU \(shownTemp($0))\(tempUnit)" } ?? "Mac Pro unreachable", systemImage: "thermometer.medium")
            case .systemSmall:
                if let h = hottest {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) { Image(systemName: "thermometer.medium").foregroundStyle(heatColor(h.c)); Text(h.name).font(.system(size: 13, weight: .semibold)).opacity(0.8) }
                        Spacer(minLength: 0)
                        Text("\(shownTemp(h.c))°").font(.system(size: 50, weight: .semibold, design: .rounded)).foregroundStyle(heatColor(h.c)).monospacedDigit()
                        Text(heatLine(h.c)).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(2).minimumScaleFactor(0.8)
                    }
                } else { Problem(text: entry.problem ?? "No sensors yet.") }
            default:
                if let h = hottest {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text(heatLine(h.c)).font(.system(size: 16, weight: .semibold)); Spacer(); Image(systemName: "thermometer.medium").foregroundStyle(heatColor(h.c)) }
                        Spacer(minLength: 6)
                        let shown = Array(entry.temps.prefix(family == .systemLarge ? 8 : 4))
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 12) {
                            ForEach(shown, id: \.name) { t in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Text(t.name).lineLimit(1).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.8)); Spacer(); Text("\(shownTemp(t.c))°").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(heatColor(t.c)) }
                                    Bar(value: (t.c - 20) / 80, color: heatColor(t.c))
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                } else { Problem(text: entry.problem ?? "No sensors yet.") }
            }
        }
        .modifier(Graphite())
    }
}
struct MacTempWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProTemps", intent: WidgetAddress.self, provider: MacProvider()) { TempView(entry: $0).widgetURL(URL(string: "macproapp://tab/0")) }
            .configurationDisplayName("Mac Pro Temperatures")
            .description("How hot the trash can is running.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Claude usage
struct ClaudeView: View {
    let entry: MacEntry
    // The 5-hour figure only when Claude reports one; the week is always there.
    var plan: (Double?, Double)? {
        if entry.isSample { return (nil, 47) }
        guard let p = entry.status?.usage.plan, let w = p.sevenDay else { return nil }
        return (p.fiveHour, w)
    }
    var body: some View {
        Group {
            if let p = plan {
                // The same meters as the Mac Pro's own, in Claude's colour.
                let claude = claudeTint
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) { Image("ClaudeTab").resizable().scaledToFit().frame(width: 18, height: 18); Text("Claude").font(.system(size: 16, weight: .semibold)) }
                    Spacer(minLength: 6)
                    if let f = p.0 {
                        VStack(spacing: 10) {
                            Meter(label: "5 hours", value: f / 100, text: "\(Int(f))%", tint: claude)
                            Meter(label: "This week", value: p.1 / 100, text: "\(Int(p.1))%", tint: claude)
                        }
                    } else {
                        Text("\(Int(p.1))%").font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("of this week’s limit").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.75)).padding(.bottom, 6)
                        Bar(value: p.1 / 100, color: p.1 > 85 ? .red : p.1 > 65 ? .orange : claude)
                    }
                }
            } else { Problem(text: entry.problem ?? "Waiting for Claude’s usage.") }
        }
        .modifier(Graphite())
    }
}
struct MacClaudeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProClaude", intent: WidgetAddress.self, provider: MacProvider()) { ClaudeView(entry: $0).widgetURL(URL(string: "macproapp://tab/3")) }
            .configurationDisplayName("Claude Usage")
            .description("How much of your Claude limits are left.")
            .supportedFamilies([.systemSmall])
    }
}

// MARK: - Sideloaded apps
struct AppsView: View {
    let entry: MacEntry
    func left(_ a: WidgetStatus.SeedApp) -> (String, Color) {
        guard a.expires > 0 else { return (a.own ? "New" : "SideStore’s", .white.opacity(0.6)) }
        let d = Int(ceil((a.expires / 1000 - entry.date.timeIntervalSince1970) / 86400))
        return d > 0 ? ("\(d)d left", d > 1 ? .green : .orange) : ("Expired", .red)
    }
    var body: some View {
        Group {
            if let s = entry.status?.iosApps {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("On this iPhone").font(.caption.weight(.semibold)); Spacer()
                        Label(s.reachable ? "Mac can reach it" : "Away from the Mac", systemImage: s.reachable ? "wifi" : "airplane").font(.caption2).opacity(0.7)
                    }
                    ForEach(Array(s.apps.prefix(4)), id: \.name) { a in
                        let l = left(a)
                        HStack { Text(a.name).font(.system(size: 14, weight: .medium)).lineLimit(1); Spacer(); Text(l.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(l.1) }
                    }
                    Spacer(minLength: 0)
                }
            } else { Problem(text: entry.problem ?? "Checking your apps.") }
        }
        .modifier(Graphite())
    }
}
struct MacAppsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProApps", intent: WidgetAddress.self, provider: MacProvider()) { AppsView(entry: $0).widgetURL(URL(string: "macproapp://tab/1")) }
            .configurationDisplayName("Sideloaded Apps")
            .description("Days left on your apps, before they need renewing.")
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
        MacScreenControl()
        MacDisplayOffControl()
        MacRenewControl()
        MacAppsWidget()
    }
}
#endif
