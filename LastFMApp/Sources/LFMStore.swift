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

struct Profile: Sendable, Equatable {
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
    // The song the screens show (the hero, the strip, the ground behind every tab). It follows `hero`, but moves to a
    // song with a new cover only once that cover and its backdrop are ready, so cover, ground and words change together
    // in one crossfade (run 39: the ground cut to black for half a second and the cover showed its stand-in).
    private(set) var shown: Scrobble?
    @ObservationIgnored private var preparing: String?
    // Polls in a row that said nothing is on while a song was: one is let pass before the song is called over (Last.fm
    // often says nothing between two songs), so "now playing" and the hero don't flip and back.
    @ObservationIgnored private var missedNow = 0
    // A list under his finger is never changed by a poll: while a page is being scrolled the new list waits here and
    // goes in when the scroll comes to rest (run 39 review, fault 7: a new scrobble pushed the list down mid-drag).
    @ObservationIgnored private var queued: [Scrobble]?
    @ObservationIgnored private var scrollingSince: Date?
    @ObservationIgnored var scrolling: Bool {
        get { scrollingSince.map { Date().timeIntervalSince($0) < 8 } ?? false }
        set {
            scrollingSince = newValue ? Date() : nil
            if !newValue, let q = queued { queued = nil; if q != recent { recent = q; showHero() } }
        }
    }
    // The newest list known, shown yet or not.
    private var latest: [Scrobble] { queued ?? recent }
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
        _ = ArtStore.born
        // The last thing each screen showed, before anything is asked.
        if let (j, _) = LastFM.shared.kept("user.getinfo") { profile = Profile.parse(j) }
        // A kept "now playing" is only believed if the reply is a few minutes old: from yesterday it opened on live bars
        // over a song long over until the first answer came (and kept them while Last.fm was away).
        if let (j, when) = LastFM.shared.kept("user.getrecenttracks", ["limit": "200", "extended": "1"]) {
            apply(j, hold: false)
            if Date().timeIntervalSince(when) > Self.nowLasts { nowPlaying = nil }
            answered = when
        }
        if let k = Insights.kept() { insights = k }
        if let k = Deep.kept() { deep = k }
        // The hero's cover and backdrop from the disk before the first frame, so it opens on the picture, not its stand-in.
        if let h = hero { ArtStore.shared.warm(h.art) }
        // His picture at the size his page draws it.
        if let p = profile { ArtStore.shared.warm(ArtRef(artist: p.name, album: "avatar", url: p.image), px: [240], backdrop: false) }
        shown = hero
        // The covers of today's wall, decoded off the main thread while the first frame is made, so they're there in it.
        let wall = ArtWall.gather(recent)
        Task.detached(priority: .userInitiated) { for r in wall { ArtStore.shared.warm(r, px: [156], backdrop: false) } }
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
        if Date().timeIntervalSince(answered) > Self.nowLasts, nowPlaying != nil { nowPlaying = nil; missedNow = 0; showHero() }
        polling?.cancel()
        polling = Task {
            // What's on first: the profile waited in front of it, so a slow profile held the song back.
            await refresh()
            await loadProfile()
            while !Task.isCancelled {
                // (-pollEvery N on the build's mock: polls N seconds apart, for the film of a poll under a moving finger.)
                let every = LastFM.shared.mock ? max(UserDefaults.standard.double(forKey: "pollEvery"), 0) : 0
                try? await Task.sleep(nanoseconds: UInt64((every > 0 ? every : 12) * 1_000_000_000))
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }
    func stop() { polling?.cancel(); polling = nil }

    private func loadProfile(fresh: TimeInterval = 600) async {
        if let j = try? await LastFM.shared.call("user.getinfo", fresh: fresh), let p = Profile.parse(j), p != profile { profile = p }
    }

    func refresh() async {
        do {
            // The first look takes a full page (and is kept, for the next launch's first frame); after that, only the top.
            let j = try await LastFM.shared.call("user.getrecenttracks", ["limit": polled ? "30" : "200", "extended": "1"], keep: !polled)
            polled = true
            answered = Date()
            let before = latest.first?.id, playingBefore = nowPlaying?.id
            apply(j)
            failingSince = nil
            if trouble { withAnimation(.smooth) { trouble = false } }
            if latest.first?.id != before || nowPlaying?.id != playingBefore {
                WidgetCenter.shared.reloadTimelines(ofKind: "now")
            }
            if latest.first?.id != before {
                await sync.keep(Array(latest.prefix(200)))
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

    // Only what changed is assigned, and with no animation of the store's own: every 12 s the whole app was told
    // everything had changed, inside a 0.45 s animation, and lists hitched under his finger (run 39 review, fault 7).
    private func apply(_ j: J, hold: Bool = true) {
        let all = j["recenttracks"]["track"].array.map(Scrobble.parse)
        var now = all.first { $0.nowPlaying }
        let played = all.filter { !$0.nowPlaying }
        if now == nil, let was = nowPlaying, hold, missedNow < 1, played.first.map({ $0.artist == was.artist && $0.title == was.title }) != true {
            missedNow += 1
            now = was
        } else if now != nil || nowPlaying == nil {
            missedNow = 0
        }
        if now != nowPlaying { nowPlaying = now }
        // New plays go on top; older pages already loaded stay below.
        let next: [Scrobble]
        let had = latest
        if let first = played.last, let i = had.firstIndex(where: { $0.id == first.id }) {
            next = played + had.dropFirst(i + 1)
        } else {
            next = played
        }
        if scrolling { queued = next == recent ? nil : next }
        else { queued = nil; if next != recent { recent = next } }
        showHero()
    }

    private func showHero() {
        let h = hero
        guard h != shown else { return }
        // Same cover (the song scrobbled, a flag changed), or nothing to wait for: at once.
        guard let h, let s = shown, h.art.key != s.art.key else { shown = h; preparing = nil; return }
        preparing = h.id
        let ref = h.art
        // Never held back for long: a cover that won't come (no network, a slow store) lets the song through after 4 s,
        // over the old ground, rather than leaving the last song on the screen.
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard preparing == h.id, let cur = hero, cur.art.key == ref.key else { return }
            preparing = nil
            withAnimation(.easeInOut(duration: 0.5)) { shown = cur }
        }
        Task {
            async let big = ArtStore.shared.image(ref, px: 1000)
            async let small = ArtStore.shared.image(ref, px: 156)
            async let ground = ArtStore.shared.backdrop(ref)
            _ = await (big, small, ground)
            guard preparing == h.id, let cur = hero, cur.art.key == ref.key else { return }
            preparing = nil
            withAnimation(.easeInOut(duration: 0.5)) { shown = cur }
        }
    }

    func loadMore() async {
        guard !loadingMore, !reachedEnd, let oldest = recent.last?.date else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let j = try? await LastFM.shared.call("user.getrecenttracks", ["limit": "100", "extended": "1", "to": "\(Int(oldest.timeIntervalSince1970) - 1)"], fresh: 3600) {
            let more = j["recenttracks"]["track"].array.map(Scrobble.parse).filter { !$0.nowPlaying }
            if more.isEmpty { reachedEnd = true } else { recent += more; if queued != nil { queued! += more } }
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
    var plays: Int?                    // everyone's scrobbles of it
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
        info.plays = t["playcount"].int
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
