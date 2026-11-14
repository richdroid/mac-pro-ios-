import SwiftUI
import WidgetKit

// Rotation's widgets at their real sizes for the build's review, never shipped: every family in each look (dark, light,
// tinted, clear), the Lock Screen and StandBy, in each state (playing, last played, stale, waiting, long names), as PNG
// sheets ("-sheets YES", written to Documents/sheets). The covers are the app's own mock art (LastFMApp/Mock).
enum LFMSample {
    static func art(_ name: String) -> Data? {
        Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Mock/art").flatMap { try? Data(contentsOf: $0) }
            .flatMap { WClient.downsample($0, px: 600) }
    }
    // Albums from the mock catalog, in order, each with its picture.
    static let albums: [(WCover, Data?)] = {
        guard let u = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Mock"),
              let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) else { return [] }
        var out: [(WCover, Data?)] = []
        for a in WJ(o)["artists"].array {
            for al in a["albums"].array {
                let file = al["art"].text
                out.append((WCover(artist: a["name"].text, album: al["name"].text, title: al["tracks"].array.first?.text ?? "", url: "mock:" + file), art(file)))
            }
        }
        return out
    }()
    static func entry(playing: Bool = true, seenAgo: TimeInterval = 60, never: Bool = false, long: Bool = false, noFacts: Bool = false) -> LFMEntry {
        let now = Date()
        var e = LFMEntry(date: now)
        e.seen = never ? nil : now.addingTimeInterval(-seenAgo)
        guard !never else { return e }
        var images: [String: Data] = [:]
        for (c, d) in albums { if let u = c.url, let d { images[u] = d } }
        e.images = images
        let plays = [64, 51, 47, 40, 33, 29, 22, 18, 15, 12]
        e.week = albums.prefix(10).enumerated().map { i, a in var c = a.0; c.plays = plays[i % plays.count]; return c }
        var song = albums.dropFirst(3).first?.0 ?? WCover(artist: "", album: "")
        if long { song.title = "An Extraordinarily Long Song Title (Extended Version)"; song.artist = "The Artist With A Very Long Name Indeed" }
        e.song = song
        e.playing = playing
        e.songAt = playing ? nil : now.addingTimeInterval(-14 * 60)
        e.artists = [(0, 86), (4, 51), (7, 33)].compactMap { i, n in
            guard i < albums.count else { return nil }
            var c = albums[i].0; c.plays = n
            if long && i == 0 { c.artist = "The Artist With A Very Long Name Indeed" }
            return c
        }
        e.scrobbles = 223_092
        e.today = 41
        if !noFacts {
            e.streak = 1_412
            e.best = 1_412
            let mid = [38, 79, 118, 161, 205, 252, 301], lo = [25, 58, 92, 130, 171, 210, 252], hi = [52, 101, 149, 199, 248, 300, 352]
            e.pace = WPace(now: 214, usual: 186, weeks: 8, line: [44, 97, 151, 214], mid: mid, lo: lo, hi: hi)
            e.weekPlays = 214
        } else {
            e.weekPlays = 214
        }
        return e
    }
    static let states: [(String, LFMEntry)] = [
        ("Playing", entry()), ("Last played 14 min ago", entry(playing: false)), ("Last seen (Last.fm quiet for 2 h)", entry(playing: false, seenAgo: 2 * 3600)),
        ("Waiting (never answered)", entry(never: true)), ("Long names", entry(long: true)), ("No streak from the app yet", entry(noFacts: true)),
    ]
}

struct LFMSheets: View {
    @State private var names: [String] = []
    func home(_ look: Look) -> some View {
        Sheet("Rotation widgets · \(look.title)", colors: look.wallpaper) {
            ForEach(LFMSample.states, id: \.0) { name, e in
                SheetRow(name) {
                    HomeCell(look, Fam.small, margins: false, bg: WBlur(data: e.image(e.song))) { NowBody(family: .systemSmall, entry: e).foregroundStyle(.white) }
                    HomeCell(look, Fam.medium, bg: WBlur(data: e.image(e.song))) { NowBody(family: .systemMedium, entry: e).foregroundStyle(.white) }
                    HomeCell(look, Fam.small, bg: StreakGround()) { StreakBody(family: .systemSmall, entry: e).foregroundStyle(.white) }
                }
            }
        }
    }
    func week(_ look: Look) -> some View {
        Sheet("Rotation · the week · \(look.title)", colors: look.wallpaper) {
            ForEach([LFMSample.states[0], LFMSample.states[2], LFMSample.states[3], LFMSample.states[4], LFMSample.states[5]], id: \.0) { name, e in
                SheetRow(name) {
                    HomeCell(look, Fam.small, margins: false, bg: WS.ground) { CollageBody(family: .systemSmall, entry: e).foregroundStyle(.white) }
                    HomeCell(look, Fam.medium, bg: StreakGround()) { PaceBody(family: .systemMedium, entry: e).foregroundStyle(.white) }
                    HomeCell(look, Fam.small, bg: StreakGround()) { PaceBody(family: .systemSmall, entry: e).foregroundStyle(.white) }
                }
                SheetRow(name + ", continued") {
                    HomeCell(look, Fam.medium, bg: WS.ground) { CollageBody(family: .systemMedium, entry: e).foregroundStyle(.white) }
                    HomeCell(look, Fam.medium, margins: true, bg: WBlur(data: e.image(e.artists.first))) { ArtistBody(family: .systemMedium, entry: e).foregroundStyle(.white) }
                }
                SheetRow(name + ", top artist small") {
                    HomeCell(look, Fam.small, margins: false, bg: WBlur(data: e.image(e.artists.first))) { ArtistBody(family: .systemSmall, entry: e).foregroundStyle(.white) }
                }
            }
        }
    }
    func large(_ look: Look) -> some View {
        Sheet("Rotation · large · \(look.title)", colors: look.wallpaper) {
            SheetRow("Collage, this week; then stale") {
                HomeCell(look, Fam.large, margins: false, bg: WS.ground) { CollageBody(family: .systemLarge, entry: LFMSample.states[0].1).foregroundStyle(.white) }
                HomeCell(look, Fam.large, margins: false, bg: WS.ground) { CollageBody(family: .systemLarge, entry: LFMSample.states[2].1).foregroundStyle(.white) }
            }
        }
    }
    var lock: some View {
        Sheet("Rotation · Lock Screen (vibrant)", colors: [Color(red: 0.2, green: 0.3, blue: 0.45), Color(red: 0.55, green: 0.35, blue: 0.4), Color(red: 0.85, green: 0.6, blue: 0.4)]) {
            ForEach(LFMSample.states, id: \.0) { name, e in
                SheetRow(name) {
                    LockCell(Fam.circular) { StreakBody(family: .accessoryCircular, entry: e) }
                    LockCell(Fam.rectangular) { NowBody(family: .accessoryRectangular, entry: e) }
                    LockCell(Fam.rectangular) { PaceBody(family: .accessoryRectangular, entry: e) }
                    LockCell(Fam.inline) { StreakBody(family: .accessoryInline, entry: e) }
                }
            }
        }
    }
    var standby: some View {
        Sheet("Rotation · StandBy (day, night)", colors: [.black, .black]) {
            ForEach([LFMSample.states[0], LFMSample.states[2]], id: \.0) { name, e in
                SheetRow(name) {
                    StandByCell { NowBody(family: .systemSmall, entry: e).foregroundStyle(.white).padding(-16) }
                    StandByCell(night: true) { NowBody(family: .systemSmall, entry: e).foregroundStyle(.white).padding(-16) }
                    StandByCell { StreakBody(family: .systemSmall, entry: e).foregroundStyle(.white) }
                }
            }
        }
    }
    var body: some View {
        SheetsDone(names: names).task {
            for look in Look.allCases {
                for (n, v) in [("home", AnyView(home(look))), ("week", AnyView(week(look))), ("large", AnyView(large(look)))] {
                    let name = "lfm-widgets-\(n)-\(look.rawValue)"
                    writeSheet(name, v); names.append(name)
                }
            }
            writeSheet("lfm-widgets-lock", scale: 3, lock); names.append("lfm-widgets-lock")
            writeSheet("lfm-widgets-standby", standby); names.append("lfm-widgets-standby")
            print("sheets done")
        }
    }
}

@main struct GalleryApp: App {
    var body: some Scene { WindowGroup { LFMSheets() } }
}
