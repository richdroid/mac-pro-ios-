import AppIntents
import SwiftUI
import WidgetKit

// What the Chumby says right now, for the controls that show a state: the next alarm (and whether it's skipped) and night
// mode. Read the same way the widgets read it; nil if it can't be reached, so a control never shows a guess as fact.
struct ChumbyNow {
    var skipped: SkippedAlarm?
    // A "just this once" standing behind that skip: the alarm moved for one ring, said as such, never as a skip.
    var moved: JustOnceNow?
    var next: Date?
    var night = false
    static func read() async -> ChumbyNow? {
        guard let both = try? await chumbyTry({ api -> (Sys, ChumbyState?) in
            // Not the Mac's old copy as it stands: Control Center asks after a quiet spell, and a skip or night mode set on
            // the Chumby itself would show the state from before it.
            // Both asked for at once: each may wait a couple of seconds for the Mac's new copy, and one after the other
            // that was twice the wait before Control Center drew the control.
            async let sysData = api.recent("sys").data
            async let stateData = api.recent("state").data
            let sys = try JSONDecoder().decode(Sys.self, from: try await sysData)
            let st = try? JSONDecoder().decode(ChumbyState.self, from: try await stateData)
            return (sys, st)
        }) else { return nil }
        var n = ChumbyNow(night: chumbyNightWanted() ?? (both.0.night == 1))
        n.skipped = both.1?.skipped.flatMap { $0.date > Date() ? $0 : nil }
        n.moved = both.1?.justOnce().flatMap { $0.pinned ? $0 : nil }
        n.next = both.1?.nextRing()?.at
        return n
    }
    var skipLabel: String {
        if let m = moved { return "Just this once \(m.at.formatted(date: .omitted, time: .shortened))" }
        if let s = skipped { return "Skipped \(s.date.formatted(date: .omitted, time: .shortened))" }
        return next.map { "Skip \($0.formatted(date: .omitted, time: .shortened))" } ?? "Skip Alarm"
    }
}
// The skip control's value carries its words too, so it can say which time it skips.
struct ChumbySkipState: Sendable { var on: Bool; var label: String; var moved = false }
struct ChumbySkipValue: ControlValueProvider {
    var previewValue: ChumbySkipState { ChumbySkipState(on: false, label: "Skip 6:45 AM") }
    func currentValue() async throws -> ChumbySkipState {
        let n = await ChumbyNow.read()
        return ChumbySkipState(on: n?.skipped != nil, label: n?.skipLabel ?? "Skip Alarm", moved: n?.moved != nil)
    }
}
struct ChumbyNightValue: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { await ChumbyNow.read()?.night ?? false }
}

// Skip the next alarm from Control Center or the Lock Screen: on lets it pass, off lets it ring after all.
struct ChumbySkipControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbySkipControl", provider: ChumbySkipValue()) { v in
            ControlWidgetToggle(v.label, isOn: v.on, action: ChumbySkipToggleIntent()) { on in
                Label(on ? (v.moved ? "Just this once" : "Skipped") : "Skip", systemImage: on ? (v.moved ? "clock.arrow.circlepath" : "moon.zzz.fill") : "forward.end.fill")
            }
        }
        .displayName("Skip Chumby Alarm").description("Lets the next alarm pass without ringing, once. Tap again to undo.")
    }
}
// One switch for night mode, showing the mode the Chumby is really in.
struct ChumbyNightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyNightToggle", provider: ChumbyNightValue()) { on in
            ControlWidgetToggle("Night Mode", isOn: on, action: ChumbyNightToggleIntent()) { on in
                Label(on ? "Night" : "Day", systemImage: on ? "moon.fill" : "sun.max.fill")
            }
        }
        .displayName("Chumby Night Mode").description("Night mode on the Chumby, on or off.")
    }
}
struct ChumbyNextControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyNextControl") {
            ControlWidgetButton(action: ChumbyNextIntent()) { Label("Next Widget", systemImage: "forward.fill") }
        }.displayName("Chumby Next Widget").description("Moves the Chumby on to its next widget.")
    }
}
struct ChumbyNapControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyNapControl") {
            ControlWidgetButton(action: ChumbyNapIntent(minutes: 20)) { Label("20-Minute Nap", systemImage: "zzz") }
        }.displayName("Chumby 20-Minute Nap").description("Sets a one-off alarm in 20 minutes.")
    }
}
// The ringing alarm's Stop, for the moment it goes off and the phone is nearer than the Chumby.
struct ChumbyStopAlarmControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyStopAlarmControl") {
            ControlWidgetButton(action: ChumbyStopAlarmIntent()) { Label("Stop Alarm", systemImage: "alarm.waves.left.and.right.fill") }
        }.displayName("Chumby Stop Alarm").description("Stops the alarm that’s ringing or snoozing.")
    }
}
struct ChumbyOpenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyOpenControl") {
            ControlWidgetButton(action: ChumbyOpenIntent()) { Label("Chumby", systemImage: "hand.tap.fill") }
        }.displayName("Open Chumby")
    }
}
