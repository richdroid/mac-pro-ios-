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
    struct Session: Decodable, Equatable {
        let pkg: String; let playing: Bool; let description: [String]
        // Where it is when the Mac looked, in ms, and on the Mac's clock; how long it runs if known; whether it can jump.
        var position: Double?; var sampledAt: Double?; var duration: Double?; var canSeek: Bool?
        // The poster of what's really playing, when the Mac could find one by its title.
        var art: String?
        // For an episode, said outright by the Mac: the show, which one, and its name.
        var show: String?; var season: Int?; var episode: Int?; var episodeTitle: String?
        // The show's name, the Mac's word first, else the first line of what the player says.
        var showName: String { show?.isEmpty == false ? show! : description.first ?? "" }
        // "S3 E4 · Notapusy", from the Mac's fields, else read off the player's second line. Nil for a film.
        var episodeLine: String? {
            if let s = season, let e = episode {
                let t = episodeTitle ?? ""
                return "S\(s) E\(e)" + (t.isEmpty ? "" : " · " + t)
            }
            return description.count > 1 ? Wording.episode(description[1]) : nil
        }
        // Which episode, from the Mac's fields, else "S02E03" or "S2 E3" anywhere in what the player says (r19: a session
        // without the fields read as a film, so ⏭ dimmed and the episode line went missing). Nil for a film.
        var seasonEpisode: (season: Int, episode: Int)? {
            if let s = season, let e = episode { return (s, e) }
            for line in description {
                guard let r = line.range(of: #"[Ss](\d{1,2})\s*[Ee](\d{1,3})"#, options: .regularExpression) else { continue }
                let digits = line[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if digits.count == 2 { return (digits[0], digits[1]) }
            }
            return nil
        }
        // Whether this is the show called this, by its name as the Mac or the player says it.
        func isShow(_ title: String) -> Bool {
            func plain(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
            let a = plain(showName), b = plain(title)
            return !a.isEmpty && !b.isEmpty && (a == b || a.hasPrefix(b) || b.hasPrefix(a))
        }
    }
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
    // A stream start the Mac is running, and how the last one ended (for 30 s after), so the Remote can follow a start
    // even after the flick screen that sent it has closed. Both absent on a Mac from before.
    struct Start: Decodable, Equatable { var imdb: String?; var video: String?; var token: String?; var phase: String?; var since: Double? }
    struct LastStart: Decodable, Equatable { var result: String?; var token: String?; var at: Double? }
    var starting: Start?
    var lastStart: LastStart?
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

// The words under a title: only what helps. Never the service a rec came from, what kind of thing it is, or the app
// doing the playing, which are plumbing once he's chosen. Episodes read one way everywhere: "S1 E2 · Name".
enum Wording {
    static let services: Set<String> = ["peacock", "prime video", "amazon prime video", "amazon", "paramount+", "paramount plus", "netflix", "hulu", "disney+",
        "max", "hbo max", "apple tv", "apple tv+", "tubi", "pluto tv", "stremio", "youtube", "crunchyroll", "mgm+", "starz", "showtime", "amc+", "fubo",
        "plex", "the roku channel", "kanopy", "mubi", "shudder", "britbox", "fandango at home", "vudu", "criterion channel"]
    static let kinds: Set<String> = ["film", "films", "movie", "series", "show", "tv show", "continue"]
    static func subtitle(_ s: String) -> String {
        s.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !services.contains($0.lowercased()) && !kinds.contains($0.lowercased()) }
            .map(tidy).joined(separator: " · ")
    }
    // "85m left" reads "85 min left"; "S2E2" reads "S2 E2".
    static func tidy(_ part: String) -> String {
        if part.range(of: #"^\d+m left$"#, options: .regularExpression) != nil { return String(part.dropLast(6)) + " min left" }
        return episode(part)
    }
    // "S1E2 Episode 2", "S1 E2: Episode 2" and the like, as "S1 E2 · Episode 2".
    static func episode(_ s: String) -> String {
        guard let r = s.range(of: #"^[Ss](\d+)\s*[Ee](\d+)"#, options: .regularExpression) else { return s }
        let head = s[r], digits = head.split(whereSeparator: { !$0.isNumber })
        guard digits.count == 2 else { return s }
        let rest = s[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ·:-–—"))
        return "S\(digits[0]) E\(digits[1])" + (rest.isEmpty ? "" : " · " + rest)
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
    // The TV took the stream but the player never got going, even after a second try.
    struct DidNotStart: Error {}
    // Too busy to answer in time. Asking again usually works.
    struct Slow: Error {}
    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> Data {
        guard let u = url("/api/tv/" + path), let base = URL(string: address) else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode
        if code == 409 {
            // The TV being slow is worth another go, and the Mac says so; anything else refused here has gone for good.
            let retry = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["retry"] as? Bool == true
            throw retry ? Slow() as Error : Gone()
        }
        if code == 422, (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["failed"] as? String == "start" { throw DidNotStart() }
        guard code == 200 else { throw TVIntentError.noAnswer }
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
        // The AirPlay list comes first. The app brings Mint forward behind it, once it knows AirPlay can reach the TV.
        FlickRequest.wantsAirPlay = true
        NotificationCenter.default.post(name: FlickRequest.airPlay, object: nil)
        return .result()
    }
}
