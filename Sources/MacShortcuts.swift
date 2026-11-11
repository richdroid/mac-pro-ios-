import AppIntents

struct MacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MacStatusIntent(), phrases: ["\(.applicationName) status", "How is my \(.applicationName)"], shortTitle: "Status", systemImageName: "gauge.with.dots.needle.67percent")
        AppShortcut(intent: MacClaudeUsageIntent(), phrases: ["Claude usage on \(.applicationName)"], shortTitle: "Claude Usage", systemImageName: "sparkle")
        AppShortcut(intent: MacOpenScreenIntent(), phrases: ["Show the \(.applicationName) screen"], shortTitle: "Screen", systemImageName: "macwindow")
        AppShortcut(intent: MacDisplayOffIntent(), phrases: ["Turn off the \(.applicationName) display"], shortTitle: "Display Off", systemImageName: "moon")
        AppShortcut(intent: MacCopyIntent(), phrases: ["Copy from \(.applicationName)"], shortTitle: "Copy from Mac", systemImageName: "doc.on.doc")
        AppShortcut(intent: MacSendIntent(), phrases: ["Paste to \(.applicationName)", "Send to \(.applicationName)"], shortTitle: "Paste to Mac", systemImageName: "doc.on.clipboard")
    }
}
