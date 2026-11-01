import Foundation
import SwiftUI
struct Film: Identifiable, Hashable {
    let slug: String, title: String, year: String, poster: String, note: String
    var imdb = ""
    var id: String { slug + note }
    var media: MediaItem { MediaItem(title: title, subtitle: note.isEmpty ? year : note, art: poster, id: imdb, kind: "movie", slug: slug) }
}

@MainActor
final class TVModel: ObservableObject {
    @Published var status: TVStatus?
    let mirrorStore = MirrorStore()
    @Published var mirrorLive = false
    @Published var reachable = true
    @Published var watchlist: [Film] = []
    @Published var friends: [Film] = []
    @Published var recommended: [Film] = []
    @Published var flicking: FlickTarget?
    @Published var browsing: MediaSource?
    @Published var toast: String?
    @Published var filmsNote: String? = "Loading your films…"
    // Browse used to be tab 4; the apps' banners lead there now.
    @Published var tab = { let t = UserDefaults.standard.integer(forKey: "tab"); return t == 4 ? 1 : t }()
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "address") } }
    private var loops: [Task<Void, Never>] = []
    private var toastTask: Task<Void, Never>?
    private var lastKeyAt = Date.distantPast
    private var lastTouch = Date()
    private var keyChain: Task<Void, Never>?
    private var filmsLoaded = false
    private static var cacheFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tv.json") }

    init() {
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        address = stored.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : stored
        // Open with what was last known; the live state replaces it moments later.
        if let d = try? Data(contentsOf: Self.cacheFile) { status = try? JSONDecoder().decode(TVStatus.self, from: d) }
    }
    func url(_ path: String) -> URL? { URL(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) }
    func start() {
        stop()
        // Nobody looking, nothing polled. Status steps aside just after a key, so it never competes with one.
        loops = [
            Task { [weak self] in
                while !Task.isCancelled {
                    if let self, Date().timeIntervalSince(self.lastKeyAt) > 1.5 { await self.load() }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    if let self, self.mirrorLive {
                        if Date().timeIntervalSince(self.lastTouch) > 60 { self.mirrorLive = false }
                        else { await self.loadMirror() }
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            },
        ]
    }
    func stop() { loops.forEach { $0.cancel() }; loops = [] }
    func load() async {
        guard let u = url("/api/tv/status") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 8; r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(TVStatus.self, from: d) else { if !Task.isCancelled { reachable = false }; return }
        if !reachable { reachable = true }
        #if os(iOS)
        await TVIsland.sync(s)
        #endif
        if s != status { status = s; if s.online { try? d.write(to: Self.cacheFile, options: .atomic) } }
    }
    func setMirror(_ on: Bool) {
        lastTouch = Date()
        mirrorLive = on
        if on { Task { await loadMirror() } }
    }
    func loadMirror() async {
        guard let u = url("/api/tv/shot") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 10; r.cachePolicy = .reloadIgnoringLocalCacheData
        if let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, let i = TVImage(data: d) { mirrorStore.image = i }
    }
    func loadFilms(force: Bool = false) async {
        if filmsLoaded && !force { return }
        guard let u = url("/api/tv/letterboxd" + (force ? "?fresh=1" : "")), let (d, resp) = try? await URLSession.shared.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { filmsNote = "Can’t reach your films. Pull down to try again."; return }
        filmsLoaded = true
        filmsNote = j["signedIn"] as? Bool == false ? "Sign in to Letterboxd on the TV." : nil
        func list(_ key: String, _ note: ([String: String]) -> String) -> [Film] {
            // A friend can log the same film twice; show it once.
            var seen = Set<String>()
            return ((j[key] as? [[String: String]]) ?? []).compactMap { r in
                guard let slug = r["film_slug"], !slug.isEmpty else { return nil }
                let f = Film(slug: slug, title: r["film_title"] ?? slug, year: r["film_year"] ?? "", poster: r["poster_url"] ?? "", note: note(r), imdb: r["imdb_id"] ?? "")
                return seen.insert(f.id).inserted ? f : nil
            }
        }
        watchlist = list("watchlist") { r in
            let n = Int(r["friends_count"] ?? "") ?? 0, a = Double(r["friends_rating_avg"] ?? "") ?? 0
            return n > 0 && a > 0 ? String(format: "★ %.1f · %d friends", a, n) : (r["film_year"] ?? "")
        }
        friends = list("friends") { r in
            let who = r["friend_name"] ?? "", rating = Double(r["rating"] ?? "") ?? 0
            return rating > 0 ? who + String(format: " ★ %.1f", rating) : who
        }
        struct Recs: Decodable { struct One: Decodable { let title, year, slug, imdb, art, why: String }; let films: [One] }
        if let d = await TVBridge.data(url("/api/tv/recs"), timeout: 10), let r = try? JSONDecoder().decode(Recs.self, from: d) {
            recommended = r.films.map { Film(slug: $0.slug, title: $0.title, year: $0.year, poster: $0.art, note: $0.why, imdb: $0.imdb) }
        }
    }
    func say(_ t: String) {
        toast = t
        toastTask?.cancel()
        toastTask = Task { [weak self] in try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { self?.toast = nil } }
    }
    func tick() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    private func request(_ path: String, _ body: [String: Any]) -> URLRequest? {
        guard let u = url("/api/tv/" + path), let base = URL(string: address) else { return nil }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }
    // Keys leave in order, one after another, so a fast swipe can't arrive scrambled.
    func key(_ name: String, long: Bool = false, repeating: Bool = false) {
        lastKeyAt = Date(); lastTouch = Date()
        if !repeating { tick() }
        // A hold can't get ahead of the connection, so lifting your finger stops the TV promptly.
        if repeating && repeatPending { return }
        guard var r = request("key", ["key": name, "long": long, "repeat": repeating]) else { return }
        r.timeoutInterval = 3
        if repeating { repeatPending = true }
        let before = keyChain, sent = Date(), power = name == "wake" || name == "sleep"
        keyChain = Task { [weak self] in
            await before?.value
            defer { if repeating { self?.repeatPending = false } }
            // A slow network must not replay old repeats at the TV. A deliberate press gets longer.
            if !power && Date().timeIntervalSince(sent) > (repeating ? 1 : 4) {
                if !repeating { self?.say("The TV didn’t get that") }
                return
            }
            let result = try? await URLSession.shared.data(for: r)
            if (result?.1 as? HTTPURLResponse)?.statusCode != 200, !repeating { self?.say("The TV didn’t get that") }
        }
        // Outside the chain, so a slow picture never holds up the next press.
        if mirrorLive && !repeating {
            mirrorSoon?.cancel()
            mirrorSoon = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !Task.isCancelled { await self?.loadMirror() }
            }
        }
    }
    private var repeatPending = false
    private var mirrorSoon: Task<Void, Never>?
    func post(_ path: String, _ body: [String: Any] = [:], say msg: String? = nil) {
        guard let r = request(path, body) else { return }
        if let msg { say(msg) }
        lastTouch = Date()
        Task {
            let result = try? await URLSession.shared.data(for: r)
            if (result?.1 as? HTTPURLResponse)?.statusCode != 200 { say("The TV didn’t get that") }
            else { try? await Task.sleep(nanoseconds: 800_000_000); await load() }
        }
    }
    // Links, search words, or anything else from the phone. The Mac decides where it goes.
    func send(_ text: String) {
        guard let r = request("send", ["text": text]) else { return }
        tick()
        Task {
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { say("The TV didn’t get that"); return }
            switch j["kind"] as? String {
            case "apple", "words": say("Sent to Mint Music")
            case "youtube": say("Opening on YouTube")
            case "film": say("Opening in Letterboxd")
            case "imdb": say("Opening in Stremio")
            default: say("That link can’t open on the TV. Try AirPlay.")
            }
        }
    }
}

// The mirror changes every 1.5 s. Only the mirror should redraw when it does.
@MainActor
final class MirrorStore: ObservableObject { @Published var image: TVImage? }

// A half-typed link outlives unfolding, which rebuilds the layout.
@MainActor
final class SendDraft: ObservableObject {
    static let shared = SendDraft()
    @Published var text = ""
}
