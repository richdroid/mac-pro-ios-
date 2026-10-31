import AppIntents
import SwiftUI
import WidgetKit

struct ChumbyWidgetAddress: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Chumby"
    static var description = IntentDescription("Your Chumby, on your Home Screen.")
    @Parameter(title: "Different address (optional)") var address: String?
}

func chumbyBase(_ override: String?) -> URL? {
    var text = (override ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { text = Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "" }
    return URL(string: text).flatMap { $0.host == nil ? nil : $0 }
}

struct ChumbyEntry: TimelineEntry {
    let date: Date
    var reachable = false
    var sys = Sys()
    var nextAlarm: Alarm?
    var nextAt: Date?
    var shot: Data?
    var sample = false
    var channel: String { sys.chan.isEmpty ? "Awake" : sys.chan }
    var image: Image? { shot.flatMap { d in PlatformWidgetImage(data: d).map { Image(platform: $0) } } }
}
#if canImport(UIKit)
import UIKit
typealias PlatformWidgetImage = UIImage
extension Image { init(platform i: UIImage) { self.init(uiImage: i) } }
#else
import AppKit
typealias PlatformWidgetImage = NSImage
extension Image { init(platform i: NSImage) { self.init(nsImage: i) } }
#endif

struct ChumbyProvider: AppIntentTimelineProvider {
    var wantsShot = false
    func placeholder(in context: Context) -> ChumbyEntry { ChumbyEntry(date: Date(), reachable: true, sample: true) }
    func snapshot(for c: ChumbyWidgetAddress, in context: Context) async -> ChumbyEntry { await load(c) }
    func timeline(for c: ChumbyWidgetAddress, in context: Context) async -> Timeline<ChumbyEntry> {
        Timeline(entries: [await load(c)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
    func load(_ c: ChumbyWidgetAddress) async -> ChumbyEntry {
        var e = ChumbyEntry(date: Date())
        guard let base = chumbyBase(c.address) else { return e }
        let api = ChumbyAPI(base: base)
        if let s = try? await api.get("sys", as: Sys.self) { e.sys = s; e.reachable = true }
        if let st = try? await api.get("state", as: ChumbyState.self) {
            let next = st.alarms.compactMap { a in a.nextFire().map { (a, $0) } }.min { $0.1 < $1.1 }
            e.nextAlarm = next?.0; e.nextAt = next?.1
        }
        if wantsShot { e.shot = try? await api.shot() }
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
        if let base = chumbyBase(nil) { try await ChumbyAPI(base: base).cmd(command, value) }
        return .result()
    }
}

struct Sea: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.containerBackground(for: .widget) { StillSea(dark: scheme == .dark) }
    }
}
extension Font { static func trebuchet(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .custom("Trebuchet MS", size: s).weight(w) } }

let buddyLines = ["chumbalicious!", "blub.", "eight arms, one job", "squeeze me!", "i run on 175 MHz and vibes", "enjoy tinkering?", "wake up to your internet life", "still ticking since 2008", "who’s a good gadget?", "ink-credible."]
func unreachableLine(_ e: ChumbyEntry) -> String { e.reachable || e.sample ? "" : "Can’t reach me. Is Tailscale on?" }

// MARK: - The screen, in its photo
struct ScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ChumbyEntry
    var device: some View {
        Image("Device").resizable().scaledToFit()
            .overlay {
                GeometryReader { g in
                    ZStack {
                        Color(red: 0.04, green: 0.04, blue: 0.05)
                        if let i = entry.image { i.resizable() }
                        else { OctopusMark(color: ChumbyPalette.hex(0x79bbff)).frame(width: g.size.width * 0.2) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(width: g.size.width * 0.6065, height: g.size.height * 0.517)
                    .position(x: g.size.width * (0.1833 + 0.6065 / 2), y: g.size.height * (0.234 + 0.517 / 2))
                }
            }
    }
    var body: some View {
        Group {
            if family == .systemMedium {
                HStack(spacing: 10) {
                    device
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.channel).font(.trebuchet(15, .bold)).lineLimit(2)
                        Text(entry.date, style: .time).font(.trebuchet(11)).foregroundStyle(.secondary)
                        if let at = entry.nextAt { Label(at.formatted(date: .omitted, time: .shortened), systemImage: "alarm").font(.trebuchet(12)) }
                        Spacer(minLength: 0)
                        Text(unreachableLine(entry).isEmpty ? "As of the last peek" : unreachableLine(entry)).font(.trebuchet(10)).foregroundStyle(.secondary)
                    }.frame(maxWidth: 110, alignment: .leading)
                }
            } else {
                device
            }
        }
        .modifier(Sea())
    }
}
struct ChumbyScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyScreen", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider(wantsShot: true)) { ScreenView(entry: $0) }
            .configurationDisplayName("Chumby Screen")
            .description("A peek at what your Chumby is showing.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

// MARK: - Next alarm
struct AlarmView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ChumbyEntry
    var clock: (String, String)? { entry.nextAlarm.map { ($0.clock, $0.meridiem) } }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "alarm").font(.system(size: 11))
                        Text(clock?.0 ?? "—").font(.system(size: 14, weight: .semibold)).minimumScaleFactor(0.6)
                    }
                }
            case .accessoryInline:
                Label(clock.map { "\($0.0) \($0.1)" } ?? "No Chumby alarm", systemImage: "alarm")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 0) {
                    Text("Chumby alarm").font(.caption2.weight(.semibold))
                    if let c = clock, let at = entry.nextAt {
                        Text("\(c.0) \(c.1)").font(.headline)
                        Text(at, style: .relative).font(.caption2)
                    } else { Text("Sleep in. Nothing set.").font(.caption) }
                }
            default:
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.nextAlarm?.name.isEmpty == false ? entry.nextAlarm!.name : "next alarm").font(.trebuchet(12, .bold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        OctopusMark(color: ChumbyPalette.orange).frame(width: 24)
                    }
                    Spacer(minLength: 0)
                    if let c = clock, let at = entry.nextAt {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(c.0).font(.trebuchet(36)).minimumScaleFactor(0.6).monospacedDigit()
                            Text(c.1).font(.trebuchet(14))
                        }
                        Text(at, style: .relative).font(.trebuchet(12)).foregroundStyle(.secondary).lineLimit(1)
                        Text(entry.nextAlarm!.soundText).font(.trebuchet(11)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(entry.reachable ? "Nothing set." : "Can’t reach me.").font(.trebuchet(20, .bold))
                        Text(entry.reachable ? "Sleep in, friend." : "Is Tailscale on?").font(.trebuchet(12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .modifier(Sea())
    }
}
struct ChumbyAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyAlarm", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { AlarmView(entry: $0) }
            .configurationDisplayName("Next Alarm")
            .description("When your Chumby wakes you next.")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - The octopus himself
struct BuddyView: View {
    let entry: ChumbyEntry
    var line: String {
        let hour = Calendar.current.component(.hour, from: entry.date)
        if !entry.reachable && !entry.sample { return "where’d you go?" }
        if hour < 6 { return "shh. sleeping." }
        return buddyLines[(Calendar.current.ordinality(of: .hour, in: .year, for: entry.date) ?? 0) % buddyLines.count]
    }
    var body: some View {
        VStack(spacing: 4) {
            OctopusMark(color: ChumbyPalette.hex(0x2c5bae))
                .frame(maxHeight: .infinity)
            Text(line).font(.trebuchet(13, .bold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
            if entry.reachable { Text("awake \(entryDuration(entry.sys.up))").font(.trebuchet(10)).foregroundStyle(.secondary) }
        }
        .modifier(Sea())
    }
}
func entryDuration(_ s: Int) -> String {
    let d = s / 86400, h = s / 3600 % 24, m = s / 60 % 60
    return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
struct ChumbyBuddyWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyBuddy", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { BuddyView(entry: $0) }
            .configurationDisplayName("Octopus")
            .description("Your little octopus, with something to say every hour.")
            .supportedFamilies([.systemSmall])
    }
}

// MARK: - A remote you can press
struct RemoteView: View {
    let entry: ChumbyEntry
    func press(_ icon: String, _ intent: ChumbyPress, _ label: String) -> some View {
        Button(intent: intent) {
            Image(systemName: icon).font(.system(size: 17)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).accessibilityLabel(label)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                OctopusMark(color: ChumbyPalette.hex(0x2c5bae)).frame(width: 22)
                Text(entry.reachable || entry.sample ? entry.channel : "Can’t reach the Chumby").font(.trebuchet(13, .bold)).lineLimit(1)
                Spacer()
                if entry.sys.vol >= 0 { Label("\(entry.sys.vol)%", systemImage: "speaker.wave.2.fill").font(.trebuchet(11)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                press("backward.fill", ChumbyPress("prev"), "Previous widget")
                press("forward.fill", ChumbyPress("next"), "Next widget")
                press("moon.fill", ChumbyPress("night", "on"), "Night")
                press("sun.max.fill", ChumbyPress("night", "off"), "Wake")
                press("speaker.slash.fill", ChumbyPress("stopmusic"), "Stop music")
            }
        }
        .modifier(Sea())
    }
}
struct ChumbyRemoteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyRemote", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { RemoteView(entry: $0) }
            .configurationDisplayName("Chumby Remote")
            .description("Skip, sleep, wake and hush from your Home Screen.")
            .supportedFamilies([.systemMedium])
    }
}

// MARK: - Right now
struct RightNowView: View {
    let entry: ChumbyEntry
    func stat(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.trebuchet(12)).lineLimit(1)
    }
    var body: some View {
        HStack(spacing: 12) {
            OctopusMark(color: ChumbyPalette.hex(0x2c5bae)).frame(width: 62)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.reachable || entry.sample ? entry.channel : "Can’t reach the Chumby").font(.trebuchet(16, .bold)).lineLimit(1)
                stat("alarm", entry.nextAt.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? "No alarm set")
                stat("wifi", entry.sys.wifi >= 0 ? "Wi-Fi \(entry.sys.wifi)/100" : "No Wi-Fi")
                stat("speaker.wave.2.fill", entry.sys.vol >= 0 ? "Volume \(entry.sys.vol)%" : "Volume unknown")
                stat("clock", "Awake \(entryDuration(entry.sys.up))")
            }
            Spacer(minLength: 0)
        }
        .modifier(Sea())
    }
}
struct ChumbyRightNowWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyRightNow", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { RightNowView(entry: $0) }
            .configurationDisplayName("Right Now")
            .description("Channel, next alarm, Wi-Fi, volume and uptime.")
            .supportedFamilies([.systemMedium])
    }
}

@main
struct ChumbyWidgets: WidgetBundle {
    var body: some Widget {
        ChumbyScreenWidget()
        ChumbyAlarmWidget()
        ChumbyBuddyWidget()
        ChumbyRemoteWidget()
        ChumbyRightNowWidget()
    }
}
