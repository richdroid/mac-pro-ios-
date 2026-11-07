import AppIntents
import Foundation
import WidgetKit

// The Mac's cache first; straight to the Chumby at home if Tailscale is off.
func chumbyRoutes(_ override: String?) -> [URL] {
    let o = (override ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let list = [o, UserDefaults.standard.string(forKey: "address") ?? "", Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "", Bundle.main.object(forInfoDictionaryKey: "ChumbyFallback") as? String ?? ""]
    var seen = Set<String>()
    return list.filter { !$0.isEmpty && seen.insert($0).inserted }.compactMap { URL(string: $0) }.filter { $0.host != nil }
}
func chumbyTry<T>(_ work: (ChumbyAPI) async throws -> T) async throws -> T {
    var last: Error = ChumbyError.deviceDown
    for base in chumbyRoutes(nil) {
        do { return try await work(ChumbyAPI(base: base)) } catch { last = error }
    }
    throw last
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
        try await chumbyTry { try await $0.cmd(command, value) }
        return .result()
    }
}
// The panel's own SKIP and its undo, from a widget, Control Center or Siri. The panel takes a couple of seconds to
// confirm, so this waits (up to 4 s) for a read that shows it, keeps that read for the widgets, and refreshes them, so the
// button never looks as if it did nothing.
func chumbySetSkip(_ on: Bool) async throws {
    do {
        try await chumbyTry { api in
            _ = try await api.post(on ? "skip" : "unskip")
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let d = try? await api.fresh("state"), let s = try? JSONDecoder().decode(ChumbyState.self, from: d) else { continue }
                if (s.skipped != nil) == on {
                    try? d.write(to: chumbyWidgetCache, options: .atomic)
                    break
                }
            }
        }
    } catch { throw ChumbyError.message(AlarmWriter.explain(error)) }
    WidgetCenter.shared.reloadAllTimelines()
}
// The widgets' copy of the alarm list, kept so they can still answer "when's the next one" with no connection.
var chumbyWidgetCache: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-state.json") }
struct ChumbySkipIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Next Chumby Alarm"
    static var description = IntentDescription("Lets the next alarm pass without ringing, once.")
    func perform() async throws -> some IntentResult { try await chumbySetSkip(true); return .result() }
}
struct ChumbyUnskipIntent: AppIntent {
    static var title: LocalizedStringResource = "Undo Chumby Alarm Skip"
    static var description = IntentDescription("Lets the skipped alarm ring after all.")
    func perform() async throws -> some IntentResult { try await chumbySetSkip(false); return .result() }
}
// For Control Center's toggle: on skips, off undoes.
struct ChumbySkipToggleIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Skip Next Chumby Alarm"
    static var isDiscoverable = false
    @Parameter(title: "Skipped") var value: Bool
    func perform() async throws -> some IntentResult { try await chumbySetSkip(value); return .result() }
}
// Night mode as one switch that shows the mode the Chumby is really in. Night is the kind he chose in Tinker (read from the
// Chumby's own nightly time, see nightStyle); day ends night mode and brightens the screen, as Good Morning did.
struct ChumbyNightToggleIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Chumby Night Mode"
    static var isDiscoverable = false
    @Parameter(title: "Night mode") var value: Bool
    init() {}
    init(_ on: Bool) { value = on }
    func perform() async throws -> some IntentResult {
        let on = value
        do {
            try await chumbyTry { api in
                if on {
                    let style = (try? JSONDecoder().decode(ChumbyState.self, from: try await api.raw("state").data))?.nightStyle ?? "on"
                    try await api.cmd("night", style)
                } else {
                    try await api.cmd("night", "off")
                    try await api.cmd("screen", "bright")
                }
            }
        } catch { throw ChumbyError.message(AlarmWriter.explain(error)) }
        chumbyNoteNight(on)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
// What a day/night tap just asked for, kept 20 seconds, so the widget and Control Center draw the new state at once rather
// than the Mac's reading from before the Chumby had it.
func chumbyNoteNight(_ on: Bool) { UserDefaults.standard.set(["on": on, "at": Date().timeIntervalSince1970], forKey: "nightWanted") }
func chumbyNightWanted() -> Bool? {
    guard let d = UserDefaults.standard.dictionary(forKey: "nightWanted"), let on = d["on"] as? Bool, let at = d["at"] as? Double,
          Date().timeIntervalSince1970 - at < 20 else { return nil }
    return on
}
struct ChumbyNextIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Chumby Widget"
    static var description = IntentDescription("Moves the Chumby on to its next widget.")
    func perform() async throws -> some IntentResult { try await chumbyTry { try await $0.cmd("next") }; return .result() }
}
struct ChumbyGoodnightIntent: AppIntent {
    static var title: LocalizedStringResource = "Chumby Goodnight"
    static var description = IntentDescription("Puts the Chumby in night mode.")
    func perform() async throws -> some IntentResult {
        try await chumbyTry { api in
            let style = (try? JSONDecoder().decode(ChumbyState.self, from: try await api.raw("state").data))?.nightStyle ?? "on"
            try await api.cmd("night", style)
        }
        return .result()
    }
}
struct ChumbyMorningIntent: AppIntent {
    static var title: LocalizedStringResource = "Chumby Good Morning"
    static var description = IntentDescription("Turns off night mode and brightens the screen.")
    func perform() async throws -> some IntentResult {
        try await chumbyTry { try await $0.cmd("night", "off"); try await $0.cmd("screen", "bright") }
        return .result()
    }
}
struct ChumbyStopMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Chumby Music"
    static var description = IntentDescription("Stops whatever the Chumby is playing.")
    func perform() async throws -> some IntentResult { try await chumbyTry { try await $0.cmd("stopmusic") }; return .result() }
}
struct ChumbyVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Chumby Volume"
    static var description = IntentDescription("Sets the volume from 0 to 100.")
    @Parameter(title: "Volume", inclusiveRange: (0, 100)) var volume: Int
    func perform() async throws -> some IntentResult { try await chumbyTry { try await $0.cmd("volume", String(volume)) }; return .result() }
}
struct ChumbyNapIntent: AppIntent {
    static var title: LocalizedStringResource = "Chumby Nap"
    static var description = IntentDescription("Sets a one-off alarm on the Chumby.")
    @Parameter(title: "Minutes", default: 20, inclusiveRange: (1, 720)) var minutes: Int
    init() {}
    init(minutes: Int) { self.minutes = minutes }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // A real alarm on the Chumby, so its backup and catch-up cover it, saved the one careful way.
        let minutes = minutes
        do { _ = try await chumbyTry { try await AlarmWriter.shared.edit($0, permit: SavePermit()) { (s: inout ChumbyState) -> Void in s.addNap(minutes: minutes) } } }
        catch { throw ChumbyError.message(AlarmWriter.explain(error)) }
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: IntentDialog(stringLiteral: "Blub. Waking you in \(minutes) minutes."))
    }
}
struct ChumbyNextAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Chumby Alarm"
    static var description = IntentDescription("When the Chumby next goes off.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let s = try await chumbyTry { try JSONDecoder().decode(ChumbyState.self, from: await $0.fresh("state")) }
        var text = "No alarms set. Sleep in."
        if let next = s.nextRing() {
            let when = next.1.formatted(.dateTime.weekday(.wide).hour().minute())
            text = next.0.name.isEmpty ? "\(when)." : "\(when): \(next.0.name)."
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
struct ChumbyStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Chumby Status"
    static var description = IntentDescription("What the Chumby is up to.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let s = try await chumbyTry { try JSONDecoder().decode(Sys.self, from: await $0.fresh("sys")) }
        let h = s.up / 3600, text = "Awake \(h > 47 ? "\(h / 24) days" : "\(h) hours"), on \(s.chan.isEmpty ? "its channel" : s.chan), volume \(s.vol). Still ticking."
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
// The ringing alarm's own Stop, from Control Center or Siri: the same as pressing it on the Chumby.
struct ChumbyStopAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Chumby Alarm"
    static var description = IntentDescription("Stops the alarm that's ringing or snoozing.")
    func perform() async throws -> some IntentResult {
        do { try await chumbyTry { try await $0.cmd("ringoff") } }
        catch ChumbyError.message("not delivered") { throw ChumbyError.message("No Chumby alarm is ringing.") }
        catch { throw ChumbyError.message(AlarmWriter.explain(error)) }
        return .result()
    }
}
struct ChumbyOpenIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Chumby"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}

extension ChumbyState {
    // The kind of night he chose (Tinker's Night style): clock, dim or dark. Kept on the Chumby itself as the kind its own
    // nightly time switches to, so the widget and Control Center, which can't read the app's settings, night the same way.
    var nightStyle: String? { schedule.first { $0.cmd == "night" && $0.val != "off" }?.val }
    mutating func addNap(minutes: Int) { addNap(at: Int((Date().timeIntervalSince1970 / 60).rounded(.up)) + minutes) }
    // A one-off beep named Nap, due at `at` (minutes since 1970), in the first free place.
    // One nap at a time, from wherever it's set (app, widget, Control Center, Shortcuts): any nap still to come is replaced,
    // and the same minute twice is a no-op, so a double press can't leave two naps ringing one after the other.
    mutating func addNap(at: Int) {
        let now = Int(Date().timeIntervalSince1970 / 60)
        alarms.removeAll { $0.name == "Nap" && $0.when == "once" && (Int($0.time) ?? 0) > now && $0.time != String(at) }
        if alarms.contains(where: { $0.name == "Nap" && $0.when == "once" && $0.time == String(at) }) { return }
        var a = Alarm()
        a.name = "Nap"; a.when = "once"; a.enabled = "1"
        a.time = String(at)
        let tone = tones.first ?? "Beep"
        a.type = "beep"; a.arg = tone; a.param_description = tone; a.duration = "5"
        if let free = alarms.firstIndex(where: { $0.isPlaceholder }) { alarms[free] = a } else { alarms.append(a) }
    }
    func alarmForm() -> [(String, String)] {
        var o: [(String, String)] = [("n", "\(alarms.count)")]
        if volume >= 0 { o.append(("v", "\(volume)")) }
        o.append(("f", "\(fade)"))   // -1 is a real choice here: the Chumby's own default
        for (i, a) in alarms.enumerated() {
            o += [("\(i)_name", a.name), ("\(i)_enabled", a.enabled), ("\(i)_time", a.time), ("\(i)_when", a.when), ("\(i)_type", a.type), ("\(i)_arg", a.arg),
                  ("\(i)_param", a.param), ("\(i)_param_description", a.param_description), ("\(i)_duration", a.duration), ("\(i)_snooze", a.snooze),
                  ("\(i)_auto_dismiss", a.auto_dismiss), ("\(i)_action", a.action), ("\(i)_action_param", a.action_param), ("\(i)_backup", a.backup), ("\(i)_backupDelay", a.backupDelay)]
        }
        return o
    }
}
