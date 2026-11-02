import AppIntents
import Foundation
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
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        return URL(string: stored.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : stored)
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
        if let t = s.temps?.first(where: { $0.name == "CPU" }) ?? s.temps?.max(by: { $0.c < $1.c }) { parts.append("\(Int((t.c * 9 / 5 + 32).rounded())) °F") }
        parts.append("up \(uptime(s.uptime))")
        return parts.joined(separator: ", ") + "."
    }
}
enum MacIntentError: LocalizedError {
    case noAnswer
    var errorDescription: String? { "The Mac Pro didn’t answer. Is Tailscale on?" }
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
    static var description = IntentDescription("Darkens the Mac’s display. It keeps running.")
    func perform() async throws -> some IntentResult { try await MacBridge.action("display-off"); return .result() }
}
struct MacRenewAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "Renew iPhone Apps"
    static var description = IntentDescription("Asks the Mac to sign and reinstall your apps. The iPhone must be on the same Wi-Fi.")
    func perform() async throws -> some IntentResult { try await MacBridge.action("ios-resign"); return .result() }
}
struct MacOpenScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Show the Mac Pro Screen"
    static var description = IntentDescription("Opens straight into the Mac’s screen.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        ScreenRequest.wanted = true
        NotificationCenter.default.post(name: ScreenRequest.notification, object: nil)
        return .result()
    }
}
struct MacCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy from the Mac"
    static var description = IntentDescription("Puts the Mac’s clipboard on this iPhone, and returns it.")
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
    static var title: LocalizedStringResource = "Send to the Mac"
    static var description = IntentDescription("Puts text on the Mac’s clipboard.")
    @Parameter(title: "Text") var text: String
    func perform() async throws -> some IntentResult { try await MacBridge.send("/api/clipboard", body: Data(text.utf8), json: false); return .result() }
}
