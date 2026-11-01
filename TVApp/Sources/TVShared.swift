import AppIntents
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
import MediaPlayer
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
    var airplay: AirPlayState?
    // Sound coming from the phone. Anything but music stays out of Mint.
    struct AirPlayState: Decodable, Equatable {
        var active: Bool
        var kind: String?
        var playing: Bool?
        var title: String?
        var artist: String?
        var handoff: String?
    }
}

// What widgets, Control Center and Shortcuts use to reach the TV. They run outside the app, so they carry their own address.
enum TVBridge {
    static var address: String {
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        return stored.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : stored
    }
    static func url(_ path: String) -> URL? { URL(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) }
    struct Gone: Error {}
    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:], timeout: TimeInterval = 12) async throws -> Data {
        guard let u = url("/api/tv/" + path), let base = URL(string: address) else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: r)
        if (resp as? HTTPURLResponse)?.statusCode == 409 { throw Gone() }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw TVIntentError.noAnswer }
        return d
    }
    static func data(_ url: URL?, timeout: TimeInterval = 8, cached: Bool = false) async -> Data? {
        guard let url else { return nil }
        var r = URLRequest(url: url); r.timeoutInterval = timeout; r.cachePolicy = cached ? .useProtocolCachePolicy : .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }
    static func status(timeout: TimeInterval = 8) async -> TVStatus? { (await data(url("/api/tv/status"), timeout: timeout)).flatMap { try? JSONDecoder().decode(TVStatus.self, from: $0) } }
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
        try? await Task.sleep(nanoseconds: 300_000_000)
        return .result()
    }
}
struct TVPower: AppIntent {
    static var title: LocalizedStringResource = "Turn the TV on or off"
    static var description = IntentDescription("Wakes the TV if it’s asleep, and puts it to sleep if it’s on.")
    func perform() async throws -> some IntentResult {
        // The Mac asks the TV which it is, so this never guesses.
        try await TVBridge.post("power-toggle")
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
    @MainActor func perform() async throws -> some IntentResult {
        FlickRequest.wantsRemote = true
        NotificationCenter.default.post(name: FlickRequest.airPlay, object: nil)
        return .result()
    }
}

enum TVIntentError: LocalizedError {
    case noAnswer, cantOpen
    var errorDescription: String? {
        switch self {
        case .noAnswer: return "The TV didn’t answer. Is Tailscale on?"
        case .cantOpen: return "That link can’t open on the TV. Try AirPlay."
        }
    }
}

// Any app on the TV, for Shortcuts, Siri and the widget's settings.
struct TVAppEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "TV App"
    static var defaultQuery = TVAppQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct TVAppQuery: EntityQuery {
    func all() async -> [TVAppEntity] { (await TVBridge.status())?.apps?.map { TVAppEntity(id: $0.pkg, name: $0.name) } ?? [] }
    func entities(for identifiers: [String]) async throws -> [TVAppEntity] {
        let known = await all()
        // Offline, a choice already made keeps its place rather than vanishing from the widget.
        return identifiers.map { id in known.first { $0.id == id } ?? TVAppEntity(id: id, name: id.split(separator: ".").last.map(String.init) ?? id) }
    }
    func suggestedEntities() async throws -> [TVAppEntity] { await all() }
}
struct TVOpenOnTV: AppIntent {
    static var title: LocalizedStringResource = "Open an App on the TV"
    static var description = IntentDescription("Opens one of the TV’s apps.")
    @Parameter(title: "App") var app: TVAppEntity
    func perform() async throws -> some IntentResult { try await TVBridge.post("open", ["pkg": app.id]); return .result() }
}

enum FlickRequest {
    static let airPlay = Notification.Name("tvFlickAirPlay")
    @MainActor static var wantsAirPlay = false
    @MainActor static var wantsRemote = false
}
// A flick without looking: assign it to the Action Button or Control Center. Apple Music goes straight across; anything else opens AirPlay.
struct FlickToTV: AppIntent {
    static var title: LocalizedStringResource = "Flick to the TV"
    static var description = IntentDescription("Sends what’s playing on this iPhone to the TV.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        #if canImport(UIKit)
        let player = MPMusicPlayerController.systemMusicPlayer
        if MPMediaLibrary.authorizationStatus() == .authorized, player.playbackState == .playing, let item = player.nowPlayingItem, let title = item.title {
            // Only stop the phone once the TV has it.
            try await TVBridge.post("flick", ["title": title, "artist": item.artist ?? ""])
            player.pause()
            return .result()
        }
        #endif
        // The AirPlay list comes first; Mint getting ready can catch up behind it.
        FlickRequest.wantsAirPlay = true
        NotificationCenter.default.post(name: FlickRequest.airPlay, object: nil)
        Task { try? await TVBridge.post("music-now") }
        return .result()
    }
}
