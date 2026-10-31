import AppIntents
import SwiftUI
import WidgetKit

// The address lives in the widget's own settings, so this needs no shared App Group and survives free-account signing.
struct WidgetAddress: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Mac Pro"
    static var description = IntentDescription("Shows your Mac Pro's status.")
    @Parameter(title: "Different address (optional)") var address: String?
}

struct WidgetStatus: Decodable {
    struct CPU: Decodable { let total: Int }
    struct Memory: Decodable { let used: Double; let total: Double }
    struct Disk: Decodable { let free: Double; let total: Double }
    struct Plan: Decodable { let fiveHour: Double?; let sevenDay: Double? }
    struct Usage: Decodable { let plan: Plan? }
    struct Claude: Decodable { let remoteControl: Bool }
    struct Temp: Decodable { let name: String; let c: Double }
    let macos: String; let uptime: Double
    let cpu: CPU; let mem: Memory; let disk: Disk; let usage: Usage; let claude: Claude; let temps: [Temp]?
}

struct MacEntry: TimelineEntry {
    enum State { case ok(WidgetStatus), noAddress, unreachable, preview }
    let date: Date
    let state: State
}

struct MacProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MacEntry { MacEntry(date: Date(), state: .preview) }
    func snapshot(for c: WidgetAddress, in context: Context) async -> MacEntry {
        context.isPreview ? MacEntry(date: Date(), state: .preview) : await load(c)
    }
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

struct Meter: View {
    let label: String, value: Double, text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text(text).monospacedDigit().foregroundStyle(.secondary) }.font(.caption2)
            ProgressView(value: min(max(value, 0), 1)).tint(value > 0.85 ? .red : value > 0.65 ? .orange : .accentColor)
        }
    }
}

struct MacWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MacEntry

    var numbers: (cpu: Double, mem: Double, disk: Double, fiveHour: Double?, week: Double?, up: String, title: String, online: Bool, heat: String)? {
        switch entry.state {
        case .ok(let s):
            let d = Int(s.uptime) / 86400, h = Int(s.uptime) / 3600 % 24, m = Int(s.uptime) / 60 % 60
            let up = d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return (Double(s.cpu.total) / 100, s.mem.total > 0 ? s.mem.used / s.mem.total : 0, s.disk.total > 0 ? 1 - s.disk.free / s.disk.total : 0, s.usage.plan?.fiveHour, s.usage.plan?.sevenDay, up, "macOS " + s.macos, s.claude.remoteControl, (s.temps ?? []).filter { $0.name == "CPU" || $0.name == "GPU A" }.map { "\($0.name == "GPU A" ? "GPU" : $0.name) \(Int($0.c.rounded()))°" }.joined(separator: " · "))
        case .preview: return (0.12, 0.41, 0.58, 6, 47, "2d 4h", "macOS Tahoe", true, "CPU 53° · GPU 43°")
        default: return nil
        }
    }
    var problem: String {
        if case .noAddress = entry.state { return "No address set. Reinstall the app from the Mac." }
        return "Can’t reach it. Is Tailscale on?"
    }
    func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                if let n = numbers {
                    Gauge(value: n.cpu) { Text("CPU") } currentValueLabel: { Text("\(Int(n.cpu * 100))") }.gaugeStyle(.accessoryCircular)
                } else { Image(systemName: "desktopcomputer.trianglebadge.exclamationmark") }
            case .accessoryRectangular:
                if let n = numbers {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Mac Pro").font(.headline)
                        Text("CPU \(pct(n.cpu)) · Mem \(pct(n.mem))")
                        Text(n.heat.isEmpty ? "Up \(n.up)" : n.heat).foregroundStyle(.secondary)
                    }.font(.caption)
                } else { Text("Mac Pro unreachable").font(.caption) }
            case .systemSmall:
                if let n = numbers {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image("MacPro").resizable().scaledToFit().frame(width: 24, height: 30)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Mac Pro").font(.caption.weight(.semibold))
                                Label(n.heat.isEmpty ? "Up \(n.up)" : n.heat, systemImage: "circle.fill").labelStyle(StatusDot()).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Meter(label: "CPU", value: n.cpu, text: pct(n.cpu))
                        Meter(label: "Memory", value: n.mem, text: pct(n.mem))
                    }
                } else { failure }
            default:
                if let n = numbers {
                    HStack(spacing: 14) {
                        VStack(spacing: 4) {
                            Image("MacPro").resizable().scaledToFit().frame(height: 86)
                            Text("Up \(n.up)").font(.caption2).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text("Mac Pro").font(.subheadline.weight(.semibold)); Spacer(); Text(n.heat.isEmpty ? n.title : n.heat).font(.caption2).foregroundStyle(.secondary) }
                            Meter(label: "CPU", value: n.cpu, text: pct(n.cpu))
                            Meter(label: "Memory", value: n.mem, text: pct(n.mem))
                            Meter(label: "Disk", value: n.disk, text: pct(n.disk))
                            if let w = n.week { Meter(label: "Claude 7-day", value: w / 100, text: "\(Int(w))%") }
                        }
                    }
                } else { failure }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
    var failure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Mac Pro", systemImage: "desktopcomputer").font(.caption.weight(.semibold))
            Text(problem).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct StatusDot: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.title }
}

struct MacProWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacProStatus", intent: WidgetAddress.self, provider: MacProvider()) { MacWidgetView(entry: $0) }
            .configurationDisplayName("Mac Pro Status")
            .description("CPU, memory, disk, temperatures, uptime and Claude usage.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

@main
struct MacProWidgets: WidgetBundle { var body: some Widget { MacProWidget() } }
