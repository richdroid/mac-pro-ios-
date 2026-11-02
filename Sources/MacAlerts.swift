import SwiftUI
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif

// The Mac decides what counts as a problem, and how long it has to last. This only shows and tells.
extension Status.Alert {
    var tint: Color { level == "critical" ? .red : .orange }
    var symbol: String {
        switch kind {
        case "temp": return "thermometer.high"
        case "disk": return "internaldrive.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
    // Getting worse counts as news; the same problem still being there doesn't.
    var ledgerKey: String { id + "|" + level }
    static let samples = [
        Status.Alert(id: "temp:CPU", level: "critical", kind: "temp", metric: "temp:CPU", title: "CPU is hot", detail: "205°F", since: 0),
        Status.Alert(id: "disk", level: "warning", kind: "disk", metric: "disk", title: "Disk nearly full", detail: "21 GB free", since: 0),
        Status.Alert(id: "service:local.mac-dash-tunnel", level: "warning", kind: "service", metric: nil, title: "Public link is down", detail: "Restart it in Control", since: 0),
    ]
}

struct AlertBanner: View {
    @EnvironmentObject var model: AppModel
    let alerts: [Status.Alert]
    var body: some View {
        Section {
            ForEach(alerts) { a in
                Button {
                    // A session waiting on a question opens straight onto its screen, where it can be answered.
                    if a.id.hasPrefix("session:"), let s = model.status?.claude.sessions.first(where: { $0.key == String(a.id.dropFirst(8)) }) { model.sessionScreen = s }
                    else if let m = a.metric.flatMap(HistoryMetric.named) { model.history = m } else { model.tab = 5 }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: a.symbol).font(.title3).foregroundStyle(a.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.title).font(.body.weight(.semibold))
                            Text(a.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(a.tint.opacity(0.22))
            }
        }
    }
}

struct AlertSettings: View {
    @AppStorage(AlertWatch.enabledKey) private var enabled = true
    @State private var denied = false
    let clear: Bool
    var body: some View {
        Section {
            StateRow(label: "Mac Pro", good: clear, value: clear ? "All clear" : "Needs attention")
            Toggle("Notify this iPhone", isOn: $enabled)
                .onChange(of: enabled) { _, on in if on { Task { denied = !(await AlertWatch.shared.ask()) } } }
            #if canImport(UIKit)
            if denied && enabled, let u = URL(string: UIApplication.openSettingsURLString) {
                Link("Allow notifications in Settings", destination: u)
            }
            #endif
        } header: { Text("Alerts") } footer: {
            Text("Too hot, disk nearly full or a service down. iOS chooses when the app checks, so it can take a while.")
        }
        .task { denied = await AlertWatch.shared.isDenied() }
    }
}

final class AlertWatch: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertWatch()
    static let refreshID = "local.macpro.MacPro.alerts"
    static let enabledKey = "alertNotifications"
    static let openStatus = Notification.Name("macproOpenStatus")
    private static let ledgerKey = "alertLedger", askedKey = "alertsAsked"
    private static let quietFor: TimeInterval = 12 * 3600
    private let center = UNUserNotificationCenter.current()
    private var lastSeen: Set<String>?

    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    func install() { center.delegate = self }

    @discardableResult func ask() async -> Bool {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    func isDenied() async -> Bool { await center.notificationSettings().authorizationStatus == .denied }

    // Once, the first time the app opens. Simulator shots launch with -address and shouldn't have a prompt over them.
    func askOnce() {
        let launchedWithArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["address"] != nil
        guard enabled, !launchedWithArguments, !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        Task { await ask() }
    }

    // With the app open the banner says it, so a notification later would only repeat it.
    func sawInForeground(_ alerts: [Status.Alert]) {
        let keys = Set(alerts.map(\.ledgerKey))
        guard keys != lastSeen else { return }
        lastSeen = keys
        Task { await update(alerts, notify: false) }
    }

    func backgroundCheck() async {
        guard enabled else { return }
        let saved = UserDefaults.standard.string(forKey: "address") ?? ""
        let address = saved.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : saved
        guard let base = URL(string: address), base.host != nil else { return }
        // Not reaching the Mac says nothing: the iPhone may just have Tailscale off.
        guard let alerts = try? await API(base: base).alerts() else { return }
        await update(alerts, notify: true)
    }

    private func update(_ alerts: [Status.Alert], notify: Bool) async {
        let now = Date().timeIntervalSince1970
        var ledger = UserDefaults.standard.dictionary(forKey: Self.ledgerKey) as? [String: Double] ?? [:]
        let fresh = alerts.filter { now - (ledger[$0.ledgerKey] ?? 0) >= Self.quietFor }
        for a in alerts where fresh.contains(where: { $0.id == a.id }) { ledger[a.ledgerKey] = now }
        // Fixed problems leave the ledger only after the quiet time, so one that keeps coming back stays quiet.
        ledger = ledger.filter { now - $0.value < Self.quietFor }
        UserDefaults.standard.set(ledger, forKey: Self.ledgerKey)

        var live = Set(alerts.map(\.id))
        if !alerts.isEmpty { live.insert("several") }
        let over = await center.deliveredNotifications().map(\.request.identifier).filter { !live.contains($0) }
        if !over.isEmpty { center.removeDeliveredNotifications(withIdentifiers: over) }

        guard notify, !fresh.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default
        // Several things going wrong together is one piece of news.
        if fresh.count == 1 {
            content.title = fresh[0].title
            content.body = fresh[0].detail
        } else {
            content.title = "Mac Pro needs attention"
            content.body = fresh.map(\.title).joined(separator: ", ")
        }
        try? await center.add(UNNotificationRequest(identifier: fresh.count == 1 ? fresh[0].id : "several", content: content, trigger: nil))
    }

    #if os(iOS)
    func scheduleRefresh() {
        guard enabled else { return }
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        r.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
    #endif

    // Tapping a notification opens Status, where the banner is.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        UserDefaults.standard.set(0, forKey: "tab")
        NotificationCenter.default.post(name: Self.openStatus, object: nil)
        done()
    }
}
