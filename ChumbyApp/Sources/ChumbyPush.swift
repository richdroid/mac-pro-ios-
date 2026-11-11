import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// Real notifications for the Chumby (Richard, 2026-11-10: "those should come through notif center now like fr same with
// chumby alarms and the like"). The Mac watches the Chumby, reading only, and sends them through Apple's push service:
// - an alarm that was missed (the Chumby was frozen or off);
// - the Chumby gone offline with an alarm due later today, and again at the alarm's own minute if it's still gone;
// - quietly, that it's back with the alarm set.
// One is made here on the phone: a calendar alarm the background update couldn't put on the Chumby.
// A second one made here: a skip or an undo of his that the Chumby never confirmed, found out after he'd left the app.
// Never sent, by ruling: an alarm ringing or ringing late (he's there), skips and naps (his own doing), and no badges.
final class ChumbyNotify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ChumbyNotify()
    static let enabledKey = "chumbyNotifications"
    // noAlarmID is the Mac's: a work event coming with no alarm before it, which the calendar update here then sets.
    static let unsetID = "chumby-unset", offlineID = "chumby-offline", noAlarmID = "chumby-noalarm", skipID = "chumby-skip"
    private static let tokenKey = "pushToken", askedKey = "notifyAsked", toldKey = "unsetTold", knownKey = "wakesOnChumby"
    private let center = UNUserNotificationCenter.current()
    private var sent: String?

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    // The build's simulator shots launch with -address or a pose: no prompt over them, and no Mac to tell.
    var staged: Bool {
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return args["address"] != nil || args["pose"] != nil
    }

    func install() {
        center.delegate = self
        guard !staged else { return }
        if enabled, !UserDefaults.standard.bool(forKey: Self.askedKey) { Task { await ask() } }
    }
    @discardableResult func ask() async -> Bool {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func isDenied() async -> Bool { await center.notificationSettings().authorizationStatus == .denied }

    // This iPhone's address for notifications, handed to the Mac over the tailnet, and again whenever the app comes
    // forward, so the Mac always holds the current one. Off in Settings: the Mac is told to forget it.
    func got(_ token: String) { UserDefaults.standard.set(token, forKey: Self.tokenKey); share() }
    func share() {
        guard !staged, let token = UserDefaults.standard.string(forKey: Self.tokenKey), !token.isEmpty,
              let bundle = Bundle.main.bundleIdentifier,
              let mac = Bundle.main.object(forInfoDictionaryKey: "MacAddress") as? String,
              let base = URL(string: mac), let host = base.host,
              let url = URL(string: mac.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/push/token") else { return }
        let on = enabled, stamp = "\(token)|\(on)"
        guard stamp != sent else { return }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 15
        // The Mac turns away requests from other sites, so this says which site it is, as its own app does.
        r.setValue("\(base.scheme ?? "https")://\(host)\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["app": "chumby", "bundle": bundle, "token": token, "off": !on])
        Task {
            guard let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            await MainActor.run { self.sent = stamp }
        }
    }

    // Opening Alarms is reading them: nothing stays behind on the Lock Screen.
    func clearDelivered() { center.removeAllDeliveredNotifications() }

    // After the calendar's update in the background. A wake due within a day that the Chumby isn't known to hold, and
    // couldn't be given, is worth saying once; an update that went through takes the note away again.
    @MainActor func afterBackgroundSync() async {
        let cal = CalendarWake.shared
        let now = Date()
        let wanted = cal.rules.enabled ? cal.plan.filter { !$0.skipped && $0.wake > now } : []
        func key(_ w: PlannedWake) -> String { CalendarWake.minutes(w.wake) + CalendarWake.alarmName(w) }
        guard let note = cal.note else {
            // It went through: these are on the Chumby now.
            UserDefaults.standard.set(wanted.map(key), forKey: Self.knownKey)
            center.removeDeliveredNotifications(withIdentifiers: [Self.unsetID])
            return
        }
        // Held for a ringing alarm: it tries again by itself, and he's being woken as it is.
        guard enabled, !note.hasPrefix("Holding") else { return }
        let known = Set(UserDefaults.standard.stringArray(forKey: Self.knownKey) ?? [])
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chumby-state")
        let last = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ChumbyState.self, from: $0) }
        let onChumby = Set((last?.alarms ?? []).filter(\.isOn).map { $0.time + $0.name })
        guard let w = wanted.filter({ $0.wake.timeIntervalSince(now) <= 86400 && !known.contains(key($0)) && !onChumby.contains(key($0)) }).min(by: { $0.wake < $1.wake }) else { return }
        guard UserDefaults.standard.string(forKey: Self.toldKey) != key(w) else { return }
        // The Mac has already said the Chumby is offline: the same trouble, told once.
        guard !(await center.deliveredNotifications()).contains(where: { $0.request.identifier == Self.offlineID }) else { return }
        UserDefaults.standard.set(key(w), forKey: Self.toldKey)
        let content = UNMutableNotificationContent()
        content.title = "\(w.wake.formatted(date: .omitted, time: .shortened)) alarm isn’t set"
        content.body = "\(w.shown) isn’t on the Chumby yet. Open to retry."
        content.sound = .default
        // Tonight's alarm is worth breaking through for; one for tomorrow afternoon can wait its turn.
        content.interruptionLevel = w.wake.timeIntervalSince(now) <= 12 * 3600 ? .timeSensitive : .active
        try? await center.add(UNNotificationRequest(identifier: Self.unsetID, content: content, trigger: nil))
    }

    // A skip or an undo asked for in the app that the Chumby still hadn't confirmed 22 s later (ChumbyModel.settleSkip),
    // by which time the app had been left: at the card it would be said there. The Mac can't see this (a skip set on
    // the Chumby looks the same whether he meant it or it's an undo that failed), so the phone says it. An undo that
    // didn't land is an alarm that may not ring, and breaks through; a skip that didn't land is only an alarm he didn't
    // want. No prompt of its own: it's sent only if notifications were already allowed (install, or Tinker's switch).
    func skipUnconfirmed(undo: Bool, at: Date?) async {
        guard enabled, !staged, await center.notificationSettings().authorizationStatus == .authorized else { return }
        let which = at.map { "Your \($0.formatted(date: .omitted, time: .shortened)) alarm" } ?? "Your alarm"
        let content = UNMutableNotificationContent()
        content.title = undo ? "Skip not undone" : "Skip not confirmed"
        content.body = undo ? "\(which) may not ring. Open Chumby to check." : "\(which) may still ring. Open Chumby to check."
        content.sound = .default
        content.interruptionLevel = undo ? .timeSensitive : .active
        try? await center.add(UNNotificationRequest(identifier: Self.skipID, content: content, trigger: nil))
    }
    // Gone once it's put right: the Chumby agrees, or he skips or undoes again.
    func skipSettled() { center.removeDeliveredNotifications(withIdentifiers: [Self.skipID]) }

    // Every one of them is about an alarm: a tap opens Alarms, and the one about an alarm not set tries again at once.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["alert"] as? String ?? response.notification.request.identifier
        UserDefaults.standard.set(2, forKey: "tab")
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.opened, object: id) }
        done()
    }
    static let opened = Notification.Name("chumbyOpenedNotification")
}

// Tinker's "Notifications": one switch, as the Mac Pro app has.
struct NotifySettings: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(ChumbyNotify.enabledKey) private var enabled = true
    @State private var denied = false
    var askSettings: Bool {
        #if canImport(UIKit)
        denied && enabled
        #else
        false
        #endif
    }
    var body: some View {
        Section {
            // What it sends, said in the row (it was the footer, under a one-row capsule: designer, 11-11).
            Toggle("Notify this iPhone", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    if on { Task { denied = !(await ChumbyNotify.shared.ask()) } }
                    ChumbyNotify.shared.share()
                }
                .soloCard(note: "Only when an alarm was missed or may not ring.", on: !askSettings)
            #if canImport(UIKit)
            if askSettings, let u = URL(string: UIApplication.openSettingsURLString) {
                Link("Allow notifications in Settings", destination: u)
            }
            #endif
        } header: { SectionHead(icon: "bell.fill", text: "Notifications") }
        .task { denied = await ChumbyNotify.shared.isDenied() }
    }
}

#if canImport(UIKit)
// Only for the notification token iOS hands to an app delegate.
final class ChumbyPushDelegate: NSObject, UIApplicationDelegate {
    // Asked for at every launch: iOS answers with the current token, which can change after a restore.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !ChumbyNotify.shared.staged { application.registerForRemoteNotifications() }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ChumbyNotify.shared.got(deviceToken.map { String(format: "%02x", $0) }.joined())
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
#endif
