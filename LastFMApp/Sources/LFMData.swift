import Foundation
import SQLite3

// Phase 2's reading of his history: charts for any stretch of time with movement against the stretch before, his
// library (every artist, album and track he's played), each one's own story (plays, first and last, its tide over the
// years, its rank), and the all-history insights (eras, takeovers, the canon's river, discoveries that stuck, record
// days, months against his median, year-over-year carry-over, listening time). All from the plays on the phone.
private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum Kind: Int, CaseIterable, Codable, Sendable {
    case artists, albums, tracks
    var name: String { ["Artists", "Albums", "Tracks"][rawValue] }
    var noun: String { ["artists", "albums", "tracks"][rawValue] }
}

enum Move: Hashable, Sendable, Codable { case up(Int), down(Int), same, new }

// One line of a chart or the library: an artist, an album or a track, and his plays of it.
struct Entry: Identifiable, Hashable, Sendable {
    let kind: Kind
    let artist: String
    let album: String          // the album (albums), the album most played from (tracks), the cover's album (artists)
    let track: String
    let plays: Int
    var secs: Int? = nil       // listening time, when enough of its lengths are known
    var image: String? = nil
    var rank = 0
    var move: Move? = nil
    var first: Int? = nil
    var last: Int? = nil
    var id: String { kind == .artists ? "a|\(artist)" : kind == .albums ? "l|\(artist)|\(album)" : "t|\(artist)|\(track)" }
    var title: String { kind == .artists ? artist : kind == .albums ? album : track }
    var art: ArtRef { ArtRef(artist: artist, album: album, url: image) }
    var route: Route {
        switch kind {
        case .artists: return .artist(artist)
        case .albums: return .album(artist, album)
        case .tracks: return .track(Scrobble.song(artist: artist, title: track, album: album, image: image))
        }
    }
}

// Where a tap goes: every artist, album and track in the app opens its own page.
enum Route: Hashable, Sendable {
    case artist(String)
    case album(String, String)
    case track(Scrobble)
    var key: String {
        switch self {
        case .artist(let a): return "artist|\(a.lowercased())"
        case .album(let a, let l): return "album|\(a.lowercased())|\(l.lowercased())"
        case .track(let s): return "track|\(s.artist.lowercased())|\(s.title.lowercased())|\(s.id)"
        }
    }
}
// A page pushed, and the cover it grows out of (when one was tapped).
struct Go: Hashable, Sendable { let route: Route; let zoom: String? }

extension Scrobble {
    // A song as a thing, not one play of it: for pages opened from a chart, the library or Last.fm's lists.
    static func song(artist: String, title: String, album: String, image: String?) -> Scrobble {
        Scrobble(id: "song|\(artist)|\(title)", title: title, artist: artist, album: album, image: image, date: nil, nowPlaying: false, loved: false, url: nil)
    }
}

// An artist, album or track's own story in his plays.
struct Story: Sendable {
    var plays = 0
    var first: Int?
    var last: Int?
    var rank: Int?
    var of = 0
    var secs: Int?
    var months: [Int: Int] = [:]       // calendar month (year × 12 + month) → plays
    var top: [Entry] = []              // an artist's: his top tracks; an album's: its tracks by his plays
    var albums: [Entry] = []           // an artist's albums by his plays
}

extension HistoryDB {
    private func bind(_ s: OpaquePointer, _ binds: [Any]) {
        for (i, b) in binds.enumerated() {
            if let n = b as? Int { sqlite3_bind_int64(s, Int32(i + 1), sqlite3_int64(n)) }
            else if let t = b as? String { sqlite3_bind_text(s, Int32(i + 1), t, -1, TRANSIENT) }
        }
    }

    // MARK: Track lengths, for listening time

    // The middle length of every track known: what a play of a track whose length isn't known yet is counted as.
    func medianLength() -> Int {
        var n = 0
        rows("SELECT COUNT(*) FROM durations") { n = int($0, 0) }
        guard n > 0 else { return 215 }
        var m = 215
        rows("SELECT secs FROM durations ORDER BY secs LIMIT 1 OFFSET ?", [n / 2]) { m = int($0, 0) }
        return m
    }
    func keepLengths(_ list: [(String, String, Int)]) {
        guard !list.isEmpty, let p = prepare("INSERT OR REPLACE INTO durations(artist, track, secs) VALUES(?,?,?)") else { return }
        defer { sqlite3_finalize(p) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (a, t, s) in list where s > 20 && s < 3600 {
            sqlite3_reset(p); bind(p, [a, t, s]); sqlite3_step(p)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }
    func markFilled(_ artist: String, _ album: String) {
        guard let p = prepare("INSERT OR IGNORE INTO filled(artist, album) VALUES(?,?)") else { return }
        bind(p, [artist, album]); sqlite3_step(p); sqlite3_finalize(p)
    }
    // His most played albums whose track lengths haven't been asked for yet.
    func albumsToFill(limit: Int) -> [(String, String)] {
        var out: [(String, String)] = []
        rows("""
            SELECT p.artist, p.album, COUNT(*) c FROM plays p WHERE p.album != ''
            AND NOT EXISTS (SELECT 1 FROM filled f WHERE f.artist = p.artist AND f.album = p.album)
            GROUP BY p.artist, p.album ORDER BY c DESC LIMIT ?
            """, [limit]) { out.append((text($0, 0), text($0, 1))) }
        return out
    }
    // Plays, the seconds known, and how many plays those seconds cover, between two moments.
    func time(from: Int, to: Int) -> (plays: Int, secs: Int, known: Int) {
        var r = (0, 0, 0)
        rows("SELECT COUNT(*), TOTAL(d.secs), COUNT(d.secs) FROM plays p LEFT JOIN durations d ON d.artist = p.artist AND d.track = p.track WHERE p.uts >= ? AND p.uts < ?", [from, to]) {
            r = (int($0, 0), Int(sqlite3_column_double($0, 1)), int($0, 2))
        }
        return r
    }

    // MARK: Charts

    // The top of a stretch of time, with listening time where enough of it is known.
    func top(_ kind: Kind, from: Int, to: Int, limit: Int, median: Int) -> [Entry] {
        let sql: String
        switch kind {
        case .artists: sql = "SELECT p.artist, '', '', COUNT(*) c, TOTAL(d.secs), COUNT(d.secs) FROM plays p LEFT JOIN durations d ON d.artist = p.artist AND d.track = p.track WHERE p.uts >= ? AND p.uts < ? GROUP BY p.artist ORDER BY c DESC LIMIT ?"
        case .albums: sql = "SELECT p.artist, p.album, '', COUNT(*) c, TOTAL(d.secs), COUNT(d.secs) FROM plays p LEFT JOIN durations d ON d.artist = p.artist AND d.track = p.track WHERE p.uts >= ? AND p.uts < ? AND p.album != '' GROUP BY p.artist, p.album ORDER BY c DESC LIMIT ?"
        case .tracks: sql = "SELECT p.artist, MAX(p.album), p.track, COUNT(*) c, TOTAL(d.secs), COUNT(d.secs) FROM plays p LEFT JOIN durations d ON d.artist = p.artist AND d.track = p.track WHERE p.uts >= ? AND p.uts < ? GROUP BY p.artist, p.track ORDER BY c DESC LIMIT ?"
        }
        var out: [Entry] = []
        rows(sql, [from, to, limit]) { s in
            let plays = int(s, 3), secs = Int(sqlite3_column_double(s, 4)), known = int(s, 5)
            out.append(Entry(kind: kind, artist: text(s, 0), album: text(s, 1), track: text(s, 2), plays: plays,
                             secs: Self.listening(plays: plays, secs: secs, known: known, median: median), rank: out.count + 1))
        }
        for i in out.indices { out[i].image = cover(for: out[i], from: from) }
        if kind == .artists { for i in out.indices { if let c = cover(of: out[i].artist, from: from) { out[i] = out[i].with(album: c.album, image: c.url) } } }
        return out
    }
    // Ranks only, for the stretch before: name → rank.
    func ranks(_ kind: Kind, from: Int, to: Int, limit: Int) -> [String: Int] {
        let sql: String
        switch kind {
        case .artists: sql = "SELECT artist, '', COUNT(*) c FROM plays WHERE uts >= ? AND uts < ? GROUP BY artist ORDER BY c DESC LIMIT ?"
        case .albums: sql = "SELECT artist, album, COUNT(*) c FROM plays WHERE uts >= ? AND uts < ? AND album != '' GROUP BY artist, album ORDER BY c DESC LIMIT ?"
        case .tracks: sql = "SELECT artist, track, COUNT(*) c FROM plays WHERE uts >= ? AND uts < ? GROUP BY artist, track ORDER BY c DESC LIMIT ?"
        }
        var out: [String: Int] = [:]
        rows(sql, [from, to, limit]) { s in out[text(s, 0) + "\u{1}" + text(s, 1)] = out.count + 1 }
        return out
    }
    func cover(for e: Entry, from: Int = 0) -> String? {
        switch e.kind {
        case .artists: return nil
        case .albums, .tracks: return e.album.isEmpty ? nil : artURL(e.artist, e.album)
        }
    }
    static func listening(plays: Int, secs: Int, known: Int, median: Int) -> Int? {
        guard plays > 0, Double(known) / Double(plays) >= 0.6 else { return nil }
        return secs + (plays - known) * median
    }

    // MARK: The library

    func library(_ kind: Kind) -> [Entry] {
        let sql: String
        switch kind {
        case .artists: sql = "SELECT artist, '', '', COUNT(*), MIN(uts), MAX(uts) FROM plays GROUP BY artist"
        case .albums: sql = "SELECT artist, album, '', COUNT(*), MIN(uts), MAX(uts) FROM plays WHERE album != '' GROUP BY artist, album"
        case .tracks: sql = "SELECT artist, MAX(album), track, COUNT(*), MIN(uts), MAX(uts) FROM plays GROUP BY artist, track"
        }
        var out: [Entry] = []
        rows(sql) { s in out.append(Entry(kind: kind, artist: text(s, 0), album: text(s, 1), track: text(s, 2), plays: int(s, 3), first: int(s, 4), last: int(s, 5))) }
        var art: [String: String] = [:]
        rows("SELECT artist, album, url FROM art") { art[text($0, 0) + "\u{1}" + text($0, 1)] = text($0, 2) }
        out.sort { $0.plays > $1.plays }
        var prev = -1, rank = 0
        for i in out.indices {
            if out[i].plays != prev { rank = i + 1; prev = out[i].plays }
            out[i].rank = rank
            if kind != .artists { out[i].image = art[out[i].artist + "\u{1}" + out[i].album] }
        }
        return out
    }
    // Each artist's most played album and its cover, for every artist at once (the library's artist rows).
    func artistCovers() -> [String: (String, String?)] {
        var best: [String: (String, Int)] = [:]
        rows("SELECT artist, album, COUNT(*) FROM plays WHERE album != '' GROUP BY artist, album") { s in
            let a = text(s, 0), n = int(s, 2)
            if n > (best[a]?.1 ?? 0) { best[a] = (text(s, 1), n) }
        }
        var art: [String: String] = [:]
        rows("SELECT artist, album, url FROM art") { art[text($0, 0) + "\u{1}" + text($0, 1)] = text($0, 2) }
        return best.reduce(into: [:]) { acc, kv in acc[kv.key] = (kv.value.0, art[kv.key + "\u{1}" + kv.value.0]) }
    }

    // MARK: One artist, album or track

    func story(artist: String, album: String? = nil, track: String? = nil, median: Int) -> Story {
        var st = Story()
        var whereSQL = "artist = ?"
        var binds: [Any] = [artist]
        if let album { whereSQL += " AND album = ?"; binds.append(album) }
        if let track { whereSQL += " AND track = ?"; binds.append(track) }
        rows("SELECT COUNT(*), MIN(uts), MAX(uts) FROM plays WHERE \(whereSQL)", binds) { s in
            st.plays = int(s, 0)
            if st.plays > 0 { st.first = int(s, 1); st.last = int(s, 2) }
        }
        guard st.plays > 0 else { return st }
        rows("SELECT month, COUNT(*) FROM plays WHERE \(whereSQL) GROUP BY month", binds) { st.months[int($0, 0)] = int($0, 1) }
        if st.months.keys.contains(0) { backfillMonths(); st.months = [:]; rows("SELECT month, COUNT(*) FROM plays WHERE \(whereSQL) GROUP BY month", binds) { st.months[int($0, 0)] = int($0, 1) } }
        var t = (0, 0)
        let pre = whereSQL.replacingOccurrences(of: "artist", with: "p.artist").replacingOccurrences(of: "album", with: "p.album").replacingOccurrences(of: "track", with: "p.track")
        rows("SELECT TOTAL(d.secs), COUNT(d.secs) FROM plays p LEFT JOIN durations d ON d.artist = p.artist AND d.track = p.track WHERE \(pre)", binds) { t = (Int(sqlite3_column_double($0, 0)), int($0, 1)) }
        st.secs = Self.listening(plays: st.plays, secs: t.0, known: t.1, median: median)
        // Rank among his artists, albums or tracks: one more than how many he's played more.
        let group = track != nil ? "artist, track" : album != nil ? "artist, album" : "artist"
        let filter = album != nil && track == nil ? "WHERE album != ''" : ""
        rows("SELECT SUM(c > ?), COUNT(*) FROM (SELECT COUNT(*) c FROM plays \(filter) GROUP BY \(group))", [st.plays]) { s in
            st.rank = int(s, 0) + 1; st.of = int(s, 1)
        }
        if track == nil {
            if let album {
                rows("SELECT track, COUNT(*) c FROM plays WHERE artist = ? AND album = ? GROUP BY track ORDER BY c DESC", [artist, album]) { s in
                    st.top.append(Entry(kind: .tracks, artist: artist, album: album, track: text(s, 0), plays: int(s, 1)))
                }
            } else {
                rows("SELECT track, MAX(album), COUNT(*) c FROM plays WHERE artist = ? GROUP BY track ORDER BY c DESC LIMIT 10", [artist]) { s in
                    st.top.append(Entry(kind: .tracks, artist: artist, album: text(s, 1), track: text(s, 0), plays: int(s, 2), rank: st.top.count + 1))
                }
                rows("SELECT album, COUNT(*) c, MIN(uts) FROM plays WHERE artist = ? AND album != '' GROUP BY album ORDER BY c DESC LIMIT 12", [artist]) { s in
                    st.albums.append(Entry(kind: .albums, artist: artist, album: text(s, 0), track: "", plays: int(s, 1), first: int(s, 2)))
                }
                for i in st.albums.indices { st.albums[i].image = artURL(artist, st.albums[i].album) }
            }
            for i in st.top.indices { st.top[i].image = artURL(artist, st.top[i].album) }
        }
        return st
    }
    // His plays of each name in a list (an artist's top tracks on Last.fm, similar artists), by name, case aside.
    func playsOf(artists: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for a in artists { rows("SELECT COUNT(*) FROM plays WHERE artist = ? COLLATE NOCASE", [a]) { out[a.lowercased()] = int($0, 0) } }
        return out
    }
    func playsOf(artist: String, tracks: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for t in tracks { rows("SELECT COUNT(*) FROM plays WHERE artist = ? COLLATE NOCASE AND track = ? COLLATE NOCASE", [artist, t]) { out[t.lowercased()] = int($0, 0) } }
        return out
    }
    // The most played album of a week (the week list's covers).
    func weekTop(from: Int, to: Int) -> (plays: Int, artist: String, album: String, url: String?)? {
        var total = 0
        rows("SELECT COUNT(*) FROM plays WHERE uts >= ? AND uts < ?", [from, to]) { total = int($0, 0) }
        guard total > 0 else { return nil }
        var hit: (String, String)?
        rows("SELECT artist, album, COUNT(*) c FROM plays WHERE uts >= ? AND uts < ? AND album != '' GROUP BY artist, album ORDER BY c DESC LIMIT 1", [from, to]) { hit = (text($0, 0), text($0, 1)) }
        guard let hit else { return (total, "", "", nil) }
        return (total, hit.0, hit.1, artURL(hit.0, hit.1))
    }
    // How each of the most played names ranked, week by week (the bump chart).
    func weekly(_ kind: Kind, weeks: [(Int, Int)], depth: Int) -> [[String: Int]] {
        weeks.map { ranks(kind, from: $0.0, to: $0.1, limit: depth) }
    }

    // MARK: All of it, at once (the insights that need his whole history)

    func monthArtist() -> [(month: Int, artist: String, plays: Int)] {
        backfillMonths()
        var out: [(Int, String, Int)] = []
        out.reserveCapacity(40_000)
        rows("SELECT month, artist, COUNT(*) FROM plays GROUP BY month, artist") { out.append((int($0, 0), text($0, 1), int($0, 2))) }
        return out.map { (month: $0.0, artist: $0.1, plays: $0.2) }
    }
    func artistSpans() -> [(artist: String, plays: Int, first: Int, last: Int)] {
        var out: [(String, Int, Int, Int)] = []
        rows("SELECT artist, COUNT(*), MIN(uts), MAX(uts) FROM plays GROUP BY artist") { out.append((text($0, 0), int($0, 1), int($0, 2), int($0, 3))) }
        return out.map { (artist: $0.0, plays: $0.1, first: $0.2, last: $0.3) }
    }
    // The days that broke records: the most plays in a day, of one track in a day, of one artist in a day.
    func recordDay() -> (day: Int, plays: Int)? { var r: (Int, Int)?; rows("SELECT day, COUNT(*) c FROM plays GROUP BY day ORDER BY c DESC LIMIT 1") { r = (int($0, 0), int($0, 1)) }; return r }
    func recordTrackDay() -> (day: Int, artist: String, track: String, album: String, plays: Int)? {
        var r: (Int, String, String, String, Int)?
        rows("SELECT day, artist, track, MAX(album), COUNT(*) c FROM plays GROUP BY day, artist, track ORDER BY c DESC LIMIT 1") { r = (int($0, 0), text($0, 1), text($0, 2), text($0, 3), int($0, 4)) }
        return r.map { (day: $0.0, artist: $0.1, track: $0.2, album: $0.3, plays: $0.4) }
    }
    func recordArtistDay() -> (day: Int, artist: String, plays: Int)? {
        var r: (Int, String, Int)?
        rows("SELECT day, artist, COUNT(*) c FROM plays GROUP BY day, artist ORDER BY c DESC LIMIT 1") { r = (int($0, 0), text($0, 1), int($0, 2)) }
        return r.map { (day: $0.0, artist: $0.1, plays: $0.2) }
    }
    func dayTopAlbum(_ day: Int) -> (artist: String, album: String)? {
        var r: (String, String)?
        rows("SELECT artist, album, COUNT(*) c FROM plays WHERE day = ? AND album != '' GROUP BY artist, album ORDER BY c DESC LIMIT 1", [day]) { r = (text($0, 0), text($0, 1)) }
        return r.map { (artist: $0.0, album: $0.1) }
    }
}

extension Entry {
    func with(album: String, image: String?) -> Entry {
        var e = Entry(kind: kind, artist: artist, album: album, track: track, plays: plays, secs: secs, image: image, rank: rank, move: move, first: first, last: last)
        e.rank = rank
        return e
    }
}

// MARK: - Track lengths, filled in quietly

// After the first read, his most played albums' track lengths are asked of Last.fm, one album at a time behind
// everything else (a screen's own questions never wait more than one turn), a few hundred per launch, kept for good.
// Listening time is shown only where most of its plays have a known length.
@MainActor final class LengthFill {
    static let shared = LengthFill()
    private var running = false
    private(set) var median = 215
    var onChange: (() -> Void)?
    func start() {
        guard !running, HistorySync.shared.complete else { return }
        running = true
        Task {
            let db = HistoryDB.shared
            median = await db.medianLength()
            var done = 0
            while done < 400 {
                let batch = await db.albumsToFill(limit: 20)
                if batch.isEmpty { break }
                for (artist, album) in batch {
                    if let j = try? await LastFM.shared.call("album.getinfo", ["artist": artist, "album": album, "autocorrect": "0"], keep: false) {
                        let list = j["album"]["tracks"]["track"].array.compactMap { t -> (String, String, Int)? in
                            guard let s = t["duration"].int, s > 0 else { return nil }
                            return (artist, t["name"].text, s)
                        }
                        await db.keepLengths(list)
                        await db.markFilled(artist, album)
                    } else if Task.isCancelled { break }
                    else { await db.markFilled(artist, album) }
                    done += 1
                    if done % 40 == 0 { median = await db.medianLength(); onChange?() }
                }
            }
            median = await db.medianLength()
            if done > 0 { onChange?() }
            running = false
        }
    }
}

// MARK: - The insights that need all of it

struct Era: Codable, Sendable, Hashable, Identifiable {
    var id: Int { from }
    let from: Int             // first month (year × 12 + month)
    let to: Int               // last month
    let artist: String
    let album: String
    let image: String?
    let plays: Int            // the artist's plays in those months
    let share: Double         // of all his plays in those months
    var months: Int { to - from + 1 }
}
struct Takeover: Codable, Sendable, Hashable, Identifiable {
    var id: Int { month }
    let month: Int
    let artist: String
    let album: String
    let image: String?
    let plays: Int
    let share: Double         // of the month
    let usual: Double         // the artist's share of everything else he's played
}
struct RiverLayer: Codable, Sendable, Hashable, Identifiable {
    var id: String { artist }
    let artist: String
    let album: String
    let image: String?
    let values: [Double]      // plays per month, smoothed, from River.from
    let total: Int
}
struct River: Codable, Sendable { let from: Int; let layers: [RiverLayer] }
struct DiscoveryYear: Codable, Sendable, Hashable, Identifiable {
    var id: Int { year }
    let year: Int
    let found: Int            // artists first played that year
    let stuck: Int            // of them, played 20 times or more and still played a year after
    let top: [ArtistCount]    // the ones that stuck, most played first
}
struct Record: Codable, Sendable, Hashable, Identifiable {
    enum What: String, Codable, Sendable { case day, track, artist }
    var id: String { what.rawValue }
    let what: What
    let day: Int
    let plays: Int
    let artist: String
    let track: String
    let album: String
    let image: String?
}
struct Carry: Codable, Sendable, Hashable, Identifiable {
    var id: Int { year }
    let year: Int
    let carried: Int          // of his top 50 that year, how many were in the year before's top 50
    let of: Int
    let soFar: Bool           // this year, still going
}
struct TimeTotals: Codable, Sendable {
    let all: Int, year: Int, month: Int, perDay: Int    // seconds
    let coverage: Double
}

struct Deep: Codable, Sendable {
    var day = 0
    var months: [Int: Int] = [:]        // every month → plays
    var median = 0                      // his median month
    var eras: [Era] = []
    var takeovers: [Takeover] = []
    var river: River?
    var discoveries: [DiscoveryYear] = []
    var records: [Record] = []
    var carry: [Carry] = []
    var time: TimeTotals?

    static var file: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(LastFM.shared.mock ? "deep-mock.json" : "deep.json") }
    static func kept() -> Deep? {
        if UserDefaults.standard.bool(forKey: "fresh") { return nil }
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Deep.self, from: $0) }
    }
    func keep() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Deep.file, options: .atomic) } }

    static func work(canon: Set<String>) async -> Deep {
        let db = HistoryDB.shared
        var d = Deep(day: LocalDay.today)
        let ma = await db.monthArtist()
        var monthTotal: [Int: Int] = [:]
        var byMonth: [Int: [(String, Int)]] = [:]
        var artistTotal: [String: Int] = [:]
        var yearArtist: [Int: [String: Int]] = [:]
        for r in ma {
            monthTotal[r.month, default: 0] += r.plays
            byMonth[r.month, default: []].append((r.artist, r.plays))
            artistTotal[r.artist, default: 0] += r.plays
            yearArtist[r.month / 12, default: [:]][r.artist, default: 0] += r.plays
        }
        d.months = monthTotal
        let sorted = monthTotal.values.sorted()
        d.median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let all = max(artistTotal.values.reduce(0, +), 1)
        let months = monthTotal.keys.sorted()
        let thisMonth = LocalDay.month(LocalDay.today)

        // The leader of each month, and eras: months in a row led by the same artist.
        var leaders: [(month: Int, artist: String, plays: Int)] = []
        for m in months {
            guard let top = byMonth[m]?.max(by: { $0.1 < $1.1 }) else { continue }
            leaders.append((m, top.0, top.1))
        }
        var runs: [(from: Int, to: Int, artist: String)] = []
        for l in leaders {
            if let last = runs.last, last.artist == l.artist, last.to == l.month - 1 { runs[runs.count - 1].to = l.month }
            else { runs.append((l.month, l.month, l.artist)) }
        }
        for r in runs where r.to > r.from {
            var plays = 0, total = 0
            for m in r.from...r.to { plays += byMonth[m]?.first { $0.0 == r.artist }?.1 ?? 0; total += monthTotal[m] ?? 0 }
            let c = await db.cover(of: r.artist)
            d.eras.append(Era(from: r.from, to: r.to, artist: r.artist, album: c?.album ?? "", image: c?.url, plays: plays, share: Double(plays) / Double(max(total, 1))))
        }
        // Takeovers: a month one artist owned, far beyond their place in the rest of his listening.
        for l in leaders where l.month != thisMonth {
            let total = monthTotal[l.month] ?? 0
            guard total >= 150 else { continue }
            let share = Double(l.plays) / Double(total)
            let rest = Double((artistTotal[l.artist] ?? 0) - l.plays) / Double(max(all - total, 1))
            guard share >= 0.3, share >= 2.5 * rest else { continue }
            let c = await db.cover(of: l.artist, from: 0)
            d.takeovers.append(Takeover(month: l.month, artist: l.artist, album: c?.album ?? "", image: c?.url, plays: l.plays, share: share, usual: rest))
        }

        // The canon's river: his staples' months, smoothed over three.
        if let first = months.first, !canon.isEmpty {
            let staples = canon.sorted { (artistTotal[$0] ?? 0) > (artistTotal[$1] ?? 0) }.prefix(12)
            let span = thisMonth - first + 1
            var layers: [RiverLayer] = []
            for a in staples {
                var raw = [Double](repeating: 0, count: span)
                for m in months where m >= first && m - first < span { raw[m - first] = Double(byMonth[m]?.first { $0.0 == a }?.1 ?? 0) }
                let smooth = raw.indices.map { i -> Double in
                    let w = [i - 1, i, i + 1].filter { $0 >= 0 && $0 < raw.count }
                    return w.reduce(0) { $0 + raw[$1] } / Double(w.count)
                }
                let c = await db.cover(of: a)
                layers.append(RiverLayer(artist: a, album: c?.album ?? "", image: c?.url, values: smooth, total: artistTotal[a] ?? 0))
            }
            d.river = River(from: first, layers: layers)
        }

        // Discoveries that stuck: each year's first plays, and which of them stayed.
        let spans = await db.artistSpans()
        let regYear = spans.map(\.first).min().map { Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval($0))) } ?? 0
        var byYear: [Int: [(String, Int, Int, Int)]] = [:]
        for s in spans {
            let y = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(s.first)))
            byYear[y, default: []].append((s.artist, s.plays, s.first, s.last))
        }
        for y in byYear.keys.sorted() where y > regYear {
            let list = byYear[y] ?? []
            let stuck = list.filter { $0.1 >= 20 && $0.3 - $0.2 >= 365 * 86400 }.sorted { $0.1 > $1.1 }
            var top: [ArtistCount] = []
            for s in stuck.prefix(8) {
                let c = await db.cover(of: s.0)
                top.append(ArtistCount(name: s.0, plays: s.1, album: c?.album ?? "", image: c?.url, first: s.2))
            }
            d.discoveries.append(DiscoveryYear(year: y, found: list.count, stuck: stuck.count, top: top))
        }

        // Record days.
        if let r = await db.recordDay() {
            let t = await db.dayTopAlbum(r.day)
            var image: String?
            if let t { image = await db.artURL(t.artist, t.album) }
            d.records.append(Record(what: .day, day: r.day, plays: r.plays, artist: t?.artist ?? "", track: "", album: t?.album ?? "", image: image))
        }
        if let r = await db.recordTrackDay() {
            d.records.append(Record(what: .track, day: r.day, plays: r.plays, artist: r.artist, track: r.track, album: r.album, image: await db.artURL(r.artist, r.album)))
        }
        if let r = await db.recordArtistDay() {
            let c = await db.cover(of: r.artist)
            d.records.append(Record(what: .artist, day: r.day, plays: r.plays, artist: r.artist, track: "", album: c?.album ?? "", image: c?.url))
        }

        // Year over year: how much of each year's top 50 was in the year before's.
        let years = yearArtist.keys.sorted()
        func top50(_ y: Int) -> Set<String> { Set((yearArtist[y] ?? [:]).sorted { $0.value > $1.value }.prefix(50).map(\.key)) }
        for y in years where y > (years.first ?? 0) && y > regYear {
            let a = top50(y), b = top50(y - 1)
            guard a.count >= 20, b.count >= 20 else { continue }
            d.carry.append(Carry(year: y, carried: a.intersection(b).count, of: a.count, soFar: y == thisMonth / 12))
        }

        // Listening time.
        let now = Int(Clock.now.timeIntervalSince1970)
        let median = await db.medianLength()
        let t = await db.time(from: 0, to: now + 1)
        if t.plays > 0 {
            let cov = Double(t.known) / Double(t.plays)
            let cal = Calendar.current
            let ys = Int(cal.dateInterval(of: .year, for: Clock.now)?.start.timeIntervalSince1970 ?? 0)
            let ms = Int(cal.dateInterval(of: .month, for: Clock.now)?.start.timeIntervalSince1970 ?? 0)
            let ty = await db.time(from: ys, to: now + 1), tm = await db.time(from: ms, to: now + 1)
            let est = { (x: (plays: Int, secs: Int, known: Int)) in x.secs + (x.plays - x.known) * median }
            let firstUts = spans.map(\.first).min() ?? now
            let daysSince = max(1, (now - firstUts) / 86400)
            d.time = TimeTotals(all: est(t), year: est(ty), month: est(tm), perDay: est(t) / daysSince, coverage: cov)
        }
        return d
    }
}

// Seconds said as he'd say them: "41 h", "2 h 10 min", "48 min".
func duration(_ secs: Int) -> String {
    let h = secs / 3600, m = (secs % 3600) / 60
    if h >= 100 { return "\(number(h)) h" }
    if h > 0 { return m > 0 && h < 10 ? "\(h) h \(m) min" : "\(h) h" }
    return "\(max(m, 1)) min"
}
func monthName(_ m: Int, year: Bool = true) -> String {
    var c = DateComponents(); c.year = m / 12; c.month = m % 12 + 1; c.day = 1
    let d = Calendar.current.date(from: c) ?? Clock.now
    return year ? d.formatted(.dateTime.month(.wide).year()) : d.formatted(.dateTime.month(.wide))
}
func monthShort(_ m: Int) -> String {
    var c = DateComponents(); c.year = m / 12; c.month = m % 12 + 1; c.day = 1
    return (Calendar.current.date(from: c) ?? Clock.now).formatted(.dateTime.month(.abbreviated).year())
}
func dayLong(_ key: Int) -> String { LocalDay.date(key).formatted(.dateTime.weekday(.wide).month(.wide).day().year()) }
func dateShort(_ uts: Int) -> String {
    let d = Date(timeIntervalSince1970: TimeInterval(uts))
    return Calendar.current.isDate(d, equalTo: Clock.now, toGranularity: .year) ? d.formatted(.dateTime.month(.abbreviated).day()) : d.formatted(.dateTime.month(.abbreviated).day().year())
}

extension HistoryDB {
    func distinct(from: Int, to: Int) -> (artists: Int, albums: Int, tracks: Int) {
        var r = (0, 0, 0)
        rows("SELECT COUNT(DISTINCT artist), COUNT(DISTINCT CASE WHEN album != '' THEN artist || char(1) || album END), COUNT(DISTINCT artist || char(1) || track) FROM plays WHERE uts >= ? AND uts < ?", [from, to]) {
            r = (int($0, 0), int($0, 1), int($0, 2))
        }
        return (artists: r.0, albums: r.1, tracks: r.2)
    }
}

extension Entry {
    // The same key HistoryDB.ranks gives a name, to find it in the stretch before.
    var rankKey: String { kind == .artists ? artist + "\u{1}" : kind == .albums ? artist + "\u{1}" + album : artist + "\u{1}" + track }
}
