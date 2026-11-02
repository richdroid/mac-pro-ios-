import AppIntents

struct ChumbyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ChumbyStatusIntent(), phrases: ["How is my \(.applicationName)", "\(.applicationName) status"], shortTitle: "Status", systemImageName: "waveform.path.ecg")
        AppShortcut(intent: ChumbyNextAlarmIntent(), phrases: ["When is my next \(.applicationName) alarm"], shortTitle: "Next Alarm", systemImageName: "alarm")
        AppShortcut(intent: ChumbyCalendarIntent(), phrases: ["Update \(.applicationName) from my calendar"], shortTitle: "Calendar Alarms", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: ChumbyNapIntent(), phrases: ["Nap with \(.applicationName)"], shortTitle: "Nap", systemImageName: "zzz")
        AppShortcut(intent: ChumbyGoodnightIntent(), phrases: ["Goodnight \(.applicationName)"], shortTitle: "Goodnight", systemImageName: "moon.fill")
        AppShortcut(intent: ChumbyMorningIntent(), phrases: ["Good morning \(.applicationName)"], shortTitle: "Good Morning", systemImageName: "sun.max.fill")
        AppShortcut(intent: ChumbyNextIntent(), phrases: ["Next \(.applicationName) widget"], shortTitle: "Next Widget", systemImageName: "forward.fill")
        AppShortcut(intent: ChumbyStopMusicIntent(), phrases: ["Stop \(.applicationName) music"], shortTitle: "Stop Music", systemImageName: "stop.fill")
        AppShortcut(intent: ChumbyVolumeIntent(), phrases: ["Set \(.applicationName) volume"], shortTitle: "Volume", systemImageName: "speaker.wave.2.fill")
    }
}
