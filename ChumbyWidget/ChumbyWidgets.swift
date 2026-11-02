import AppIntents
import SwiftUI
import WidgetKit

struct ChumbyWidgetAddress: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Chumby"
    static var description = IntentDescription("Your Chumby, on your Home Screen.")
    @Parameter(title: "Different address (optional)") var address: String?
}

struct ChumbyEntry: TimelineEntry {
    let date: Date
    var reachable = false
    var sys = Sys()
    var alarmsKnown = false     // false means "couldn't read them", which is not the same as "none set"
    var nextAlarm: Alarm?
    var nextAt: Date?
    var channel: String { sys.chan.isEmpty ? "Awake" : sys.chan }
    var deviceDown = false
    var problem: String { deviceDown ? "Chumby not answering" : "Tailscale off?" }
    var whenText: String {
        guard let at = nextAt else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(at) { return "Today" }
        if cal.isDateInTomorrow(at) { return "Tomorrow" }
        return at.formatted(.dateTime.weekday(.wide))
    }
}

struct ChumbyProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ChumbyEntry { Self.sample }
    func snapshot(for c: ChumbyWidgetAddress, in context: Context) async -> ChumbyEntry { context.isPreview ? Self.sample : await load(c).0 }
    func timeline(for c: ChumbyWidgetAddress, in context: Context) async -> Timeline<ChumbyEntry> {
        let (first, state) = await load(c)
        // A fresh entry at each alarm and each midnight, so the widget moves on by itself without a reload.
        var entries = [first]
        if let state {
            var marks = Set<Date>()
            var cursor = first.date
            for _ in 0..<3 { guard let n = Self.next(state, after: cursor) else { break }; marks.insert(n.at.addingTimeInterval(1)); cursor = n.at.addingTimeInterval(1) }
            if let midnight = Calendar.current.nextDate(after: first.date, matching: DateComponents(hour: 0), matchingPolicy: .nextTime) { marks.insert(midnight) }
            for m in marks.sorted() {
                var e = ChumbyEntry(date: m, reachable: first.reachable, sys: first.sys, alarmsKnown: true, deviceDown: first.deviceDown)
                if let n = Self.next(state, after: m) { e.nextAlarm = n.alarm; e.nextAt = n.at }
                entries.append(e)
            }
        }
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(30 * 60)))
    }
    static func next(_ s: ChumbyState, after d: Date) -> (alarm: Alarm, at: Date)? {
        s.alarms.compactMap { a in a.nextFire(after: d).map { (alarm: a, at: $0) } }.min { $0.at < $1.at }
    }
    static var sample: ChumbyEntry {
        var s = Sys(); s.chan = "Default"; s.vol = 40; s.wifi = 71; s.up = 291000; s.memFree = 14300; s.memTotal = 61948; s.pspFree = 424
        var a = Alarm(); a.time = "405"; a.name = "Work"
        let cal = Calendar.current
        let at = cal.nextDate(after: Date(), matching: DateComponents(hour: 6, minute: 45), matchingPolicy: .nextTime) ?? Date()
        return ChumbyEntry(date: Date(), reachable: true, sys: s, alarmsKnown: true, nextAlarm: a, nextAt: at)
    }
    private static var cacheFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-state.json") }
    func load(_ c: ChumbyWidgetAddress) async -> (ChumbyEntry, ChumbyState?) {
        var e = ChumbyEntry(date: Date())
        var state: ChumbyState?
        for base in chumbyRoutes(c.address) {
            let api = ChumbyAPI(base: base)
            do {
                var r = try await api.raw("sys")
                // Old is normal after a quiet spell, and asking starts a refresh. Only old twice means trouble.
                if r.age > 60 { try await Task.sleep(nanoseconds: 3_000_000_000); r = try await api.raw("sys") }
                guard let s = try? JSONDecoder().decode(Sys.self, from: r.data) else { continue }
                e.sys = s; e.deviceDown = r.age > 60; e.reachable = !e.deviceDown
            } catch ChumbyError.deviceDown { e.deviceDown = true; continue } catch { continue }
            if e.reachable, let r = try? await api.raw("state"),
               (try? JSONSerialization.jsonObject(with: r.data) as? [String: Any])?["ok"] as? Bool == true,
               let st = try? JSONDecoder().decode(ChumbyState.self, from: r.data) {
                state = st
                try? r.data.write(to: Self.cacheFile, options: .atomic)
            }
            break
        }
        // Alarms are rules, so the last list read still answers "when's the next one" with no connection.
        if state == nil, let d = try? Data(contentsOf: Self.cacheFile) { state = try? JSONDecoder().decode(ChumbyState.self, from: d) }
        if let state {
            e.alarmsKnown = true
            if let n = Self.next(state, after: e.date) { e.nextAlarm = n.alarm; e.nextAt = n.at }
        }
        return (e, state)
    }
}

struct SeaFor: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { StillSea(dark: scheme == .dark) }
}
extension Font { static func trebuchet(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .custom("Trebuchet MS", size: s).weight(w) } }
// The octopus in the right blue for the sea it's on.
struct Octo: View {
    @Environment(\.colorScheme) private var scheme
    var faded = false
    var blink: CGFloat = 1
    var body: some View { OctopusMark(color: ChumbyPalette.oct(scheme == .dark).opacity(faded ? 0.45 : 1), blink: blink) }
}

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
            Octo(faded: true).frame(maxHeight: 62)
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
                    Text(clock?.0 ?? (entry.alarmsKnown ? "–" : "?")).font(.system(size: 14, weight: .semibold)).minimumScaleFactor(0.6)
                }
            }
        case .accessoryInline:
            Label(clock.map { "\($0.0) \($0.1)" } ?? (entry.alarmsKnown ? "No alarm" : "Can’t check alarm"), systemImage: "alarm")
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "alarm.fill").font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(clock.map { "\($0.0) \($0.1)" } ?? (entry.alarmsKnown ? "No alarm" : "Can’t check alarm")).font(.headline)
                    if entry.nextAt != nil { Text(entry.whenText).font(.caption2).lineLimit(1) }
                }
            }
        default:
            if let c = clock, entry.nextAt != nil {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Image(systemName: "alarm.fill").font(.system(size: 17)).foregroundStyle(ChumbyPalette.orange)
                        Spacer()
                        Octo(faded: !entry.reachable).frame(width: 40)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(c.0).font(.trebuchet(38, .bold)).minimumScaleFactor(0.6).monospacedDigit()
                        Text(c.1).font(.trebuchet(14, .bold))
                    }
                    Text(entry.whenText).font(.trebuchet(12)).opacity(0.7).lineLimit(1)
                }
            } else if !entry.alarmsKnown {
                Lost(text: entry.problem)
            } else {
                VStack(spacing: 6) {
                    Octo(blink: 0.08).frame(maxHeight: 74)
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
            Octo(faded: !entry.reachable, blink: Calendar.current.component(.hour, from: entry.date) < 6 ? 0.08 : 1).frame(maxHeight: .infinity)
            Text(line).font(.trebuchet(13, .bold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Your Chumby: what's next on the left, buttons on the right
struct RemoteBody: View {
    let entry: ChumbyEntry
    func face(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44).background(.white.opacity(0.3), in: Circle()).contentShape(Circle()).widgetAccentable()
    }
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Octo(faded: !entry.reachable).frame(height: 44)
                Spacer(minLength: 2)
                if let a = entry.nextAlarm, entry.nextAt != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(a.clock).font(.trebuchet(26, .bold)).monospacedDigit().minimumScaleFactor(0.7)
                        Text(a.meridiem).font(.trebuchet(12, .bold))
                    }
                    Label(entry.whenText, systemImage: "alarm.fill").font(.trebuchet(12)).opacity(0.75).lineLimit(1)
                } else {
                    Text(entry.reachable ? entry.channel : entry.problem).font(.trebuchet(14, .bold)).lineLimit(2).minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Button(intent: ChumbyPress("prev")) { face("chevron.backward") }.buttonStyle(.plain).accessibilityLabel("Previous widget")
                    Button(intent: ChumbyPress("next")) { face("chevron.forward") }.buttonStyle(.plain).accessibilityLabel("Next widget")
                    Button(intent: ChumbyStopMusicIntent()) { face("stop.fill") }.buttonStyle(.plain).accessibilityLabel("Stop music")
                }
                GridRow {
                    Button(intent: ChumbyGoodnightIntent()) { face("moon.fill") }.buttonStyle(.plain).accessibilityLabel("Goodnight")
                    Button(intent: ChumbyMorningIntent()) { face("sun.max.fill") }.buttonStyle(.plain).accessibilityLabel("Good morning")
                    Button(intent: ChumbyNapIntent(minutes: 20)) { face("zzz") }.buttonStyle(.plain).accessibilityLabel("20-minute nap")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The widgets
struct InSea<C: View>: View {
    @Environment(\.widgetFamily) private var family
    var tab = 0
    let content: (WidgetFamily) -> C
    var body: some View { content(family).containerBackground(for: .widget) { SeaFor() }.widgetURL(URL(string: "chumbyapp://tab/\(tab)")) }
}
// MARK: - Status
struct StatusBar: View {
    let value: Double, color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.14))
                Capsule().fill(color).frame(width: max(5, g.size.width * min(max(value, 0), 1))).widgetAccentable()
            }
        }
        .frame(height: 5)
    }
}
struct StatusRow: View {
    let label: String, text: String
    var value: Double?
    var color = Color(red: 0.17, green: 0.35, blue: 0.68)
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.trebuchet(13)).opacity(0.8).lineLimit(1)
                Spacer(minLength: 4)
                Text(text).font(.trebuchet(14, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
            if let value { StatusBar(value: value, color: color) }
        }
    }
}
struct ChumbyStatusBody: View {
    let family: WidgetFamily
    let entry: ChumbyEntry
    var sys: Sys { entry.sys }
    var memoryUsed: Double { sys.memTotal > 0 ? 1 - Double(sys.memFree) / Double(sys.memTotal) : 0 }
    var memoryColor: Color { memoryUsed > 0.92 ? .red : memoryUsed > 0.8 ? .orange : Color(red: 0.17, green: 0.35, blue: 0.68) }
    var alarmText: String? {
        guard let a = entry.nextAlarm else { return entry.alarmsKnown ? "None set" : nil }
        return "\(entry.whenText) \(a.clock) \(a.meridiem)"
    }
    var awake: some View {
        HStack(spacing: 5) {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text("Up \(entryDuration(sys.up))").font(.trebuchet(13, .bold)).monospacedDigit().lineLimit(1)
        }
    }
    var body: some View {
        if !entry.reachable {
            Lost(text: entry.problem)
        } else if family == .systemSmall {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Octo().frame(width: 48, height: 40)
                    Spacer(minLength: 0)
                    awake
                }
                Spacer(minLength: 0)
                if sys.wifi >= 0 { StatusRow(label: "Wi-Fi", text: "\(sys.wifi)%", value: Double(sys.wifi) / 100) }
                StatusRow(label: "Memory", text: "\(Int((memoryUsed * 100).rounded()))%", value: memoryUsed, color: memoryColor)
            }
        } else {
            HStack(spacing: 14) {
                VStack(spacing: 6) {
                    Octo().frame(width: 92, height: 76)
                    awake
                }
                VStack(alignment: .leading, spacing: 6) {
                    if sys.wifi >= 0 { StatusRow(label: "Wi-Fi", text: "\(sys.wifi)%", value: Double(sys.wifi) / 100) }
                    StatusRow(label: "Memory", text: "\(Int((memoryUsed * 100).rounded()))%", value: memoryUsed, color: memoryColor)
                    if let alarmText { StatusRow(label: "Next alarm", text: alarmText) }
                    if !sys.chan.isEmpty { StatusRow(label: "Channel", text: sys.chan) }
                }
            }
        }
    }
}
struct ChumbyStatusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyStatus", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { e in InSea { ChumbyStatusBody(family: $0, entry: e) } }
            .configurationDisplayName("Chumby Status")
            .description("Whether your Chumby is up, how long for, and its Wi-Fi, memory and next alarm.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct ChumbyAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChumbyAlarm", intent: ChumbyWidgetAddress.self, provider: ChumbyProvider()) { e in InSea(tab: 2) { AlarmBody(family: $0, entry: e) } }
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
            .configurationDisplayName("Your Chumby")
            .description("Your next alarm, and skip, sleep, wake and nap from the Home Screen.")
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
        ChumbyStatusWidget()
        ChumbyNextControl()
        ChumbyNightControl()
        ChumbyMorningControl()
        ChumbyStopControl()
        ChumbyNapControl()
        ChumbyOpenControl()
    }
}
#endif
