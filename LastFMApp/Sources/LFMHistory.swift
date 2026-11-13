import Foundation
import SQLite3

// His whole history, on the phone. Every scrobble since he joined is read once, newest first, into a small SQLite file;
// after that only what's new is asked for. Everything the app says about him as a listener (streaks, what's rising,
// first plays, eras) is worked out here from his own plays, never from a top list someone else ranked.
private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Row: Sendable { let uts: Int; let artist: String; let album: String; let track: String; let image: String? }

enum LocalDay {
    // Days since 1970 on his own calendar, and the hour, as he lived them (the zone he was in is the one he's in now;
    // a trip abroad shifts a few hours, never a count).
    static func key(_ uts: Int) -> Int {
        let off = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(uts)))
        return Int((Double(uts + off) / 86400).rounded(.down))
    }
    static func hour(_ uts: Int) -> Int {
        let off = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(uts)))
        return ((uts + off) % 86400 + 86400) % 86400 / 3600
    }
    static func date(_ key: Int) -> Date {
        let utc = Date(timeIntervalSince1970: TimeInterval(key) * 86400)
        return utc.addingTimeInterval(-TimeInterval(TimeZone.current.secondsFromGMT(for: utc)))
    }
    static var today: Int { key(Int(Clock.now.timeIntervalSince1970)) }
}

actor HistoryDB {
    static let shared = HistoryDB()
    private var db: OpaquePointer?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = LastFM.shared.mock ? "history-mock.sqlite" : "history.sqlite"
        let url = dir.appendingPathComponent(name)
        // The build starts each launch it asks for afresh (-fresh YES), to film the first read.
        if UserDefaults.standard.bool(forKey: "fresh") { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        var h: OpaquePointer?
        if sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK { db = h }
        for sql in [
            "PRAGMA journal_mode=WAL", "PRAGMA synchronous=NORMAL",
            "CREATE TABLE IF NOT EXISTS plays(uts INTEGER NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL, track TEXT NOT NULL, day INTEGER NOT NULL, hour INTEGER NOT NULL, PRIMARY KEY(uts, artist, track)) WITHOUT ROWID",
            "CREATE INDEX IF NOT EXISTS plays_artist ON plays(artist, uts)",
            "CREATE INDEX IF NOT EXISTS plays_day ON plays(day)",
            "CREATE TABLE IF NOT EXISTS art(artist TEXT NOT NULL, album TEXT NOT NULL, url TEXT NOT NULL, PRIMARY KEY(artist, album)) WITHOUT ROWID",
            "CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL)",
        ] { sqlite3_exec(db, sql, nil, nil, nil) }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var s: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK ? s : nil
    }
    private func rows(_ sql: String, _ binds: [Any] = [], _ each: (OpaquePointer) -> Void) {
        guard let s = prepare(sql) else { return }
        defer { sqlite3_finalize(s) }
        for (i, b) in binds.enumerated() {
            if let n = b as? Int { sqlite3_bind_int64(s, Int32(i + 1), sqlite3_int64(n)) }
            else if let t = b as? String { sqlite3_bind_text(s, Int32(i + 1), t, -1, TRANSIENT) }
        }
        while sqlite3_step(s) == SQLITE_ROW { each(s) }
    }
    private func text(_ s: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
    private func int(_ s: OpaquePointer, _ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }

    func meta(_ k: String) -> String? { var v: String?; rows("SELECT v FROM meta WHERE k=?", [k]) { v = text($0, 0) }; return v }
    func setMeta(_ k: String, _ v: String) {
        guard let s = prepare("INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)") else { return }
        sqlite3_bind_text(s, 1, k, -1, TRANSIENT); sqlite3_bind_text(s, 2, v, -1, TRANSIENT)
        sqlite3_step(s); sqlite3_finalize(s)
    }

    // A page's plays and their covers, in one transaction. Plays already kept are left as they are.
    @discardableResult func insert(_ rs: [Row]) -> Int {
        guard !rs.isEmpty, let p = prepare("INSERT OR IGNORE INTO plays(uts, artist, album, track, day, hour) VALUES(?,?,?,?,?,?)"),
              let a = prepare("INSERT OR IGNORE INTO art(artist, album, url) VALUES(?,?,?)") else { return 0 }
        defer { sqlite3_finalize(p); sqlite3_finalize(a) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var added = 0
        for r in rs {
            sqlite3_reset(p)
            sqlite3_bind_int64(p, 1, sqlite3_int64(r.uts))
            sqlite3_bind_text(p, 2, r.artist, -1, TRANSIENT); sqlite3_bind_text(p, 3, r.album, -1, TRANSIENT); sqlite3_bind_text(p, 4, r.track, -1, TRANSIENT)
            sqlite3_bind_int64(p, 5, sqlite3_int64(LocalDay.key(r.uts))); sqlite3_bind_int64(p, 6, sqlite3_int64(LocalDay.hour(r.uts)))
            if sqlite3_step(p) == SQLITE_DONE, sqlite3_changes(db) > 0 { added += 1 }
            if let u = r.image, !r.album.isEmpty {
                sqlite3_reset(a)
                sqlite3_bind_text(a, 1, r.artist, -1, TRANSIENT); sqlite3_bind_text(a, 2, r.album, -1, TRANSIENT); sqlite3_bind_text(a, 3, u, -1, TRANSIENT)
                sqlite3_step(a)
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return added
    }

    func count() -> Int { var n = 0; rows("SELECT COUNT(*) FROM plays") { n = int($0, 0) }; return n }
    func newest() -> Int? { var n: Int?; rows("SELECT MAX(uts) FROM plays") { n = sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : int($0, 0) }; return n }
    func dayCounts() -> [Int: Int] { var d: [Int: Int] = [:]; rows("SELECT day, COUNT(*) FROM plays GROUP BY day") { d[int($0, 0)] = int($0, 1) }; return d }
    func hourCounts(since: Int = 0) -> [Int] { var h = [Int](repeating: 0, count: 24); rows("SELECT hour, COUNT(*) FROM plays WHERE uts >= ? GROUP BY hour", [since]) { h[max(0, min(23, int($0, 0)))] = int($0, 1) }; return h }
    func between(_ a: Int, _ b: Int) -> Int { var n = 0; rows("SELECT COUNT(*) FROM plays WHERE uts >= ? AND uts < ?", [a, b]) { n = int($0, 0) }; return n }
    func artists(from: Int, to: Int, limit: Int) -> [(String, Int)] {
        var out: [(String, Int)] = []
        rows("SELECT artist, COUNT(*) c FROM plays WHERE uts >= ? AND uts < ? GROUP BY artist ORDER BY c DESC LIMIT ?", [from, to, limit]) { out.append((text($0, 0), int($0, 1))) }
        return out
    }
    func plays(of artist: String, from: Int, to: Int) -> Int { var n = 0; rows("SELECT COUNT(*) FROM plays WHERE artist = ? AND uts >= ? AND uts < ?", [artist, from, to]) { n = int($0, 0) }; return n }
    func firstPlay(of artist: String) -> Int? { var n: Int?; rows("SELECT MIN(uts) FROM plays WHERE artist = ?", [artist]) { n = sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : int($0, 0) }; return n }
    // His most played album by an artist in a window, and its cover if one was ever seen.
    func cover(of artist: String, from: Int = 0) -> (album: String, url: String?)? {
        var album: String?
        rows("SELECT album, COUNT(*) c FROM plays WHERE artist = ? AND uts >= ? AND album != '' GROUP BY album ORDER BY c DESC LIMIT 1", [artist, from]) { album = text($0, 0) }
        guard let album else { return nil }
        var url: String?
        rows("SELECT url FROM art WHERE artist = ? AND album = ?", [artist, album]) { url = text($0, 0) }
        return (album, url)
    }
    func artURL(_ artist: String, _ album: String) -> String? { var u: String?; rows("SELECT url FROM art WHERE artist = ? AND album = ?", [artist, album]) { u = text($0, 0) }; return u }
    // How many calendar months had any music, and each artist heard in at least `min` of them: his canon.
    private var canonKept: (count: Int, months: Int, names: Set<String>, day: Int)?
    func canon(share: Double = 0.6) -> (months: Int, names: Set<String>) {
        let n = count(), today = LocalDay.today
        if let k = canonKept, k.day == today, abs(k.count - n) < 500 { return (k.months, k.names) }
        var months = 0
        rows("SELECT COUNT(DISTINCT strftime('%Y-%m', uts, 'unixepoch', 'localtime')) FROM plays") { months = int($0, 0) }
        var names = Set<String>()
        rows("SELECT artist, COUNT(DISTINCT strftime('%Y-%m', uts, 'unixepoch', 'localtime')) m FROM plays GROUP BY artist HAVING m >= ?", [max(1, Int((Double(months) * share).rounded(.up)))]) { names.insert(text($0, 0)) }
        canonKept = (n, months, names, today)
        return (months, names)
    }
    // Artists first heard after a moment, with how much since.
    func discoveries(since: Int, minPlays: Int) -> [(String, Int, Int)] {
        var out: [(String, Int, Int)] = []
        rows("SELECT artist, MIN(uts) f, COUNT(*) c FROM plays GROUP BY artist HAVING f >= ? AND c >= ? ORDER BY c DESC LIMIT 12", [since, minPlays]) { out.append((text($0, 0), int($0, 1), int($0, 2))) }
        return out
    }
}

// MARK: - Reading the history in

// The first read: every page of his scrobbles, 200 at a time, newest first, up to four on their way at once within
// Last.fm's pace. The pages are counted back from a moment pinned at the start, so page 731 means the same plays
// tomorrow, and a read left half done (the app closed, the network gone) carries on where it was. Newest first means the
// last few months, which most of what he looks at needs, arrive in the first seconds.
@MainActor @Observable final class HistorySync {
    static let shared = HistorySync()
    private(set) var total = 0                  // scrobbles to read, as Last.fm counted them at the pin
    private(set) var read = 0                   // scrobbles read so far
    private(set) var complete = false
    private(set) var running = false
    private(set) var years: [Int: Int] = [:]   // plays per year read so far: the read draws his years as it goes
    private(set) var coveredFrom: Int = .max    // every play from this moment to now is on the phone
    private(set) var stuckSince: Date?          // the read has been failing since
    @ObservationIgnored var onProgress: (() -> Void)?
    @ObservationIgnored private var done: [Bool] = []
    @ObservationIgnored private var pageOldest: [Int: Int] = [:]
    @ObservationIgnored private var pin = 0

    // What the read had reached, from the last launch: the first frame shows it, not "0%" until the database answers.
    private init() {
        let d = UserDefaults.standard
        if d.bool(forKey: "fresh") { d.removeObject(forKey: "history.state"); return }
        guard let s = d.dictionary(forKey: "history.state") else { return }
        complete = s["complete"] as? Bool ?? false
        total = s["total"] as? Int ?? 0
        read = s["read"] as? Int ?? 0
        coveredFrom = s["coveredFrom"] as? Int ?? .max
        years = ((s["years"] as? [String: Int]) ?? [:]).reduce(into: [:]) { if let y = Int($1.key) { $0[y] = $1.value } }
    }
    private func save() {
        UserDefaults.standard.set(["complete": complete, "total": total, "read": read, "coveredFrom": coveredFrom,
                                   "years": years.reduce(into: [String: Int]()) { $0[String($1.key)] = $1.value }], forKey: "history.state")
    }

    var fraction: Double { total == 0 ? 0 : min(1, Double(read) / Double(total)) }

    func start() {
        guard !running else { return }
        running = true
        Task {
            await load()
            onProgress?()
            if !complete { await firstRead() }
            if complete { await catchUp() }
            running = false
        }
    }

    private func load() async {
        let db = HistoryDB.shared
        complete = await db.meta("complete") == "1"
        pin = Int(await db.meta("pin") ?? "") ?? 0
        total = Int(await db.meta("total") ?? "") ?? 0
        coveredFrom = Int(await db.meta("coveredFrom") ?? "") ?? .max
        if let d = await db.meta("done") { done = d.map { $0 == "1" } }
        read = await db.count()
        if read > 0 { years = Dictionary(grouping: await db.dayCounts(), by: { Calendar.current.component(.year, from: LocalDay.date($0.key)) }).mapValues { $0.reduce(0) { $0 + $1.value } } }
        if complete { coveredFrom = 0 }
        save()
    }

    private func parse(_ j: J) -> [Row] {
        j["recenttracks"]["track"].array.compactMap { t in
            guard !t["@attr"]["nowplaying"].bool, let uts = t["date"]["uts"].int else { return nil }
            return Row(uts: uts, artist: t["artist"]["name"].string ?? t["artist"].text, album: t["album"].text, track: t["name"].text, image: Scrobble.bestImage(t["image"]))
        }
    }

    private func firstRead() async {
        let db = HistoryDB.shared
        if pin == 0 || done.isEmpty {
            pin = Int(Clock.now.timeIntervalSince1970)
            guard let j = try? await LastFM.shared.call("user.getrecenttracks", ["limit": "200", "page": "1", "to": "\(pin)"], keep: false) else { stuck(); return }
            let pages = j["recenttracks"]["@attr"]["totalPages"].int ?? 0
            total = j["recenttracks"]["@attr"]["total"].int ?? 0
            done = [Bool](repeating: false, count: max(pages, 0))
            await db.setMeta("pin", "\(pin)"); await db.setMeta("total", "\(total)")
            if pages > 0 { await take(1, parse(j)) }
        }
        // The pages still to read, in order; four readers take the next one each as they finish.
        nextPage = 0
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<4 {
                g.addTask { @MainActor in
                    while let p = self.claim() {
                        var tries = 0
                        while true {
                            if let j = try? await LastFM.shared.call("user.getrecenttracks", ["limit": "200", "page": "\(p)", "to": "\(self.pin)"], keep: false) {
                                await self.take(p, self.parse(j)); self.stuckSince = nil; break
                            }
                            tries += 1
                            self.stuck()
                            try? await Task.sleep(nanoseconds: UInt64(min(30, pow(2, Double(tries)))) * 1_000_000_000)
                        }
                    }
                }
            }
        }
        if !done.isEmpty, done.allSatisfy({ $0 }) {
            complete = true; coveredFrom = 0
            await db.setMeta("complete", "1")
            save()
            onProgress?()
        }
    }

    @ObservationIgnored private var nextPage = 0
    private func claim() -> Int? {
        while nextPage < done.count { nextPage += 1; if !done[nextPage - 1] { return nextPage } }
        return nil
    }

    private func stuck() { if stuckSince == nil { stuckSince = Date() } }

    // One page in: kept, counted, drawn into its year, and the stretch read without a gap moved back if it joins up.
    private func take(_ page: Int, _ rows: [Row]) async {
        let db = HistoryDB.shared
        let added = await db.insert(rows)
        read += added
        for r in rows { years[Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(r.uts))), default: 0] += 1 }
        guard page - 1 < done.count else { return }
        done[page - 1] = true
        pageOldest[page] = rows.map(\.uts).min() ?? pin
        var k = 0
        while k < done.count && done[k] { k += 1 }
        // The pages before the first gap, read whole: everything since the oldest play on the last of them is here.
        if k > 0, let oldest = pageOldest[k] ?? (k == done.count ? 0 : nil) { coveredFrom = k == done.count ? 0 : min(coveredFrom, oldest) }
        if page % 8 == 0 || k == done.count {
            save()
            await db.setMeta("done", String(done.map { $0 ? "1" : "0" }))
            if coveredFrom != .max { await db.setMeta("coveredFrom", "\(coveredFrom)") }
        }
        onProgress?()
    }

    // After the first read, only what's new since the newest play kept.
    func catchUp() async {
        let db = HistoryDB.shared
        guard let newest = await db.newest() else { return }
        var page = 1
        while page < 50 {
            guard let j = try? await LastFM.shared.call("user.getrecenttracks", ["limit": "200", "page": "\(page)", "from": "\(newest + 1)"], keep: false) else { return }
            let rows = parse(j)
            read += await db.insert(rows)
            let pages = j["recenttracks"]["@attr"]["totalPages"].int ?? 1
            if page >= pages || rows.isEmpty { break }
            page += 1
        }
        save()
        onProgress?()
    }

    // Plays the app saw arrive while it was open.
    func keep(_ s: [Scrobble]) async {
        let rows = s.compactMap { x -> Row? in x.date.map { Row(uts: Int($0.timeIntervalSince1970), artist: x.artist, album: x.album, track: x.title, image: x.image) } }
        read += await HistoryDB.shared.insert(rows)
    }
}

// MARK: - What it says about him

struct ArtistCount: Identifiable, Hashable, Sendable, Codable { var id: String { name }; let name: String; let plays: Int; var album: String = ""; var image: String? = nil; var isNew = false }

struct Band: Sendable, Codable { let lo: Int; let mid: Int; let hi: Int }
struct Pace: Sendable, Codable {
    let days: Int                     // days of this week so far, today included
    let now: Int                      // plays this week so far
    let usual: Int                    // the median of the weeks before at the same moment
    let weeks: Int                    // how many weeks before it was measured against
    let thisWeek: [Int]               // plays by day, cumulative, through today
    let usualBand: [Band]             // the weeks before, cumulative by day: middle half and median
    let lastWeek: [Int]
    var delta: Double { usual == 0 ? 0 : Double(now - usual) / Double(usual) }
}

// The artists that are always there: heard in at least six of every ten months he's listened, and how much of this
// week went to them.
struct Canon: Sendable, Codable {
    let artists: Int
    let months: Int
    let weekPlays: Int
    let weekTotal: Int
    let thisWeek: [ArtistCount]       // the canon's artists heard in the last seven days, most played first
    var share: Double { weekTotal == 0 ? 0 : Double(weekPlays) / Double(weekTotal) }
}

struct Rising: Sendable, Codable {
    let artist: String
    let album: String
    let image: String?
    let weekShare: Double             // of his plays in the last seven days
    let yearShare: Double             // of his plays in the year before that
    let weekPlays: Int
}

struct Insights: Sendable, Codable {
    var coveredFrom = Int.max
    var complete = false
    var days: [Int: Int] = [:]
    var streak: Int?
    var best: Int?
    var pace: Pace?
    var rising: Rising?
    var week: [ArtistCount] = []
    var discoveries: [ArtistCount] = []
    var hours: [Int] = []             // all his plays by hour of the day
    var hoursWeek: [Int] = []         // the last seven days by hour
    var dayStart = 6                  // his quietest hour: where his day begins
    var canon: Canon?

    // The last worked out, kept, so the first frame of a launch shows them; they're worked out again behind it.
    static var file: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(LastFM.shared.mock ? "insights-mock.json" : "insights.json") }
    static func kept() -> Insights? {
        if UserDefaults.standard.bool(forKey: "fresh") { return nil }
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Insights.self, from: $0) }
    }
    func keep() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Insights.file, options: .atomic) } }

    static func work(coveredFrom: Int, complete: Bool) async -> Insights {
        let db = HistoryDB.shared
        var s = Insights(coveredFrom: coveredFrom, complete: complete)
        guard coveredFrom != .max else { return s }
        let now = Int(Clock.now.timeIntervalSince1970)
        let cal = Calendar.current
        s.days = await db.dayCounts()
        // His clock: all of it, and the last seven days. His day starts at its quietest hour (a night owl's midnight is
        // the middle of his evening), once there's enough to know.
        s.hours = await db.hourCounts()
        s.hoursWeek = await db.hourCounts(since: now - 7 * 86400)
        if s.hours.reduce(0, +) > 2000, let q = s.hours.indices.min(by: { s.hours[$0] < s.hours[$1] }) { s.dayStart = q }
        let today = LocalDay.today
        let coveredDay = complete ? Int.min : LocalDay.key(coveredFrom) + 1

        // The streak: days in a row with something played, counting today once it has a play, or from yesterday until
        // it does (it isn't broken until the day is over). Known once the day it began after is read.
        var d = (s.days[today] ?? 0) > 0 ? today : today - 1
        var run = 0
        while (s.days[d] ?? 0) > 0 && d >= coveredDay { run += 1; d -= 1 }
        if d >= coveredDay { s.streak = run }
        if complete {
            var best = 0, cur = 0, last = Int.min
            for k in s.days.keys.sorted() where (s.days[k] ?? 0) > 0 { cur = k == last + 1 ? cur + 1 : 1; best = max(best, cur); last = k }
            s.best = best
        }

        // This week against his usual: each of the eight weeks before, measured to the same moment of its week.
        if let ws = cal.dateInterval(of: .weekOfYear, for: Clock.now)?.start {
            let start = Int(ws.timeIntervalSince1970)
            let elapsed = now - start
            let wsDay = LocalDay.key(start)
            let daysIn = min(7, today - wsDay + 1)
            var weeksBefore: [(Int, [Int])] = []
            for k in 1...8 {
                guard let b = cal.date(byAdding: .weekOfYear, value: -k, to: ws) else { continue }
                let bs = Int(b.timeIntervalSince1970)
                guard complete || bs >= coveredFrom else { break }
                let atMoment = await db.between(bs, bs + elapsed)
                let bDay = LocalDay.key(bs)
                var cum: [Int] = [], acc = 0
                for i in 0..<7 { acc += s.days[bDay + i] ?? 0; cum.append(acc) }
                weeksBefore.append((atMoment, cum))
            }
            if weeksBefore.count >= 4 {
                var cum: [Int] = [], acc = 0
                for i in 0..<daysIn { acc += s.days[wsDay + i] ?? 0; cum.append(acc) }
                let moments = weeksBefore.map(\.0).sorted()
                let band = (0..<7).map { i -> Band in
                    let v = weeksBefore.map { $0.1[i] }.sorted()
                    return Band(lo: v[v.count / 4], mid: v[v.count / 2], hi: v[(v.count * 3) / 4])
                }
                s.pace = Pace(days: daysIn, now: await db.between(start, now + 1), usual: moments[moments.count / 2], weeks: weeksBefore.count,
                              thisWeek: cum, usualBand: band, lastWeek: weeksBefore[0].1)
            }
        }

        // This week's artists, the last seven days rolling, and the one taking over: a much bigger share of the week
        // than of the year before it.
        let weekFrom = now - 7 * 86400
        if complete || coveredFrom <= weekFrom {
            let top = await db.artists(from: weekFrom, to: now + 1, limit: 20)
            let weekTotal = await db.between(weekFrom, now + 1)
            var list: [ArtistCount] = []
            for (name, n) in top {
                let c = await db.cover(of: name, from: weekFrom)
                list.append(ArtistCount(name: name, plays: n, album: c?.album ?? "", image: c?.url))
            }
            let yearFrom = weekFrom - 365 * 86400
            if complete || coveredFrom <= yearFrom, weekTotal > 0 {
                let yearTotal = await db.between(yearFrom, weekFrom)
                var best: (Rising, Double)?
                for a in list.prefix(10) where a.plays >= 15 {
                    let share = Double(a.plays) / Double(weekTotal)
                    let usual = yearTotal == 0 ? 0 : Double(await db.plays(of: a.name, from: yearFrom, to: weekFrom)) / Double(yearTotal)
                    let lift = share / max(usual, 0.002)
                    guard share >= 0.08, lift >= 3 else { continue }
                    let score = share * log(lift)
                    if score > (best?.1 ?? 0) { best = (Rising(artist: a.name, album: a.album, image: a.image, weekShare: share, yearShare: usual, weekPlays: a.plays), score) }
                }
                s.rising = best?.0
            }
            // First heard in the last month, and played enough to count: only with the whole history read, since a first
            // play is only first if nothing older exists.
            if complete {
                let found = await db.discoveries(since: now - 30 * 86400, minPlays: 8)
                let newNames = Set(found.map(\.0))
                for i in list.indices where newNames.contains(list[i].name) { list[i].isNew = true }
                for (name, _, n) in found.prefix(6) {
                    let c = await db.cover(of: name)
                    s.discoveries.append(ArtistCount(name: name, plays: n, album: c?.album ?? "", image: c?.url, isNew: true))
                }
            }
            if complete, weekTotal > 0 {
                let (months, names) = await db.canon()
                if months >= 6, !names.isEmpty {
                    let mine = list.filter { names.contains($0.name) }
                    var inCanon = 0
                    for (name, n) in await db.artists(from: weekFrom, to: now + 1, limit: 400) where names.contains(name) { inCanon += n }
                    s.canon = Canon(artists: names.count, months: months, weekPlays: inCanon, weekTotal: weekTotal, thisWeek: mine)
                }
            }
            s.week = list
        }
        return s
    }
}
