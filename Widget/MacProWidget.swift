import AppIntents
import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

struct WidgetAddress: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Mac Pro"
    static var description = IntentDescription("Shows your computer at a glance.")
    @Parameter(title: "Different address (optional)") var address: String?
}

struct WidgetStatus: Decodable {
    // Every field optional: one renamed or missing field used to blank all four widgets, the temperatures included.
    struct CPU: Decodable { let total: Int? }
    struct Memory: Decodable { let used: Double?; let total: Double? }
    struct Disk: Decodable { let free: Double?; let total: Double? }
    struct Plan: Decodable { let fiveHour: Double?; let sevenDay: Double?; let fiveHourResets: Double?; let sevenDayResets: Double? }
    struct Usage: Decodable { let plan: Plan? }
    struct Temp: Decodable { let name: String; let c: Double }
    struct SeedApp: Decodable { let name: String; let expires: Double?; let state: String?; let own: Bool?; let icon: String?; let build: String? }
    struct Seed: Decodable { let reachable: Bool?; let apps: [SeedApp]? }
    // What the Mac says needs him, named ("CPU is hot"), after it's lasted (the bridge's own rule).
    struct Alert: Decodable { let title: String?; let level: String? }
    let uptime: Double?
    let cpu: CPU?; let mem: Memory?; let disk: Disk?; let usage: Usage?; let temps: [Temp]?; let iosApps: Seed?; let alerts: [Alert]?
}

// "3:42 PM" today, "Tue 3:42 PM" before: the one way every widget says when a reading was taken.
func widgetTime(_ d: Date) -> String {
    Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

struct MacEntry: TimelineEntry {
    // `unreadable`: the Mac answered, but not with a status this build can read (it wants its code, or its bridge has
    // changed). Every failure used to read "Is Tailscale on?", which pointed at the wrong fix.
    enum State { case ok(WidgetStatus), noAddress, unreachable, unreadable, sample }
    let date: Date
    let state: State
    // Set when the Mac didn't answer this time and the widget shows the last reading it had, taken then (Richard,
    // 2026-11-11: never an offline message for a blip; the last reading at once, a calm word only once it's been a while).
    var readAt: Date? = nil
    // The apps' icons, for the apps widget only.
    var icons: [String: Data] = [:]
    var status: WidgetStatus? { if case .ok(let s) = state { return s }; return nil }
    // Not heard from for a while: the reading shown is over half an hour old. A blip leaves no trace.
    var quiet: Bool { readAt.map { date.timeIntervalSince($0) > 30 * 60 } ?? false }
    var isSample: Bool { if case .sample = state { return true }; return false }
    // What the waiting widget says in its time's place: short and calm.
    var problem: String? {
        switch state {
        case .noAddress: return "Set the address in the app"
        case .unreachable: return "Waiting for the Mac"
        case .unreadable: return "Open the app to update"
        default: return nil
        }
    }
    // When the reading was taken ("11:09 PM"), or after a while without word "Last seen 11:09 PM"; waiting, the calm word.
    var when: String {
        if let problem { return problem }
        if isSample { return "" }
        let at = readAt ?? date
        return quiet ? "Last seen \(widgetTime(at))" : widgetTime(at)
    }
    var temps: [WidgetStatus.Temp] {
        isSample ? [.init(name: "CPU", c: 54), .init(name: "GPU A", c: 44), .init(name: "GPU B", c: 45), .init(name: "Memory", c: 42), .init(name: "Chipset", c: 52), .init(name: "Drive", c: 38), .init(name: "Power supply", c: 51), .init(name: "Intake air", c: 27)]
            : status?.temps ?? []
    }
    var hottest: WidgetStatus.Temp? { temps.max { $0.c < $1.c } }
    var uptime: String? {
        guard isSample || status?.uptime != nil else { return nil }
        let u = Int(status?.uptime ?? 187200), d = u / 86400, h = u / 3600 % 24, m = u / 60 % 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

struct MacProvider: AppIntentTimelineProvider {
    // Which widget, so each backs off on its own count (one shared count made the fourth wait half an hour after a blip).
    var kind = "status"
    var icons = false
    func placeholder(in context: Context) -> MacEntry { MacEntry(date: Date(), state: .sample) }
    func snapshot(for c: WidgetAddress, in context: Context) async -> MacEntry { context.isPreview ? MacEntry(date: Date(), state: .sample) : await load(c) }
    func timeline(for c: WidgetAddress, in context: Context) async -> Timeline<MacEntry> {
        let e = await load(c)
        // A fresh reading: a quarter of an hour. Without one, sooner, then backing off (2, 5, 15, 30 minutes), so a Mac away
        // overnight doesn't spend the day's refreshes and every widget keeps refreshing once it's back.
        let key = "macWidgetFails-" + kind
        let fails = UserDefaults.standard.integer(forKey: key)
        let fresh: Bool = { if case .ok = e.state, e.readAt == nil { return true }; return e.isSample }()
        UserDefaults.standard.set(fresh ? 0 : fails + 1, forKey: key)
        let wait: TimeInterval = fresh ? 15 * 60 : [2, 5, 15, 30][min(fails, 3)] * 60
        return Timeline(entries: [e], policy: .after(Date().addingTimeInterval(wait)))
    }
    private func load(_ c: WidgetAddress) async -> MacEntry {
        // Its own field, else the address the app is using (shared with the widgets once the build has their App Group,
        // MacPrefs.shared; until then this is the address baked into the build).
        var text = (c.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = SavedAddress.value }
        if text.isEmpty { return MacEntry(date: Date(), state: .noAddress) }
        if !text.contains("://") { text = "https://" + text }
        guard let base = URL(string: text), let url = URL(string: text + "/api/status") else { return MacEntry(date: Date(), state: .noAddress) }
        var r = URLRequest(url: url); r.timeoutInterval = 6; r.cachePolicy = .reloadIgnoringLocalCacheData
        // One missed answer isn't the Mac being away (the app's rule, 2026-11-10): asked twice, 15 s at most in all. Only an
        // answer that came (200) and couldn't be read is "unreadable"; a 502 while the bridge restarts is no answer.
        var unreadable = false
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            guard let s = try? JSONDecoder().decode(WidgetStatus.self, from: d) else { unreadable = true; break }
            try? d.write(to: Self.lastFile, options: .atomic)
            var e = MacEntry(date: Date(), state: .ok(s))
            if icons { e.icons = await Self.icons(s, base) }
            return e
        }
        // No reading this time: the last one, with its time, rather than a message (a day old at most).
        if let at = (try? Self.lastFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(at) < 86400, let d = try? Data(contentsOf: Self.lastFile), let s = try? JSONDecoder().decode(WidgetStatus.self, from: d) {
            var e = MacEntry(date: Date(), state: .ok(s), readAt: at)
            if icons { e.icons = await Self.icons(s, nil) }
            return e
        }
        return MacEntry(date: Date(), state: unreadable ? .unreadable : .unreachable)
    }
    static var lastFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-mac-status.json") }
    // The apps' icons, kept on disk by name: fetched once, then read from there (with no base, only read).
    static func icons(_ s: WidgetStatus, _ base: URL?) async -> [String: Data] {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // All at once: one after the other they could take 20 s on top of the status.
        return await withTaskGroup(of: (String, Data?).self) { group -> [String: Data] in
            for a in (s.iosApps?.apps ?? []).prefix(4) {
                group.addTask {
                    let file = dir.appendingPathComponent("widget-icon-" + a.name.filter { $0.isLetter || $0.isNumber } + ".png")
                    if let d = try? Data(contentsOf: file) { return (a.name, d) }
                    guard let base, let path = a.icon, let u = URL(string: path, relativeTo: base) else { return (a.name, nil) }
                    var r = URLRequest(url: u); r.timeoutInterval = 5
                    guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, d.count > 100 else { return (a.name, nil) }
                    try? d.write(to: file, options: .atomic)
                    return (a.name, d)
                }
            }
            var out: [String: Data] = [:]
            for await (n, d) in group { if let d { out[n] = d } }
            return out
        }
    }
}

// The cylinder's own look: dark graphite with a cool glow.
struct Graphite: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(.white).containerBackground(for: .widget) { GraphiteBackground() }
    }
}
struct GraphiteBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.17), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.74).opacity(0.28), .clear], center: .center, startRadius: 10, endRadius: 170)
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
// Cool is the meters' own blue: one blue across the widgets.
func heatColor(_ c: Double) -> Color { c >= 90 ? .red : c >= 75 ? .orange : c >= 60 ? .yellow : meterTint }
func heatLine(_ c: Double) -> String { c >= 90 ? "Fans, please!" : c >= 75 ? "Getting toasty" : c >= 60 ? "Warming up" : "Cool as a trash can" }
// Heat carried by shape as well as colour, so it survives a clear Home Screen where every colour is one.
func heatGlyph(_ c: Double) -> String { c >= 75 ? "thermometer.high" : c >= 60 ? "thermometer.medium" : "thermometer.low" }
func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// Thick enough to read at arm's length. No value: an empty track, as the meter waits.
struct Bar: View {
    let value: Double?, color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                if let value { Capsule().fill(color).frame(width: max(height - 1, g.size.width * min(max(value, 0), 1))).widgetAccentable() }
            }
        }
        .frame(height: height)
    }
}
// A reading's number, in its warning colour in full colour; in white with a mark beside it when it's high, so the warning
// is a shape too.
struct Reading: View {
    @Environment(\.widgetRenderingMode) private var mode
    let text: String
    var color: Color = .white
    var warn = false
    var size: CGFloat = 15
    var body: some View {
        HStack(spacing: 3) {
            if warn { Image(systemName: "flame.fill").font(.system(size: size * 0.7, weight: .semibold)).foregroundStyle(mode == .fullColor ? color : .white) }
            Text(text).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(mode == .fullColor ? color : .white)
        }
        .lineLimit(1)
    }
}
// Each bar sits right under its own label, and well apart from the next meter's. A value of nil draws the meter waiting.
struct Meter: View {
    let label: String, value: Double?, text: String
    var tint = meterTint
    // How full is orange and red: the Mac's memory sits near full by design, and a disk 86 % full isn't an emergency.
    var orange = 0.65, red = 0.85
    // Claude's meters keep Claude's colour and carry the warning on the number.
    var keepTint = false
    var labelSize: CGFloat = 14
    var body: some View {
        let v = value ?? 0
        let warn = value != nil && v > red
        let color: Color = keepTint ? tint : v > red ? .red : v > orange ? .orange : tint
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: labelSize, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer(minLength: 4)
                if keepTint, warn {
                    HStack(spacing: 2) { Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11, weight: .bold)); Text(text).font(.system(size: labelSize + 1, weight: .bold, design: .rounded)).monospacedDigit() }
                } else {
                    Text(value == nil ? "–" : text).font(.system(size: labelSize + 1, weight: .semibold, design: .rounded)).monospacedDigit().opacity(value == nil ? 0.5 : 1)
                }
            }
            Bar(value: value, color: color, height: labelSize >= 14 ? 6 : 5)
        }
    }
}
// The Mac Pro's portrait. Black on black with the background gone (StandBy) or on a tinted screen, so there it stands on a
// soft light.
struct MacPhoto: View {
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.showsWidgetContainerBackground) private var background
    var body: some View {
        Image("MacPro").resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit()
            .background {
                if mode != .fullColor || !background {
                    GeometryReader { g in
                        Ellipse().fill(RadialGradient(colors: [.white.opacity(0.28), .clear], center: .center, startRadius: 2, endRadius: max(g.size.width, g.size.height) * 0.75))
                            .frame(width: g.size.width * 1.6, height: g.size.height * 1.3).position(x: g.size.width / 2, y: g.size.height / 2)
                    }
                }
            }
    }
}
// When the reading was taken, or the calm word while it waits.
struct When: View {
    let entry: MacEntry
    var size: CGFloat = 11
    var body: some View {
        if !entry.when.isEmpty { Text(entry.when).font(.system(size: size, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).minimumScaleFactor(0.8) }
    }
}

// MARK: - Status
struct StatusView: View {
    @Environment(\.widgetFamily) private var systemFamily
    var forced: WidgetFamily?
    var family: WidgetFamily { forced ?? systemFamily }
    let entry: MacEntry
    // Each figure, or nil while there's no reading: the widget keeps its layout and waits.
    var cpu: Double? { entry.isSample ? 0.12 : entry.status?.cpu?.total.map { Double($0) / 100 } }
    var mem: Double? {
        if entry.isSample { return 0.41 }
        guard let m = entry.status?.mem, let u = m.used, let t = m.total, t > 0 else { return nil }
        return u / t
    }
    var disk: Double? {
        if entry.isSample { return 0.58 }
        guard let d = entry.status?.disk, let f = d.free, let t = d.total, t > 0 else { return nil }
        return 1 - f / t
    }
    var week: Double? { entry.isSample ? 47 : entry.status?.usage?.plan?.sevenDay }
    var hot: some View {
        Group {
            if let h = entry.hottest {
                HStack(spacing: 3) {
                    Image(systemName: heatGlyph(h.c)).font(.system(size: 11, weight: .semibold))
                    Reading(text: "\(shownTemp(h.c))°", color: heatColor(h.c), warn: h.c >= 75, size: 14)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: cpu ?? 0) { Text("CPU") } currentValueLabel: { Text(cpu.map { "\(Int($0 * 100))" } ?? "–") }.gaugeStyle(.accessoryCircular)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Mac Pro").font(.headline)
                        Spacer(minLength: 2)
                        if let h = entry.hottest { Text("\(shownTemp(h.c))°").font(.system(.caption, design: .rounded).weight(.semibold)) }
                    }
                    slim("CPU", cpu)
                    slim("Mem", mem, orange: 0.92, red: 0.97)
                    if entry.quiet || entry.problem != nil { Text(entry.when).font(.caption2).opacity(0.7).lineLimit(1) }
                }
            case .systemSmall:
                VStack(alignment: .leading, spacing: 0) {
                    // The photo with the name and uptime; under them, the full width: when (or the calm word) and the
                    // hottest temperature, so neither is squeezed beside the photo.
                    HStack(alignment: .center, spacing: 8) {
                        MacPhoto().frame(width: 34, height: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Mac Pro").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            if let up = entry.uptime { Text("Up \(up)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        When(entry: entry)
                        Spacer(minLength: 0)
                        hot
                    }
                    .frame(height: 16)
                    .padding(.top, 2)
                    Spacer(minLength: 4)
                    VStack(spacing: 10) {
                        Meter(label: "CPU", value: cpu, text: cpu.map(pct) ?? "")
                        Meter(label: "Memory", value: mem, text: mem.map(pct) ?? "", orange: 0.92, red: 0.97)
                    }
                }
            default:
                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        MacPhoto().frame(maxHeight: 88)
                        // What needs him takes the uptime's line; the temperature and the time share one.
                        if let a = entry.status?.alerts?.first(where: { !($0.title ?? "").isEmpty }), entry.readAt == nil {
                            Label(a.title ?? "", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8).labelStyle(.titleAndIcon)
                        } else if let up = entry.uptime { Text("Up \(up)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).fixedSize() }
                        HStack(spacing: 5) { hot; When(entry: entry) }.fixedSize()
                    }
                    .frame(minWidth: 76, maxWidth: 110)
                    // The meters share the height evenly, the space falling between them rather than inside them.
                    VStack(alignment: .leading, spacing: 0) {
                        Meter(label: "CPU", value: cpu, text: cpu.map(pct) ?? "")
                        Spacer(minLength: 6)
                        Meter(label: "Memory", value: mem, text: mem.map(pct) ?? "", orange: 0.92, red: 0.97)
                        Spacer(minLength: 6)
                        Meter(label: "Disk", value: disk, text: disk.map(pct) ?? "", orange: 0.9, red: 0.95)
                        if entry.status == nil || week != nil {
                            Spacer(minLength: 6)
                            Meter(label: "Claude week", value: week.map { $0 / 100 }, text: week.map { "\(Int($0))%" } ?? "", tint: claudeTint, keepTint: true)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .modifier(Graphite())
    }
    func slim(_ label: String, _ v: Double?, orange: Double = 0.65, red: Double = 0.85) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2.weight(.semibold)).frame(width: 26, alignment: .leading)
            Bar(value: v, color: .white, height: 5)
            Text(v.map(pct) ?? "–").font(.system(.caption2, design: .rounded).weight(.semibold)).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
    }
}
struct MacProWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProStatus", intent: WidgetAddress.self, provider: MacProvider()) { StatusView(entry: $0).widgetURL(URL(string: "macproapp://tab/0")) }
            .configurationDisplayName("Mac Pro Status")
            .description("CPU, memory, disk, uptime, temperature and Claude.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

// MARK: - Temperatures
struct TempView: View {
    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.widgetRenderingMode) private var mode
    var forced: WidgetFamily?
    var family: WidgetFamily { forced ?? systemFamily }
    let entry: MacEntry
    var hottest: WidgetStatus.Temp? { entry.hottest }
    var cpu: Double? { entry.temps.first { $0.name == "CPU" }?.c ?? hottest?.c }
    // The sensors, hottest first, for the lines that can't show them all.
    var ranked: [WidgetStatus.Temp] { entry.temps.sorted { $0.c > $1.c } }
    func row(_ t: WidgetStatus.Temp, label: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(t.name).lineLimit(1).minimumScaleFactor(0.85).font(.system(size: label, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 2)
                Reading(text: "\(shownTemp(t.c))°", color: heatColor(t.c), warn: t.c >= 75, size: label + 1)
            }
            Bar(value: (t.c - 20) / 80, color: heatColor(t.c), height: label >= 14 ? 6 : 4)
        }
    }
    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(hottest.map { heatLine($0.c) } ?? "Temperatures").font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            When(entry: entry)
            Image(systemName: hottest.map { heatGlyph($0.c) } ?? "thermometer.medium").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(mode == .fullColor ? (hottest.map { heatColor($0.c) } ?? .white) : .white)
        }
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: min(cpu ?? 20, 100), in: 20...100) { Image(systemName: cpu.map(heatGlyph) ?? "thermometer.medium") } currentValueLabel: { Text(cpu.map { "\(shownTemp($0))" } ?? "–") }.gaugeStyle(.accessoryCircular)
            case .accessoryInline:
                Label(cpu.map { "CPU \(shownTemp($0))\(tempUnit)" + ($0 >= 75 ? " · hot" : "") } ?? "Mac Pro · waiting", systemImage: cpu.map(heatGlyph) ?? "thermometer.medium")
            case .systemSmall:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: hottest.map { heatGlyph($0.c) } ?? "thermometer.medium").foregroundStyle(mode == .fullColor ? (hottest.map { heatColor($0.c) } ?? .white) : .white)
                        Text(hottest?.name ?? "Mac Pro").font(.system(size: 13, weight: .semibold)).opacity(0.8).lineLimit(1)
                        Spacer(minLength: 0)
                        if !entry.quiet && entry.problem == nil { When(entry: entry) }
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(hottest.map { "\(shownTemp($0.c))°" } ?? "–").font(.system(size: 50, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(mode == .fullColor ? (hottest.map { heatColor($0.c) } ?? .white) : .white)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if let h = hottest, h.c >= 75 { Image(systemName: "flame.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(mode == .fullColor ? heatColor(h.c) : .white) }
                    }
                    if ranked.count > 2 {
                        Text("\(ranked[1].name) \(shownTemp(ranked[1].c))° · \(ranked[2].name) \(shownTemp(ranked[2].c))°").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    if entry.quiet || entry.problem != nil { When(entry: entry, size: 12) }
                    else { Text(hottest.map { heatLine($0.c) } ?? "").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.8) }
                }
            case .systemLarge:
                // The photo and every sensor, one to a line.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        MacPhoto().frame(width: 44, height: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hottest.map { heatLine($0.c) } ?? "Mac Pro").font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            When(entry: entry, size: 12)
                        }
                        Spacer(minLength: 0)
                        if let h = hottest { Reading(text: "\(shownTemp(h.c))°", color: heatColor(h.c), warn: h.c >= 75, size: 30) }
                    }
                    Spacer(minLength: 10)
                    VStack(spacing: 0) {
                        if entry.temps.isEmpty {
                            ForEach(["CPU", "GPU A", "GPU B", "Memory", "Chipset", "Drive", "Power supply", "Intake air"], id: \.self) { n in
                                Meter(label: n, value: nil, text: "")
                                if n != "Intake air" { Spacer(minLength: 4) }
                            }
                        } else {
                            ForEach(Array(entry.temps.enumerated()), id: \.offset) { i, t in
                                row(t, label: 14)
                                if i < entry.temps.count - 1 { Spacer(minLength: 4) }
                            }
                        }
                    }
                }
            default:
                // All eight sensors in two columns of four.
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Spacer(minLength: 4)
                    let shown = Array(entry.temps.prefix(8))
                    if shown.isEmpty {
                        // Waiting: the same grid, its meters empty (the calm word is already in the header).
                        let names = ["CPU", "GPU A", "GPU B", "Memory", "Chipset", "Drive", "Power supply", "Intake air"]
                        Grid(horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(0..<4, id: \.self) { r in
                                GridRow { Meter(label: names[r * 2], value: nil, text: "", labelSize: 12); Meter(label: names[r * 2 + 1], value: nil, text: "", labelSize: 12) }
                            }
                        }
                    } else {
                        Grid(horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(0..<((shown.count + 1) / 2), id: \.self) { r in
                                GridRow {
                                    row(shown[r * 2], label: 12)
                                    if r * 2 + 1 < shown.count { row(shown[r * 2 + 1], label: 12) } else { Color.clear }
                                }
                            }
                        }
                    }
                }
            }
        }
        .modifier(Graphite())
    }
}
struct MacTempWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProTemps", intent: WidgetAddress.self, provider: MacProvider(kind: "temps")) { TempView(entry: $0).widgetURL(URL(string: "macproapp://tab/0")) }
            .configurationDisplayName("Mac Pro Temperatures")
            .description("How hot the trash can is running, every sensor.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Claude usage
struct ClaudeView: View {
    @Environment(\.widgetRenderingMode) private var mode
    let entry: MacEntry
    var plan: WidgetStatus.Plan? { entry.status?.usage?.plan }
    var week: Double? { entry.isSample ? 47 : plan?.sevenDay }
    var five: Double? { entry.isSample ? nil : plan?.fiveHour }
    // When each limit starts afresh: "resets 3:40 PM" within the day, "resets Thu" after.
    func resets(_ ms: Double?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let d = Date(timeIntervalSince1970: ms / 1000)
        guard d > entry.date else { return nil }
        return "resets " + (d.timeIntervalSince(entry.date) < 20 * 3600 ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.weekday(.abbreviated)))
    }
    func meter(_ label: String, _ v: Double?, _ reset: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Meter(label: label, value: v.map { $0 / 100 }, text: v.map { "\(Int($0))%" } ?? "", tint: claudeTint, keepTint: true)
            if let reset { Text(reset).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image("ClaudeTab").resizable().renderingMode(.template).scaledToFit().frame(width: 22, height: 22)
                    .foregroundStyle(mode == .fullColor ? claudeTint : .white).widgetAccentable()
                Text("Claude").font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
            }
            When(entry: entry).padding(.top, 2)
            Spacer(minLength: 4)
            if five != nil || week == nil {
                VStack(spacing: 4) {
                    meter("5 hours", five, resets(plan?.fiveHourResets))
                    meter("This week", week, resets(plan?.sevenDayResets))
                }
            } else if let w = week {
                Text("\(Int(w))%").font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("of this week’s limit").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.75)).padding(.bottom, 6)
                Bar(value: w / 100, color: claudeTint)
                if let r = resets(plan?.sevenDayResets) { Text(r).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).padding(.top, 3) }
            }
        }
        .modifier(Graphite())
    }
}
struct MacClaudeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProClaude", intent: WidgetAddress.self, provider: MacProvider(kind: "claude")) { ClaudeView(entry: $0).widgetURL(URL(string: "macproapp://tab/3")) }
            .configurationDisplayName("Claude Usage")
            .description("How much of your Claude limits are left, and when they reset.")
            .supportedFamilies([.systemSmall])
    }
}

// MARK: - Apps on this iPhone
func iconImage(_ d: Data) -> Image? {
    #if canImport(UIKit)
    return UIImage(data: d).map { Image(uiImage: $0) }
    #else
    return NSImage(data: d).map { Image(nsImage: $0) }
    #endif
}
struct AppsView: View {
    @Environment(\.widgetRenderingMode) private var mode
    let entry: MacEntry
    // Richard's apps come from TestFlight (their build), a signed one by the days it has left.
    func status(_ a: WidgetStatus.SeedApp) -> (String, Color) {
        if a.state == "testflight" { return (a.build.map { "Build \($0)" } ?? "TestFlight", .white.opacity(0.6)) }
        guard let x = a.expires, x > 0 else { return (a.build.map { "Build \($0)" } ?? "", .white.opacity(0.6)) }
        let d = Int(ceil((x / 1000 - entry.date.timeIntervalSince1970) / 86400))
        return d > 0 ? ("\(d)d left", d > 2 ? .green : .orange) : ("Expired", .red)
    }
    var apps: [WidgetStatus.SeedApp] { Array((entry.status?.iosApps?.apps ?? []).prefix(4)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("On this iPhone").font(.system(size: 14, weight: .semibold)); Spacer()
                When(entry: entry)
            }
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 0) {
                if apps.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.1)).frame(width: 48, height: 48).frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(apps, id: \.name) { a in
                        let st = status(a)
                        VStack(spacing: 3) {
                            Group {
                                if let d = entry.icons[a.name], let i = iconImage(d) {
                                    i.resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
                                } else {
                                    ZStack { Color.white.opacity(0.12); Text(String(a.name.prefix(1))).font(.system(size: 20, weight: .semibold)) }
                                }
                            }
                            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            Text(a.name).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(st.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(mode == .fullColor ? st.1 : .white.opacity(0.7)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .modifier(Graphite())
    }
}
struct MacAppsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProApps", intent: WidgetAddress.self, provider: MacProvider(kind: "apps", icons: true)) { AppsView(entry: $0).widgetURL(URL(string: "macproapp://tab/1")) }
            .configurationDisplayName("Apps on this iPhone")
            .description("Your apps from the Mac, their builds, and the days left on any it signed.")
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
        MacAppsWidget()
    }
}
#endif
