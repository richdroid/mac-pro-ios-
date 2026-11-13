import Foundation

// The build's stand-in for Last.fm: a heavy listener made up from the bundled catalog (Mock/catalog.json, invented
// artists, generated covers) plus a long tail of invented names, answering in Last.fm's own JSON so every screen reads
// the real shapes. Nothing in it is anyone's real listening.
//
// The whole history since 2017 is made once, the way a life of listening is shaped: staples heard every month for
// years, eras that swell for a year and fade, obsessions that take over for a few weeks, discoveries with a first play,
// a night owl's day, more at weekends, a few days off in the early years and none lately. Every number the app works out
// (streaks, eras, what's rising, first plays) comes from these plays, so they agree the way real ones do.
final class MockLastFM: @unchecked Sendable {
    static let shared = MockLastFM()

    struct Album { let name: String; let art: String; let tracks: [String]; let year: Int }
    struct Artist { let name: String; let weight: Double; let albums: [Album]; let listeners: Int; let tags: [String] }
    struct Play { let uts: Int; let artist: Int; let album: Int; let track: Int }

    private(set) var artists: [Artist] = []
    private var plays: [Play] = []           // newest first
    private var queue: [Play] = []           // what plays next, for the films where a new song arrives
    private var current: Play?
    private var profile: [String: Any] = [:]
    private var rising = 0, discovery = 0
    private let lock = NSLock()
    var profileName: String { profile["name"] as? String ?? "listener" }
    // His name alone, from the catalog, without making the history (which takes seconds, and never on the main thread).
    static var catalogName: String {
        guard let u = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Mock"),
              let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) else { return "listener" }
        return J(o)["profile"]["name"].string ?? "listener"
    }
    // -playing NO: nothing on right now (the "last played" state).
    private let playing = UserDefaults.standard.object(forKey: "playing") == nil || UserDefaults.standard.bool(forKey: "playing")
    // -mockAdvance N: every N seconds the song on now is scrobbled and the next begins.
    private let advance = UserDefaults.standard.double(forKey: "mockAdvance")

    private init() {
        guard let u = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Mock"),
              let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) else { return }
        let j = J(o)
        artists = j["artists"].array.map { a in
            Artist(name: a["name"].text, weight: (a["weight"].v as? Double) ?? 1, albums: a["albums"].array.map {
                Album(name: $0["name"].text, art: $0["art"].text, tracks: $0["tracks"].array.map(\.text), year: $0["year"].int ?? 2020)
            }, listeners: a["listeners"].int ?? 50_000, tags: a["tags"].array.map(\.text))
        }
        profile = (j["profile"].v as? [String: Any]) ?? [:]
        rising = artists.firstIndex { $0.name == j["rising"].text } ?? 0
        discovery = artists.firstIndex { $0.name == j["discovery"].text } ?? 0
        LaunchLog.mark("mock making")
        if !artists.isEmpty { addTail(); makeHistory() }
        LaunchLog.mark("mock made")
    }

    // SplitMix64: the same history on every run.
    private struct Rand {
        var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    // A long tail: hundreds of names heard a handful of times each, as any heavy listener has.
    private var core = 0
    private func addTail() {
        core = artists.count
        var r = Rand(s: 77)
        let first = ["Ada", "Theo", "Mara", "Jonah", "Lena", "Felix", "Iris", "Otto", "Nina", "Cal", "Ruth", "Milo", "Esme", "Hugo", "Wren", "Remy", "Jules", "Clara", "Ezra", "Lou"]
        let last = ["Hart", "Lindqvist", "Moreau", "Vance", "Okafor", "Bell", "Strand", "Novak", "Reyes", "Quill", "Ambrose", "Frey", "Castell", "Doyle", "Marsh", "Kade", "Sato", "Ferro", "Lisle", "Penn"]
        let a1 = ["Velvet", "Paper", "Static", "Northern", "Golden", "Hollow", "Glass", "Silver", "Neon", "Quiet", "Wild", "Lunar", "Copper", "Amber", "Coral", "Ivory", "Cobalt", "Saffron", "Indigo", "Ember"]
        let a2 = ["Saints", "Arcade", "Harbour", "Parade", "Society", "Machines", "Gardens", "Rivals", "Satellites", "Animals", "Cathedral", "Engines", "Lovers", "Atlas", "Season", "Choir", "Theatre", "Motel", "Cinema", "Orchard"]
        let covers = Array(Set(artists.flatMap { $0.albums.map(\.art) })).sorted()
        let pool = artists.flatMap { $0.albums.flatMap(\.tracks) }
        var names = Set(artists.map(\.name))
        while artists.count < core + 1100 {
            let name: String
            switch r.int(3) {
            case 0: name = "\(first[r.int(20)]) \(last[r.int(20)])"
            case 1: name = "The \(a1[r.int(20)]) \(a2[r.int(20)])"
            default: name = "\(a1[r.int(20)]) \(a2[r.int(20)])"
            }
            guard names.insert(name).inserted else { continue }
            let tracks = (0..<(5 + r.int(6))).map { _ in pool[r.int(pool.count)] }
            let album = Album(name: "\(a1[r.int(20)]) \(a2[r.int(20)])", art: covers[r.int(covers.count)], tracks: Array(Set(tracks)), year: 2005 + r.int(21))
            artists.append(Artist(name: name, weight: 0.02 + r.unit() * 0.12, albums: [album], listeners: 2_000 + r.int(400_000), tags: ["indie"]))
        }
    }

    private func makeHistory() {
        var r = Rand(s: 20261113)
        let cal = Calendar.current
        let now = Clock.now
        let nowUts = Int(now.timeIntervalSince1970)
        let today = cal.startOfDay(for: now)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let reg = Date(timeIntervalSince1970: TimeInterval(profile["registered"] as? Int ?? 1_488_326_400))
        let totalDays = max(1, cal.dateComponents([.day], from: cal.startOfDay(for: reg), to: today).day ?? 1)
        // A night owl: a little on the way to work, more in the afternoon, most after ten.
        let hours: [Double] = [3.2, 2.0, 1.0, 0.4, 0.1, 0.1, 0.5, 1.6, 1.8, 1.0, 0.8, 1.0, 1.4, 1.2, 1.3, 1.6, 2.0, 2.2, 2.0, 2.4, 2.9, 3.4, 3.8, 3.6]
        // Each artist's life in his listening, by day since registering: when it began, and its shape after.
        enum Shape { case staple, era(Int, Int), obsession(Int), tail(Int) }
        var start = [Int](repeating: 0, count: artists.count)
        var shape = [Shape](repeating: .staple, count: artists.count)
        for i in artists.indices {
            if i >= core { let s = r.int(totalDays); start[i] = s; shape[i] = .tail(30 + r.int(500)); continue }
            switch i % 5 {
            case 0, 3: start[i] = r.int(totalDays / 4); shape[i] = .staple
            case 1: let s = r.int(totalDays * 2 / 3); start[i] = s; shape[i] = .era(s + 120 + r.int(200), 160 + r.int(200))
            case 2: let s = r.int(totalDays - 120); start[i] = s; shape[i] = .obsession(s + 20 + r.int(30))
            default: start[i] = totalDays / 3 + r.int(totalDays / 2); shape[i] = .staple
            }
        }
        start[rising] = totalDays / 5
        shape[rising] = .staple
        start[discovery] = totalDays - 4
        shape[discovery] = .staple
        func weight(_ i: Int, _ day: Int) -> Double {
            guard day >= start[i] else { return 0 }
            let back = totalDays - day
            if i == rising { return back <= 6 ? 7 : artists[i].weight * 0.6 }
            if i == discovery { return 4 }
            let w = artists[i].weight
            switch shape[i] {
            case .staple: return w * (0.75 + 0.25 * sin(Double(day) / 90 + Double(i)))
            case .era(let peak, let width): let x = Double(day - peak) / Double(width); return w * (0.12 + 2.6 * exp(-x * x))
            case .obsession(let peak): let x = Double(day - peak) / 22; return w * (0.05 + 9 * exp(-x * x))
            case .tail(let life): return day - start[i] < life ? w : w * 0.05
            }
        }
        var out: [Play] = []
        out.reserveCapacity(200_000)
        var cumulative: [Double] = []
        for day in 0...totalDays {
            guard let date = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: reg)) else { continue }
            let back = totalDays - day
            // Weights change slowly; worked out again every few days.
            if day % 4 == 0 || cumulative.isEmpty || back <= 7 {
                var acc = 0.0
                cumulative = artists.indices.map { acc += weight($0, day); return acc }
            }
            // Days off: some in the early years, one 47 days ago, none since.
            let year = Double(day) / 365
            if back == 47 { continue }
            if back > 47, r.unit() < max(0.02, 0.12 - year * 0.015) { continue }
            var target = Int((28 + year * 6.5) * (0.6 + r.unit() * 0.8))
            let weekday = cal.component(.weekday, from: date)
            if weekday == 1 || weekday == 7 { target = Int(Double(target) * 1.25) }
            if date >= weekStart { target = Int(Double(target) * 1.2) }
            var made = 0, sessions = 0
            // Today, only the hours already lived.
            let nowHour = cal.component(.hour, from: now)
            let dayHours = back == 0 ? hours.enumerated().map { $0.offset <= nowHour ? $0.element : 0 } : hours
            while made < target && sessions < 400 {
                sessions += 1
                // A session: one artist, an album in order, sometimes on to the next.
                let h = pick(dayHours, &r)
                var t = date.addingTimeInterval(Double(h) * 3600 + Double(r.int(3600)))
                let x = r.unit() * (cumulative.last ?? 1)
                var lo = 0, hi = cumulative.count - 1
                while lo < hi { let m = (lo + hi) / 2; if cumulative[m] < x { lo = m + 1 } else { hi = m } }
                let a = lo
                var al = r.int(artists[a].albums.count)
                var tr = r.int(max(1, artists[a].albums[al].tracks.count / 2))
                let len = a >= core ? 1 + r.int(3) : 4 + r.int(9)
                for _ in 0..<len where made < target {
                    if Int(t.timeIntervalSince1970) >= nowUts { break }
                    out.append(Play(uts: Int(t.timeIntervalSince1970), artist: a, album: al, track: tr))
                    made += 1
                    t = t.addingTimeInterval(170 + Double(r.int(110)))
                    tr += 1
                    if tr >= artists[a].albums[al].tracks.count { al = (al + 1) % artists[a].albums.count; tr = 0 }
                }
            }
        }
        // Sessions overlap; one phone plays one song at a time, so a scrobble every two and a half minutes at most.
        out.sort { $0.uts < $1.uts }
        var spaced: [Play] = []
        spaced.reserveCapacity(out.count)
        var last = 0
        for p in out {
            let u = max(p.uts, last + 150)
            if u < nowUts - 60 { spaced.append(Play(uts: u, artist: p.artist, album: p.album, track: p.track)); last = u }
        }
        plays = spaced.reversed()
        // What's on now, and what follows, continuing the last session.
        var n = plays.first ?? Play(uts: 0, artist: 0, album: 0, track: 0)
        var upcoming: [Play] = []
        for _ in 0..<40 {
            let al = artists[n.artist].albums[n.album]
            n = n.track + 1 < al.tracks.count ? Play(uts: 0, artist: n.artist, album: n.album, track: n.track + 1)
                : Play(uts: 0, artist: rising, album: r.int(artists[rising].albums.count), track: 0)
            upcoming.append(n)
        }
        current = upcoming.first
        queue = Array(upcoming.dropFirst())
    }

    private func pick(_ w: [Double], _ r: inout Rand) -> Int {
        var x = r.unit() * w.reduce(0, +)
        for (i, v) in w.enumerated() { x -= v; if x <= 0 { return i } }
        return w.count - 1
    }

    // The song on now advances with the clock in the films that ask for it.
    private func tick() {
        guard advance > 0, playing, current != nil else { return }
        let due = Int(Date().timeIntervalSince(Clock.launched) / advance)
        let done = 39 - queue.count
        guard due > done else { return }
        for _ in 0..<(due - done) where !queue.isEmpty {
            if let p = current { plays.insert(Play(uts: Int(Clock.now.timeIntervalSince1970) - 5, artist: p.artist, album: p.album, track: p.track), at: 0) }
            current = queue.removeFirst()
        }
    }

    // Plays newest first: the index range between two times, by halving.
    private func span(from: Int, to: Int) -> Range<Int> {
        func firstAtOrBelow(_ u: Int) -> Int { var lo = 0, hi = plays.count; while lo < hi { let m = (lo + hi) / 2; if plays[m].uts > u { lo = m + 1 } else { hi = m } }; return lo }
        let a = firstAtOrBelow(to), b = firstAtOrBelow(from - 1)
        return a..<max(a, b)
    }

    // A song's length, the same every time it's asked.
    static func length(_ title: String) -> Int { 150 + hash(title) % 170 }
    static func hash(_ s: String) -> Int { Int(s.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % 1_000_000) }
    // Artists he's never played, for what's similar and what to discover.
    static let invented = ["Marrow Lane", "The Paper Kites Club", "Juniper Static", "Hollis Wren", "Saltwater Hymns", "Night Ferry", "Opal Sisters",
                           "Low Orbit Choir", "Fennel & Frost", "The Quiet Arcade", "Dovetail Radio", "Ines Marlowe", "Cardinal Drift", "Sunday Engines",
                           "Willow Static", "The Long Afternoons", "Pale Harbour", "Kestrel Bloom", "Mona Vale", "Tin Cathedral"]

    // MARK: Replies, in Last.fm's shapes
    private func image(_ art: String) -> [[String: String]] {
        ["small", "medium", "large", "extralarge"].map { ["size": $0, "#text": "mock://\(art)"] }
    }
    private func loved(_ p: Play) -> Bool { p.artist < core && (p.artist * 7 + p.track * 3) % 11 == 0 }
    private func trackJSON(_ p: Play, now: Bool = false, extended: Bool) -> [String: Any] {
        let a = artists[p.artist], al = a.albums[p.album]
        var t: [String: Any] = [
            "name": al.tracks[p.track],
            "artist": extended ? ["name": a.name, "url": ""] : ["#text": a.name],
            "album": ["#text": al.name],
            "image": image(al.art),
            "url": "https://www.last.fm/music/\(a.name.replacingOccurrences(of: " ", with: "+"))",
        ]
        if extended { t["loved"] = loved(p) ? "1" : "0" }
        if now { t["@attr"] = ["nowplaying": "true"] } else { t["date"] = ["uts": "\(p.uts)", "#text": ""] }
        return t
    }
    private func page(_ params: [String: String]) -> (Int, Int) { (max(1, Int(params["page"] ?? "1") ?? 1), max(1, min(200, Int(params["limit"] ?? "50") ?? 50))) }
    private func counts(_ range: Range<Int>) -> [Int: Int] {
        var c: [Int: Int] = [:]
        for k in range { c[plays[k].artist, default: 0] += 1 }
        return c
    }

    func respond(_ method: String, _ params: [String: String]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        tick()
        let nowUts = Int(Clock.now.timeIntervalSince1970)
        switch method {
        case "user.getinfo":
            var p = profile
            p["registered"] = ["unixtime": "\(profile["registered"] ?? 0)", "#text": profile["registered"] ?? 0]
            p["image"] = image(profile["avatar"] as? String ?? "avatar")
            p["playcount"] = "\(plays.count)"
            p["artist_count"] = "\(Set(plays.map(\.artist)).count)"
            p["album_count"] = "\(Set(plays.map { $0.artist * 8 + $0.album }).count)"
            p["track_count"] = "\(Set(plays.map { $0.artist * 4096 + $0.album * 64 + $0.track }).count)"
            p["url"] = "https://www.last.fm/user/\(profileName)"
            return ["user": p]
        case "user.getrecenttracks":
            let from = Int(params["from"] ?? "") ?? 0, to = Int(params["to"] ?? "") ?? Int.max
            let range = span(from: from, to: to)
            let (pg, limit) = page(params)
            let lo = min(range.upperBound, range.lowerBound + (pg - 1) * limit), hi = min(range.upperBound, lo + limit)
            let ext = params["extended"] == "1"
            var list = (lo..<hi).map { trackJSON(plays[$0], extended: ext) }
            if pg == 1, playing, params["to"] == nil, let c = current { list.insert(trackJSON(c, now: true, extended: ext), at: 0) }
            let total = range.count
            return ["recenttracks": ["track": list, "@attr": ["user": profileName, "page": "\(pg)", "perPage": "\(limit)", "total": "\(total)", "totalPages": "\(max(1, (total + limit - 1) / limit))"]]]
        case "user.gettopartists", "user.gettopalbums":
            let days = ["7day": 7, "1month": 30, "3month": 90, "6month": 180, "12month": 365][params["period"] ?? "overall"]
            let c = counts(span(from: days.map { nowUts - $0 * 86400 } ?? 0, to: nowUts))
            let totals = c.sorted { $0.value > $1.value }
            let (pg, limit) = page(params)
            let slice = totals.dropFirst((pg - 1) * limit).prefix(limit)
            if method == "user.gettopartists" {
                let list: [[String: Any]] = slice.enumerated().map { k, e in
                    ["name": artists[e.key].name, "playcount": "\(e.value)", "@attr": ["rank": "\((pg - 1) * limit + k + 1)"], "image": image(artists[e.key].albums[0].art), "url": ""]
                }
                return ["topartists": ["artist": list, "@attr": ["user": profileName, "total": "\(totals.count)", "page": "\(pg)"]]]
            }
            let list: [[String: Any]] = slice.enumerated().map { k, e in
                ["name": artists[e.key].albums[0].name, "playcount": "\(e.value)", "artist": ["name": artists[e.key].name], "@attr": ["rank": "\(k + 1)"], "image": image(artists[e.key].albums[0].art)]
            }
            return ["topalbums": ["album": list, "@attr": ["user": profileName, "total": "\(totals.count)"]]]
        case "user.gettoptracks", "user.getweeklytrackchart", "user.getweeklyartistchart", "user.getweeklyalbumchart":
            let range: Range<Int>
            if let f = Int(params["from"] ?? ""), let t = Int(params["to"] ?? "") { range = span(from: f, to: t - 1) }
            else {
                let days = ["7day": 7, "1month": 30, "3month": 90, "6month": 180, "12month": 365][params["period"] ?? "overall"]
                range = span(from: days.map { nowUts - $0 * 86400 } ?? 0, to: nowUts)
            }
            let (_, limit) = page(params)
            if method == "user.getweeklyartistchart" {
                let c = counts(range).sorted { $0.value > $1.value }.prefix(limit)
                return ["weeklyartistchart": ["artist": c.map { ["name": artists[$0.key].name, "playcount": "\($0.value)"] }]]
            }
            if method == "user.getweeklyalbumchart" {
                var c: [Int: Int] = [:]
                for k in range { c[plays[k].artist * 8 + plays[k].album, default: 0] += 1 }
                let top = c.sorted { $0.value > $1.value }.prefix(limit)
                return ["weeklyalbumchart": ["album": top.map { e -> [String: Any] in
                    let a = artists[e.key / 8], al = a.albums[e.key % 8]
                    return ["name": al.name, "artist": ["#text": a.name], "playcount": "\(e.value)"]
                }]]
            }
            var c: [Int: Int] = [:]
            for k in range { c[plays[k].artist * 4096 + plays[k].album * 64 + plays[k].track, default: 0] += 1 }
            let top = c.sorted { $0.value > $1.value }.prefix(limit)
            let list: [[String: Any]] = top.map { e in
                let a = artists[e.key / 4096], al = a.albums[(e.key / 64) % 64]
                return ["name": al.tracks[e.key % 64], "artist": ["name": a.name, "#text": a.name], "playcount": "\(e.value)", "image": image(al.art), "duration": "\(Self.length(al.tracks[e.key % 64]))"]
            }
            return method == "user.gettoptracks" ? ["toptracks": ["track": list]] : ["weeklytrackchart": ["track": list]]
        case "user.getweeklychartlist":
            // Last.fm's weeks run Sunday noon to Sunday noon, UTC.
            let reg = profile["registered"] as? Int ?? 1_488_326_400
            var start = reg - ((reg - 3 * 86400 - 43200) % 604800 + 604800) % 604800
            var list: [[String: String]] = []
            while start + 604800 <= nowUts { list.append(["from": "\(start)", "to": "\(start + 604800)"]); start += 604800 }
            return ["weeklychartlist": ["chart": list]]
        case "user.getlovedtracks":
            var seen = Set<Int>(), list: [[String: Any]] = []
            for p in plays where loved(p) {
                let key = p.artist * 4096 + p.album * 64 + p.track
                guard seen.insert(key).inserted else { continue }
                let a = artists[p.artist], al = a.albums[p.album]
                list.append(["name": al.tracks[p.track], "artist": ["name": a.name], "image": image(al.art), "date": ["uts": "\(p.uts)"]])
            }
            let (pg, limit) = page(params)
            let slice = Array(list.dropFirst((pg - 1) * limit).prefix(limit))
            return ["lovedtracks": ["track": slice, "@attr": ["total": "\(list.count)", "totalPages": "\(max(1, (list.count + limit - 1) / limit))", "page": "\(pg)"]]]
        case "artist.getinfo":
            let name = params["artist"] ?? ""
            guard let i = artists.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
                let h = Self.hash(name)
                return ["artist": ["name": name, "stats": ["listeners": "\(20_000 + h % 900_000)", "playcount": "\((20_000 + h % 900_000) * 19)", "userplaycount": "0"],
                                   "tags": ["tag": [["name": "indie"], ["name": "dream pop"]]], "url": "https://www.last.fm/music/\(name.replacingOccurrences(of: " ", with: "+"))",
                                   "bio": ["summary": "\(name) is a band that grew out of late-night sessions in a shared rehearsal room, known for patient songs that build slowly. <a href=\"https://www.last.fm\">Read more on Last.fm</a>"]]]
            }
            let a = artists[i]
            return ["artist": ["name": a.name, "image": image(a.albums[0].art), "stats": ["listeners": "\(a.listeners)", "playcount": "\(a.listeners * 23)", "userplaycount": "\(plays.filter { $0.artist == i }.count)"],
                               "url": "https://www.last.fm/music/\(a.name.replacingOccurrences(of: " ", with: "+"))",
                               "tags": ["tag": a.tags.map { ["name": $0] }],
                               "bio": ["summary": "\(a.name) formed in \(a.albums.map(\.year).min() ?? 2010) and have made \(a.albums.count == 1 ? "one album" : "\(a.albums.count) albums") since, moving between \(a.tags.prefix(2).joined(separator: " and ")). Their records are known for warm, wide-open production and songs that reward a second listen; \(a.albums[0].name) is the one most people start with. <a href=\"https://www.last.fm\">Read more on Last.fm</a>"]]]
        case "artist.getsimilar":
            let name = (params["artist"] ?? "").lowercased()
            let h = Self.hash(name)
            let limit = Int(params["limit"] ?? "30") ?? 30
            var out: [[String: String]] = []
            var used = Set([name])
            // Some he knows well, some he's barely heard, some he never has.
            for k in 0..<limit {
                let pick: String
                switch k % 3 {
                case 0: pick = artists[(h / 7 + k * 5) % max(core, 1)].name
                case 1: pick = artists[core + (h / 3 + k * 37) % max(artists.count - core, 1)].name
                default: pick = Self.invented[(h + k * 11) % Self.invented.count]
                }
                guard used.insert(pick.lowercased()).inserted else { continue }
                out.append(["name": pick, "match": String(format: "%.3f", max(0.05, 1 - Double(k) * 0.03))])
            }
            return ["similarartists": ["artist": out]]
        case "artist.gettoptracks":
            let name = params["artist"] ?? ""
            let limit = Int(params["limit"] ?? "10") ?? 10
            let titles: [String]
            if let a = artists.first(where: { $0.name.lowercased() == name.lowercased() }) { titles = Array(Set(a.albums.flatMap(\.tracks))).sorted { Self.hash($0 + name) < Self.hash($1 + name) } }
            else { let pool = artists.prefix(core).flatMap { $0.albums.flatMap(\.tracks) }; titles = (0..<12).map { pool[(Self.hash(name) / 5 + $0 * 13) % pool.count] } }
            let list: [[String: Any]] = Array(Set(titles)).sorted { Self.hash($0 + name) < Self.hash($1 + name) }.prefix(limit).enumerated().map { k, t in
                ["name": t, "playcount": "\(900_000 / (k + 1) + Self.hash(t) % 5000)", "listeners": "\(240_000 / (k + 1) + Self.hash(t) % 900)", "artist": ["name": name]]
            }
            return ["toptracks": ["track": list]]
        case "artist.gettopalbums":
            let name = params["artist"] ?? ""
            if let a = artists.first(where: { $0.name.lowercased() == name.lowercased() }) {
                return ["topalbums": ["album": a.albums.map { ["name": $0.name, "image": image($0.art)] }]]
            }
            let covers = Array(Set(artists.prefix(core).flatMap { $0.albums.map(\.art) })).sorted()
            return ["topalbums": ["album": [["name": "\(name.split(separator: " ").first ?? "First") Light", "image": image(covers[Self.hash(name) % covers.count])]]]]
        case "album.getinfo":
            let name = (params["artist"] ?? "").lowercased(), title = (params["album"] ?? "").lowercased()
            guard let a = artists.first(where: { $0.name.lowercased() == name }), let al = a.albums.first(where: { $0.name.lowercased() == title }) else {
                return ["error": 6, "message": "Album not found"]
            }
            return ["album": ["name": al.name, "artist": a.name, "image": image(al.art), "listeners": "\(a.listeners / 2)", "playcount": "\(a.listeners * 9)",
                              "url": "https://www.last.fm/music/\(a.name.replacingOccurrences(of: " ", with: "+"))/\(al.name.replacingOccurrences(of: " ", with: "+"))",
                              "tags": ["tag": a.tags.map { ["name": $0] }],
                              "tracks": ["track": al.tracks.enumerated().map { k, t in ["name": t, "duration": "\(Self.length(t))", "@attr": ["rank": "\(k + 1)"]] }],
                              "wiki": ["summary": "\(al.name) is the \(al.year < 2015 ? "early" : "later") album by \(a.name), released in \(al.year). Recorded over one long winter, it's the record where their sound settled. <a href=\"https://www.last.fm\">Read more on Last.fm</a>"]]]
        case "track.getsimilar":
            let name = (params["artist"] ?? "").lowercased()
            let h = Self.hash(name + (params["track"] ?? ""))
            var out: [[String: Any]] = []
            for k in 0..<10 {
                let a = artists[(h / 3 + k * 7) % max(core, 1)]
                guard a.name.lowercased() != name else { continue }
                let al = a.albums[(h + k) % a.albums.count]
                out.append(["name": al.tracks[(h / 5 + k) % al.tracks.count], "artist": ["name": a.name], "image": image(al.art), "match": "\(1 - Double(k) * 0.07)"])
            }
            return ["similartracks": ["track": out]]
        default:
            return ["error": 3, "message": "Invalid Method"]
        }
    }
}
