import Foundation
import SwiftUI
import CryptoKit
import Security
import MediaPlayer
import BackgroundTasks
import AuthenticationServices
import WidgetKit

// Scrobbling his Apple Music listening from the phone, the way Marvis does (Richard, 2026-11-24: "add marvis like last fm
// scrobbling functionality like background and otherwise"). Two ways in:
// - Live, while the app is open: the system music player says what's on and when it plays or pauses; a song is scrobbled
//   once it has played half its length or four minutes (whichever comes first) and is longer than 30 s, stamped with
//   the moment it began; "now playing" is sent as each song starts.
// - Catch-up, for what played while the app was closed: the library keeps each song's play count and when it was last
//   played. On opening and on a background refresh, songs whose count rose since the last look are scrobbled, stamped
//   back from when they were last played. Songs played outside the library (radio, songs not added) can't be seen this
//   way; that's iOS, and the log says nothing about what it can't see.
// Everything sent is first checked against what Last.fm already has around that moment (another scrobbler, a second
// device), so nothing is counted twice. A log of every decision is kept on the phone.
// Writing to Last.fm needs the app's shared secret (baked at signing from ~/.local/state/mac-dash/ship/lastfm-secret,
// never in the repo) and his approval once in Safari; the session key that gives is kept in the Keychain.

// MARK: - Signed calls

enum LFMSecret {
    static var secret: String? { (Bundle.main.infoDictionary?["LastFMSecret"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    static var key: String? { LastFM.shared.key }
}

enum SessionKeychain {
    private static let service = "local.macpro.LastFM.session"
    static func read() -> (key: String, name: String)? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? [String: Any],
              let data = d[kSecValueData as String] as? Data, let key = String(data: data, encoding: .utf8),
              let name = d[kSecAttrAccount as String] as? String else { return nil }
        return (key, name)
    }
    static func write(key: String, name: String) {
        clear()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name,
                                kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

// Last.fm's signed methods: every parameter but `format` sorted by name, joined name-then-value, the secret appended, MD5.
// Sent as a form POST (writes) or a GET (auth.getToken, auth.getSession).
enum LFMSigned {
    static func sign(_ p: [String: String], secret: String) -> String {
        let base = p.keys.filter { $0 != "format" && $0 != "callback" }.sorted().map { $0 + (p[$0] ?? "") }.joined() + secret
        return Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func call(_ method: String, _ params: [String: String], post: Bool) async throws -> J {
        guard let key = LFMSecret.key, let secret = LFMSecret.secret else { throw LFMError.noKey }
        var p = params
        p["method"] = method; p["api_key"] = key
        p["api_sig"] = sign(p, secret: secret)
        p["format"] = "json"
        var req: URLRequest
        if post {
            req = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form(p).data(using: .utf8)
        } else {
            var c = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
            c.queryItems = p.map { URLQueryItem(name: $0.key, value: $0.value) }
            req = URLRequest(url: c.url!)
        }
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = J(try? JSONSerialization.jsonObject(with: data))
        if let e = j["error"].int { throw LFMError.api(e, j["message"].text) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LFMError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
        return j
    }
    private static func form(_ p: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
    }
}

// MARK: - His account (web auth)

@MainActor @Observable final class LFMAccount: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = LFMAccount()
    enum State: Equatable { case noSecret, signedOut, waiting, signedIn(String) }
    private(set) var state: State = .signedOut
    private(set) var problem: String?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var web: ASWebAuthenticationSession?

    override init() {
        super.init()
        refresh()
    }
    func refresh() {
        if let mock = Self.mockState { state = mock; return }
        if LFMSecret.secret == nil || LFMSecret.key == nil { state = .noSecret; return }
        if let s = SessionKeychain.read() { state = .signedIn(s.name) } else if state != .waiting { state = .signedOut }
    }
    // The build's shots of each state (-scrobbleState waiting|connected|signedout); the default build has no secret.
    static var mockState: State? {
        guard LastFM.shared.mock else { return nil }
        switch UserDefaults.standard.string(forKey: "scrobbleState") ?? "" {
        case "connected": return .signedIn(LastFM.shared.user)
        case "signedout": return .signedOut
        default: return .noSecret
        }
    }
    var sessionKey: String? { SessionKeychain.read()?.key }
    var signedIn: Bool { if case .signedIn = state { return true }; return false }

    // auth.getToken, his approval on last.fm in Safari, then auth.getSession for the key that lets the app write.
    func connect() {
        guard state != .noSecret else { return }
        problem = nil
        Task {
            do {
                let j = try await LFMSigned.call("auth.gettoken", [:], post: false)
                guard let t = j["token"].string, let key = LFMSecret.key else { throw LFMError.shape }
                token = t
                state = .waiting
                let url = URL(string: "https://www.last.fm/api/auth/?api_key=\(key)&token=\(t)")!
                let s = ASWebAuthenticationSession(url: url, callbackURLScheme: LinkScheme.scheme) { [weak self] _, _ in
                    // Approved or closed: either way, ask for the session; if he didn't approve, it says so.
                    Task { @MainActor in await self?.finish() }
                }
                s.presentationContextProvider = self
                s.prefersEphemeralWebBrowserSession = false
                web = s
                s.start()
            } catch {
                problem = "Last.fm didn't answer. Try again in a moment."
                refresh()
            }
        }
    }
    // Also tried on coming back to the app while waiting (he may approve in Safari itself).
    func finish() async {
        guard let t = token else { return }
        do {
            let j = try await LFMSigned.call("auth.getsession", ["token": t], post: false)
            guard let key = j["session"]["key"].string, let name = j["session"]["name"].string else { throw LFMError.shape }
            SessionKeychain.write(key: key, name: name)
            token = nil
            state = .signedIn(name)
            Scrobbler.shared.connected()
        } catch LFMError.api(14, _) {
            problem = "Not approved yet. Tap Connect and choose Yes, allow access."
            state = .signedOut
        } catch {
            problem = "Couldn't finish connecting. Try again."
            state = .signedOut
        }
    }
    func signOut() {
        SessionKeychain.clear()
        state = .signedOut
    }
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

// MARK: - The log

struct ScrobbleNote: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case scrobbled, nowPlaying, duplicate, tooShort, ignored, queued, failed }
    var id = UUID()
    let at: Double              // when the note was made
    let played: Double          // when the song began
    let artist: String
    let title: String
    let album: String
    var kind: Kind
    var how: String             // "live" or "caught up"
    var detail: String? = nil
}

struct PendingScrobble: Codable, Hashable {
    let artist: String
    let title: String
    let album: String
    let albumArtist: String
    let started: Int
    let duration: Int?
    let how: String
    let item: UInt64
}

// MARK: - The scrobbler

@MainActor @Observable final class Scrobbler {
    static let shared = Scrobbler()
    static let refreshID = "local.macpro.LastFM.scrobble"

    // His switch (Settings in the scrobbling hub). On by default once he has connected.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "scrobble.on"); enabled ? start() : stop() }
    }
    private(set) var log: [ScrobbleNote] = []
    private(set) var queue: [PendingScrobble] = []
    private(set) var library: MPMediaLibraryAuthorizationStatus = MPMediaLibrary.authorizationStatus()
    private(set) var lastCatchUp: Date?
    private(set) var sending = false
    // The song the system player has on, as the scrobbler tracks it.
    private(set) var live: Live?

    struct Live: Equatable {
        let item: UInt64
        let artist: String
        let title: String
        let album: String
        let albumArtist: String
        let duration: Double
        let started: Date
        var played: Double = 0
        var since: Date?            // playing since (nil while paused)
        var sent = false
        var position: Double = 0
        var progress: Double { played + (since.map { Date().timeIntervalSince($0) } ?? 0) }
        // Last.fm's rule: longer than 30 s, and played half its length or four minutes, whichever comes first.
        var threshold: Double { min(duration / 2, 240) }
        var counts: Bool { duration > 30 && progress >= threshold }
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var player: MPMusicPlayerController?
    private let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private var logFile: URL { dir.appendingPathComponent(LastFM.shared.mock ? "scrobble-log-mock.json" : "scrobble-log.json") }
    private var queueFile: URL { dir.appendingPathComponent("scrobble-queue.json") }
    private var countsFile: URL { dir.appendingPathComponent("scrobble-counts.json") }

    init() {
        enabled = UserDefaults.standard.object(forKey: "scrobble.on") as? Bool ?? true
        if let d = try? Data(contentsOf: logFile), let l = try? JSONDecoder().decode([ScrobbleNote].self, from: d) { log = l }
        if let d = try? Data(contentsOf: queueFile), let q = try? JSONDecoder().decode([PendingScrobble].self, from: d) { queue = q }
        lastCatchUp = UserDefaults.standard.object(forKey: "scrobble.caught") as? Date
        if LastFM.shared.mock, case .signedIn = LFMAccount.mockState { log = Self.mockLog(); lastCatchUp = Clock.now.addingTimeInterval(-240) }
    }

    var ready: Bool { enabled && LFMAccount.shared.signedIn && !LastFM.shared.mock }

    // MARK: Lifecycle

    // Registered once, before the app finishes launching (BGTaskScheduler's rule).
    nonisolated static func registerBackground() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                await Scrobbler.shared.catchUp()
                await Scrobbler.shared.flush()
                Scrobbler.shared.schedule()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
    func schedule() {
        guard ready else { return }
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    // The app came to the front.
    func start() {
        library = MPMediaLibrary.authorizationStatus()
        guard ready, library == .authorized else { return }
        watch()
        Task {
            await catchUp()
            await flush()
        }
    }
    // The app went to the back: what's played so far is counted where it stands, and a refresh is asked for.
    func stop() {
        if var l = live, let s = l.since { l.played += Date().timeIntervalSince(s); l.since = nil; live = l }
        ticker?.cancel(); ticker = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        player?.endGeneratingPlaybackNotifications()
        player = nil
        // The songs the live watch saw are in the library's counts already; the next catch-up starts after them.
        markCaughtUp(Date())
        schedule()
    }
    func connected() {
        // Nothing from before he connected is sent: the library's counts as they stand now are the starting point.
        Task {
            await snapshotCounts()
            markCaughtUp(Date())
            start()
        }
    }
    func askLibrary() {
        MPMediaLibrary.requestAuthorization { s in
            Task { @MainActor in
                Scrobbler.shared.library = s
                if s == .authorized { Scrobbler.shared.connected() }
            }
        }
    }

    // MARK: Live

    private func watch() {
        guard player == nil else { return }
        let p = MPMusicPlayerController.systemMusicPlayer
        player = p
        p.beginGeneratingPlaybackNotifications()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { Scrobbler.shared.itemChanged() }
        })
        observers.append(nc.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { Scrobbler.shared.stateChanged() }
        })
        itemChanged()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.tick()
            }
        }
    }

    private func itemChanged() {
        guard let p = player else { return }
        // The same song announced again without starting over (a resume, a route change): nothing ends.
        if let l = live, let it = p.nowPlayingItem, it.persistentID == l.item, p.currentPlaybackTime + 2 >= l.position { stateChanged(); return }
        // The song that was on ends here: it was sent already if it counted.
        if let l = live, !l.sent {
            if l.counts { enqueue(l, how: "live"); Task { await flush() } }
            else if l.progress > 10, ready {
                note(ScrobbleNote(at: Date().timeIntervalSince1970, played: l.started.timeIntervalSince1970, artist: l.artist, title: l.title, album: l.album,
                                  kind: .tooShort, how: "live", detail: l.duration <= 30 ? "Under 30 seconds" : "Skipped before half way"))
            }
        }
        guard let it = p.nowPlayingItem, let title = it.title, let artist = it.artist ?? it.albumArtist else { live = nil; handOff(); return }
        let playing = p.playbackState == .playing
        live = Live(item: it.persistentID, artist: artist, title: title, album: it.albumTitle ?? "", albumArtist: it.albumArtist ?? "",
                    duration: it.playbackDuration, started: Date().addingTimeInterval(-max(0, p.currentPlaybackTime)),
                    since: playing ? Date() : nil, position: p.currentPlaybackTime)
        if playing { nowPlaying() }
        handOff(item: it)
    }
    private func stateChanged() {
        guard let p = player, var l = live else { return }
        if p.playbackState == .playing {
            if l.since == nil { l.since = Date() }
            live = l
            nowPlaying()
        } else {
            if let s = l.since { l.played += Date().timeIntervalSince(s); l.since = nil }
            live = l
        }
        handOff(item: p.nowPlayingItem)
    }
    private func tick() {
        guard let p = player, var l = live else { return }
        let pos = p.currentPlaybackTime
        // Played again from the top (repeat one, or started over): the last play is done and a new one begins.
        if pos.isFinite, pos + 5 < l.position, pos < 15, l.progress > 30 {
            if !l.sent, l.counts { enqueue(l, how: "live") }
            l = Live(item: l.item, artist: l.artist, title: l.title, album: l.album, albumArtist: l.albumArtist, duration: l.duration,
                     started: Date().addingTimeInterval(-pos), since: p.playbackState == .playing ? Date() : nil, position: pos)
            live = l
            nowPlaying()
            return
        }
        l.position = pos.isFinite ? pos : l.position
        if !l.sent, l.counts {
            l.sent = true
            enqueue(l, how: "live")
            Task { await flush() }
        }
        live = l
    }
    private func nowPlaying() {
        guard ready, let l = live, let sk = LFMAccount.shared.sessionKey else { return }
        var p = ["artist": l.artist, "track": l.title, "sk": sk]
        if !l.album.isEmpty { p["album"] = l.album }
        if l.duration > 0 { p["duration"] = "\(Int(l.duration))" }
        Task {
            if (try? await LFMSigned.call("track.updatenowplaying", p, post: true)) != nil {
                self.note(ScrobbleNote(at: Date().timeIntervalSince1970, played: l.started.timeIntervalSince1970, artist: l.artist, title: l.title, album: l.album, kind: .nowPlaying, how: "live"))
            }
        }
    }

    private func enqueue(_ l: Live, how: String) {
        let p = PendingScrobble(artist: l.artist, title: l.title, album: l.album, albumArtist: l.albumArtist, started: Int(l.started.timeIntervalSince1970),
                                duration: l.duration > 0 ? Int(l.duration) : nil, how: how, item: l.item)
        guard !queue.contains(where: { $0.item == p.item && abs($0.started - p.started) < 30 }) else { return }
        queue.append(p)
        saveQueue()
    }

    // MARK: Catch-up from the library

    private struct Counts: Codable { var plays: [String: Int] }
    private func loadCounts() -> [UInt64: Int] {
        guard let d = try? Data(contentsOf: countsFile), let c = try? JSONDecoder().decode(Counts.self, from: d) else { return [:] }
        var out: [UInt64: Int] = [:]
        for (k, v) in c.plays { if let id = UInt64(k) { out[id] = v } }
        return out
    }
    private nonisolated static func readLibrary() -> [(id: UInt64, plays: Int, last: Date?, artist: String, title: String, album: String, albumArtist: String, duration: Double)] {
        (MPMediaQuery.songs().items ?? []).compactMap { it in
            guard it.playCount > 0, let t = it.title, let a = it.artist ?? it.albumArtist else { return nil }
            return (it.persistentID, it.playCount, it.lastPlayedDate, a, t, it.albumTitle ?? "", it.albumArtist ?? "", it.playbackDuration)
        }
    }
    private func snapshotCounts() async {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        let items = await Task.detached(priority: .utility) { Self.readLibrary() }.value
        saveCounts(Dictionary(items.map { ($0.id, $0.plays) }) { a, _ in a })
    }
    private func saveCounts(_ c: [UInt64: Int]) {
        let s = Counts(plays: Dictionary(c.map { ("\($0.key)", $0.value) }) { a, _ in a })
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: countsFile, options: .atomic) }
    }
    private func markCaughtUp(_ d: Date) { lastCatchUp = d; UserDefaults.standard.set(d, forKey: "scrobble.caught") }

    // Songs whose play count rose since the last look: one scrobble per new play, the newest stamped back from when it
    // was last played by its length, earlier ones a length apart before it. Last.fm takes nothing older than 14 days.
    func catchUp() async {
        guard ready, MPMediaLibrary.authorizationStatus() == .authorized else { return }
        let before = loadCounts()
        guard !before.isEmpty else { await snapshotCounts(); markCaughtUp(Date()); return }
        let items = await Task.detached(priority: .utility) { Self.readLibrary() }.value
        let floor = Date().addingTimeInterval(-14 * 86400 + 600)
        var found: [PendingScrobble] = []
        for it in items {
            // A song not seen at the last look (new to the library) counts as one play, never its whole count.
            let new = before[it.id].map { it.plays - $0 } ?? 1
            guard new > 0, let last = it.last, last > floor else { continue }
            let len = it.duration > 30 ? it.duration : 210
            for k in 0..<min(new, 20) {
                let start = last.addingTimeInterval(-len * Double(k + 1))
                guard start > floor else { break }
                found.append(PendingScrobble(artist: it.artist, title: it.title, album: it.album, albumArtist: it.albumArtist, started: Int(start.timeIntervalSince1970),
                                             duration: it.duration > 0 ? Int(it.duration) : nil, how: "caught up", item: it.id))
            }
        }
        // Not twice what the live watch already queued or sent.
        let sent = log.filter { $0.kind == .scrobbled || $0.kind == .duplicate }
        found = found.filter { f in
            !queue.contains { $0.item == f.item && abs($0.started - f.started) < Self.window(f.duration) } &&
            !sent.contains { $0.artist.lowercased() == f.artist.lowercased() && $0.title.lowercased() == f.title.lowercased() && abs(Int($0.played) - f.started) < Self.window(f.duration) }
        }
        // Plays can't overlap: sorted newest first, each one moved to end before the next one began.
        found.sort { $0.started > $1.started }
        var next = Int.max
        found = found.compactMap { f in
            let len = f.duration ?? 210
            let s = min(f.started, next - len)
            guard Double(s) > floor.timeIntervalSince1970 else { return nil }
            next = s
            return PendingScrobble(artist: f.artist, title: f.title, album: f.album, albumArtist: f.albumArtist, started: s, duration: f.duration, how: f.how, item: f.item)
        }
        queue.append(contentsOf: found.reversed())
        saveQueue()
        saveCounts(Dictionary(items.map { ($0.id, $0.plays) }) { a, _ in a })
        markCaughtUp(Date())
    }

    // MARK: Sending

    // What's waiting, checked against Last.fm's own list around those moments, sent fifty at a time.
    func flush() async {
        guard ready, !sending, !queue.isEmpty, let sk = LFMAccount.shared.sessionKey else { return }
        sending = true
        defer { sending = false }
        let batch = Array(queue.sorted { $0.started < $1.started }.prefix(50))
        let lo = (batch.map(\.started).min() ?? 0) - 900, hi = (batch.map(\.started).max() ?? 0) + 900
        // What Last.fm already has then (another scrobbler, a second device): never counted twice.
        var there: [(String, String, Int)] = []
        if let j = try? await LastFM.shared.call("user.getrecenttracks", ["from": "\(lo)", "to": "\(hi)", "limit": "200"], keep: false) {
            there = j["recenttracks"]["track"].array.compactMap { t in
                guard let u = t["date"]["uts"].int else { return nil }
                return (Self.norm(t["artist"]["#text"].string ?? t["artist"].text), Self.norm(t["name"].text), u)
            }
        }
        var send: [PendingScrobble] = []
        for p in batch {
            let window = Self.window(p.duration)
            if there.contains(where: { $0.0 == Self.norm(p.artist) && $0.1 == Self.norm(p.title) && abs($0.2 - p.started) < window }) {
                note(ScrobbleNote(at: Date().timeIntervalSince1970, played: Double(p.started), artist: p.artist, title: p.title, album: p.album, kind: .duplicate, how: p.how, detail: "Already on Last.fm"))
            } else { send.append(p) }
        }
        var done = Set(batch.map { "\($0.item)|\($0.started)" })
        if !send.isEmpty {
            var params = ["sk": sk]
            for (i, p) in send.enumerated() {
                params["artist[\(i)]"] = p.artist; params["track[\(i)]"] = p.title; params["timestamp[\(i)]"] = "\(p.started)"
                if !p.album.isEmpty { params["album[\(i)]"] = p.album }
                if !p.albumArtist.isEmpty, p.albumArtist != p.artist { params["albumArtist[\(i)]"] = p.albumArtist }
                if let d = p.duration { params["duration[\(i)]"] = "\(d)" }
            }
            do {
                let j = try await LFMSigned.call("track.scrobble", params, post: true)
                let results = j["scrobbles"]["scrobble"].array
                for (i, p) in send.enumerated() {
                    let r = i < results.count ? results[i] : J(nil)
                    let code = r["ignoredMessage"]["code"].int ?? 0
                    if code == 0 {
                        note(ScrobbleNote(at: Date().timeIntervalSince1970, played: Double(p.started), artist: p.artist, title: p.title, album: p.album, kind: .scrobbled, how: p.how))
                    } else {
                        let why = [1: "Artist ignored by Last.fm", 2: "Track ignored by Last.fm", 3: "Too old for Last.fm", 4: "Time in the future", 5: "Daily limit reached"][code] ?? "Ignored by Last.fm"
                        note(ScrobbleNote(at: Date().timeIntervalSince1970, played: Double(p.started), artist: p.artist, title: p.title, album: p.album, kind: .ignored, how: p.how, detail: why))
                    }
                }
            } catch LFMError.api(let code, _) where code == 9 {
                // The session was revoked on last.fm: connect again; nothing is lost from the queue.
                LFMAccount.shared.signOut()
                done = []
            } catch {
                // Offline or Last.fm away: kept for next time.
                done = []
            }
        }
        if !done.isEmpty {
            queue.removeAll { done.contains("\($0.item)|\($0.started)") }
            saveQueue()
            // A new scrobble changes his figures: the store's next look picks it up.
            WidgetCenter.shared.reloadTimelines(ofKind: "now")
        }
        if !queue.isEmpty, !done.isEmpty { await flush() }
    }

    // Two plays of one song closer than this are one play: half its length, at least 90 s. A live scrobble and the
    // library's later count of the same play land seconds apart; the same song played twice in a row lands a length apart.
    nonisolated static func window(_ duration: Int?) -> Int { max((duration ?? 210) / 2, 90) }

    nonisolated static func norm(_ s: String) -> String {
        s.lowercased().folding(options: [.diacriticInsensitive], locale: nil).replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces)
    }

    private func note(_ n: ScrobbleNote) {
        log.insert(n, at: 0)
        if log.count > 400 { log.removeLast(log.count - 400) }
        if let d = try? JSONEncoder().encode(log) { try? d.write(to: logFile, options: .atomic) }
    }
    private func saveQueue() { if let d = try? JSONEncoder().encode(queue) { try? d.write(to: queueFile, options: .atomic) } }

    // What the log says today.
    var todayCount: Int {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return log.filter { $0.kind == .scrobbled && $0.at >= start }.count
    }

    // MARK: The widget's song

    // The song the system player has on, handed to the now-playing widget (the Keychain group the signing gives both),
    // with its cover small and his figures with it once known.
    private func handOff(item: MPMediaItem? = nil) {
        guard let l = live else {
            PlayingFacts.clear(); WidgetCenter.shared.reloadTimelines(ofKind: "now"); return
        }
        let playing = player?.playbackState == .playing
        var f = PlayingFacts(at: Date().timeIntervalSince1970, title: l.title, artist: l.artist, album: l.album, started: l.started.timeIntervalSince1970,
                             duration: l.duration, playing: playing)
        if let art = item?.artwork?.image(at: CGSize(width: 240, height: 240)) {
            f.cover = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).jpegData(withCompressionQuality: 0.72) { _ in art.draw(in: CGRect(x: 0, y: 0, width: 240, height: 240)) }
        }
        let base = f
        if base.write() { WidgetCenter.shared.reloadTimelines(ofKind: "now") }
        // Last.fm's figures for it: everyone's listeners and his plays.
        Task {
            guard let j = try? await LastFM.shared.call("track.getinfo", ["artist": l.artist, "track": l.title, "autocorrect": "1"], fresh: 3600) else { return }
            var g = base
            g.listeners = j["track"]["listeners"].int
            g.scrobbles = j["track"]["playcount"].int
            g.yours = j["track"]["userplaycount"].int
            if g.write() { WidgetCenter.shared.reloadTimelines(ofKind: "now") }
        }
    }

    // MARK: The build's log

    private static func mockLog() -> [ScrobbleNote] {
        let now = Clock.now.timeIntervalSince1970
        let songs = Array(Store.shared.recent.prefix(14))
        var out: [ScrobbleNote] = []
        for (i, s) in songs.enumerated() {
            let kind: ScrobbleNote.Kind = i == 3 ? .duplicate : i == 7 ? .tooShort : i == 10 ? .ignored : .scrobbled
            let detail: String? = i == 3 ? "Already on Last.fm" : i == 7 ? "Skipped before half way" : i == 10 ? "Too old for Last.fm" : nil
            let played = s.date?.timeIntervalSince1970 ?? now - Double(i) * 220
            out.append(ScrobbleNote(at: played + 200, played: played, artist: s.artist, title: s.title, album: s.album, kind: kind,
                                    how: i % 4 == 2 ? "caught up" : "live", detail: detail))
        }
        if let first = songs.first {
            out.insert(ScrobbleNote(at: now, played: now - 40, artist: first.artist, title: first.title, album: first.album, kind: .nowPlaying, how: "live"), at: 0)
        }
        return out
    }
}
