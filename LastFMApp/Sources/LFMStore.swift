import Foundation
import SwiftUI
import WidgetKit

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
    var deep = Deep()                  // the insights that need his whole history, worked out once a day
    var todaySecs: Int?                // today's listening time, once enough of its lengths are known
    var loadingMore = false
    var reachedEnd = false
    // Failing since; the app says so only once it's been a while (never on one miss, never on opening). `trouble` is
    // stored, set by the poll itself: worked out from the clock, nothing told the screens when 25 s had passed, so the
    // note could stay away however long Last.fm was gone.
    var failingSince: Date?
    private(set) var trouble = false
    // The song the hero shows: the one on now, else the last one played.
    var hero: Scrobble? { nowPlaying ?? recent.first }
    var opened: Scrobble?              // the track whose page is up
    let sync = HistorySync.shared
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var polled = false
    // When Last.fm last answered the poll, and how long a song it called "now playing" is believed without a new answer.
    @ObservationIgnored private var answered = Date.distantPast
    static let nowLasts: TimeInterval = 240
    @ObservationIgnored private var insightTask: Task<Void, Never>?
    @ObservationIgnored private var lastInsight = Date.distantPast

    init() {
        LaunchLog.mark("store init")
        defer { LaunchLog.mark("store ready") }
        // The last thing each screen showed, before anything is asked.
        if let (j, _) = LastFM.shared.kept("user.getinfo") { profile = Profile.parse(j) }
        // A kept "now playing" is only believed if the reply is a few minutes old: from yesterday it opened on live bars
        // over a song long over until the first answer came (and kept them while Last.fm was away).
        if let (j, when) = LastFM.shared.kept("user.getrecenttracks", ["limit": "200", "extended": "1"]) {
            apply(j)
            if Date().timeIntervalSince(when) > Self.nowLasts { nowPlaying = nil }
            answered = when
        }
        if let k = Insights.kept() { insights = k }
        if let k = Deep.kept() { deep = k }
        // The hero's cover and backdrop from the disk before the first frame, so it opens on the picture, not its stand-in.
        if let h = hero { ArtStore.shared.warm(h.art) }
        // The build's mock makes its listening history off the main thread, while the first frame draws.
        if LastFM.shared.mock { Task.detached(priority: .userInitiated) { _ = MockLastFM.shared.profileName } }
        sync.onProgress = { [weak self] in self?.workInsights() }
        LengthFill.shared.onChange = { [weak self] in self?.workToday(); self?.workDeep(force: true) }
    }

    func start() {
        // The history loads first; insights follow it (HistorySync's onProgress), the kept ones showing meanwhile.
        sync.start()
        // Back from the background (hours, maybe), the first look is a full page again: thirty would leave today's
        // figures and the day counting only the last thirty plays until he scrolled.
        polled = false
        // Back after a while: what was on then isn't shown as on now while the first answer is awaited.
        if Date().timeIntervalSince(answered) > Self.nowLasts, nowPlaying != nil { withAnimation(.smooth) { nowPlaying = nil } }
        polling?.cancel()
        polling = Task {
            // What's on first: the profile waited in front of it, so a slow profile held the song back.
            await refresh()
            await loadProfile()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }
    func stop() { polling?.cancel(); polling = nil }

    private func loadProfile(fresh: TimeInterval = 600) async {
        if let j = try? await LastFM.shared.call("user.getinfo", fresh: fresh), let p = Profile.parse(j) { profile = p }
    }

    func refresh() async {
        do {
            // The first look takes a full page (and is kept, for the next launch's first frame); after that, only the top.
            let j = try await LastFM.shared.call("user.getrecenttracks", ["limit": polled ? "30" : "200", "extended": "1"], keep: !polled)
            polled = true
            answered = Date()
            let before = recent.first?.id, playingBefore = nowPlaying?.id
            apply(j)
            failingSince = nil
            if trouble { withAnimation(.smooth) { trouble = false } }
            if recent.first?.id != before || nowPlaying?.id != playingBefore {
                WidgetCenter.shared.reloadTimelines(ofKind: "now")
            }
            if recent.first?.id != before {
                await sync.keep(Array(recent.prefix(200)))
                workInsights()
                // A new scrobble moves his total too (it was asked once per opening, so it sat still while he listened).
                if before != nil { await loadProfile(fresh: 60) }
            }
        } catch {
            // (-mockDown YES: as if gone for a while already, so the build's shots show the note without waiting.)
            if failingSince == nil { failingSince = Date().addingTimeInterval(UserDefaults.standard.bool(forKey: "mockDown") ? -30 : 0) }
            if let f = failingSince, Date().timeIntervalSince(f) > 25, !trouble { withAnimation(.smooth) { trouble = true } }
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
            if s.coveredFrom != .max { s.keep(); shareWithWidgets(s) }
            if !s.hours.isEmpty { UserDefaults.standard.set(s.dayStart, forKey: "dayStart") }
            lastInsight = Date()
            insightTask = nil
            workToday()
            if s.complete { workDeep() }
        }
    }

    // The widgets' share of what only the history knows (the streak, his usual week); they redraw when it changes.
    private func shareWithWidgets(_ s: Insights) {
        guard !LastFM.shared.mock, s.streak != nil || s.pace != nil else { return }
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Clock.now)?.start.timeIntervalSince1970 ?? 0
        let p = s.pace
        let f = WidgetFacts(at: Date().timeIntervalSince1970, day: LocalDay.today, playedThatDay: (s.days[LocalDay.today] ?? 0) > 0,
                            streak: s.streak, best: s.best, weekStart: start, weekPlays: p?.now, usual: p?.usual, weeks: p?.weeks,
                            thisWeek: p?.thisWeek ?? [], usualMid: p?.usualBand.map(\.mid) ?? [], usualLo: p?.usualBand.map(\.lo) ?? [],
                            usualHi: p?.usualBand.map(\.hi) ?? [])
        if f.write() { WidgetCenter.shared.reloadAllTimelines() }
    }

    // Today's listening time: the lengths known, the rest at the middle length, shown once most are known.
    func workToday() {
        let from = Int(dayBegan.timeIntervalSince1970), to = Int(Clock.now.timeIntervalSince1970) + 1
        Task {
            let db = HistoryDB.reader
            let t = await db.time(from: from, to: to)
            let median = await db.medianLength()
            // For the plays the day's figure counts, so the two can't disagree (the phone's history can hold a few more or
            // fewer than the list on screen; 119 plays read as 12 hours, review 2026-11-14, item 2).
            let shown = today.filter { !$0.nowPlaying }.count
            todaySecs = HistoryDB.listening(plays: t.plays, secs: t.secs, known: t.known, median: median).map { t.plays > 0 ? Int(Double($0) / Double(t.plays) * Double(shown)) : $0 }
        }
    }

    // Eras, the river, records and the rest: once a day (and again when more track lengths are known), never before the
    // whole history is read.
    @ObservationIgnored private var deepTask: Task<Void, Never>?
    func workDeep(force: Bool = false) {
        guard sync.complete, deepTask == nil else { return }
        guard force || deep.day != LocalDay.today else { Task { try? await Task.sleep(nanoseconds: 3_000_000_000); LengthFill.shared.start() }; return }
        deepTask = Task {
            let (_, names) = await HistoryDB.shared.canon()
            let d = await Deep.work(canon: names)
            withAnimation(.smooth(duration: 0.4)) { deep = d }
            d.keep()
            deepTask = nil
            // Track lengths after: the database answers the screens first.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            LengthFill.shared.start()
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
