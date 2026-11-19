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
let chumbyUnskipDoubt = "The skip wasn’t confirmed off, so the just-this-once ring was kept. Both may ring."
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
// The ringing alarm's own Stop, from Control Center or Siri: the same as pressing it on the Chumby, through the same desk
// as the card's keys, and answered when the Chumby confirms. Allowed on a locked phone, as the card's keys are.
struct ChumbyStopAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Chumby Alarm"
    static var description = IntentDescription("Stops the alarm that’s ringing or snoozing.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await RingDesk.shared.press(.stop) {
        case .confirmed:
            await ChumbyRingCard.over(); await ChumbyRingCard.handled()
            return .result(dialog: "Stopped.")
        case .nothingRinging: throw ChumbyError.message("No Chumby alarm is ringing.")
        case .unconfirmed: return .result(dialog: "Sent. The Chumby hasn’t confirmed yet.")
        case .failed(let why): throw ChumbyError.message(why)
        }
    }
}
// The ringing alarm's own Snooze, by voice from bed: the same as pressing it on the Chumby. Says when it rings again,
// by the Chumby's own clock.
struct ChumbySnoozeAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Snooze Chumby Alarm"
    static var description = IntentDescription("Snoozes the alarm that’s ringing.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await RingDesk.shared.press(.snooze) {
        case .confirmed(let until):
            await ChumbyRingCard.handled()
            let at = until.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) }
            return .result(dialog: IntentDialog(stringLiteral: at.map { "Snoozed. It rings again at \($0)." } ?? "Snoozed."))
        case .nothingRinging: throw ChumbyError.message("No Chumby alarm is ringing.")
        case .unconfirmed: return .result(dialog: "Sent. The Chumby hasn’t confirmed yet.")
        case .failed(let why): throw ChumbyError.message(why)
        }
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

// MARK: - The ringing alarm, on the Lock Screen and in the Dynamic Island
// Richard, 2026-11-14: "i feel like i should be able to turn an alarm off from my phone like could u have a notif go off
// that the alarm is ringing with details make it beautiful and full screen chumby esque". The Mac sees the ring and
// starts this card by push (push.js, "A ringing alarm on the phone"); Stop and Snooze on it, on the notification beside
// it and on the app's ringing screen are all the Chumby's own (cmd ringoff / ringsnooze, the panel's stop and snooze).
struct ChumbyRingAttributes: Codable, Hashable {
    // Plain numbers (seconds since 1970) and words, as the Mac sends them; `problem` is only ever set here on the phone.
    struct ContentState: Codable, Hashable {
        var name: String
        var sound: String
        var at: Double
        var snoozed: Bool
        var until: Double?
        // How long this alarm's snooze is, in minutes, when the Mac knows: the card can say until when without asking.
        var snooze: Int?
        var problem: String?
        // "Stopping…" or "Snoozing…": a key was pressed and the Chumby hasn't answered yet.
        var working: String?
        var rang: Date { Date(timeIntervalSince1970: at) }
        var again: Date? { until.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }
        // "Work", or the time it's for when it has no name of its own.
        var title: String { name.isEmpty ? "\(rang.formatted(date: .omitted, time: .shortened)) alarm" : name }
    }
    var id: String
}

#if os(iOS)
import ActivityKit
import UserNotifications
extension ChumbyRingAttributes: ActivityAttributes {}

// The cards themselves. There is only ever one ring, so every card this phone holds is that ring's.
enum ChumbyRingCard {
    static var all: [Activity<ChumbyRingAttributes>] { Activity<ChumbyRingAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale } }
    static func over() async {
        for a in Activity<ChumbyRingAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        await clearNotice()
    }
    // What it shows now; out of date half an hour on (an alarm's usual length), or that long after a snooze ends, should
    // nothing more reach the phone.
    static func show(_ s: ChumbyRingAttributes.ContentState) async {
        let stale = (s.snoozed ? s.again ?? Date() : Date()).addingTimeInterval(31 * 60)
        for a in all { await a.update(ActivityContent(state: s, staleDate: stale)) }
    }
    static func change(_ edit: (inout ChumbyRingAttributes.ContentState) -> Void) async {
        for a in all { var s = a.content.state; edit(&s); await a.update(ActivityContent(state: s, staleDate: a.content.staleDate)) }
    }
    // Stop or Snooze pressed on this phone and taken: the Mac is told, so it doesn't put a "Snoozed" or "over" notice in
    // place of the one this phone has already put away (push.js, ringRestate). Only a signed build knows the Mac.
    static func handled() async { await post(["kind": "ring-handled"]) }
    static func diag(_ fields: [String: Any]) async { await post(fields.merging(["kind": "ring-diag"]) { a, _ in a }) }
    private static func post(_ fields: [String: Any]) async {
        guard let bundle = Bundle.main.bundleIdentifier, let mac = Bundle.main.object(forInfoDictionaryKey: "MacAddress") as? String,
              let base = URL(string: mac), let host = base.host,
              let url = URL(string: mac.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/push/token") else { return }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.setValue("\(base.scheme ?? "https")://\(host)\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: fields.merging(["app": "chumby", "bundle": bundle]) { a, _ in a })
        _ = try? await URLSession.shared.data(for: r)
    }
    // The ring's notification, by what the Mac marked it with (its identifier is Apple's to choose).
    static func clearNotice() async {
        let c = UNUserNotificationCenter.current()
        let ids = await c.deliveredNotifications().filter { ($0.request.content.userInfo["alert"] as? String) == ChumbyRingActions.noticeID || $0.request.identifier == ChumbyRingActions.noticeID }.map(\.request.identifier)
        c.removeDeliveredNotifications(withIdentifiers: ids + [ChumbyRingActions.noticeID])
    }
    // The Chumby, read at `asOf`, says nothing is ringing: whatever is left of a ring from before then goes. A ring is
    // only told once it has begun, within seconds of its minute, so half a minute past that a reading is newer than it;
    // a reading older than that could be a copy from before the ring, and ends nothing.
    static func sweep(asOf: Date) async {
        let cut = asOf.timeIntervalSince1970 - 30
        for a in Activity<ChumbyRingAttributes>.activities where a.content.state.at < cut && (a.content.state.until ?? 0) < cut { await a.end(nil, dismissalPolicy: .immediate) }
        let c = UNUserNotificationCenter.current()
        let old = await c.deliveredNotifications().filter { n in
            let info = n.request.content.userInfo
            guard (info["alert"] as? String) == ChumbyRingActions.noticeID else { return false }
            let at = ((info["ring"] as? [String: Any])?["at"] as? NSNumber)?.doubleValue ?? n.date.timeIntervalSince1970
            return at < cut && n.date.timeIntervalSince1970 < cut
        }.map(\.request.identifier)
        if !old.isEmpty { c.removeDeliveredNotifications(withIdentifiers: old) }
    }
}
#else
enum ChumbyRingCard {
    static func handled() async {}
    static func diag(_ fields: [String: Any]) async {}
    static func over() async {}
    static func show(_ s: ChumbyRingAttributes.ContentState) async {}
    static func change(_ edit: (inout ChumbyRingAttributes.ContentState) -> Void) async {}
    static func clearNotice() async {}
    static func sweep(asOf: Date) async {}
}
#endif

// Stop and Snooze, from wherever they're pressed (the card, the notification, the app's ringing page, Siri), all go
// through one desk (Richard, 2026-11-18: "stop or snooze looks good but doesnt work all the way through and is a bit
// janky"). What went wrong before:
//  - a press counted as done the moment the Chumby took the command, before the Chumby had stopped or snoozed: the card
//    ended, or said "Snoozed" with a guessed time, whatever the Chumby then did;
//  - two presses in a second (11-17 and 11-18: the card and the notification, or a press repeated) sent two taps.
// Now one press is on its way at a time (a second joins it), and it is done when the Chumby itself says so: a reading of
// what's ringing taken after the press shows nothing ringing (Stop) or the snooze with its own time (Snooze).
enum RingOutcome: Equatable {
    // The Chumby says it's done. `until`: when a snooze rings again, by the Chumby's own clock.
    case confirmed(until: Double?)
    // Nothing was ringing when it arrived (another press, or the Chumby's own button, got there first).
    case nothingRinging
    // The Chumby took it but hasn't said so yet (it said nothing within the wait, or its readings didn't come).
    case unconfirmed
    case failed(String)
}
actor RingDesk {
    static let shared = RingDesk()
    // What's ringing, read for a confirmation: the Chumby's own a=ring (answers at once, never kept by the Mac; 11-18),
    // or, from a Chumby without it, a=sys. Both carry the hook's line as "ring".
    struct RingLine: Decodable { let ring: String }
    static func ringLine(_ api: ChumbyAPI) async throws -> (data: Data, age: Double) {
        if let r = try? await api.raw("ring"), (try? JSONDecoder().decode(RingLine.self, from: r.data)) != nil { return r }
        return try await api.raw("sys")
    }
    enum Kind: String { case stop = "ringoff", snooze = "ringsnooze" }
    private var running: (kind: Kind, at: Date, id: UUID, task: Task<RingOutcome, Never>)?
    // How long the Chumby is given to show the change: its hook notes a stop or snooze within 2 s, and a=ring answers in
    // well under a second on either route (measured 11-18: 0.2 s at home, 0.5 s through the Mac).
    static let patience: TimeInterval = 14
    // `send` and `read` default to the routes every intent uses; the app's own page passes its own connection.
    func press(_ kind: Kind, send: (@Sendable (String) async throws -> Void)? = nil, read: (@Sendable () async throws -> (data: Data, age: Double))? = nil) async -> RingOutcome {
        if let r = running, Date().timeIntervalSince(r.at) < Self.patience + 6 {
            // The same press already on its way: its answer is this one's.
            if r.kind == kind { return await r.task.value }
            // A Snooze behind a Stop: once the Stop is through, nothing is left to snooze.
            if kind == .snooze { let o = await r.task.value; return o == .confirmed(until: nil) ? .nothingRinging : o }
            // A Stop behind a Snooze goes at once (gate, 11-18: it waited up to 14 s): the Chumby takes it whether the
            // snooze has landed (it ends the snooze for good) or not (it stops the ring).
        }
        let send = send ?? { c in try await chumbyTry { try await $0.cmd(c) } }
        let read = read ?? { try await chumbyTry { try await RingDesk.ringLine($0) } }
        let id = UUID(), task = Task { await Self.run(kind, send: send, read: read) }
        running = (kind, Date(), id, task)
        let out = await task.value
        if running?.id == id { running = nil }
        return out
    }
    private static func run(_ kind: Kind, send: @Sendable (String) async throws -> Void, read: @Sendable () async throws -> (data: Data, age: Double)) async -> RingOutcome {
        let sent = Date()
        do { try await send(kind.rawValue) }
        catch ChumbyError.message("not delivered") { return .nothingRinging }
        catch { return .failed(AlarmWriter.explain(error)) }
        while Date().timeIntervalSince(sent) < patience {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let r = try? await read(), let line = try? JSONDecoder().decode(RingLine.self, from: r.data) else { continue }
            var sys = Sys(); sys.ring = line.ring
            // Only a reading taken after the press says anything about it.
            guard r.age < Date().timeIntervalSince(sent) - 0.5 else { continue }
            switch (kind, sys.ringing) {
            case (_, nil): return kind == .stop ? .confirmed(until: nil) : .nothingRinging
            case (.snooze, let n?) where n.snoozed:
                let f = sys.ring.components(separatedBy: "\t")
                return .confirmed(until: f.count > 3 ? Double(f[3]).flatMap { $0 > 0 ? $0 : nil } : nil)
            default: continue
            }
        }
        return .unconfirmed
    }
}

// The card and the notification's side of it: the card says "Stopping…" from the press until the Chumby's answer, then
// ends (Stop) or shows the snooze by the Chumby's own time. A press that didn't get through, or that the Chumby hasn't
// confirmed, is said on the card with the keys back. Each answers nil when done, or why not.
enum ChumbyRingActions {
    static let noticeID = "chumby-ring"
    // Where a press came from and how it ended, to the Mac's log ("ring: phone ..."), so a press on the Lock Screen that
    // never arrives, or arrives and fails, can be told apart (Richard, 11-18: "i dont want to have to unlock").
    static func report(_ from: String, _ kind: String, _ out: RingOutcome, since: Date) async {
        let how: String
        switch out { case .confirmed: how = "confirmed"; case .nothingRinging: how = "nothing ringing"; case .unconfirmed: how = "unconfirmed"; case .failed(let w): how = "failed: " + w }
        await ChumbyRingCard.diag(["from": from, "press": kind, "outcome": how, "ms": Int(Date().timeIntervalSince(since) * 1000)])
    }
    @discardableResult static func stop(from: String = "card") async -> String? {
        let began = Date()
        await ChumbyRingCard.change { $0.working = "Stopping…"; $0.problem = nil }
        let out = await RingDesk.shared.press(.stop)
        await report(from, "stop", out, since: began)
        switch out {
        case .confirmed, .nothingRinging:
            await ChumbyRingCard.over()
            await ChumbyRingCard.handled()
            return nil
        case .unconfirmed:
            // It may well have stopped (the Mac ends the card when it sees so); the keys are back in case it didn't.
            await ChumbyRingCard.change { $0.working = nil; $0.problem = "Sent. The Chumby hasn’t confirmed yet." }
            return nil
        case .failed(let why):
            await ChumbyRingCard.change { $0.working = nil; $0.problem = "Didn’t stop. Try again." }
            return why
        }
    }
    @discardableResult static func snooze(from: String = "card") async -> String? {
        let began = Date()
        await ChumbyRingCard.change { $0.working = "Snoozing…"; $0.problem = nil }
        let out = await RingDesk.shared.press(.snooze)
        await report(from, "snooze", out, since: began)
        switch out {
        case .confirmed(let until):
            // Until when: the Chumby's own time; failing that, this alarm's snooze length from now (9 minutes is the
            // Chumby's usual), and the Mac's next word carries the panel's time.
            let now = Date()
            await ChumbyRingCard.change { $0.working = nil; $0.problem = nil; $0.snoozed = true; $0.until = until ?? now.addingTimeInterval(Double($0.snooze ?? 9) * 60).timeIntervalSince1970 }
            await ChumbyRingCard.clearNotice()
            await ChumbyRingCard.handled()
            return nil
        case .nothingRinging:
            await ChumbyRingCard.over()
            return nil
        case .unconfirmed:
            await ChumbyRingCard.change { $0.working = nil; $0.problem = "Sent. The Chumby hasn’t confirmed yet." }
            return nil
        case .failed(let why):
            await ChumbyRingCard.change { $0.working = nil; $0.problem = "Didn’t snooze. Try again." }
            return why
        }
    }
}

// The card's two keys. They run in the app, woken behind the Lock Screen, never opening it. (Only iOS has such keys; the
// Mac's typecheck of these files reads them as plain intents.)
#if os(iOS)
typealias ChumbyRingKey = LiveActivityIntent
#else
typealias ChumbyRingKey = AppIntent
#endif
// Richard, 2026-11-18: "i dont want to have to unlock to stop an alarm". Said outright rather than left to the defaults:
// they run on a locked phone (alwaysAllowed) and only in the background (never bringing the app forward to the unlock).
struct ChumbyRingStopIntent: ChumbyRingKey {
    static var title: LocalizedStringResource = "Stop the alarm"
    static var description = IntentDescription("Stops the alarm that’s ringing or snoozing.")
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult { await ChumbyRingActions.stop(); return .result() }
}
struct ChumbyRingSnoozeIntent: ChumbyRingKey {
    static var title: LocalizedStringResource = "Snooze the alarm"
    static var description = IntentDescription("Snoozes the alarm that’s ringing.")
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult { await ChumbyRingActions.snooze(); return .result() }
}
