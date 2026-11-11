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
        do { return try await work(ChumbyAPI(base: base)) }
        // The Chumby answered and said no (the safety net, an alarm ringing, a skip it didn't confirm): that's the answer.
        // Trying the other route would do the whole thing a second time.
        catch ChumbyError.refused(let why) { throw ChumbyError.refused(why) }
        catch ChumbyError.waiting(let why) { throw ChumbyError.waiting(why) }
        catch { last = error }
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
// Answers in words what happened, for Siri and Shortcuts: which alarm was skipped, or why nothing was (a skip already
// set, no alarm ahead). It used to answer "done" either way. And a skip the Chumby never confirmed is an error said
// aloud, never a button that quietly went back.
@discardableResult
func chumbySetSkip(_ on: Bool) async throws -> String {
    var said = on ? "No alarm to skip." : "No alarm was skipped."
    func when(_ d: Date) -> String { d.formatted(.dateTime.weekday(.wide).hour().minute()) }
    do {
        try await chumbyTry { api in
            var asked = false
            // The Chumby's own answer to the request says whether its panel took it (it waits up to 5 s for the panel);
            // when it does, that's the confirmation, with no further reading needed.
            var confirmed = false
            func took(_ j: [String: Any]) -> Bool { (j["pending"] as? Bool) == false && (j["skipped"] is [String: Any]) == on }
            if on {
                // Pinned by name to the ring the app shows as next (chumby 2c90cc9), and never over a skip already set: the
                // Chumby holds one, and replacing it would bring back an alarm (or a "just this once" pair) skipped on purpose.
                let s = try AlarmWriter.strict(await api.fresh("state"))
                if let k = s.skipped, k.date > Date() { said = "The \(when(k.date)) alarm is already skipped. Nothing was changed."; return }
                guard let n = s.nextRing() else { return }
                confirmed = took(try await api.post("skip", extra: "&name=" + ChumbyAPI.enc(n.alarm.name) + "&at=\(Int((n.at.timeIntervalSince1970 / 60).rounded()))"))
                said = "Skipped \(when(n.at))." + (s.ring(of: n.alarm, after: n.at.addingTimeInterval(60)).map { " It rings again \(when($0))." } ?? "")
                asked = true
            } else {
                // A "just this once" standing behind the skip goes back the app's way (ChumbyModel.undoJustOnce): the skip
                // taken back first, so the usual ring is on again, then its one-off removed. Never neither.
                let s = try AlarmWriter.strict(await api.fresh("state"))
                guard let k = s.skipped, k.date > Date() else { return }
                confirmed = took(try await api.post("unskip"))
                said = "The \(when(k.date)) alarm will ring."
                asked = true
                if let j = s.justOnce(), j.pinned, j.canUndo {
                    // Only once the Chumby itself says the skip is off: with the skip still on and the one-off gone,
                    // nothing would ring. Unconfirmed, the one-off stays, and both ring.
                    guard await chumbyUnskipConfirmed(api, since: s.chumbyNow) else { throw ChumbyError.refused(chumbyUnskipDoubt) }
                    _ = try await AlarmWriter.shared.edit(api, permit: SavePermit(userOff: [j.alarm.key])) { st in st.alarms.removeAll { $0.key == j.alarm.key } }
                }
            }
            guard asked else { return }
            // The list read back for the widgets' own copy; and, when the answer above didn't settle it, until it does.
            var cached = false
            for i in 0..<12 where !cached && (!confirmed || i < 3) {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let d = try? await api.fresh("state"), let s = try? AlarmWriter.strict(d) else { continue }
                if (s.skipped.map { $0.date > Date() } == true) == on {
                    try? d.write(to: chumbyWidgetCache, options: .atomic)
                    cached = true; confirmed = true
                }
            }
            if !confirmed { throw ChumbyError.refused(on ? "The Chumby didn’t confirm the skip. Check the alarm before you sleep." : "The Chumby didn’t confirm the undo. Check the alarm before you sleep.") }
        }
    } catch { WidgetCenter.shared.reloadAllTimelines(); throw ChumbyError.message(AlarmWriter.explain(error)) }
    WidgetCenter.shared.reloadAllTimelines()
    return said
}
// Reads the Chumby until it says no skip is set, in an answer made after `since` (its own clock when the undo was asked
// for, so a copy from before the request is never taken as its answer). The panel takes a couple of seconds, longer
// while it's loading a saved list. False when it never said so.
let chumbyUnskipDoubt = "The skip wasn’t confirmed off, so the one-off was kept. Both may ring."
func chumbyUnskipConfirmed(_ api: ChumbyAPI, since: Date?, tries: Int = 15) async -> Bool {
    for _ in 0..<tries {
        if let d = try? await api.fresh("state"), let s = try? AlarmWriter.strict(d), ChumbyState.answered(s, since: since) {
            if s.skipped.map({ $0.date > Date() }) != true { return true }
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
    return false
}
// The widgets' copy of the alarm list, kept so they can still answer "when's the next one" with no connection.
var chumbyWidgetCache: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-state.json") }
struct ChumbySkipIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Next Chumby Alarm"
    static var description = IntentDescription("Lets the next alarm pass without ringing, once.")
    func perform() async throws -> some IntentResult & ProvidesDialog { .result(dialog: IntentDialog(stringLiteral: try await chumbySetSkip(true))) }
}
struct ChumbyUnskipIntent: AppIntent {
    static var title: LocalizedStringResource = "Undo Chumby Alarm Skip"
    static var description = IntentDescription("Lets the skipped alarm ring after all.")
    func perform() async throws -> some IntentResult & ProvidesDialog { .result(dialog: IntentDialog(stringLiteral: try await chumbySetSkip(false))) }
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
        // The nap already set is replaced, by his own press: said so to the safety net, or it refuses to take away an alarm
        // due within three hours (a second press of the 20-minute control was turned down).
        do { _ = try await chumbyTry { try await AlarmWriter.shared.edit($0, planned: { s in let permit = s.napPermit(); s.addNap(minutes: minutes); return permit }) } }
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
    static var description = IntentDescription("Stops the alarm that’s ringing or snoozing.")
    func perform() async throws -> some IntentResult {
        do { try await chumbyTry { try await $0.cmd("ringoff") } }
        catch ChumbyError.message("not delivered") { throw ChumbyError.message("No Chumby alarm is ringing.") }
        catch { throw ChumbyError.message(AlarmWriter.explain(error)) }
        return .result()
    }
}
// The ringing alarm's own Snooze, by voice from bed: the same as pressing it on the Chumby. Says when it rings again.
struct ChumbySnoozeAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Snooze Chumby Alarm"
    static var description = IntentDescription("Snoozes the alarm that’s ringing.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let minutes = try await chumbyTry { api -> String? in
                // How long its snooze is, from the alarm that's ringing, read before it's pressed.
                let sys = try? JSONDecoder().decode(Sys.self, from: await api.fresh("sys"))
                let state = try? JSONDecoder().decode(ChumbyState.self, from: await api.raw("state").data)
                try await api.cmd("ringsnooze")
                return sys?.ringing.flatMap { r in state?.alarms.first { $0.name == r.name }?.snooze }
            }
            return .result(dialog: IntentDialog(stringLiteral: minutes.map { "Snoozed for \($0) minutes." } ?? "Snoozed."))
        }
        catch ChumbyError.message("not delivered") { throw ChumbyError.message("No Chumby alarm is ringing.") }
        catch { throw ChumbyError.message(AlarmWriter.explain(error)) }
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
}
