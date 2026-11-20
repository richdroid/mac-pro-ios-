import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// Notifications for the TV app (Richard, 2026-11-14: "notifs still dont work … tv"). The Mac sends them through Apple's
// push service, and only for a real failure he can act on, by the app's ruling ("no notification … unless it carries an
// action he can take or reports a real failure"): a flick or a stream send that didn't start ("tv-start-failed"), which
// opens the Remote, where the stream list is a tap away. Never for something that worked, and never a badge.
final class TVNotify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TVNotify()
    private static let tokenKey = "tvPushToken", askedKey = "tvNotifyAsked"
    private let center = UNUserNotificationCenter.current()
    private var sent: String?

    // The build's simulator shots launch with -address or a pose: no prompt over them, and no Mac to tell.
    var staged: Bool {
        // Never on a simulator: something there starts the app with no arguments now and then, and the prompt then sat
        // over every folded shot of a run (CI 439d813).
        #if targetEnvironment(simulator)
        return true
        #else
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return args["address"] != nil || args["pose"] != nil
        #endif
    }

    func install() {
        center.delegate = self
        guard !staged else { return }
        if !UserDefaults.standard.bool(forKey: Self.askedKey) {
            Task {
                UserDefaults.standard.set(true, forKey: Self.askedKey)
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    // This iPhone's address for notifications, handed to the Mac, and again whenever the app comes forward, so the Mac
    // always holds the current one.
    func got(_ token: String) { UserDefaults.standard.set(token, forKey: Self.tokenKey); share() }
    func share() {
        guard !staged, let token = UserDefaults.standard.string(forKey: Self.tokenKey), !token.isEmpty,
              let bundle = Bundle.main.bundleIdentifier, token != sent else { return }
        let address = TVBridge.address
        guard let base = URL(string: address), let host = base.host,
              let url = URL(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/push/token") else { return }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 15
        // The Mac turns away requests from other sites, so this says which site it is, as the app's other calls do.
        r.setValue("\(base.scheme ?? "https")://\(host)\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["app": "tv", "bundle": bundle, "token": token])
        Task {
            guard let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            await MainActor.run { self.sent = token }
        }
    }

    // A tap: the Remote, where the stream list is (the app's own URL, as the Now Playing card's keys use).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        #if canImport(UIKit)
        guard let u = URL(string: "tvremoteapp://tab/0") else { return }
        await MainActor.run { UIApplication.shared.open(u) }
        #endif
    }
    // While the app is open its own screen says it: nothing over it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }
}

#if canImport(UIKit)
// Only for the notification token iOS hands to an app delegate.
final class TVPushDelegate: NSObject, UIApplicationDelegate {
    // Asked for at every launch: iOS answers with the current token, which can change after a restore.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TVNotify.shared.install()
        if !TVNotify.shared.staged { application.registerForRemoteNotifications() }
        #if os(iOS)
        TVIsland.watchStarts()
        #endif
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        TVNotify.shared.got(deviceToken.map { String(format: "%02x", $0) }.joined())
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
#endif
