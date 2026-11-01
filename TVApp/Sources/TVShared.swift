import AppIntents
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias TVImage = UIImage
extension Image { init(tv i: UIImage) { self.init(uiImage: i) } }
#else
import AppKit
typealias TVImage = NSImage
extension Image { init(tv i: NSImage) { self.init(nsImage: i) } }
#endif

struct TVStatus: Decodable, Equatable {
    struct Music: Decodable, Equatable { let title: String; let artist: String; let album: String; let art: String; let playing: Bool; let position: Double; let duration: Double; let sampledAt: Double }
    struct Session: Decodable, Equatable { let pkg: String; let playing: Bool; let description: [String] }
    struct App: Decodable, Identifiable, Equatable { let pkg: String; let name: String; let hasIcon: Bool; var wide: Bool?; var id: String { pkg } }
    let online: Bool
    var screen: String?
    var app: String?
    var volume: Int?
    var volumeMax: Int?
    var music: Music?
    var session: Session?
    var apps: [App]?
}

// What widgets, Control Center and Shortcuts use to reach the TV. They run outside the app, so they carry their own address.
enum TVBridge {
    static var address: String {
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        return stored.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : stored
    }
    static func url(_ path: String) -> URL? { URL(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) }
    static func post(_ path: String, _ body: [String: Any] = [:]) async throws {
        guard let u = url("/api/tv/" + path), let base = URL(string: address) else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 8
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }
    static func data(_ url: URL?, timeout: TimeInterval = 8) async -> Data? {
        guard let url else { return nil }
        var r = URLRequest(url: url); r.timeoutInterval = timeout; r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }
    static func status() async -> TVStatus? { (await data(url("/api/tv/status"))).flatMap { try? JSONDecoder().decode(TVStatus.self, from: $0) } }
}

struct TVPress: AppIntent {
    static var title: LocalizedStringResource = "Press a key on the TV"
    static var isDiscoverable = false
    @Parameter(title: "Key") var key: String
    init() {}
    init(key: String) { self.key = key }
    func perform() async throws -> some IntentResult {
        try await TVBridge.post("key", ["key": key])
        // Long enough that the widget's refresh shows what the press did.
        try? await Task.sleep(nanoseconds: 500_000_000)
        return .result()
    }
}
struct TVPower: AppIntent {
    static var title: LocalizedStringResource = "Turn the TV on or off"
    static var description = IntentDescription("Wakes the TV if it’s asleep, and puts it to sleep if it’s on.")
    func perform() async throws -> some IntentResult {
        let asleep = await TVBridge.status()?.screen == "asleep"
        try await TVBridge.post("key", ["key": asleep ? "wake" : "sleep"])
        return .result()
    }
}
struct TVOpenApp: AppIntent {
    static var title: LocalizedStringResource = "Open an app on the TV"
    static var isDiscoverable = false
    @Parameter(title: "App") var pkg: String
    init() {}
    init(pkg: String) { self.pkg = pkg }
    func perform() async throws -> some IntentResult { try await TVBridge.post("open", ["pkg": pkg]); return .result() }
}
struct TVOpenRemote: AppIntent {
    static var title: LocalizedStringResource = "Open the TV remote"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}
