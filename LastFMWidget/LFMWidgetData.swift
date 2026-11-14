import WidgetKit
import SwiftUI
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

// What the widgets show and where it comes from. Each asks Last.fm itself (the key and user the signing bakes into
// this extension's Info.plist, as into the app's), a few small calls kept for ten minutes and shared by every widget;
// the streak and his usual week come from the app (WidgetFacts). When Last.fm doesn't answer, the last answer stays
// up with when it was seen.

struct WCover: Hashable, Codable {
    var artist: String
    var album: String
    var title: String = ""
    var plays: Int = 0
    var url: String?
}

struct WPace: Hashable, Codable {
    var now: Int
    var usual: Int
    var weeks: Int
    var line: [Int?]                  // this week, cumulative by day, through today; nil where not known
    var mid: [Int]
    var lo: [Int]
    var hi: [Int]
    var delta: Double { usual == 0 ? 0 : Double(now - usual) / Double(usual) }
}

struct LFMEntry: TimelineEntry {
    var date: Date
    var seen: Date?                   // when Last.fm last answered; nil: never yet
    var playing = false
    var song: WCover?                 // on now, or the last played
    var songAt: Date?
    var week: [WCover] = []           // this week's albums, most played first
    var artists: [WCover] = []        // this week's artists (album: their most played album this week)
    var scrobbles: Int?
    var today: Int?
    var weekPlays: Int?
    var streak: Int?
    var best: Int?
    var pace: WPace?
    var images: [String: Data] = [:]  // covers, by address
    var stale: Bool { seen.map { date.timeIntervalSince($0) > 30 * 60 } ?? false }
    func image(_ c: WCover?) -> Data? { c?.url.flatMap { images[$0] } }
}

// "Last seen 9:41 PM", with the day when it isn't today (the shared stale phrase).
func lastSeen(_ d: Date, now: Date = Date()) -> String {
    let t = d.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDate(d, inSameDayAs: now) { return "Last seen \(t)" }
    return "Last seen \(d.formatted(.dateTime.weekday(.abbreviated))) \(t)"
}
// "Played 12 min ago", "Played at 9:10 PM", "Played yesterday".
func playedWhen(_ d: Date?, now: Date = Date()) -> String {
    guard let d else { return "" }
    let gap = now.timeIntervalSince(d)
    if gap < 60 { return "Played just now" }
    if gap < 3600 { return "Played \(Int(gap / 60)) min ago" }
    if Calendar.current.isDate(d, inSameDayAs: now) { return "Played at \(d.formatted(date: .omitted, time: .shortened))" }
    if Calendar.current.isDateInYesterday(d) { return "Played yesterday" }
    return "Played \(d.formatted(.dateTime.weekday(.wide)))"
}

struct WJ {
    let v: Any?
    init(_ v: Any?) { self.v = v }
    subscript(_ k: String) -> WJ { WJ((v as? [String: Any])?[k]) }
    var text: String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let d = v as? [String: Any], let t = d["#text"] { return WJ(t).text }
        return ""
    }
    var int: Int? { if let n = v as? NSNumber { return n.intValue }; return Int(text) }
    var array: [WJ] { if let a = v as? [Any] { return a.map(WJ.init) }; if v is [String: Any] { return [self] }; return [] }
    // The largest picture, never Last.fm's grey star.
    var image: String? {
        let best = array.last { !$0.text.isEmpty }?.text
        guard let b = best, !b.contains("2a96cbd8b46e442fc41c2b86b821562f") else { return nil }
        return b
    }
}

enum WClient {
    private static func baked(_ k: String) -> String? { (Bundle.main.object(forInfoDictionaryKey: k) as? String).flatMap { $0.isEmpty ? nil : $0 } }
    static var ready: Bool { baked("LastFMKey") != nil && baked("LastFMUser") != nil }
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("lastfm-widget", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static func file(_ k: String) -> URL {
        dir.appendingPathComponent(SHA256.hash(data: Data(k.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description)
    }
    // A call, kept on disk: a fresh-enough answer is used as it is; a failed call falls back to the last answer, with
    // its age, so the widget can say when it was seen.
    static func call(_ method: String, _ params: [String: String] = [:], fresh: TimeInterval = 600) async -> (WJ, Date)? {
        guard let key = baked("LastFMKey"), let user = baked("LastFMUser") else { return nil }
        let k = method + "?" + params.keys.sorted().map { "\($0)=\(params[$0]!)" }.joined(separator: "&")
        let f = file(k)
        let kept: (WJ, Date)? = {
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
            let when = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date) ?? .distantPast
            return (WJ(o), when)
        }()
        if let kept, Date().timeIntervalSince(kept.1) < fresh { return kept }
        var c = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        c.queryItems = [URLQueryItem(name: "method", value: method), URLQueryItem(name: "api_key", value: key),
                        URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "user", value: user)]
            + params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 12
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
           let o = try? JSONSerialization.jsonObject(with: data), WJ(o)["error"].int == nil {
            try? data.write(to: f, options: .atomic)
            return (WJ(o), Date())
        }
        return kept
    }
    // A cover at about the size it's drawn, kept on disk.
    static func image(_ url: String, px: Int) async -> Data? {
        let f = file("img\(px)|" + url)
        if let d = try? Data(contentsOf: f) { return d }
        guard let u = URL(string: url), let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
        let out = downsample(data, px: px) ?? data
        try? out.write(to: f, options: .atomic)
        return out
    }
    static func downsample(_ data: Data, px: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: px,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    // Everything one kind of widget needs, and nothing else.
    static func load(_ kind: String) async -> LFMEntry {
        var e = LFMEntry(date: Date())
        var seen: [Date] = []
        let facts = WidgetFacts.read()
        let ws = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        if kind == "now" || kind == "streak" || kind == "week" {
            if let (j, at) = await call("user.getrecenttracks", ["limit": "200"], fresh: kind == "now" ? 60 : 600) {
                seen.append(at)
                let tracks = j["recenttracks"]["track"].array
                if let t = tracks.first {
                    e.playing = t["@attr"]["nowplaying"].text == "true"
                    e.song = WCover(artist: t["artist"].text, album: t["album"].text, title: t["name"].text, url: t["image"].image)
                    e.songAt = t["date"]["uts"].int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                }
                let days = tracks.compactMap { $0["date"]["uts"].int }.map { WidgetFacts.localDay(Date(timeIntervalSince1970: TimeInterval($0))) }
                let today = WidgetFacts.localDay(Date())
                e.today = days.filter { $0 == today }.count
                // A full page reaches back to its oldest day; that day itself may be only partly on it.
                let covered = tracks.count >= 200 ? (days.min() ?? today) + 1 : (days.min() ?? today)
                e.streak = facts?.streakNow(played: Set(days), covered: covered)
                e.best = facts.flatMap { f in f.best.map { max($0, e.streak ?? 0) } }
            }
        }
        if kind == "streak", let (j, at) = await call("user.getinfo", [:], fresh: 1800) {
            seen.append(at)
            e.scrobbles = j["user"]["playcount"].int
        }
        if kind == "week" {
            let from = String(Int(ws.timeIntervalSince1970))
            if let (j, at) = await call("user.getrecenttracks", ["limit": "1", "from": from], fresh: 600) {
                seen.append(at)
                e.weekPlays = j["recenttracks"]["@attr"]["total"].int
            }
            if let f = facts, let live = e.weekPlays { e.pace = pace(f, live: live, weekStart: ws) }
        }
        if kind == "collage" || kind == "artist" {
            if let (j, at) = await call("user.gettopalbums", ["period": "7day", "limit": "60"], fresh: 1200) {
                seen.append(at)
                e.week = j["topalbums"]["album"].array.map { a in
                    WCover(artist: a["artist"]["name"].text, album: a["name"].text, plays: a["playcount"].int ?? 0, url: a["image"].image)
                }
            }
        }
        if kind == "artist", let (j, at) = await call("user.gettopartists", ["period": "7day", "limit": "3"], fresh: 1200) {
            seen.append(at)
            e.artists = j["topartists"]["artist"].array.map { a in
                let name = a["name"].text
                let album = e.week.first { $0.artist == name }
                return WCover(artist: name, album: album?.album ?? "", plays: a["playcount"].int ?? 0, url: album?.url)
            }
        }
        e.seen = seen.min()
        // The covers this widget draws.
        var want: [(String, Int)] = []
        if let u = e.song?.url { want.append((u, 600)) }
        if kind == "collage" { want += e.week.prefix(9).compactMap { $0.url.map { ($0, 360) } } }
        if kind == "artist" { want += e.artists.prefix(1).compactMap { $0.url.map { ($0, 600) } } }
        if kind != "now", kind != "collage", kind != "artist" { want = [] }
        await withTaskGroup(of: (String, Data?).self) { g in
            for (u, px) in want { g.addTask { (u, await image(u, px: px)) } }
            for await (u, d) in g { if let d { e.images[u] = d } }
        }
        return e
    }

    // This week against his usual, from the app's usual band and the week's plays live from Last.fm.
    static func pace(_ f: WidgetFacts, live: Int, weekStart ws: Date, now: Date = Date()) -> WPace? {
        guard f.usualMid.count == 7, f.usualLo.count == 7, f.usualHi.count == 7 else { return nil }
        let elapsed = max(0, now.timeIntervalSince(ws) / 86400)
        let today = min(6, Int(elapsed))
        func usualAt(_ t: Double) -> Double {
            let d = min(6, Int(t)), frac = min(1, t - Double(d))
            let before = d == 0 ? 0 : Double(f.usualMid[d - 1])
            return before + (Double(f.usualMid[d]) - before) * frac
        }
        let same = abs(f.weekStart - ws.timeIntervalSince1970) < 3600
        var line: [Int?] = Array(repeating: nil, count: today + 1)
        if same { for d in 0..<min(today, f.thisWeek.count) { line[d] = f.thisWeek[d] } }
        line[today] = live
        let atFacts = (f.at - ws.timeIntervalSince1970) / 86400
        let usual = same && f.usual != nil ? Double(f.usual!) + usualAt(elapsed) - usualAt(max(0, atFacts)) : usualAt(elapsed)
        return WPace(now: live, usual: max(0, Int(usual.rounded())), weeks: f.weeks ?? 8, line: line, mid: f.usualMid, lo: f.usualLo, hi: f.usualHi)
    }
}

struct LFMProvider: TimelineProvider {
    let kind: String
    func placeholder(in context: Context) -> LFMEntry { LFMEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (LFMEntry) -> Void) {
        guard WClient.ready, !context.isPreview else { completion(LFMEntry(date: Date())); return }
        Task { completion(await WClient.load(kind)) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LFMEntry>) -> Void) {
        Task {
            let e = WClient.ready ? await WClient.load(kind) : LFMEntry(date: Date())
            // Sooner while a song plays (it changes), else every half hour; the app also asks for a redraw when it sees a
            // new song or a changed streak.
            let next = Date().addingTimeInterval(e.playing && kind == "now" ? 15 * 60 : 30 * 60)
            completion(Timeline(entries: [e], policy: .after(next)))
        }
    }
}
