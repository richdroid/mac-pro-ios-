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
    // The one alarm skipped by hand, while it's still to come; `nextAlarm` is then the one that will really ring after it.
    var skipped: SkippedAlarm?
    // Whether the Chumby says its music player is playing, so Stop only shows when there's something to stop.
    var playing = false
    var night: Bool { sys.night == 1 }
    var deviceDown = false
    // When the Chumby was last heard from, for saying how long it's been gone rather than guessing why.
    var lastSeen: Date?
    var problem: String { deviceDown ? "Chumby not answering" : "Can’t reach it" }
    // Its own smaller line, so the time never reads as an alarm time.
    var lastSeenLine: String? {
        guard let lastSeen else { return nil }
        let at = Calendar.current.isDateInToday(lastSeen) ? lastSeen.formatted(date: .omitted, time: .shortened) : lastSeen.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "Last seen \(at)"
    }
    var whenText: String { nextAt.map(Self.day) ?? "" }
    static func day(_ at: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(at) { return "Today" }
        if cal.isDateInTomorrow(at) { return "Tomorrow" }
        return at.formatted(.dateTime.weekday(.wide))
    }
    // "Today · Work": the day and the alarm's own name, the way Home's Skip says it.
    var whenLine: String {
        guard let a = nextAlarm else { return whenText }
        let n = Self.label(a.name)
        return n.isEmpty ? whenText : "\(whenText) · \(n)"
    }
    static func label(_ name: String) -> String { name.hasPrefix("Calendar: ") ? String(name.dropFirst(10)) : name }
    static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    // Short, for "then Thu 6:45".
    static func then(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) || Calendar.current.isDateInTomorrow(d) ? "\(day(d).lowercased()) \(clock(d))" : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
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
            // And the moment a skipped time passes, so "Skipped" clears by itself.
            if let s = first.skipped { marks.insert(s.date.addingTimeInterval(1)) }
            for m in marks.sorted() {
                var e = ChumbyEntry(date: m, reachable: first.reachable, sys: first.sys, alarmsKnown: true, deviceDown: first.deviceDown, lastSeen: first.lastSeen)
                if let n = Self.next(state, after: m) { e.nextAlarm = n.alarm; e.nextAt = n.at }
                e.skipped = first.skipped.flatMap { $0.date > m ? $0 : nil }
                e.playing = first.playing
                entries.append(e)
            }
        }
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(30 * 60)))
    }
    static func next(_ s: ChumbyState, after d: Date) -> (alarm: Alarm, at: Date)? {
        s.nextRing(after: d)
    }
    static var sample: ChumbyEntry {
        var s = Sys(); s.chan = "Default"; s.vol = 40; s.wifi = 71; s.up = 291000; s.memFree = 14300; s.memTotal = 61948; s.pspFree = 424
        var a = Alarm(); a.time = "405"; a.name = "Work"
        let cal = Calendar.current
        let at = cal.nextDate(after: Date(), matching: DateComponents(hour: 6, minute: 45), matchingPolicy: .nextTime) ?? Date()
        return ChumbyEntry(date: Date(), reachable: true, sys: s, alarmsKnown: true, nextAlarm: a, nextAt: at)
    }
    private static var cacheFile: URL { chumbyWidgetCache }
    private static var seenFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-seen") }
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
                if e.reachable { try? Data().write(to: Self.seenFile) }
            } catch ChumbyError.deviceDown { e.deviceDown = true; continue } catch { continue }
            if e.reachable, let r = try? await api.raw("state"),
               (try? JSONSerialization.jsonObject(with: r.data) as? [String: Any])?["ok"] as? Bool == true,
               let st = try? JSONDecoder().decode(ChumbyState.self, from: r.data) {
                state = st
                try? r.data.write(to: Self.cacheFile, options: .atomic)
            }
            break
        }
        if !e.reachable { e.lastSeen = (try? FileManager.default.attributesOfItem(atPath: Self.seenFile.path))?[.modificationDate] as? Date }
        // Alarms are rules, so the last list read still answers "when's the next one" with no connection.
        if state == nil, let d = try? Data(contentsOf: Self.cacheFile) { state = try? JSONDecoder().decode(ChumbyState.self, from: d) }
        if let state {
            e.alarmsKnown = true
            if let n = Self.next(state, after: e.date) { e.nextAlarm = n.alarm; e.nextAt = n.at }
            e.skipped = state.skipped.flatMap { $0.date > e.date ? $0 : nil }
            e.playing = e.reachable && state.musicPlaying
        }
        return (e, state)
    }
}

// Always the night sea, in the light as in the dark: his Chumby is dark, and the pastel sea read too bright on the Home
// Screen. Content on it is drawn in the dark palette too (InSea).
struct SeaFor: View {
    var body: some View { StillSea(dark: true) }
}
extension Font { static func trebuchet(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .custom("Trebuchet MS", size: s).weight(w) } }
// The octopus in the right blue for the sea it's on.
struct Octo: View {
    var faded = false
    var blink: CGFloat = 1
    var color = ChumbyPalette.oct(true)
    var body: some View { OctopusMark(color: color.opacity(faded ? 0.45 : 1), blink: blink) }
}
// Home's Skip gel in small: the logo's blue, a glossy cap, white Trebuchet. Night navy once skipped.
struct MiniGel: View {
    var night = false
    var body: some View {
        let shape = Capsule()
        shape.fill(LinearGradient(colors: (night ? [0x34508f, 0x1f2f5c] : [0x5584d6, 0x2b5cad]).map(ChumbyPalette.hex), startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                .padding(2).mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.38), .init(color: .clear, location: 0.5)], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 1))
            .widgetAccentable()
    }
}
// The Skip button, or Undo once skipped, as a full-width gel.
struct SkipButton: View {
    let entry: ChumbyEntry
    var height: CGFloat = 32
    var body: some View {
        if entry.skipped != nil {
            Button(intent: ChumbyUnskipIntent()) {
                Text("Undo").font(.trebuchet(15, .bold)).foregroundStyle(ChumbyPalette.hex(0x1f2f5c))
                    .frame(maxWidth: .infinity, minHeight: height).background(.white, in: Capsule())
            }
            .buttonStyle(.plain).accessibilityLabel("Undo the skip")
        } else if entry.nextAt != nil {
            Button(intent: ChumbySkipIntent()) {
                Label("Skip", systemImage: "forward.end.fill").font(.trebuchet(15, .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: height).background(MiniGel())
            }
            .buttonStyle(.plain).accessibilityLabel("Skip the \(entry.nextAt.map(ChumbyEntry.clock) ?? "") alarm")
        }
    }
}

let buddyLines = ["chumbalicious!", "blub.", "eight arms, one job", "squeeze me!", "i run on 175 MHz and vibes", "enjoy tinkering?", "still ticking since 2008", "who’s a good gadget?", "ink-credible."]
func entryDuration(_ s: Int) -> String {
    let d = s / 86400, h = s / 3600 % 24, m = s / 60 % 60
    return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

// A sad octopus when the Chumby can't be reached.
struct Lost: View {
    var text = "Can’t reach it"
    var seen: String?
    var body: some View {
        VStack(spacing: 4) {
            Octo(faded: true).frame(maxHeight: 62)
            Label(text, systemImage: "wifi.slash").font(.trebuchet(14, .bold)).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            if let seen { Text(seen).font(.trebuchet(12)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.8) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
// A time as the widgets draw it, big digits with a small AM, the same awake or skipped; skipped only adds a line across.
struct ClockText: View {
    let date: Date
    var big: CGFloat = 34, small: CGFloat = 14
    var struck = false
    var parts: (String, String) {
        let t = date.formatted(date: .omitted, time: .shortened)
        guard let r = t.rangeOfCharacter(from: .whitespaces, options: .backwards) else { return (t, "") }
        return (String(t[..<r.lowerBound]), String(t[r.upperBound...]))
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.0).font(.trebuchet(big, .bold)).minimumScaleFactor(0.6).monospacedDigit()
            if !parts.1.isEmpty && small > 0 { Text(parts.1).font(.trebuchet(small, .bold)) }
        }
        .lineLimit(1)
        .overlay { if struck { Rectangle().fill(.white.opacity(0.7)).frame(height: 2) } }
    }
}

// MARK: - Next alarm
struct AlarmBody: View {
    let family: WidgetFamily
    let entry: ChumbyEntry
    var clock: (String, String)? { entry.nextAlarm.map { ($0.clock, $0.meridiem) } }
    var noAlarm: String { entry.alarmsKnown ? "No alarm" : "Can’t check alarm" }
    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    // Skipped: the octopus asleep and the skipped time struck through.
                    OctopusMark(color: .white, blink: entry.skipped == nil ? 1 : 0.08).frame(width: 20, height: 15)
                    if let s = entry.skipped {
                        ClockText(date: s.date, big: 15, small: 0, struck: true).minimumScaleFactor(0.6)
                    } else {
                        Text(clock?.0 ?? (entry.alarmsKnown ? "–" : "?")).font(.trebuchet(15, .bold)).minimumScaleFactor(0.6)
                    }
                }
            }
        case .accessoryInline:
            if let s = entry.skipped {
                Text("Skipped \(ChumbyEntry.clock(s.date))")
            } else {
                Text(clock.map { "\($0.0) \($0.1)" + (entry.nextAlarm.map { ChumbyEntry.label($0.name) }.map { $0.isEmpty ? "" : " · \($0)" } ?? "") } ?? noAlarm)
            }
        case .accessoryRectangular:
            HStack(spacing: 7) {
                OctopusMark(color: .white, blink: entry.skipped == nil ? 1 : 0.08).frame(width: 30, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    if let s = entry.skipped {
                        Text("Skipped").font(.trebuchet(12, .bold)).lineLimit(1)
                        Text(ChumbyEntry.clock(s.date)).font(.trebuchet(19, .bold)).strikethrough().lineLimit(1).minimumScaleFactor(0.7)
                        if let at = entry.nextAt { Text("then \(ChumbyEntry.then(at))").font(.trebuchet(12)).lineLimit(1) }
                    } else {
                        Text(clock.map { "\($0.0) \($0.1)" } ?? noAlarm).font(.trebuchet(19, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                        if entry.nextAt != nil { Text(entry.whenLine).font(.trebuchet(12)).lineLimit(1) }
                    }
                }
            }
        default:
            if let s = entry.skipped {
                // Skipped: the octopus asleep, the time struck through, what rings instead, and Undo.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Octo(faded: !entry.reachable, blink: 0.08).frame(width: 46, height: 34)
                        Spacer()
                        Text("Skipped").font(.trebuchet(13, .bold)).opacity(0.85)
                    }
                    Spacer(minLength: 0)
                    ClockText(date: s.date, big: 34, small: 14, struck: true)
                    Text(entry.nextAt.map { "then \(ChumbyEntry.then($0))" } ?? "then none set").font(.trebuchet(14)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    if entry.reachable { SkipButton(entry: entry, height: 30) }
                }
            } else if let c = clock, entry.nextAt != nil {
                VStack(alignment: .leading, spacing: 0) {
                    Octo(faded: !entry.reachable).frame(width: 46, height: 34)
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(c.0).font(.trebuchet(34, .bold)).minimumScaleFactor(0.6).monospacedDigit()
                        Text(c.1).font(.trebuchet(14, .bold))
                    }
                    .lineLimit(1)
                    Text(entry.whenLine).font(.trebuchet(14)).opacity(0.85).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    // Only when it can reach the Chumby: a skip that can't be sent is a dead button.
                    if entry.reachable { SkipButton(entry: entry, height: 30) }
                }
            } else if !entry.alarmsKnown {
                Lost(text: entry.problem, seen: entry.lastSeenLine)
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

// MARK: - Your Chumby: what's next on the left, with Skip; four buttons on the right
struct RemoteBody: View {
    let entry: ChumbyEntry
    func face(_ icon: String, on: Bool = false) -> some View {
        Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(on ? ChumbyPalette.hex(0x1f2f5c) : .white)
            .frame(width: 50, height: 50)
            .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.18)), in: Circle())
            .contentShape(Circle()).widgetAccentable()
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Octo(faded: !entry.reachable, blink: entry.skipped != nil || entry.night ? 0.08 : 1).frame(width: 46, height: 34)
                Spacer(minLength: 2)
                if let s = entry.skipped {
                    ClockText(date: s.date, big: 26, small: 13, struck: true)
                    Text(entry.nextAt.map { "Skipped · then \(ChumbyEntry.then($0))" } ?? "Skipped").font(.trebuchet(13)).lineLimit(1).minimumScaleFactor(0.8)
                } else if let a = entry.nextAlarm, entry.nextAt != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(a.clock).font(.trebuchet(26, .bold)).monospacedDigit().minimumScaleFactor(0.7)
                        Text(a.meridiem).font(.trebuchet(13, .bold))
                    }
                    .lineLimit(1)
                    Text(entry.whenLine).font(.trebuchet(13)).opacity(0.85).lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text(entry.reachable ? (entry.alarmsKnown ? "No alarm set" : "Chumby") : entry.problem).font(.trebuchet(15, .bold)).lineLimit(2).minimumScaleFactor(0.8)
                    if !entry.reachable, let seen = entry.lastSeenLine { Text(seen).font(.trebuchet(12)).opacity(0.8).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if entry.reachable { SkipButton(entry: entry, height: 30) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    // One night button, filled while the Chumby is in night mode; tap to switch.
                    Button(intent: ChumbyNightToggleIntent(!entry.night)) { face(entry.night ? "moon.fill" : "moon", on: entry.night) }
                        .buttonStyle(.plain).accessibilityLabel(entry.night ? "End night mode" : "Night mode")
                    Button(intent: ChumbyPress("next")) { face("forward.fill") }.buttonStyle(.plain).accessibilityLabel("Next widget")
                }
                GridRow {
                    Button(intent: ChumbyNapIntent(minutes: 20)) { face("zzz") }.buttonStyle(.plain).accessibilityLabel("20-minute nap")
                    // Stop only while something plays; otherwise the slot goes back a widget.
                    if entry.playing {
                        Button(intent: ChumbyStopMusicIntent()) { face("stop.fill") }.buttonStyle(.plain).accessibilityLabel("Stop music")
                    } else {
                        Button(intent: ChumbyPress("prev")) { face("backward.fill") }.buttonStyle(.plain).accessibilityLabel("Previous widget")
                    }
                }
            }
            .disabled(!entry.reachable).opacity(entry.reachable ? 1 : 0.45)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The widgets
struct InSea<C: View>: View {
    @Environment(\.widgetFamily) private var family
    var tab = 0
    let content: (WidgetFamily) -> C
    var body: some View {
        content(family).environment(\.colorScheme, .dark).foregroundStyle(ChumbyPalette.ink(true))
            .containerBackground(for: .widget) { SeaFor() }.widgetURL(URL(string: "chumbyapp://tab/\(tab)"))
    }
}
// MARK: - Status
struct StatusBar: View {
    let value: Double, color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.14))
                Capsule().fill(color).frame(width: max(8, g.size.width * min(max(value, 0), 1))).widgetAccentable()
            }
        }
        .frame(height: 8)
    }
}
struct StatusRow: View {
    let label: String, text: String
    var value: Double?
    var color = ChumbyPalette.oct(true)
    // A long value ("Tomorrow 6:45 AM") goes under its label rather than crowding it.
    var stacked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if stacked {
                Text(label).font(.trebuchet(15)).opacity(0.85).lineLimit(1)
                Text(text).font(.trebuchet(17, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            } else {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.trebuchet(15)).opacity(0.85).lineLimit(1)
                Spacer(minLength: 4)
                Text(text).font(.trebuchet(17, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
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
    var memoryColor: Color { memoryUsed > 0.92 ? .red : memoryUsed > 0.8 ? .orange : ChumbyPalette.oct(true) }
    var alarmText: String? {
        guard let a = entry.nextAlarm else { return entry.alarmsKnown ? "None set" : nil }
        return "\(entry.whenText) \(a.clock) \(a.meridiem)"
    }
    var awake: some View {
        HStack(spacing: 5) {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text("Up \(entryDuration(sys.up))").font(.trebuchet(15, .bold)).monospacedDigit().lineLimit(1)
        }
    }
    var body: some View {
        if !entry.reachable {
            Lost(text: entry.problem, seen: entry.lastSeenLine)
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
                    if let alarmText { StatusRow(label: "Next alarm", text: alarmText, stacked: true) }
                    // Only a channel worth naming: "Default" tells him nothing.
                    // (and only when there's room: the next alarm takes two lines)
                    if alarmText == nil && !sys.chan.isEmpty && sys.chan != "Default" { StatusRow(label: "Channel", text: sys.chan) }
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
            .description("When your Chumby wakes you next, with Skip.")
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
            .description("Your next alarm with Skip, night mode, the next widget and a nap, from the Home Screen.")
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
        ChumbySkipControl()
        ChumbyNightControl()
        ChumbyStopAlarmControl()
        ChumbyNextControl()
        ChumbyNapControl()
        ChumbyOpenControl()
    }
}
#endif
