import AppIntents
import Foundation
import WidgetKit
import Security
#if canImport(UIKit)
import UIKit
#endif

// What Control Center and Shortcuts use to reach the Mac. They can run outside the app, so they carry their own address.
enum MacBridge {
    struct Brief: Decodable {
        struct CPU: Decodable { let total: Int }
        struct Memory: Decodable { let used: Double; let total: Double }
        struct Temp: Decodable { let name: String; let c: Double }
        struct Plan: Decodable { let fiveHour: Double?; let sevenDay: Double? }
        struct Usage: Decodable { let plan: Plan? }
        let uptime: Double; let cpu: CPU; let mem: Memory; let temps: [Temp]?; let usage: Usage
    }
    static var base: URL? {
        URL(string: SavedAddress.value)
    }
    private static func origin(_ u: URL) -> String { "\(u.scheme ?? "https")://\(u.host ?? "")\(u.port.map { ":\($0)" } ?? "")" }
    static func send(_ path: String, body: Data, json: Bool = true) async throws {
        guard let base, let u = URL(string: path, relativeTo: base) else { throw MacIntentError.noAnswer }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.setValue(origin(base), forHTTPHeaderField: "Origin"); r.setValue("1", forHTTPHeaderField: "x-dash")
        if json { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        guard let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MacIntentError.noAnswer }
    }
    static func action(_ name: String) async throws { try await send("/api/action/\(name)", body: Data("{}".utf8)) }
    static func get(_ path: String) async throws -> Data {
        guard let base, let u = URL(string: path, relativeTo: base) else { throw MacIntentError.noAnswer }
        var r = URLRequest(url: u); r.timeoutInterval = 12; r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MacIntentError.noAnswer }
        return d
    }
    static func uptime(_ s: Double) -> String {
        let u = Int(s), d = u / 86400, h = u / 3600 % 24, m = u / 60 % 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    static func summary(_ s: Brief) -> String {
        var parts = ["CPU \(s.cpu.total)%", String(format: "memory %.1f of %.0f GB", s.mem.used / 1_073_741_824, s.mem.total / 1_073_741_824)]
        if let t = s.temps?.first(where: { $0.name == "CPU" }) ?? s.temps?.max(by: { $0.c < $1.c }) { parts.append("\(Heat.shown(t.c)) °\(MacPrefs.celsius ? "C" : "F")") }  // in the unit chosen in Settings
        parts.append("up \(uptime(s.uptime))")
        return parts.joined(separator: ", ") + "."
    }
}
enum MacIntentError: LocalizedError {
    case noAnswer
    var errorDescription: String? { "The Mac didn’t answer. Try again in a moment." }
}
enum ScreenRequest {
    static let notification = Notification.Name("macOpenScreen")
    @MainActor static var wanted = false
}

struct MacStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Mac Pro Status"
    static var description = IntentDescription("CPU, memory, temperature and uptime, in one sentence.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let s = MacBridge.summary(try JSONDecoder().decode(MacBridge.Brief.self, from: try await MacBridge.get("/api/status")))
        return .result(value: s, dialog: IntentDialog(stringLiteral: s))
    }
}
struct MacClaudeUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Claude Usage"
    static var description = IntentDescription("How much of the 5-hour and weekly Claude limits are used.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let p = try JSONDecoder().decode(MacBridge.Brief.self, from: try await MacBridge.get("/api/status")).usage.plan
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "unknown" }
        let s = p?.fiveHour == nil ? "Weekly limit \(pct(p?.sevenDay)) used." : "5-hour limit \(pct(p?.fiveHour)), weekly limit \(pct(p?.sevenDay))."
        return .result(value: s, dialog: IntentDialog(stringLiteral: s))
    }
}
struct MacDisplayOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Off the Mac Pro Display"
    static var description = IntentDescription("Darkens the computer’s display. It keeps running.")
    func perform() async throws -> some IntentResult { try await MacBridge.action("display-off"); return .result() }
}
struct MacOpenScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Show the Mac Pro Screen"
    static var description = IntentDescription("Opens straight into the computer’s screen.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        ScreenRequest.wanted = true
        NotificationCenter.default.post(name: ScreenRequest.notification, object: nil)
        return .result()
    }
}
struct MacCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy from the Mac"
    static var description = IntentDescription("Puts the computer’s clipboard on this phone, and returns it.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        struct Clip: Decodable { let text: String }
        let text = try JSONDecoder().decode(Clip.self, from: try await MacBridge.get("/api/clipboard")).text
        #if canImport(UIKit)
        await MainActor.run { UIPasteboard.general.string = text }
        #endif
        return .result(value: text)
    }
}
struct MacSendIntent: AppIntent {
    // "Paste", as the Status key that does the same is "Paste to Mac": "Send to Mac" is the files' name (Control, the
    // share sheet).
    static var title: LocalizedStringResource = "Paste Text to the Mac"
    static var description = IntentDescription("Puts text on the computer’s clipboard.")
    @Parameter(title: "Text") var text: String
    func perform() async throws -> some IntentResult { try await MacBridge.send("/api/clipboard", body: Data(text.utf8), json: false); return .result() }
}

// The address the app reaches the Mac through, kept in the Keychain as well as the app's settings. A new install of the
// same app (a TestFlight build replacing a Mac-signed one, or the app deleted and put back) starts with empty settings,
// but the Keychain keeps its items for the same team and bundle, so the address comes back on its own (Richard,
// 2026-11-10: the Mac Pro app asked for its address again after a reinstall). The TV and Chumby apps keep theirs the
// same way (b7ee5f4). Here, not in the app's sources alone, because shortcuts and the widget read it too.
enum SavedAddress {
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.macpro.address", kSecAttrAccount as String: "address"]
    // Settings first, then the Keychain, then the address baked into this build.
    static var value: String {
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        if !stored.isEmpty { return stored }
        // In a widget or control: the address the app shares with them (MacPrefs.shareWithWidgets), once the build has
        // the App Group. A widget kept using the baked address after it was changed in the app.
        if let g = MacPrefs.shared?.string(forKey: "address"), !g.isEmpty { return g }
        if let k = sharedValue(), !k.isEmpty { return k }
        if let k = keychain(), !k.isEmpty { return k }
        return Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? ""
    }
    // The address shared with this app's widgets, controls and share sheet: a Keychain item in the app's shared access
    // group ("<team>.local.macpro.MacPro.shared"), which the TestFlight signing (store-sign.sh) gives the app and each of
    // its extensions. Their own settings and Keychain are their own, so before this they only ever had the address
    // baked into the build. No group (a simulator build, no team in the bundle id): nil, and nothing changes.
    static var sharedGroup: String? {
        // The team, as the signing writes it into Info.plist (AppIdentifierPrefix, "TEAM."), else from the bundle id it gives.
        let prefix = (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let team = prefix.flatMap({ $0.isEmpty ? nil : Substring($0) }) ?? Bundle.main.bundleIdentifier?.split(separator: ".").first(where: { $0.count == 10 && $0.allSatisfy { $0.isUppercase || $0.isNumber } }) else { return nil }
        return "\(team).local.macpro.MacPro.shared"
    }
    static func sharedValue() -> String? {
        guard let g = sharedGroup else { return nil }
        var q = base
        q[kSecAttrAccessGroup as String] = g
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func share(_ s: String) {
        guard let g = sharedGroup, sharedValue() != s else { return }
        var q = base
        q[kSecAttrAccessGroup as String] = g
        SecItemDelete(q as CFDictionary)
        guard !s.isEmpty else { return }
        q[kSecValueData as String] = Data(s.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // The widgets redraw with the new address rather than at their next refresh.
        if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { WidgetCenter.shared.reloadAllTimelines() }
    }
    static func save(_ s: String) {
        UserDefaults.standard.set(s, forKey: "address")
        share(s)
        guard keychain() != s else { return }
        SecItemDelete(base as CFDictionary)
        guard !s.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(s.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    static func keychain() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
