import Foundation

// What Last.fm knows about an artist, album or track beyond his own plays: its listeners and plays everywhere, its
// tags, its words, what's like it, and its top tracks. Asked when a page opens; kept a day.
struct Words {
    // Last.fm ends its words with a link back to itself; the words are kept, the link isn't.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cut = raw.components(separatedBy: "<a href").first ?? raw
        let w = cut.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? nil : w
    }
}

struct Similar: Identifiable, Hashable, Sendable {
    var id: String { name.lowercased() }
    let name: String
    let match: Double
}

struct ArtistInfo: Sendable {
    var listeners: Int?
    var plays: Int?
    var tags: [String] = []
    var bio: String?
    var url: String?
    var similar: [Similar] = []
    var top: [Entry] = []          // its top tracks on Last.fm (plays here are everyone's)
    var topListeners: [String: Int] = [:]

    static func load(_ name: String) async -> ArtistInfo {
        var i = ArtistInfo()
        if let j = try? await LastFM.shared.call("artist.getinfo", ["artist": name, "autocorrect": "1"], fresh: 86400) {
            let a = j["artist"]
            i.listeners = a["stats"]["listeners"].int
            i.plays = a["stats"]["playcount"].int
            i.tags = a["tags"]["tag"].array.map { $0["name"].text.lowercased() }.filter { !$0.isEmpty }.prefix(6).map { $0 }
            i.bio = Words.clean(a["bio"]["summary"].string)
            i.url = a["url"].string
        }
        if let j = try? await LastFM.shared.call("artist.getsimilar", ["artist": name, "limit": "16", "autocorrect": "1"], fresh: 86400) {
            i.similar = j["similarartists"]["artist"].array.map { Similar(name: $0["name"].text, match: Double($0["match"].text) ?? 0) }.filter { !$0.name.isEmpty }
        }
        if let j = try? await LastFM.shared.call("artist.gettoptracks", ["artist": name, "limit": "10", "autocorrect": "1"], fresh: 86400) {
            for t in j["toptracks"]["track"].array {
                let title = t["name"].text
                guard !title.isEmpty else { continue }
                i.top.append(Entry(kind: .tracks, artist: name, album: "", track: title, plays: t["playcount"].int ?? 0, rank: i.top.count + 1))
                i.topListeners[title.lowercased()] = t["listeners"].int
            }
        }
        return i
    }
}

struct AlbumInfo: Sendable {
    var listeners: Int?
    var plays: Int?
    var tags: [String] = []
    var wiki: String?
    var url: String?
    var image: String?
    var tracks: [(title: String, secs: Int?)] = []

    static func load(artist: String, album: String) async -> AlbumInfo {
        var i = AlbumInfo()
        guard let j = try? await LastFM.shared.call("album.getinfo", ["artist": artist, "album": album, "autocorrect": "1"], fresh: 86400) else { return i }
        let a = j["album"]
        i.listeners = a["listeners"].int
        i.plays = a["playcount"].int
        i.tags = a["tags"]["tag"].array.map { $0["name"].text.lowercased() }.filter { !$0.isEmpty }.prefix(6).map { $0 }
        i.wiki = Words.clean(a["wiki"]["summary"].string)
        i.url = a["url"].string
        i.image = Scrobble.bestImage(a["image"])
        i.tracks = a["tracks"]["track"].array.map { (title: $0["name"].text, secs: $0["duration"].int.flatMap { $0 > 0 ? $0 : nil }) }.filter { !$0.title.isEmpty }
        // Lengths learnt here count toward listening time too.
        let lengths = i.tracks.compactMap { t in t.secs.map { (artist, t.title, $0) } }
        if !lengths.isEmpty { Task { await HistoryDB.shared.keepLengths(lengths) } }
        return i
    }
}

extension TrackInfo {
    static func similar(_ s: Scrobble) async -> [Entry] {
        guard let j = try? await LastFM.shared.call("track.getsimilar", ["artist": s.artist, "track": s.title, "limit": "10", "autocorrect": "1"], fresh: 86400) else { return [] }
        return j["similartracks"]["track"].array.compactMap { t in
            let name = t["name"].text, artist = t["artist"]["name"].text
            guard !name.isEmpty, !artist.isEmpty else { return nil }
            return Entry(kind: .tracks, artist: artist, album: "", track: name, plays: t["playcount"].int ?? 0, image: Scrobble.bestImage(t["image"]))
        }
    }
}

// A cover for an artist he may never have played: his own most played album when he has, else the artist's top album
// on Last.fm (asked once, kept a month).
enum ArtistArt {
    static func ref(_ name: String) async -> ArtRef {
        if let c = await HistoryDB.shared.cover(of: name), c.url != nil { return ArtRef(artist: name, album: c.album, url: c.url) }
        if let j = try? await LastFM.shared.call("artist.gettopalbums", ["artist": name, "limit": "2", "autocorrect": "1"], fresh: 30 * 86400) {
            for a in j["topalbums"]["album"].array {
                let album = a["name"].text
                if !album.isEmpty, album != "(null)" { return ArtRef(artist: name, album: album, url: Scrobble.bestImage(a["image"])) }
            }
        }
        return ArtRef(artist: name, album: "", url: nil)
    }
}

// Apple Music: the artist, album or song itself when Apple's store finds it, else a search for it there.
actor AppleMusic {
    static let shared = AppleMusic()
    private var known: [String: URL] = [:]
    private var next = Date.distantPast
    private let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("applemusic.json")
    init() {
        if let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([String: String].self, from: d) { known = m.compactMapValues(URL.init(string:)) }
    }
    enum What: String { case artist = "musicArtist", album, song }
    func link(_ what: What, artist: String, title: String = "") async -> URL {
        let key = "\(what.rawValue)|\(artist.lowercased())|\(title.lowercased())"
        if let u = known[key] { return u }
        let term = title.isEmpty ? artist : "\(artist) \(title)"
        let search = URL(string: "https://music.apple.com/search?term=" + (term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))!
        guard !LastFM.shared.mock else { return search }
        let slot = max(Date(), next); next = slot.addingTimeInterval(1.5)
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: what.rawValue), URLQueryItem(name: "limit", value: "5")]
        guard let (d, _) = try? await URLSession.shared.data(from: c.url!), let o = try? JSONSerialization.jsonObject(with: d) else { return search }
        let want = artist.lowercased()
        let hits = J(o)["results"].array
        let hit = hits.first { $0["artistName"].text.lowercased() == want && (title.isEmpty || ($0[what == .song ? "trackName" : "collectionName"].text.lowercased().hasPrefix(title.lowercased()))) }
            ?? hits.first { $0["artistName"].text.lowercased() == want }
        let field = what == .artist ? "artistLinkUrl" : what == .album ? "collectionViewUrl" : "trackViewUrl"
        guard let s = hit?[field].string, let u = URL(string: s) else { return search }
        known[key] = u
        if let d = try? JSONEncoder().encode(known.mapValues(\.absoluteString)) { try? d.write(to: file, options: .atomic) }
        return u
    }
}

// Loved tracks, newest love first, every page of them; the last list shows at once while it's asked again.
struct Loved: Identifiable, Hashable, Sendable {
    var id: String { "\(artist)|\(title)" }
    let artist: String
    let title: String
    let image: String?
    let when: Date?
    static func kept() -> [Loved] { (LastFM.shared.kept("user.getlovedtracks", ["limit": "500", "page": "1"])?.0).map(parse) ?? [] }
    static func parse(_ j: J) -> [Loved] {
        j["lovedtracks"]["track"].array.compactMap { t in
            let artist = t["artist"]["name"].text, title = t["name"].text
            guard !artist.isEmpty, !title.isEmpty else { return nil }
            return Loved(artist: artist, title: title, image: Scrobble.bestImage(t["image"]), when: t["date"]["uts"].int.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }
    static func load() async -> [Loved]? {
        guard let j = try? await LastFM.shared.call("user.getlovedtracks", ["limit": "500", "page": "1"]) else { return nil }
        var all = parse(j)
        let pages = j["lovedtracks"]["@attr"]["totalPages"].int ?? 1
        if pages > 1 {
            for p in 2...min(pages, 20) {
                guard let k = try? await LastFM.shared.call("user.getlovedtracks", ["limit": "500", "page": "\(p)"], fresh: 3600) else { break }
                all += parse(k)
            }
        }
        return all
    }
}

// Last.fm's own weeks (Sunday to Sunday), for "any week".
struct ChartWeek: Identifiable, Hashable, Sendable {
    var id: Int { from }
    let from: Int
    let to: Int
    var label: String {
        // Last.fm's weeks turn at Sunday noon: said as Sunday to Saturday, so two weeks never share a day.
        let a = Date(timeIntervalSince1970: TimeInterval(from)), b = Date(timeIntervalSince1970: TimeInterval(to - 86400))
        let sameMonth = Calendar.current.isDate(a, equalTo: b, toGranularity: .month)
        return a.formatted(.dateTime.month(.abbreviated).day()) + " – " + (sameMonth ? b.formatted(.dateTime.day()) : b.formatted(.dateTime.month(.abbreviated).day()))
    }
    var year: Int { Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(from))) }
    @MainActor static func load() async -> [ChartWeek] {
        guard let j = try? await LastFM.shared.call("user.getweeklychartlist", fresh: 86400) else { return [] }
        return j["weeklychartlist"]["chart"].array.compactMap { c in
            guard let f = Int(c["from"].text), let t = Int(c["to"].text) else { return nil }
            return ChartWeek(from: f, to: t)
        }
        // Last.fm lists every week since it began; only his count.
        .filter { $0.to > since }
        .sorted { $0.from > $1.from }
    }
    // His first week: his first play, else when he joined.
    @MainActor private static var since: Int {
        let joined = Store.shared.profile.map { Int($0.registered.timeIntervalSince1970) } ?? 0
        return joined
    }
}

// Before his whole history is on the phone, a stretch it doesn't reach yet is asked of Last.fm's own charts (no movement,
// no listening time: those need the plays themselves).
enum RemoteChart {
    static func top(_ kind: Kind, period: String?, week: ChartWeek?) async -> [Entry] {
        let method: String, root: String, item: String
        var params: [String: String] = ["limit": "50"]
        if let week {
            method = ["user.getweeklyartistchart", "user.getweeklyalbumchart", "user.getweeklytrackchart"][kind.rawValue]
            root = ["weeklyartistchart", "weeklyalbumchart", "weeklytrackchart"][kind.rawValue]
            params["from"] = "\(week.from)"; params["to"] = "\(week.to)"
        } else {
            method = ["user.gettopartists", "user.gettopalbums", "user.gettoptracks"][kind.rawValue]
            root = ["topartists", "topalbums", "toptracks"][kind.rawValue]
            params["period"] = period ?? "overall"
        }
        item = ["artist", "album", "track"][kind.rawValue]
        guard let j = try? await LastFM.shared.call(method, params, fresh: 1800) else { return [] }
        var out: [Entry] = []
        for x in j[root][item].array {
            let name = x["name"].text
            let artist = kind == .artists ? name : (x["artist"]["name"].string ?? x["artist"]["#text"].string ?? x["artist"].text)
            let album = kind == .albums ? name : ""
            out.append(Entry(kind: kind, artist: artist, album: album, track: kind == .tracks ? name : "", plays: x["playcount"].int ?? 0, image: Scrobble.bestImage(x["image"]), rank: out.count + 1))
        }
        if kind == .artists || kind == .tracks {
            for i in out.indices { if let c = await HistoryDB.shared.cover(of: out[i].artist) { out[i] = out[i].with(album: c.album, image: c.url) } }
        }
        return out
    }
}
