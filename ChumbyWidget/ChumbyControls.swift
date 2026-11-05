import AppIntents
import SwiftUI
import WidgetKit

// What the Chumby says right now, for the controls that show a state: the next alarm (and whether it's skipped) and night
// mode. Read the same way the widgets read it; nil if it can't be reached, so a control never shows a guess as fact.
struct ChumbyNow {
    var skipped: SkippedAlarm?
    var next: Date?
    var night = false
    static func read() async -> ChumbyNow? {
        guard let both = try? await chumbyTry({ api -> (Sys, ChumbyState?) in
            let sys = try JSONDecoder().decode(Sys.self, from: try await api.raw("sys").data)
            let st = try? JSONDecoder().decode(ChumbyState.self, from: try await api.raw("state").data)
            return (sys, st)
        }) else { return nil }
        var n = ChumbyNow(night: both.0.night == 1)
        n.skipped = both.1?.skipped.flatMap { $0.date > Date() ? $0 : nil }
        n.next = both.1?.nextRing()?.at
        return n
    }
    var skipLabel: String {
        if let s = skipped { return "Skipped \(s.date.formatted(date: .omitted, time: .shortened))" }
        return next.map { "Skip \($0.formatted(date: .omitted, time: .shortened))" } ?? "Skip Alarm"
    }
}
// The skip control's value carries its words too, so it can say which time it skips.
struct ChumbySkipState: Sendable { var on: Bool; var label: String }
struct ChumbySkipValue: ControlValueProvider {
    var previewValue: ChumbySkipState { ChumbySkipState(on: false, label: "Skip 6:45 AM") }
    func currentValue() async throws -> ChumbySkipState {
        let n = await ChumbyNow.read()
        return ChumbySkipState(on: n?.skipped != nil, label: n?.skipLabel ?? "Skip Alarm")
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
                Label(on ? "Skipped" : "Skip", systemImage: on ? "moon.zzz.fill" : "forward.end.fill")
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
                Label(on ? "On" : "Off", systemImage: on ? "moon.fill" : "moon")
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
