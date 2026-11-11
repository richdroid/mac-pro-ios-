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
        case "usage": return "gauge.with.dots.needle.67percent"
        default: return "exclamationmark.triangle.fill"
        }
    }
    // Getting worse counts as news; the same problem still being there doesn't.
    var ledgerKey: String { id + "|" + level }
    // What a dismissal holds on to: this alert, at this level, as raised this time. Worse, or gone and back, is a new one.
    var dismissKey: String { id + "|" + level + "|" + String(Int(since)) }
    // Temperatures in the unit chosen in Settings, when the Mac sends the reading itself.
    var shownDetail: String {
        if kind == "temp", let c { return "\(Heat.shown(c))°\(MacPrefs.celsius ? "C" : "F")" }
        return detail
    }
    // The service behind a "down" alert, when it's one the Mac can restart.
    var serviceLabel: String? { kind == "service" && id.hasPrefix("service:local.") ? String(id.dropFirst(8)) : nil }
    static let samples = [
        Status.Alert(id: "temp:CPU", level: "critical", kind: "temp", metric: "temp:CPU", title: "CPU is very hot", detail: "205°F", since: 0, c: 96),
        Status.Alert(id: "disk", level: "warning", kind: "disk", metric: "disk", title: "Disk nearly full", detail: "21 GB free", since: 0),
        Status.Alert(id: "service:local.mac-dash-tunnel", level: "warning", kind: "service", metric: nil, title: "Public link is down", detail: "Restart it in Control", since: 0),
    ]
}

// Alerts put away with their ✕ (Richard, 2026-11-10: "should be dismissable"). One stays away until it gets worse, or
// clears and comes back; the Mac still sends a notification for whatever happens next.
enum AlertDismissals {
    static let key = "alertsDismissed"
    static func set(_ raw: String) -> Set<String> { Set(raw.split(separator: "\n").map(String.init)) }
    static var stored: Set<String> {
        get { set(UserDefaults.standard.string(forKey: key) ?? "") }
        set { UserDefaults.standard.set(newValue.sorted().joined(separator: "\n"), forKey: key) }
    }
    static func dismiss(_ a: Status.Alert) { stored.insert(a.dismissKey) }
    // A tapped notification brings its alert back to the banner, so the tap never lands on nothing.
    static func restore(id: String) { let kept = stored.filter { !$0.hasPrefix(id + "|") }; if kept != stored { stored = kept } }
    // Only what's still raised is worth remembering.
    static func prune(_ alerts: [Status.Alert]) { let live = Set(alerts.map(\.dismissKey)), kept = stored.intersection(live); if kept != stored { stored = kept } }
}

struct AlertBanner: View {
    @EnvironmentObject private var noticeState: NoticeStore  // redrawn when the Mac's reachability changes (not through the model)
    @EnvironmentObject var model: AppModel
    let alerts: [Status.Alert]
    @AppStorage(AlertDismissals.key) private var dismissedRaw = ""
    private static var posed = false
    var shown: [Status.Alert] { let d = AlertDismissals.set(dismissedRaw); return alerts.filter { !d.contains($0.dismissKey) } }
    func dismiss(_ a: Status.Alert) {
        withAnimation(.snappy) { AlertDismissals.dismiss(a) }
        AlertWatch.shared.putAway(a.id)
        Task { try? await model.api.pushSeen(a.id) }
    }
    @State private var restarting: String?
    @State private var fails: [String: String] = [:]
    // A service that's down is restarted right here, rather than hunted for on another tab.
    func restart(_ a: Status.Alert, _ label: String) {
        restarting = a.id; fails[a.id] = nil
        Task {
            let e = await model.run("service-restart", ["label": label])
            restarting = nil
            fails[a.id] = e
        }
    }
    func detail(_ a: Status.Alert) -> String {
        guard a.serviceLabel != nil else { return a.shownDetail }
        return a.since > 0 ? "Down since \(Date(timeIntervalSince1970: a.since / 1000).formatted(date: .omitted, time: .shortened))" : "Not running"
    }
    // What a tap on the row itself opens: a session's page, Apps, or the reading's history.
    func open(_ a: Status.Alert) {
        // A session waiting on a question opens straight onto its page, on the Claude tab.
        if a.id.hasPrefix("session:") { model.openSession(key: String(a.id.dropFirst(8))) }
        // Updates waiting while he's away: Apps, and the install starts there.
        else if a.id == OTAInstaller.alertID { model.tab = 1; OTAInstaller.shared.wanted = true }
        // Claude usage near its limit: the usage itself, on the Claude tab.
        else if a.kind == "usage" { model.show(tab: 3) }
        else if let m = a.metric.flatMap(HistoryMetric.named) { model.history = m } else { model.tab = 5 }
    }
    func what(_ a: Status.Alert) -> some View {
        HStack(spacing: 12) {
            Image(systemName: a.symbol).font(.title3).foregroundStyle(a.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.body.weight(.semibold))
                Text(detail(a)).font(.footnote).foregroundStyle(.secondary)
                if let f = fails[a.id] { Text(f).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
    // The alert, what can be done about it, and its ✕: three things side by side, never a button inside a button.
    func row(_ a: Status.Alert) -> some View {
        HStack(spacing: 4) {
            if let label = a.serviceLabel {
                what(a)
                if restarting == a.id { ProgressView().padding(.trailing, 8) }
                else { Button("Restart") { restart(a, label) }.buttonStyle(.bordered).controlSize(.small).tint(a.tint).disabled(model.stale) }
            } else {
                Button { open(a) } label: { what(a) }.buttonStyle(.plain)
            }
            // Put away with the mark beside it, drawn at full strength: it's a button, not a hint.
            Button { dismiss(a) } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            // Plain, so the mark is the row's own ink: a borderless button drew it in the accent blue (CI e883e9d).
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss \(a.title)")
            .padding(.trailing, -12)
        }
    }
    // Arriving, or the last one put away: the page makes room in one move, never in one frame.
    var body: some View {
        Group { banner }.animation(.snappy, value: shown.map(\.dismissKey))
    }
    @ViewBuilder var banner: some View {
        if !shown.isEmpty {
            Section {
                ForEach(shown) { a in
                    row(a).listRowBackground(a.tint.opacity(0.22))
                }
            }
            // For the build's film of a dismissal: all three shown, then the first put away. Only with the pose.
            .task {
                guard model.pose == "alerts" || model.pose == "alertsdismiss", !Self.posed else { return }
                Self.posed = true
                AlertDismissals.stored = []
                guard model.pose == "alertsdismiss" else { return }
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                if let a = shown.first { withAnimation(.snappy) { AlertDismissals.dismiss(a) } }
            }
        }
    }
}

struct AlertSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AlertWatch.enabledKey) private var enabled = true
    // Starts from what was last found, so a rebuilt row (a new posture, the list making it again) doesn't gain its Settings
    // link a moment after it's drawn and push the page down.
    @MainActor private static var lastDenied = false
    @State private var denied = AlertSettings.lastDenied
    var body: some View {
        Section {
            Toggle("Notify this iPhone", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    if on { Task { denied = !(await AlertWatch.shared.ask()); Self.lastDenied = denied } }
                    // Off: the Mac forgets this iPhone. On: it's told where to send again.
                    PushToken.share(model.api)
                }
            #if canImport(UIKit)
            if denied && enabled, let u = URL(string: UIApplication.openSettingsURLString) {
                Link("Allow notifications in Settings", destination: u)
            }
            #endif
        } header: { Text("Alerts") } footer: {
            Text("Too hot, disk nearly full, something down, or Claude usage nearly out.")
        }
        .task { let d = await AlertWatch.shared.isDenied(); Self.lastDenied = d; if d != denied { withAnimation(Motion.quick) { denied = d } } }
    }
}

final class AlertWatch: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertWatch()
    static let refreshID = "local.macpro.MacPro.alerts"
    static let enabledKey = "alertNotifications"
    // Carries the tapped notification's identifier, so the app can open where it points.
    static let openAlert = Notification.Name("macproOpenAlert")
    static var pending: String?
    private static let ledgerKey = "alertLedger", askedKey = "alertsAsked"
    private static let quietFor: TimeInterval = 12 * 3600
    private let center = UNUserNotificationCenter.current()
    private var lastSeen: Set<String>?

    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    // The waiting-updates notification carries Install, which opens the app and starts them, as tapping it does.
    func install() {
        center.delegate = self
        let install = UNNotificationAction(identifier: "install", title: "Install", options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "arrow.down.circle"))
        center.setNotificationCategories([UNNotificationCategory(identifier: OTAInstaller.alertID, actions: [install], intentIdentifiers: [], options: [])])
    }
    // Put away in the app: its notification goes from the Lock Screen too.
    func putAway(_ id: String) { center.removeDeliveredNotifications(withIdentifiers: [id]) }

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
        AlertDismissals.prune(alerts)
        Task { await update(alerts, notify: false) }
    }

    func backgroundCheck() async {
        guard enabled else { return }
        let address = SavedAddress.value
        guard let base = URL(string: address), base.host != nil else { return }
        // Not reaching the Mac says nothing: the iPhone may just have Tailscale off.
        guard let alerts = try? await API(base: base).alerts() else { return }
        await update(alerts, notify: true)
    }

    private func update(_ alerts: [Status.Alert], notify: Bool) async {
        let now = Date().timeIntervalSince1970
        var ledger = UserDefaults.standard.dictionary(forKey: Self.ledgerKey) as? [String: Double] ?? [:]
        let due = alerts.filter { now - (ledger[$0.ledgerKey] ?? 0) >= Self.quietFor }
        for a in alerts where due.contains(where: { $0.id == a.id }) { ledger[a.ledgerKey] = now }
        // Fixed problems leave the ledger only after the quiet time, so one that keeps coming back stays quiet.
        ledger = ledger.filter { now - $0.value < Self.quietFor }
        UserDefaults.standard.set(ledger, forKey: Self.ledgerKey)

        var live = Set(alerts.map(\.id))
        if !alerts.isEmpty { live.insert("several") }
        let over = await center.deliveredNotifications().map(\.request.identifier).filter { !live.contains($0) }
        if !over.isEmpty { center.removeDeliveredNotifications(withIdentifiers: over) }

        // The Mac sends the real notification now, the moment something changes. This check is only the fallback, for
        // what the Mac couldn't send: nothing Apple already took from it, and nothing already on the Lock Screen.
        let shown = Set(await center.deliveredNotifications().map(\.request.identifier))
        let fresh = due.filter { $0.pushed != true && !shown.contains($0.id) }
        guard notify, !fresh.isEmpty else { return }
        // Updates waiting are news of their own, with Install on them, never folded into "needs attention".
        if let o = fresh.first(where: { $0.id == OTAInstaller.alertID }) {
            let content = UNMutableNotificationContent()
            content.sound = .default
            content.title = o.title
            content.body = o.shownDetail
            content.categoryIdentifier = OTAInstaller.alertID
            try? await center.add(UNNotificationRequest(identifier: o.id, content: content, trigger: nil))
        }
        let rest = fresh.filter { $0.id != OTAInstaller.alertID }
        guard !rest.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default
        // Several things going wrong together is one piece of news.
        if rest.count == 1 {
            content.title = rest[0].title
            content.body = rest[0].shownDetail
        } else {
            content.title = "Mac Pro needs attention"
            content.body = rest.map(\.title).joined(separator: ", ")
        }
        try? await center.add(UNNotificationRequest(identifier: rest.count == 1 ? rest[0].id : "several", content: content, trigger: nil))
    }

    #if os(iOS)
    func scheduleRefresh() {
        guard enabled else { return }
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        r.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
    #endif

    // Tapping a notification opens where it can be acted on: a waiting session on its own page, waiting updates on Apps
    // with their install started (tapped or its Install), anything else on Status, where the banner is.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        // The Mac's notifications carry the alert's id; one made here is named by it.
        let id = response.notification.request.content.userInfo["alert"] as? String ?? response.notification.request.identifier
        AlertDismissals.restore(id: id)
        UserDefaults.standard.set(id.hasPrefix("session:") || id.hasPrefix("usage:") ? 2 : id == OTAInstaller.alertID ? 1 : 0, forKey: "tab")
        if id == OTAInstaller.alertID { Task { @MainActor in OTAInstaller.shared.wanted = true } }
        // Kept too, in case the tap launched the app and nothing is listening yet.
        Self.pending = id
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.openAlert, object: id) }
        done()
    }
}

// This iPhone's address for notifications, handed to the Mac (tailnet only) so its alerts arrive through Apple's push
// service the moment they're raised, app open or not. Sent again whenever the app comes forward, so the Mac always holds
// the current one and the unit temperatures are read in.
enum PushToken {
    static let key = "pushToken"
    private static var sent: String?
    // Simulator shots have no push service, and no Mac to tell.
    static var staged: Bool { UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["address"] != nil }
    static func got(_ token: String) {
        UserDefaults.standard.set(token, forKey: key)
        guard let base = URL(string: SavedAddress.value), base.host != nil else { return }
        share(API(base: base))
    }
    static func share(_ api: API) {
        guard let token = UserDefaults.standard.string(forKey: key), !token.isEmpty, let bundle = Bundle.main.bundleIdentifier else { return }
        let on = UserDefaults.standard.object(forKey: AlertWatch.enabledKey) as? Bool ?? true
        let celsius = MacPrefs.celsius
        let stamp = "\(token)|\(on)|\(celsius)"
        guard stamp != sent else { return }
        Task {
            do { try await api.pushToken(token, bundle: bundle, celsius: celsius, off: !on); sent = stamp } catch {}
        }
    }
}

#if canImport(UIKit)
final class PushDelegate: NSObject, UIApplicationDelegate {
    // Asked for at every launch: iOS answers with the current token, which can change after a restore.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !PushToken.staged { application.registerForRemoteNotifications() }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushToken.got(deviceToken.map { String(format: "%02x", $0) }.joined())
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
#endif
