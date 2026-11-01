import AppIntents

struct MacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MacStatusIntent(), phrases: ["\(.applicationName) status", "How is my \(.applicationName)"], shortTitle: "Status", systemImageName: "gauge.with.dots.needle.67percent")
        AppShortcut(intent: MacClaudeUsageIntent(), phrases: ["Claude usage on \(.applicationName)"], shortTitle: "Claude Usage", systemImageName: "sparkle")
        AppShortcut(intent: MacOpenScreenIntent(), phrases: ["Show the \(.applicationName) screen"], shortTitle: "Screen", systemImageName: "macwindow")
        AppShortcut(intent: MacDisplayOffIntent(), phrases: ["Turn off the \(.applicationName) display"], shortTitle: "Display Off", systemImageName: "moon")
        AppShortcut(intent: MacCopyIntent(), phrases: ["Copy from \(.applicationName)"], shortTitle: "Copy from Mac", systemImageName: "square.and.arrow.down")
        AppShortcut(intent: MacSendIntent(), phrases: ["Send to \(.applicationName)"], shortTitle: "Send to Mac", systemImageName: "square.and.arrow.up")
        AppShortcut(intent: MacRenewAppsIntent(), phrases: ["Renew my apps with \(.applicationName)"], shortTitle: "Renew Apps", systemImageName: "arrow.clockwise")
    }
}
