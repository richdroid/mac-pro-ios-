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
    // True until the first answer since launch. Until then the status is the one kept from last time: good for laying
    // out the pages, but not for saying what's playing, where it's got to, or whether it's paused.
    @Published var staleStatus = true
    let mirrorStore = MirrorStore()
    // The TV's screen on the Remote: on unless he's turned it off, and kept that way.
    @Published var mirrorLive = UserDefaults.standard.object(forKey: "mirrorLive") as? Bool ?? true
    #if os(iOS)
    let live = LiveMirror()
    #endif
    // Where the Remote's picture of the TV is on the display, while it's there. Not published: only read, never drawn.
    var mirrorSlot: CGRect?
    private var mirrorViewers = 0
    // The poster standing in on the Remote's picture for a film just flicked, until the TV's own word catches up.
    @Published private(set) var standInArt: String?
    private var standInUntil = Date.distantPast
    var standInNow: String? { standInUntil > Date() ? standInArt : nil }
    func standIn(_ art: String) { standInArt = art; standInUntil = Date().addingTimeInterval(30) }
    // When a flick's controls last handed over to the Remote, so its keys can settle in after the screen lands.
    @Published var remoteArrival = Date.distantPast
    // When the flick's screen actually starts its move onto the Remote's picture, which the keys follow closely.
    var remoteMoveAt = Date.distantPast
    // A film's colour kept on the pages behind after the flick closes, until something else is playing.
    var moodArt: String?
    func keepMood(until art: String) { moodArt = art }
    @Published var reachable = true
    @Published var watchlist: [Film] = []
    @Published var friends: [Film] = []
    @Published var recommended: [Film] = []
    @Published var flicking: FlickTarget?
    // The colour of wherever you are: an app's own, or whatever you've picked. Nil lets what's playing set it.
    @Published var mood: Color?
    // The cover of the last thing flicked, for when the TV's player has none of its own to show.
    @Published var lastArt: String?
    @Published var lastArtPkg: String?
    var lastArtTitle: String?
    // A picture for what an app is playing: its real poster if the Mac found one, else the cover of what was flicked to
    // it if that's still what's on, else the app's own banner. Never the cover of something that played before.
    func picture(for s: TVStatus.Session) -> String? {
        if let a = s.art, !a.isEmpty { return a }
        if s.pkg == lastArtPkg, let a = lastArt, let t = lastArtTitle, let now = s.description.first,
           now.localizedCaseInsensitiveContains(t) || t.localizedCaseInsensitiveContains(now) { return a }
        return url("/api/tv/icon?pkg=\(s.pkg)&v=2")?.absoluteString
    }
    // The flick screen brings itself in and out, so the system's slide stays out of it.
    func flick(_ target: FlickTarget) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { flicking = target }
    }
    func closeFlick() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { flicking = nil }
    }
    // Sound from the phone that isn't music. Mint's last song is still in the status then, but it isn't what's playing.
    var otherAirPlay: Bool { status?.airplay?.active == true && status?.airplay?.kind != "music" }
    var nowMusic: TVStatus.Music? { otherAirPlay ? nil : status?.music }
    // The cover of what's on, for the wall behind every page and the Playing tab's icon. Nothing while the phone plays
    // something of its own, rather than the cover of whatever played before.
    var nowArt: String? {
        if otherAirPlay { return nil }
        if videoIsCurrent, let s = status?.session { return picture(for: s) }
        return status?.music?.art
    }
    // Whether another app's player, rather than Mint, is what's on. A paused player only counts if it's the app in
    // front, or a song would lose out to something long since left.
    var videoIsCurrent: Bool {
        guard let s = status?.session, s.pkg != "com.codex.musicwebtv" else { return false }
        return s.playing || nowMusic == nil || s.pkg == status?.app
    }
    // A film playing, which the TV's screenshot leaves black: it never captures protected video.
    var filmOnScreen: Bool { !staleStatus && videoIsCurrent && status?.session?.playing == true }
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
                    // Not while a flick is up: every refresh redraws the pages behind it, which shows as stutter in the flick.
                    // Its control screen keeps itself current.
                    if let self, self.flicking == nil, Date().timeIntervalSince(self.lastKeyAt) > 1.5 { await self.load() }
                    // What's playing changes under you, so the Playing tab keeps closer watch.
                    try? await Task.sleep(nanoseconds: self?.tab == 2 ? 2_500_000_000 : 5_000_000_000)
                }
            },
            // Still pictures, only while the screen is on show and the live stream isn't. Never switched off by itself
            // while he's looking at it.
            Task { [weak self] in
                while !Task.isCancelled {
                    if let self, self.mirrorLive, self.mirrorViewers > 0 {
                        // The film's poster stands in for it, and a frame from before it started mustn't show after.
                        // Nor does the box record its screen during a film: it's black anyway, and the box is small.
                        if self.filmOnScreen {
                            if self.mirrorStore.image != nil { self.mirrorStore.set(nil) }
                            #if os(iOS)
                            self.live.stop()
                            #endif
                        } else {
                            self.warmMirror()
                            if !self.liveShowing { await self.loadMirror() }
                        }
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            },
        ]
        if mirrorLive && mirrorViewers > 0 { warmMirror() }
    }
    func stop() {
        loops.forEach { $0.cancel() }; loops = []
        #if os(iOS)
        live.stop()
        #endif
    }
    var liveShowing: Bool {
        #if os(iOS)
        live.showing
        #else
        false
        #endif
    }
    // The live stream started early, as the Remote comes up, so its first picture is there by the time it's looked at.
    func warmMirror() {
        #if os(iOS)
        if mirrorLive && !filmOnScreen { live.start(url("/api/tv/screen-live")) }
        #endif
    }
    // The Remote's picture of the TV coming on and off the screen.
    func mirrorShown(_ on: Bool) {
        mirrorViewers = max(0, mirrorViewers + (on ? 1 : -1))
        if on {
            warmMirror()
            if mirrorLive && !liveShowing { Task { await loadMirror() } }
        } else if mirrorViewers == 0 {
            mirrorSlot = nil
            #if os(iOS)
            live.stop(after: 5)
            #endif
        }
    }
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
        if staleStatus { staleStatus = false }
        PhonePlayer.shared.follow(s)
        NextUp.shared.follow(s)
    }
    // His choice, kept from one visit and one launch to the next.
    func setMirror(_ on: Bool) {
        lastTouch = Date()
        mirrorLive = on
        UserDefaults.standard.set(on, forKey: "mirrorLive")
        if on {
            warmMirror()
            Task { await loadMirror() }
        } else {
            #if os(iOS)
            live.stop()
            #endif
        }
    }
    // A still of the TV's screen. After a key, the first one taken after it, so the press shows rather than the frame
    // from before it.
    func loadMirror(after: Date? = nil) async {
        guard let u = url("/api/tv/shot" + (after.map { "?after=\(Int($0.timeIntervalSince1970 * 1000))" } ?? "")) else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 10; r.cachePolicy = .reloadIgnoringLocalCacheData
        if let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, let i = TVImage(data: d) { mirrorStore.set(i) }
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
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 30
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
        // Outside the chain, so a slow picture never holds up the next press. The live stream shows the press by
        // itself; without it, the first still taken after the press is asked for straight away.
        if mirrorLive && !repeating && mirrorViewers > 0 && !liveShowing {
            mirrorSoon?.cancel()
            let pressed = Date()
            mirrorSoon = Task { [weak self] in await self?.loadMirror(after: pressed) }
        }
    }
    // Typing into the TV: what was deleted, then what was added, in order with the keys around it. Nothing is dropped
    // for being late, or the box on the TV would end up different from the field on the phone.
    func type(deleting n: Int, adding text: String) {
        lastKeyAt = Date(); lastTouch = Date()
        let sends = Array(repeating: request("key", ["key": "del"]), count: n) + [text.isEmpty ? nil : request("text", ["text": text])]
        let before = keyChain
        keyChain = Task { [weak self] in
            await before?.value
            for case var r? in sends {
                r.timeoutInterval = 6
                let result = try? await URLSession.shared.data(for: r)
                if (result?.1 as? HTTPURLResponse)?.statusCode != 200 { self?.say("The TV didn’t get that"); return }
            }
        }
    }
    private var repeatPending = false
    private var mirrorSoon: Task<Void, Never>?
    // Nothing is said when it works: what changes on the TV, or on the button pressed, says that. Only a failure is told.
    func post(_ path: String, _ body: [String: Any] = [:]) {
        guard let r = request(path, body) else { return }
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
            // Only a link the TV can't open needs saying, since then there's something else to do.
            if !["apple", "words", "youtube", "film", "imdb"].contains(j["kind"] as? String ?? "") { say("That link can’t open on the TV. Try AirPlay.") }
        }
    }
}

// The still mirror changes every 1.5 s. Only the mirror should redraw when it does. When the picture was taken, so an
// old one can be shown as old.
@MainActor
final class MirrorStore: ObservableObject {
    @Published private(set) var image: TVImage?
    @Published private(set) var at = Date.distantPast
    func set(_ i: TVImage?) { image = i; if i != nil { at = Date() } }
}

// A half-typed link outlives unfolding, which rebuilds the layout.
@MainActor
final class SendDraft: ObservableObject {
    static let shared = SendDraft()
    @Published var text = ""
}
