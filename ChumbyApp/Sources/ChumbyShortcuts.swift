import AppIntents

struct ChumbyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ChumbyStatusIntent(), phrases: ["How is my \(.applicationName)", "\(.applicationName) status"], shortTitle: "Status", systemImageName: "waveform.path.ecg")
        AppShortcut(intent: ChumbyNextAlarmIntent(), phrases: ["When is my next \(.applicationName) alarm"], shortTitle: "Next Alarm", systemImageName: "alarm")
        // The three things said from bed: skip tomorrow's, snooze the one ringing, stop it. iOS takes ten of these per app,
        // so "Next widget" and "Set volume" gave their places up (both are still actions in Shortcuts and Control Center).
        AppShortcut(intent: ChumbySkipIntent(), phrases: ["Skip my next \(.applicationName) alarm", "Skip the \(.applicationName) alarm"], shortTitle: "Skip Next Alarm", systemImageName: "forward.end.fill")
        AppShortcut(intent: ChumbySnoozeAlarmIntent(), phrases: ["Snooze the \(.applicationName) alarm", "Snooze \(.applicationName)"], shortTitle: "Snooze Alarm", systemImageName: "moon.zzz.fill")
        AppShortcut(intent: ChumbyStopAlarmIntent(), phrases: ["Stop the \(.applicationName) alarm"], shortTitle: "Stop Alarm", systemImageName: "alarm.waves.left.and.right.fill")
        AppShortcut(intent: ChumbyCalendarIntent(), phrases: ["Update \(.applicationName) from my calendar"], shortTitle: "Calendar Alarms", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: ChumbyNapIntent(), phrases: ["Nap with \(.applicationName)"], shortTitle: "Nap", systemImageName: "zzz")
        AppShortcut(intent: ChumbyGoodnightIntent(), phrases: ["Goodnight \(.applicationName)"], shortTitle: "Goodnight", systemImageName: "moon.fill")
        AppShortcut(intent: ChumbyMorningIntent(), phrases: ["Good morning \(.applicationName)"], shortTitle: "Good Morning", systemImageName: "sun.max.fill")
        AppShortcut(intent: ChumbyStopMusicIntent(), phrases: ["Stop \(.applicationName) music"], shortTitle: "Stop Music", systemImageName: "stop.fill")
    }
}
