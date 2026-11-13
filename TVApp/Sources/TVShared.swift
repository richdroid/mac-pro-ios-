import AppIntents
import Foundation
import Security
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
        // The file the Mac itself started, while it's still what's on, and what it is a stream of (the episode's id, or the
        // film's): so that file's row in the stream list can say Playing, also after the app has been opened afresh.
        var streamFile: String?; var streamOf: String?
        // The show's name, the Mac's word first, else the first line of what the player says.
        var showName: String { show?.isEmpty == false ? show! : description.first ?? "" }
        // "S3 E4 · Notapusy", from the Mac's fields, else read off the player's second line. Nil for a film.
        var episodeLine: String? {
            if let s = season, let e = episode {
                let t = Wording.episodeName(episodeTitle ?? "", number: e)
                return "S\(s) E\(e)" + (t.map { " · " + $0 } ?? "")
            }
            // A YouTube video's second line is its channel, not an episode (r35: "Lil B" set as the title, the video's own
            // name as the small line over it).
            if pkg == "com.google.android.youtube.tv" { return nil }
            return description.count > 1 ? Wording.episode(description[1]) : nil
        }
        // A YouTube video's channel, the player's second line.
        var channel: String? { pkg == "com.google.android.youtube.tv" && description.count > 1 && !description[1].isEmpty ? description[1] : nil }
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
        // Exactly, once case, punctuation and spaces are set aside; a longer name only when what's left is a year or a
        // bracket, as in "Doctor Who (2005)" or "The Office US" (r20: "You" matched "Young Sheldon").
        func isShow(_ title: String) -> Bool { Self.sameName(showName, title) }
        static func sameName(_ x: String, _ y: String) -> Bool {
            func plain(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
            let a = plain(x), b = plain(y)
            guard !a.isEmpty, !b.isEmpty else { return false }
            if a == b { return true }
            let (long, short) = a.count > b.count ? (x, y) : (y, x)
            guard plain(long).hasPrefix(plain(short)) else { return false }
            // What the longer one has after the shorter, in its own spelling: only a year or a bracketed note may differ.
            var rest = long.lowercased()
            for ch in short.lowercased() where ch.isLetter || ch.isNumber {
                guard let i = rest.firstIndex(of: ch) else { return false }
                rest = String(rest[rest.index(after: i)...])
            }
            let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if tail.isEmpty { return true }
            if tail.count == 4, Int(tail).map({ (1900...2100).contains($0) }) == true { return true }
            // A bracketed note only when it's all that follows ("Heat (1995)", "The Office [US]"), never a bracket further on
            // ("Aliens (1986)" is not "Alien"; r21).
            if let first = rest.trimmingCharacters(in: .whitespaces).first, first == "(" || first == "[" { return true }
            return ["us", "uk", "au", "ca", "nz"].contains(tail)
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
    // The television behind the box, as the box hears it over HDMI-CEC. Absent from a Mac that doesn't read it; with
    // CEC off on the box, only `enabled: false`. `tv`: on, off, waking, sleeping, or empty when it isn't known.
    // `input`: box (showing this box), tv (its own screen), other (another device, named in `source` if it says), or empty.
    struct CEC: Decodable, Equatable {
        var enabled: Bool
        var tv: String?; var input: String?; var source: String?
        // Who made it, whether its own remote's keys have been heard by the box, and what else is on its HDMI sockets.
        var brand: String?; var keys: Bool?; var others: [String]?
    }
    var cec: CEC?
    // The box is awake, but the television is known to be off or showing something else. Nil while it shows the box,
    // while the box itself is asleep (that is said as asleep), and whenever it simply isn't known: nothing is claimed.
    enum Away: Equatable {
        case off, elsewhere(String?)
        // Off reads exactly as the box asleep does ("Asleep", "Wake the TV"): to him it's one black TV, and the box
        // follows the television to sleep a few seconds later, so the words never change under him (designer, 11-10).
        // Elsewhere reads as its siblings do: "Asleep", "Screensaver", "On PlayStation 5".
        var line: String {
            switch self {
            case .off: return "Asleep"
            case .elsewhere(let name?): return "On \(name)"
            case .elsewhere(nil): return "On another input"
            }
        }
        var glyph: String { self == .off ? "moon.fill" : "rectangle.2.swap" }
    }
    var away: Away? {
        guard online, screen != "asleep", let c = cec, c.enabled else { return nil }
        if c.tv == "off" || c.tv == "sleeping" { return .off }
        if c.input == "other" { return .elsewhere(c.source?.isEmpty == false ? c.source : nil) }
        if c.input == "tv" { return .elsewhere(nil) }
        return nil
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
        let name = episodeName(rest, number: Int(digits[1]))
        return "S\(digits[0]) E\(digits[1])" + (name.map { " · " + $0 } ?? "")
    }
    // An episode's own name, without the "Episode 2" a catalogue puts in front of it or in place of one: "Episode 2: The
    // One Where…" is "The One Where…", and "Episode 2" alone is no name at all (gate 276: the hero said "Episode 2", its
    // row "Episode 2: The One Where…"). The number is said by whatever shows the name.
    static func episodeName(_ s: String, number: Int?) -> String? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^(?i:episode|ep\.?)\s*(\d+)"#, options: .regularExpression) {
            let n = Int(t[r].filter(\.isNumber))
            if number == nil || n == number { t = t[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ·:-–—.")) }
        }
        return t.isEmpty ? nil : t
    }
}

// The address the app reaches the Mac (or the Chumby) through, kept in the Keychain as well as the app's settings. A new
// install of the same app (a TestFlight build replacing a Mac-signed one, or the app deleted and put back) starts with
// empty settings, but the Keychain keeps its items for the same team and bundle, so the address comes back on its own
// (Richard, 2026-11-10: "make sure that doesnt happen in the future").
enum SavedAddress {
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.macpro.address", kSecAttrAccount as String: "address"]
    // Settings first, then the Keychain, then the address baked into this build.
    static var value: String {
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        if !stored.isEmpty { return stored }
        if let k = keychain(), !k.isEmpty { return k }
        return Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? ""
    }
    static func save(_ s: String) {
        UserDefaults.standard.set(s, forKey: "address")
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

// What widgets, Control Center and Shortcuts use to reach the TV. They run outside the app, so they carry their own address.
enum TVBridge {
    static var address: String {
        SavedAddress.value
    }
    static func url(_ path: String) -> URL? { URL(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) }
    struct Gone: Error {}
    // The TV took the stream but the player never got going, even after a second try.
    struct DidNotStart: Error {}
    // An `again` about a send the Mac never saw: the first try was lost on the way, so it can go once as itself.
    struct Unseen: Error {}
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

// What a widget's press leaves behind for the reload WidgetKit runs once the press is done: the TV's status and, where
// the picture widget is in use, its picture taken after the key, fetched by the press itself with short waits and put on
// disk. The reload then reads them without asking the network (TVProvider.load), so the widget is up and taking the next
// press within a moment. Before this the press returned after its key, and every reload asked for the status (8 s wait)
// and the picture (15 s) afresh, on a session that waits 30 s for a key: on a slow tunnel the widget sat in its pressed
// state for the whole of that, its buttons taking nothing (Richard, 2026-11-09: "stops accepting inputs after the first
// three taps"), and the picture it then showed was from before the key.
enum WidgetFresh {
    static var dir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
    static var statusFile: URL { dir.appendingPathComponent("widget-tv.json") }
    static var shotFile: URL { dir.appendingPathComponent("widget-shot.jpg") }
    // Written moments ago by a press: good as it is.
    static func fresh(_ f: URL, within s: TimeInterval = 12) -> Data? {
        guard let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, Date().timeIntervalSince(at) < s else { return nil }
        return try? Data(contentsOf: f)
    }
    // The picture only for a phone that has the picture widget (it's the one that ever writes the file).
    static func refresh(after pressed: Date) async {
        let picture = FileManager.default.fileExists(atPath: shotFile.path)
        async let status = TVBridge.data(TVBridge.url("/api/tv/status"), timeout: 3)
        async let shot: Data? = picture ? TVBridge.data(TVBridge.url("/api/tv/shot?after=\(Int(pressed.timeIntervalSince1970 * 1000))"), timeout: 5) : nil
        if let d = await status { try? d.write(to: statusFile, options: .atomic) }
        if let d = await shot, d.count > 100 { try? d.write(to: shotFile, options: .atomic) }
    }
}
struct TVPress: AppIntent {
    static var title: LocalizedStringResource = "Press a key on the TV"
    static var isDiscoverable = false
    @Parameter(title: "Key") var key: String
    init() {}
    init(key: String) { self.key = key }
    func perform() async throws -> some IntentResult {
        let pressed = Date()
        // A short wait: a key answers in milliseconds, and a tunnel that's down shouldn't hold the widget's buttons.
        try await TVBridge.post("key", ["key": key], timeout: 6)
        await WidgetFresh.refresh(after: pressed)
        return .result()
    }
}
struct TVPower: AppIntent {
    static var title: LocalizedStringResource = "Turn the TV on or off"
    static var description = IntentDescription("Wakes the TV if it’s asleep, and puts it to sleep if it’s on.")
    func perform() async throws -> some IntentResult {
        let pressed = Date()
        // The Mac asks the TV which it is, so this never guesses.
        try await TVBridge.post("power-toggle", timeout: 20)
        await WidgetFresh.refresh(after: pressed)
        return .result()
    }
}
struct TVOpenApp: AppIntent {
    static var title: LocalizedStringResource = "Open an app on the TV"
    static var isDiscoverable = false
    @Parameter(title: "App") var pkg: String
    init() {}
    init(pkg: String) { self.pkg = pkg }
    func perform() async throws -> some IntentResult {
        let pressed = Date()
        try await TVBridge.post("open", ["pkg": pkg], timeout: 10)
        // The app takes a moment to be the one in front.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await WidgetFresh.refresh(after: pressed)
        return .result()
    }
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
    static var description = IntentDescription("Sends what’s playing on this phone to the TV.")
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
