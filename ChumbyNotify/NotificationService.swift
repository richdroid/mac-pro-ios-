import Foundation
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

// The Chumby app's notification extension (11-26). One job: when the Mac's notice says a ring was stopped on the Chumby
// itself (push.js ringRestate, `ring: {over, stopped, at}`, sent with mutable-content), cancel this phone's backup alarm
// for that ring. The app does the same when it is running; this is for when he has force-quit it, which leaves iOS
// handing the app nothing, and the backup rang minutes after he had woken to the Chumby. The backup's id is made from
// its ring's minute (BackupPlan.stableID), so the notice's `at` is all this needs. The notice itself is shown unchanged.
// What it did goes to the Mac's log ("ring: phone extension ...") so the first real Stop shows whether it works.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        content = request.content
        guard case .stopped(_, let at?)? = BackupPlan.signal(request.content.userInfo, now: Date()) else { finish(); return }
        let t0 = Date()
        let outcome = BackupStop.cancel(ringAt: at)
        Task {
            await MacLog.diag(["from": "extension", "press": "stop on the Chumby", "outcome": outcome, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
            self.finish()
        }
    }
    override func serviceExtensionTimeWillExpire() { finish() }
    private func finish() {
        guard let h = handler, let c = content else { return }
        handler = nil
        h(c)
    }
}

enum BackupStop {
    // "backup 15:30 cancelled" style words for the log; never throws.
    static func cancel(ringAt at: Date) -> String {
        #if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
        let m = AlarmManager.shared
        let auth: String
        switch m.authorizationState { case .authorized: auth = "auth"; case .denied: auth = "denied"; default: auth = "notasked" }
        let listed = (try? m.alarms.map(\.id))
        let before = listed.map { BackupPlan.stopMatches($0, at: at) }
        var gone = 0
        for id in BackupPlan.stopCandidates(at: at) {
            do { try m.cancel(id: id); gone += 1 } catch {}
        }
        let after = (try? m.alarms.map(\.id)).map { BackupPlan.stopMatches($0, at: at) }
        let seen = before.map { "\($0.count) listed" } ?? "list unreadable"
        let left = after.map { "\($0.count) left" } ?? "?"
        return "\(auth), \(seen), \(gone) cancelled, \(left)"
        #else
        return "no AlarmKit"
        #endif
    }
}

// The Mac's /api/push/token "ring-diag" line, as the app sends it (ChumbyRingCard.diag), under the app's own bundle id.
enum MacLog {
    static func diag(_ fields: [String: Any]) async {
        guard let own = Bundle.main.bundleIdentifier, let mac = Bundle.main.object(forInfoDictionaryKey: "MacAddress") as? String,
              let base = URL(string: mac), let host = base.host,
              let url = URL(string: mac.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/push/token") else { return }
        let bundle = own.hasSuffix(".Notify") ? String(own.dropLast(".Notify".count)) : own
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 8
        r.setValue("\(base.scheme ?? "https")://\(host)\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = fields; body["kind"] = "ring-diag"; body["app"] = "chumby"; body["bundle"] = bundle
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: r)
    }
}
