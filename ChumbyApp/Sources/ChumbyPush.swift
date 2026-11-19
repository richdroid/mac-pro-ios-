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
// And, from 2026-11-14, an alarm that is ringing (Richard: "i should be able to turn an alarm off from my phone like could u
// have a notif go off that the alarm is ringing with details"): Time Sensitive, with Snooze and Stop that work from the
// Lock Screen, beside the ring's own card there (ChumbyRing.swift). A snooze takes it away; ringing again brings it back.
// Never sent, by ruling: an alarm that rang late (he was there), skips and naps (his own doing), and no badges.
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

    // The ringing alarm's notification: Snooze and Stop on it, pressed without unlocking or opening the app.
    static let ringCategory = "CHUMBY_RING", ringStop = "RING_STOP", ringSnooze = "RING_SNOOZE"
    func install() {
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.ringSnooze, title: "Snooze", options: [], icon: UNNotificationActionIcon(systemImageName: "water.waves"))
        let stop = UNNotificationAction(identifier: Self.ringStop, title: "Stop", options: [], icon: UNNotificationActionIcon(systemImageName: "stop.fill"))
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.ringCategory, actions: [snooze, stop], intentIdentifiers: [], options: [])])
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
        guard !staged, let token = UserDefaults.standard.string(forKey: Self.tokenKey), !token.isEmpty else { return }
        let on = enabled, stamp = "\(token)|\(on)"
        guard stamp != sent else { return }
        Task { if await tellMac(["token": token, "off": !on]) { await MainActor.run { self.sent = stamp } } }
    }
    // One note to the Mac's notification desk (the alert token above, and the ringing card's tokens): true if it took it.
    @discardableResult func tellMac(_ fields: [String: Any]) async -> Bool {
        guard !staged, let bundle = Bundle.main.bundleIdentifier,
              let mac = Bundle.main.object(forInfoDictionaryKey: "MacAddress") as? String,
              let base = URL(string: mac), let host = base.host,
              let url = URL(string: mac.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/push/token") else { return false }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 15
        // The Mac turns away requests from other sites, so this says which site it is, as its own app does.
        r.setValue("\(base.scheme ?? "https")://\(host)\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["app": "chumby", "bundle": bundle].merging(fields) { _, new in new })
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
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
    // The ringing alarm's is its own case: Snooze and Stop are pressed on the Chumby from here, behind the Lock Screen, and
    // a tap on it opens the ringing page over whichever tab was showing.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = info["alert"] as? String ?? response.notification.request.identifier
        // The Mac's quiet word that the ring moved on without the phone ("Snoozed until…", "over") is a ring notice too,
        // but a tap on one that says it's over opens Alarms like any other.
        let over = (info["ring"] as? [String: Any])?["over"] != nil
        if id == ChumbyRingActions.noticeID, !(over && response.actionIdentifier == UNNotificationDefaultActionIdentifier) {
            switch response.actionIdentifier {
            // Pressed on a locked phone, the app runs only as long as iOS allows a notification's action; the press asks for
            // the time a Chumby answer can take (up to ~15 s for its confirmation), so it isn't cut off half way.
            case Self.ringStop: Task { let t = await Self.keepAwake(); await self.ringAnswered(ChumbyRingActions.stop(from: "notification"), stop: true); done(); await Self.letSleep(t) }
            case Self.ringSnooze: Task { let t = await Self.keepAwake(); await self.ringAnswered(ChumbyRingActions.snooze(from: "notification"), stop: false); done(); await Self.letSleep(t) }
            case UNNotificationDismissActionIdentifier: done()
            default:
                // Kept until the page's host is there to take it: a tap that launched the app arrives before any view listens.
                let hint = RingLink.state(info["ring"])
                DispatchQueue.main.async { self.ringTap = RingTap(hint: hint); NotificationCenter.default.post(name: Self.openedRing, object: nil) }
                done()
            }
            return
        }
        UserDefaults.standard.set(2, forKey: "tab")
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.opened, object: id) }
        done()
    }
    #if canImport(UIKit)
    @MainActor static func keepAwake() -> UIBackgroundTaskIdentifier {
        var t = UIBackgroundTaskIdentifier.invalid
        t = UIApplication.shared.beginBackgroundTask(withName: "Chumby ring press") { if t != .invalid { UIApplication.shared.endBackgroundTask(t); t = .invalid } }
        return t
    }
    @MainActor static func letSleep(_ t: UIBackgroundTaskIdentifier) { if t != .invalid { UIApplication.shared.endBackgroundTask(t) } }
    #else
    static func keepAwake() -> Int { 0 }
    static func letSleep(_ t: Int) {}
    #endif
    static let opened = Notification.Name("chumbyOpenedNotification")
    static let openedRing = Notification.Name("chumbyOpenedRing")
    struct RingTap { var hint: ChumbyRingAttributes.ContentState? }
    private var ringTap: RingTap?
    func takeRingTap() -> RingTap? { defer { ringTap = nil }; return ringTap }
    // Stop or Snooze pressed on the notification, and the Chumby didn't take it: said in its place, with the same two
    // keys to try again, since nothing else on a locked phone would say so and the alarm is still going.
    func ringAnswered(_ why: String?, stop: Bool) async {
        guard let why else { return }
        let content = UNMutableNotificationContent()
        content.title = stop ? "The alarm didn’t stop" : "The alarm didn’t snooze"
        content.body = why
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.ringCategory
        content.userInfo = ["alert": ChumbyRingActions.noticeID]
        try? await center.add(UNNotificationRequest(identifier: ChumbyRingActions.noticeID, content: content, trigger: nil))
    }
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
            Toggle(isOn: $enabled) { TwoLine("Notify this iPhone", "When an alarm rings, was missed or may not ring.") }
                .padding(.trailing, 2)
                .onChange(of: enabled) { _, on in
                    if on { Task { denied = !(await ChumbyNotify.shared.ask()) } }
                    ChumbyNotify.shared.share()
                }
                .soloCard(on: !askSettings)
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
        // The ringing card's tokens, watched from every launch, the ones iOS makes behind the Lock Screen included.
        RingLink.start()
        return true
    }
    // The Mac's quiet word that the ring changed (snoozed, ringing again, over): the card and the notification are put
    // right here, for when the card's own push hasn't a token yet.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard userInfo["ring"] != nil else { return .noData }
        // a snooze moves the phone's backup alarm; an end cancels it only after a Stop pressed here (ChumbyBackupAlarm.push),
        // done before iOS suspends the app again
        ChumbyBackupAlarm.shared.push(userInfo)
        await ChumbyBackupAlarm.shared.settle()
        await RingLink.fromMac(userInfo["ring"])
        return .newData
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ChumbyNotify.shared.got(deviceToken.map { String(format: "%02x", $0) }.joined())
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
#endif
