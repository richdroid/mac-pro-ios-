import Foundation
import SwiftUI

struct Scrobble: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let image: String?
    let date: Date?
    let nowPlaying: Bool
    let loved: Bool
    let url: String?

    var art: ArtRef { ArtRef(artist: artist, album: album, url: image) }

    // Last.fm's star placeholder stands for "no picture"; so does an empty one.
    static func bestImage(_ j: J) -> String? {
        let list = j.array
        let pick = list.first { $0["size"].text == "extralarge" } ?? list.last
        guard let u = pick?.string, !u.isEmpty, !u.contains("2a96cbd8b46e442fc41c2b86b821562f") else { return nil }
        return u
    }
    static func parse(_ t: J) -> Scrobble {
        let artist = t["artist"]["name"].string ?? t["artist"].text
        let now = t["@attr"]["nowplaying"].bool
        let uts = t["date"]["uts"].int
        return Scrobble(id: now ? "now|\(artist)|\(t["name"].text)" : "\(uts ?? 0)|\(artist)|\(t["name"].text)",
                        title: t["name"].text, artist: artist, album: t["album"].text, image: bestImage(t["image"]),
                        date: uts.map { Date(timeIntervalSince1970: TimeInterval($0)) }, nowPlaying: now, loved: t["loved"].bool, url: t["url"].string)
    }
}

struct Profile: Sendable {
    let name: String
    let realname: String
    let image: String?
    let playcount: Int
    let artists: Int
    let albums: Int
    let tracks: Int
    let registered: Date
    static func parse(_ j: J) -> Profile? {
        let u = j["user"]
        guard u.exists else { return nil }
        return Profile(name: u["name"].text, realname: u["realname"].text, image: Scrobble.bestImage(u["image"]),
                       playcount: u["playcount"].int ?? 0, artists: u["artist_count"].int ?? 0, albums: u["album_count"].int ?? 0,
                       tracks: u["track_count"].int ?? 0, registered: Date(timeIntervalSince1970: TimeInterval(u["registered"]["unixtime"].int ?? 0)))
    }
}

// Everything the screens show, kept in one place so a tab left and come back to is exactly as it was.
@MainActor @Observable final class Store {
    static let shared = Store()
    var profile: Profile?
    var recent: [Scrobble] = []        // newest first; the song on now is never in it
    var nowPlaying: Scrobble?
    var insights = Insights()
    var loadingMore = false
    var reachedEnd = false
    // Failing since; the app says so only once it's been a while (never on one miss, never on opening).
    var failingSince: Date?
    var trouble: Bool { failingSince.map { Date().timeIntervalSince($0) > 25 } ?? false }
    // The song the hero shows: the one on now, else the last one played.
    var hero: Scrobble? { nowPlaying ?? recent.first }
    var opened: Scrobble?              // the track whose page is up
    let sync = HistorySync.shared
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var polled = false
    @ObservationIgnored private var insightTask: Task<Void, Never>?
    @ObservationIgnored private var lastInsight = Date.distantPast

    init() {
        LaunchLog.mark("store init")
        defer { LaunchLog.mark("store ready") }
        // The last thing each screen showed, before anything is asked.
        if let (j, _) = LastFM.shared.kept("user.getinfo") { profile = Profile.parse(j) }
        if let (j, _) = LastFM.shared.kept("user.getrecenttracks", ["limit": "200", "extended": "1"]) { apply(j) }
        if let k = Insights.kept() { insights = k }
        // The hero's cover and backdrop from the disk before the first frame, so it opens on the picture, not its stand-in.
        if let h = hero { ArtStore.shared.warm(h.art) }
        // The build's mock makes its listening history off the main thread, while the first frame draws.
        if LastFM.shared.mock { Task.detached(priority: .userInitiated) { _ = MockLastFM.shared.profileName } }
        sync.onProgress = { [weak self] in self?.workInsights() }
    }

    func start() {
        // The history loads first; insights follow it (HistorySync's onProgress), the kept ones showing meanwhile.
        sync.start()
        polling?.cancel()
        polling = Task {
            await loadProfile()
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
    }
    func stop() { polling?.cancel(); polling = nil }

    private func loadProfile() async {
        if let j = try? await LastFM.shared.call("user.getinfo", fresh: 600), let p = Profile.parse(j) { profile = p }
    }

    func refresh() async {
        do {
            // The first look takes a full page (and is kept, for the next launch's first frame); after that, only the top.
            let j = try await LastFM.shared.call("user.getrecenttracks", ["limit": polled ? "30" : "200", "extended": "1"], keep: !polled)
            polled = true
            let before = recent.first?.id
            apply(j)
            failingSince = nil
            if recent.first?.id != before {
                await sync.keep(Array(recent.prefix(200)))
                workInsights()
            }
        } catch {
            if failingSince == nil { failingSince = Date() }
        }
    }

    private func apply(_ j: J) {
        let all = j["recenttracks"]["track"].array.map(Scrobble.parse)
        let now = all.first { $0.nowPlaying }
        let played = all.filter { !$0.nowPlaying }
        withAnimation(.smooth(duration: 0.45)) {
            nowPlaying = now
            // New plays go on top; older pages already loaded stay below.
            if let first = played.last, let i = recent.firstIndex(where: { $0.id == first.id }) {
                recent = played + recent.dropFirst(i + 1)
            } else {
                recent = played
            }
        }
    }

    func loadMore() async {
        guard !loadingMore, !reachedEnd, let oldest = recent.last?.date else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let j = try? await LastFM.shared.call("user.getrecenttracks", ["limit": "100", "extended": "1", "to": "\(Int(oldest.timeIntervalSince1970) - 1)"], fresh: 3600) {
            let more = j["recenttracks"]["track"].array.map(Scrobble.parse).filter { !$0.nowPlaying }
            if more.isEmpty { reachedEnd = true } else { recent += more }
        }
    }

    // Worked out again as the history arrives, at most every second and a half, off the main thread.
    func workInsights(now: Bool = false) {
        guard insightTask == nil else { return }
        let wait = now ? 0 : max(0, 1.5 - Date().timeIntervalSince(lastInsight))
        insightTask = Task {
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let s = await Insights.work(coveredFrom: sync.coveredFrom, complete: sync.complete)
            insights = s
            if s.coveredFrom != .max { s.keep() }
            if !s.hours.isEmpty { UserDefaults.standard.set(s.dayStart, forKey: "dayStart") }
            lastInsight = Date()
            insightTask = nil
        }
    }

    // Where his day begins: his quietest hour, from his history (kept, so the first frame of the next launch has it too).
    var dayStart: Int { insights.hours.isEmpty ? (UserDefaults.standard.object(forKey: "dayStart") as? Int ?? 6) : insights.dayStart }
    var dayBegan: Date {
        let cal = Calendar.current
        let start = cal.date(byAdding: .hour, value: dayStart, to: cal.startOfDay(for: Clock.now)) ?? Clock.now
        return start > Clock.now ? start.addingTimeInterval(-86400) : start
    }
    // His day's plays so far, oldest first.
    var today: [Scrobble] {
        let start = dayBegan
        return recent.filter { ($0.date ?? .distantPast) >= start }.reversed()
    }
}

// Detail for one track: his plays and love, its listeners, tags and words.
struct TrackInfo: Sendable {
    var userPlays: Int?
    var loved = false
    var listeners: Int?
    var duration: Int?
    var tags: [String] = []
    var summary: String?
    var url: String?

    static func load(_ s: Scrobble) async -> TrackInfo? {
        guard let j = try? await LastFM.shared.call("track.getinfo", ["artist": s.artist, "track": s.title], fresh: 3600) else { return nil }
        let t = j["track"]
        guard t.exists else { return nil }
        var info = TrackInfo()
        info.userPlays = t["userplaycount"].int
        info.loved = t["userloved"].bool
        info.listeners = t["listeners"].int
        info.duration = t["duration"].int.flatMap { $0 > 0 ? $0 / 1000 : nil }
        info.tags = t["toptags"]["tag"].array.map { $0["name"].text }.filter { !$0.isEmpty }.prefix(5).map { $0.lowercased() }
        // Last.fm ends each summary with a link back to itself; the words are kept, the link isn't.
        if let raw = t["wiki"]["summary"].string {
            let cut = raw.components(separatedBy: "<a href").first ?? raw
            let words = cut.trimmingCharacters(in: .whitespacesAndNewlines)
            info.summary = words.isEmpty ? nil : words
        }
        info.url = t["url"].string
        return info
    }
}
