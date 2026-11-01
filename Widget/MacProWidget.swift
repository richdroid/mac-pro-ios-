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
    func icon(for part: String) -> String {
        if part == "CPU" { return "cpu" }
        if part.hasPrefix("GPU") { return "display" }
        if part == "Memory" { return "memorychip" }
        if part == "Drive" { return "internaldrive" }
        if part == "Chipset" { return "square.stack.3d.up" }
        if part.hasPrefix("Power") { return "bolt" }
        return "wind"
    }
    func others(than part: String) -> [(icon: String, c: Double)] {
        var out = dials.filter { $0.icon != icon(for: part) }
        if let chip = temps.first(where: { $0.name == "Chipset" }), part != "Chipset" { out.append(("square.stack.3d.up", chip.c)) }
        return Array(out.prefix(4))
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
    var stale = false       // the last good reading, because the Mac can't be reached right now
}

struct MacProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MacEntry { MacEntry(date: Date(), snapshot: .sample) }
    func snapshot(for c: WidgetAddress, in context: Context) async -> MacEntry { context.isPreview ? MacEntry(date: Date(), snapshot: .sample) : await load(c) }
    func timeline(for c: WidgetAddress, in context: Context) async -> Timeline<MacEntry> {
        Timeline(entries: [await load(c)], policy: .after(Date().addingTimeInterval(30 * 60)))
    }
    private func load(_ c: WidgetAddress) async -> MacEntry {
        var text = (c.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "" }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text + "/api/status") else { return MacEntry(date: Date(), problem: "No address") }
        var r = URLRequest(url: url); r.timeoutInterval = 15; r.cachePolicy = .reloadIgnoringLocalCacheData
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-status.json")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(WidgetStatus.self, from: d) else {
            // Keep showing what was last known, marked as old, rather than wiping it.
            if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(WidgetStatus.self, from: d) {
                return MacEntry(date: Date(), snapshot: MacSnapshot(s, now: Date()), problem: "Tailscale off?", stale: true)
            }
            return MacEntry(date: Date(), problem: "Tailscale off?")
        }
        try? d.write(to: file, options: .atomic)
        return MacEntry(date: Date(), snapshot: MacSnapshot(s, now: Date()))
    }
}

// Black like the app, so the cylinder melts into it with the same soft glow.
struct GraphiteBackground: View {
    var body: some View {
        ZStack {
            Color.black
            EllipticalGradient(colors: [Color(white: 0.2), Color(white: 0.06)], center: UnitPoint(x: 0.5, y: 0.35), startRadiusFraction: 0, endRadiusFraction: 0.75)
        }
    }
}
// The Mac Pro as the gauge: its round body in perspective, the vented top, a polished side, and a level that curves with it.
struct CylinderMeter: View {
    let value: Double
    var tint: Color = macBlue
    var flat = false        // one tone, for clear and tinted Home Screens
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.redactionReasons) private var redacted
    var body: some View {
        let mono = flat || mode != .fullColor
        let fraction = redacted.isEmpty ? CGFloat(min(max(value, 0), 1)) : 0
        Canvas { ctx, size in
            let h = min(size.height, size.width / 0.62), w = h * 0.62
            let o = CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2)
            let e = w * 0.3                               // how tall the round ends look
            let top = CGRect(x: o.x, y: o.y, width: w, height: e)
            let base = CGRect(x: o.x, y: o.y + h - e, width: w, height: e)
            var shell = Path(CGRect(x: o.x, y: o.y + e / 2, width: w, height: h - e))
            shell.addEllipse(in: base)
            shell.addEllipse(in: top)
            let left = CGPoint(x: o.x, y: 0), right = CGPoint(x: o.x + w, y: 0)
            // A polished black side with a long highlight.
            let polish = Gradient(stops: [.init(color: Color(white: 0.05), location: 0), .init(color: Color(white: 0.36), location: 0.14), .init(color: Color(white: 0.1), location: 0.32), .init(color: Color(white: 0.05), location: 0.72), .init(color: Color(white: 0.24), location: 1)])
            ctx.fill(shell, with: mono ? .color(.white.opacity(0.2)) : .linearGradient(polish, startPoint: left, endPoint: right))
            // The level, curved like the body it sits in.
            let span = h - e
            let surface = o.y + span * (1 - fraction)
            if fraction > 0.005 {
                var liquid = Path(CGRect(x: o.x, y: surface + e / 2, width: w, height: h - e - (surface - o.y)))
                liquid.addEllipse(in: base)
                liquid.addEllipse(in: CGRect(x: o.x, y: surface, width: w, height: e))
                let shade = Gradient(stops: [.init(color: tint.opacity(0.62), location: 0), .init(color: tint, location: 0.22), .init(color: tint.opacity(0.92), location: 0.68), .init(color: tint.opacity(0.58), location: 1)])
                ctx.fill(liquid, with: mono ? .color(.white.opacity(0.82)) : .linearGradient(shade, startPoint: left, endPoint: right))
                if !mono { ctx.fill(Path(ellipseIn: CGRect(x: o.x, y: surface, width: w, height: e)), with: .color(.white.opacity(0.18))) }
            }
            // The vented top, cut out on a clear Home Screen so it still reads as a Mac Pro.
            var opening = ctx
            let inner = top.insetBy(dx: w * 0.15, dy: e * 0.17)
            if mono {
                opening.blendMode = .destinationOut
                opening.fill(Path(ellipseIn: inner), with: .color(.black))
                opening.blendMode = .normal
                opening.stroke(Path(ellipseIn: top.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white), lineWidth: max(1, h * 0.012))
            } else {
                opening.fill(Path(ellipseIn: top), with: .color(Color(white: 0.2)))
                opening.stroke(Path(ellipseIn: top.insetBy(dx: 0.5, dy: 0.5)), with: .color(Color(white: 0.72)), lineWidth: max(0.75, h * 0.01))
                opening.fill(Path(ellipseIn: inner), with: .color(.black))
                // The fins inside the opening.
                let c = CGPoint(x: inner.midX, y: inner.midY)
                for i in 0..<14 {
                    let a = CGFloat(i) / 14 * 2 * .pi
                    var fin = Path()
                    fin.move(to: CGPoint(x: c.x + cos(a) * inner.width * 0.26, y: c.y + sin(a) * inner.height * 0.26))
                    fin.addLine(to: CGPoint(x: c.x + cos(a) * inner.width * 0.47, y: c.y + sin(a) * inner.height * 0.47))
                    opening.stroke(fin, with: .color(Color(white: 0.4)), lineWidth: max(0.5, h * 0.006))
                }
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
            CylinderMeter(value: value, tint: tint, flat: flat).frame(maxHeight: .infinity)
            Text(text).font(.system(size: size, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            // A fixed box: the symbols differ in height, which would leave the cylinders uneven.
            Image(systemName: icon).font(.system(size: size - 5, weight: .medium)).opacity(0.6).frame(height: size - 2)
        }
    }
}
// Cylinders spread to the widget's margins, so all four edges match.
struct MeterRow<C: View>: View {
    @ViewBuilder let content: () -> C
    var body: some View { HStack(spacing: 0) { Spacer(minLength: 0); Group(subviews: content()) { views in
        ForEach(Array(views.enumerated()), id: \.offset) { i, v in
            if i > 0 { Spacer(minLength: 6) }
            v
        }
    }; Spacer(minLength: 0) } }
}
// Lock Screen: small cylinders with the number beneath each.
struct LockMeter: View {
    let value: Double, text: String
    var body: some View {
        VStack(spacing: 1) {
            CylinderMeter(value: value).frame(maxHeight: .infinity)
            Text(text).font(.system(size: 11, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Status
struct StatusBody: View {
    let family: WidgetFamily
    let entry: MacEntry
    var flat = false
    func whole(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }
    var body: some View {
        if let n = entry.snapshot {
            switch family {
            case .accessoryCircular:
                LockMeter(value: n.cpu, text: whole(n.cpu))
            case .accessoryRectangular:
                HStack(spacing: 12) { LockMeter(value: n.cpu, text: whole(n.cpu)); LockMeter(value: n.mem, text: whole(n.mem)); LockMeter(value: n.disk, text: whole(n.disk)) }
            case .systemSmall:
                MeterRow {
                    MeterColumn(value: n.cpu, text: whole(n.cpu), icon: "cpu", tint: levelTint(n.cpu), flat: flat, size: 14)
                    MeterColumn(value: n.mem, text: whole(n.mem), icon: "memorychip", tint: levelTint(n.mem), flat: flat, size: 14)
                    MeterColumn(value: n.disk, text: whole(n.disk), icon: "internaldrive", tint: levelTint(n.disk), flat: flat, size: 14)
                }
            default:
                MeterRow {
                    MeterColumn(value: n.cpu, text: whole(n.cpu) + "%", icon: "cpu", tint: levelTint(n.cpu), flat: flat)
                    MeterColumn(value: n.mem, text: whole(n.mem) + "%", icon: "memorychip", tint: levelTint(n.mem), flat: flat)
                    MeterColumn(value: n.disk, text: whole(n.disk) + "%", icon: "internaldrive", tint: levelTint(n.disk), flat: flat)
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
    var flat = false
    var body: some View {
        if let n = entry.snapshot, let hot = n.hottest {
            switch family {
            case .accessoryCircular:
                LockMeter(value: Heat.level(n.cpuTemp ?? hot.c), text: "\(Heat.f(n.cpuTemp ?? hot.c))°")
            case .accessoryInline:
                Label("\(Heat.f(n.cpuTemp ?? hot.c))°F", systemImage: "thermometer.medium")
            case .systemSmall:
                HStack(spacing: 12) {
                    CylinderMeter(value: Heat.level(hot.c), tint: heatTint(hot.c), flat: flat)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Heat.f(hot.c))°").font(.system(size: 32, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                        Image(systemName: n.icon(for: hot.name)).font(.system(size: 14, weight: .medium)).opacity(0.65)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                // The hottest part large, the rest as a quiet list: nothing like the Status widget.
                HStack(spacing: 18) {
                    CylinderMeter(value: Heat.level(hot.c), tint: heatTint(hot.c), flat: flat)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Heat.f(hot.c))°").font(.system(size: 42, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                        Image(systemName: n.icon(for: hot.name)).font(.system(size: 15, weight: .medium)).opacity(0.65)
                    }
                    Spacer(minLength: 0)
                    Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 9) {
                        ForEach(n.others(than: hot.name), id: \.icon) { d in
                            GridRow {
                                Image(systemName: d.icon).font(.system(size: 13, weight: .medium)).opacity(0.65).frame(width: 20)
                                Text("\(Heat.f(d.c))°").font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(flat ? .white : heatTint(d.c) == macBlue ? .white : heatTint(d.c))
                            }
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
struct ClayBar: View {
    let value: Double?
    let label: String
    static let clay = Color(red: 0.85, green: 0.47, blue: 0.34)
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(Self.clay).frame(height: max(g.size.width, g.size.height * min(max((value ?? 0) / 100, 0), 1))).opacity(value == nil ? 0 : 1).widgetAccentable()
                }
            }
            .frame(width: 30)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "–").font(.system(size: 16, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11, weight: .medium)).opacity(0.65)
        }
        .frame(maxWidth: .infinity)
    }
}
struct ClaudeBody: View {
    let entry: MacEntry
    var flat = false
    var body: some View {
        if let n = entry.snapshot, n.week != nil || n.fiveHour != nil {
            HStack(spacing: 8) {
                ClayBar(value: n.fiveHour, label: "5 hours")
                ClayBar(value: n.week, label: "This week")
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
    var tab = 0
    var stale = false
    let content: (WidgetFamily) -> C
    var body: some View {
        content(family).foregroundStyle(.white)
            .opacity(stale ? 0.6 : 1)
            .overlay(alignment: .topTrailing) { if stale { Image(systemName: "wifi.slash").font(.system(size: 11, weight: .semibold)).opacity(0.8) } }
            .containerBackground(for: .widget) { GraphiteBackground() }
            .widgetURL(URL(string: "macproapp://tab/\(tab)"))
    }
}

struct MacProWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProStatus", intent: WidgetAddress.self, provider: MacProvider()) { e in InWidget(stale: e.stale) { StatusBody(family: $0, entry: e) } }
            .configurationDisplayName("Mac Pro Status")
            .description("CPU, memory and disk at a glance.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}
struct MacTempWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProTemps", intent: WidgetAddress.self, provider: MacProvider()) { e in InWidget(stale: e.stale) { TempBody(family: $0, entry: e) } }
            .configurationDisplayName("Mac Pro Temperatures")
            .description("How hot the trash can is running.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
    }
}
struct MacClaudeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProClaude", intent: WidgetAddress.self, provider: MacProvider()) { e in InWidget(tab: 3, stale: e.stale) { _ in ClaudeBody(entry: e) } }
            .configurationDisplayName("Claude Usage")
            .description("How much of your 5-hour and weekly limits you’ve used.")
            .supportedFamilies([.systemSmall])
    }
}
struct MacAppsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProApps", intent: WidgetAddress.self, provider: MacProvider()) { e in InWidget(tab: 1, stale: e.stale) { _ in AppsBody(entry: e) } }
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
        MacScreenControl()
        MacDisplayOffControl()
        MacRenewControl()
        MacAppsWidget()
    }
}
#endif
