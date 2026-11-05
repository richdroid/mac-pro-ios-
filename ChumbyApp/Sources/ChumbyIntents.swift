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
struct ChumbyNextIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Chumby Widget"
    static var description = IntentDescription("Skips to the next widget.")
    func perform() async throws -> some IntentResult { try await chumbyTry { try await $0.cmd("next") }; return .result() }
}
struct ChumbyGoodnightIntent: AppIntent {
    static var title: LocalizedStringResource = "Chumby Goodnight"
    static var description = IntentDescription("Puts the Chumby in night mode.")
    func perform() async throws -> some IntentResult { try await chumbyTry { try await $0.cmd("night", "on") }; return .result() }
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
    mutating func addNap(minutes: Int) { addNap(at: Int((Date().timeIntervalSince1970 / 60).rounded(.up)) + minutes) }
    // A one-off beep named Nap, due at `at` (minutes since 1970), in the first free place.
    mutating func addNap(at: Int) {
        var a = Alarm()
        a.name = "Nap"; a.when = "once"; a.enabled = "1"
        a.time = String(at)
        let tone = tones.first ?? "Beep"
        a.type = "beep"; a.arg = tone; a.param_description = tone; a.duration = "5"
        if let free = alarms.firstIndex(where: { $0.isPlaceholder }) { alarms[free] = a } else { alarms.append(a) }
    }
    func alarmForm() -> [(String, String)] {
        var o: [(String, String)] = [("n", "\(alarms.count)"), ("v", "\(volume)"), ("f", "\(fade)")]
        for (i, a) in alarms.enumerated() {
            o += [("\(i)_name", a.name), ("\(i)_enabled", a.enabled), ("\(i)_time", a.time), ("\(i)_when", a.when), ("\(i)_type", a.type), ("\(i)_arg", a.arg),
                  ("\(i)_param", a.param), ("\(i)_param_description", a.param_description), ("\(i)_duration", a.duration), ("\(i)_snooze", a.snooze),
                  ("\(i)_auto_dismiss", a.auto_dismiss), ("\(i)_action", a.action), ("\(i)_action_param", a.action_param), ("\(i)_backup", a.backup), ("\(i)_backupDelay", a.backupDelay)]
        }
        return o
    }
}
