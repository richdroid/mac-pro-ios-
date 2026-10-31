import AppIntents
import SwiftUI
import WidgetKit

struct ChumbyWidgetAddress: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Chumby"
    static var description = IntentDescription("Your Chumby, on your Home Screen.")
    @Parameter(title: "Different address (optional)") var address: String?
}

// The Mac's cache first; straight to the Chumby at home if Tailscale is off.
func chumbyRoutes(_ override: String?) -> [URL] {
    let o = (override ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let list = [o, Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "", Bundle.main.object(forInfoDictionaryKey: "ChumbyFallback") as? String ?? ""]
    return list.compactMap { URL(string: $0) }.filter { $0.host != nil }
}

struct ChumbyEntry: TimelineEntry {
    let date: Date
    var reachable = false
    var sys = Sys()
    var nextAlarm: Alarm?
    var nextAt: Date?
    var channel: String { sys.chan.isEmpty ? "Awake" : sys.chan }
    var deviceDown = false
    var problem: String { deviceDown ? "Chumby not answering" : "Tailscale off?" }
}

struct ChumbyProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ChumbyEntry { Self.sample }
    func snapshot(for c: ChumbyWidgetAddress, in context: Context) async -> ChumbyEntry { context.isPreview ? Self.sample : await load(c) }
    func timeline(for c: ChumbyWidgetAddress, in context: Context) async -> Timeline<ChumbyEntry> {
        Timeline(entries: [await load(c)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
    static var sample: ChumbyEntry {
        var s = Sys(); s.chan = "Default"; s.vol = 40; s.wifi = 71; s.up = 291000
        var a = Alarm(); a.time = "405"; a.name = "Work"
        return ChumbyEntry(date: Date(), reachable: true, sys: s, nextAlarm: a, nextAt: Date().addingTimeInterval(5 * 3600))
    }
    func load(_ c: ChumbyWidgetAddress) async -> ChumbyEntry {
        var e = ChumbyEntry(date: Date())
        for base in chumbyRoutes(c.address) {
            let api = ChumbyAPI(base: base)
            do {
                let r = try await api.raw("sys")
                guard let s = try? JSONDecoder().decode(Sys.self, from: r.data) else { continue }
                e.sys = s; e.reachable = true; e.deviceDown = r.age > 60
            } catch ChumbyError.deviceDown { e.deviceDown = true; continue } catch { continue }
            if let st = try? await api.get("state", as: ChumbyState.self) {
                let next = st.alarms.compactMap { a in a.nextFire().map { (a, $0) } }.min { $0.1 < $1.1 }
                e.nextAlarm = next?.0; e.nextAt = next?.1
            }
            break
        }
        return e
    }
}

// Press a button on the Home Screen and the Chumby does it, without opening the app.
struct ChumbyPress: AppIntent {
    static var title: LocalizedStringResource = "Press a Chumby button"
    static var isDiscoverable = false
    @Parameter(title: "Command") var command: String
    @Parameter(title: "Value") var value: String?
    init() {}
    init(_ command: String, _ value: String? = nil) { self.command = command; self.value = value }
    func perform() async throws -> some IntentResult {
        for base in chumbyRoutes(nil) {
            if (try? await ChumbyAPI(base: base).cmd(command, value)) != nil { break }
        }
        return .result()
    }
}

struct SeaFor: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { StillSea(dark: scheme == .dark) }
}
extension Font { static func trebuchet(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .custom("Trebuchet MS", size: s).weight(w) } }
private let octoBlue = ChumbyPalette.hex(0x2c5bae)

let buddyLines = ["chumbalicious!", "blub.", "eight arms, one job", "squeeze me!", "i run on 175 MHz and vibes", "enjoy tinkering?", "still ticking since 2008", "who’s a good gadget?", "ink-credible."]
func entryDuration(_ s: Int) -> String {
    let d = s / 86400, h = s / 3600 % 24, m = s / 60 % 60
    return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

// A sad octopus when the Chumby can't be reached.
struct Lost: View {
    var text = "Tailscale off?"
    var body: some View {
        VStack(spacing: 4) {
            OctopusMark(color: octoBlue.opacity(0.45)).frame(maxHeight: 62)
            Label(text, systemImage: "wifi.slash").font(.trebuchet(11, .bold)).opacity(0.75)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Next alarm
struct AlarmBody: View {
    let family: WidgetFamily
    let entry: ChumbyEntry
    var clock: (String, String)? { entry.nextAlarm.map { ($0.clock, $0.meridiem) } }
    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "alarm").font(.system(size: 11))
                    Text(clock?.0 ?? "–").font(.system(size: 14, weight: .semibold)).minimumScaleFactor(0.6)
                }
            }
        case .accessoryInline:
            Label(clock.map { "\($0.0) \($0.1)" } ?? "No alarm", systemImage: "alarm")
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "alarm.fill").font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(clock.map { "\($0.0) \($0.1)" } ?? "No alarm").font(.headline)
                    if let at = entry.nextAt { Text(at, style: .relative).font(.caption2).lineLimit(1) }
                }
            }
        default:
            if !entry.reachable { Lost(text: entry.problem) }
            else if let c = clock, let at = entry.nextAt {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Image(systemName: "alarm.fill").font(.system(size: 17)).foregroundStyle(ChumbyPalette.orange)
                        Spacer()
                        OctopusMark(color: octoBlue).frame(width: 40)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(c.0).font(.trebuchet(38, .bold)).minimumScaleFactor(0.6).monospacedDigit()
                        Text(c.1).font(.trebuchet(14, .bold))
                    }
                    Text(at, style: .relative).font(.trebuchet(12)).opacity(0.7).lineLimit(1)
                }
            } else {
                VStack(spacing: 6) {
                    OctopusMark(color: octoBlue, blink: 0.08).frame(maxHeight: 74)
                    Text("sleep in").font(.trebuchet(15, .bold))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - The octopus himself
struct BuddyBody: View {
    let entry: ChumbyEntry
    var line: String {
        if !entry.reachable { return "where’d you go?" }
        if Calendar.current.component(.hour, from: entry.date) < 6 { return "shh. sleeping." }
        return buddyLines[(Calendar.current.ordinality(of: .hour, in: .year, for: entry.date) ?? 0) % buddyLines.count]
    }
    var body: some View {
        VStack(spacing: 4) {
            OctopusMark(color: octoBlue, blink: Calendar.current.component(.hour, from: entry.date) < 6 ? 0.08 : 1).frame(maxHeight: .infinity)
            Text(line).font(.trebuchet(13, .bold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - A remote you can press
struct RemoteBody: View {
    let entry: ChumbyEntry
    func press(_ icon: String, _ intent: ChumbyPress, _ label: String, big: Bool = false) -> some View {
        Button(intent: intent) {
            Image(systemName: icon).font(.system(size: big ? 22 : 17, weight: .medium)).frame(width: 54, height: 54).background(.white.opacity(0.32), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                OctopusMark(color: octoBlue).frame(width: 30)
                Text(entry.reachable ? entry.channel : entry.problem).font(.trebuchet(14, .bold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                press("moon.fill", ChumbyPress("night", "on"), "Night")
                Spacer(minLength: 0)
                press("backward.fill", ChumbyPress("prev"), "Previous widget", big: true)
                Spacer(minLength: 0)
                press("forward.fill", ChumbyPress("next"), "Next widget", big: true)
                Spacer(minLength: 0)
                press("sun.max.fill", ChumbyPress("night", "off"), "Wake")
                Spacer(minLength: 0)
                press("speaker.slash.fill", ChumbyPress("stopmusic"), "Stop music")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Right now
struct SignalBars: View {
    let value: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5).fill(value > i * 25 ? octoBlue : octoBlue.opacity(0.2)).frame(width: 5, height: CGFloat(6 + i * 4))
            }
        }
    }
}
struct RightNowBody: View {
    let entry: ChumbyEntry
    var body: some View {
        if !entry.reachable { Lost(text: entry.problem) } else {
            HStack(spacing: 16) {
                OctopusMark(color: octoBlue).frame(width: 96)
                VStack(alignment: .leading, spacing: 9) {
                    Text(entry.channel).font(.trebuchet(16, .bold)).lineLimit(1)
                    HStack(spacing: 14) {
                        SignalBars(value: entry.sys.wifi)
                        HStack(spacing: 5) {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 12))
                            ProgressView(value: Double(max(entry.sys.vol, 0)), total: 100).tint(ChumbyPalette.orange).frame(width: 52)
                        }
                    }
                    if let at = entry.nextAt {
                        Label(at.formatted(.dateTime.weekday(.abbreviated).hour().minute()), systemImage: "alarm.fill").font(.trebuchet(13, .bold))
                    } else {
                        Label("No alarm", systemImage: "alarm").font(.trebuchet(13)).opacity(0.7)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - The widgets
struct InSea<C: View>: View {
    @Environment(\.widgetFamily) private var family
    let content: (WidgetFamily) -> C
    var body: some View { content(family).containerBackground(for: .widget) { SeaFor() } }
}
struct ChumbyAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyAlarm", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { e in InSea { AlarmBody(family: $0, entry: e) } }
            .configurationDisplayName("Next Alarm")
            .description("When your Chumby wakes you next.")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct ChumbyBuddyWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyBuddy", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { e in InSea { _ in BuddyBody(entry: e) } }
            .configurationDisplayName("Octopus")
            .description("Your little octopus, with something new to say every hour.")
            .supportedFamilies([.systemSmall])
    }
}
struct ChumbyRemoteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyRemote", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { e in InSea { _ in RemoteBody(entry: e) } }
            .configurationDisplayName("Chumby Remote")
            .description("Skip, sleep, wake and hush from your Home Screen.")
            .supportedFamilies([.systemMedium])
    }
}
struct ChumbyRightNowWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyRightNow", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { e in InSea { _ in RightNowBody(entry: e) } }
            .configurationDisplayName("Right Now")
            .description("Channel, Wi-Fi, volume and your next alarm.")
            .supportedFamilies([.systemMedium])
    }
}

#if !GALLERY
@main
struct ChumbyWidgets: WidgetBundle {
    var body: some Widget {
        ChumbyAlarmWidget()
        ChumbyBuddyWidget()
        ChumbyRemoteWidget()
        ChumbyRightNowWidget()
    }
}
#endif
