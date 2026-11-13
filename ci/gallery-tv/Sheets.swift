import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

// The TV widgets in every family, look and state, as PNG sheets ("-sheets YES"). The banners, the TV's picture and the
// box's photo come from the build's stand-in Mac (ci/mock-chumby.js, the TV's real banners from ci/tv-icons), the album
// and poster from their public addresses; any that don't come in 6 s are drawn instead.
enum TVSample {
    static let names = ["Mint Music", "Letterboxd", "Stremio", "YouTube", "Netflix", "Apple TV"]
    static func status(screen: String = "on", app: String = "com.codex.musicwebtv", music: [String: Any]? = nil, session: [String: Any]? = nil, airplay: [String: Any]? = nil) -> TVStatus {
        var j: [String: Any] = ["online": true, "screen": screen, "app": app, "volume": 12, "volumeMax": 25,
                                "apps": zip(TVProvider.favourites, names).map { ["pkg": $0, "name": $1, "hasIcon": true, "wide": true] }]
        if let music { j["music"] = music }
        if let session { j["session"] = session }
        if let airplay { j["airplay"] = airplay }
        return try! JSONDecoder().decode(TVStatus.self, from: JSONSerialization.data(withJSONObject: j))
    }
    static func song(playing: Bool) -> [String: Any] {
        ["title": "Come Together", "artist": "The Beatles", "album": "Abbey Road", "art": "x", "playing": playing, "position": 39000, "duration": 259000, "sampledAt": Date().timeIntervalSince1970 * 1000]
    }
    static let video: [String: Any] = ["pkg": "com.google.android.youtube.tv", "playing": true, "description": ["Every Frame a Painting: The Art of Editing", "Tony Zhou"], "position": 95000, "duration": 540000, "sampledAt": Date().timeIntervalSince1970 * 1000, "art": "x"]
    static let film: [String: Any] = ["pkg": "com.stremio.one", "playing": false, "description": ["The Assassination of Jesse James by the Coward Robert Ford"], "position": 4210000, "duration": 9600000, "sampledAt": Date().timeIntervalSince1970 * 1000, "art": "x"]
    static let untimed: [String: Any] = ["pkg": "com.stremio.one", "playing": true, "description": ["Twin Peaks", "S1 E3"], "show": "Twin Peaks", "season": 1, "episode": 3, "episodeTitle": "Zen, or the Skill to Catch a Killer", "art": "x"]
    static let airplay: [String: Any] = ["active": true, "kind": "music", "playing": true, "title": "Here Comes the Sun", "artist": "The Beatles"]
    static let show: [String: Any] = ["pkg": "com.stremio.one", "playing": true, "description": ["Twin Peaks", "S1 E3"], "position": 600000, "duration": 2815000,
                                      "sampledAt": Date().timeIntervalSince1970 * 1000, "show": "Twin Peaks", "season": 1, "episode": 3, "episodeTitle": "Zen, or the Skill to Catch a Killer", "art": "x"]
}

struct TVSheets: View {
    @State private var names: [String] = []
    @State private var got: [String: TVImage] = [:]
    static let mock = "http://127.0.0.1:9002"
    func fetch(_ address: String) async -> TVImage? {
        guard let u = URL(string: address) else { return nil }
        var r = URLRequest(url: u); r.timeoutInterval = 6
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return TVProvider.thumbnail(d, 640)
    }
    func load() async {
        var want: [(String, String)] = [("shot", Self.mock + "/api/tv/shot"), ("box", Self.mock + "/api/tv/device-image"),
                                         ("poster", "https://images.metahub.space/poster/medium/tt0098936/img"), ("film", "https://images.metahub.space/poster/medium/tt0443680/img")]
        for pkg in TVProvider.favourites { want.append((pkg, Self.mock + "/api/tv/icon?pkg=\(pkg)&v=2")) }
        var out: [String: TVImage] = [:]
        await withTaskGroup(of: (String, TVImage?).self) { group in
            for (k, a) in want { group.addTask { (k, await fetch(a)) } }
            group.addTask {
                guard let u = URL(string: "https://itunes.apple.com/search?term=abbey+road+beatles&entity=album&limit=1"),
                      let (d, _) = try? await URLSession.shared.data(from: u),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let first = (j["results"] as? [[String: Any]])?.first,
                      let small = first["artworkUrl100"] as? String else { return ("album", nil) }
                return ("album", await fetch(small.replacingOccurrences(of: "100x100", with: "600x600")))
            }
            for await (k, i) in group { if let i { out[k] = i } }
        }
        print("sheets: fetched \(out.keys.sorted())")
        got = out
    }
    var album: TVImage? { got["album"] ?? TVProvider.sampleImage }
    func entry(_ s: TVStatus?, cover: TVImage? = nil, reachable: Bool = true, mirror: Bool = false) -> TVEntry {
        var e = TVEntry()
        e.status = s; e.reachable = reachable
        if !reachable, s != nil { e.readAt = Date().addingTimeInterval(-8 * 60) }
        if let cover { e.cover = cover; e.wall = TVProvider.shrunk(cover, to: 16) }
        if mirror, reachable, s?.screen != "asleep" { e.mirror = got["shot"] }
        e.logos = reachable ? got.filter { TVProvider.favourites.contains($0.key) } : [:]
        e.chosen = zip(TVProvider.favourites, TVSample.names).map { TVAppEntity(id: $0, name: $1) }
        return e
    }
    var nowStates: [(String, TVEntry)] {
        [
            ("A song playing", entry(TVSample.status(music: TVSample.song(playing: true)), cover: album)),
            ("A song paused", entry(TVSample.status(music: TVSample.song(playing: false)), cover: album)),
            ("A show playing in Stremio", entry(TVSample.status(app: "com.stremio.one", session: TVSample.show), cover: got["poster"])),
            ("A video in YouTube", entry(TVSample.status(app: "com.google.android.youtube.tv", session: TVSample.video), cover: got["shot"])),
            ("A film paused, long name", entry(TVSample.status(app: "com.stremio.one", session: TVSample.film), cover: got["film"])),
            ("A show with no running time", entry(TVSample.status(app: "com.stremio.one", session: TVSample.untimed), cover: got["poster"])),
            ("Music AirPlayed from this iPhone", entry(TVSample.status(airplay: TVSample.airplay), cover: album)),
            ("TV on, nothing playing (YouTube in front)", { var e = entry(TVSample.status(app: "com.google.android.youtube.tv")); e.front = got["com.google.android.youtube.tv"]; return e }()),
            ("TV asleep", entry(TVSample.status(screen: "asleep"))),
            ("Mac not answering (last known: a song)", entry(TVSample.status(music: TVSample.song(playing: true)), cover: album, reachable: false)),
            ("Never reached", entry(nil, reachable: false)),
        ]
    }
    var box: TVBoxEntry { var b = TVBoxProvider.sample; b.photo = got["box"]; return b }
    var boxStates: [(String, TVBoxEntry)] {
        var stale = box; stale.reachable = false; stale.screen = ""; stale.readAt = Date().addingTimeInterval(-40 * 60)
        var asleep = box; asleep.screen = "asleep"
        var hot = box; hot.info?.cpu = 92; hot.info?.tempC = 78; hot.info?.memUsed = 1.9e9
        return [("Awake", box), ("Hot and busy", hot), ("Asleep", asleep), ("Mac not answering (last known)", stale), ("Never reached", TVBoxEntry())]
    }
    let dark = Color(hex: 0x14181C)
    func now(_ look: Look) -> some View {
        Sheet("Playing on TV · \(look.title)", colors: look.wallpaper) {
            ForEach(nowStates, id: \.0) { name, e in
                SheetRow(name) {
                    HomeCell(look, Fam.small, margins: false, bg: WidgetWall(image: e.wall)) { NowBody(family: .systemSmall, entry: e).foregroundStyle(.white) }
                    HomeCell(look, Fam.medium, margins: false, bg: WidgetWall(image: e.wall)) { NowBody(family: .systemMedium, entry: e).foregroundStyle(.white) }
                }
            }
        }
    }
    func home(_ look: Look) -> some View {
        Sheet("TV widgets · \(look.title)", colors: look.wallpaper) {
            SheetRow("TV Remote · medium") {
                HomeCell(look, Fam.medium, margins: false, bg: TVGlass()) { RemoteBody(family: .systemMedium, entry: TVEntry()).foregroundStyle(.white) }
            }
            SheetRow("TV Apps · banners, Mac not answering") {
                HomeCell(look, Fam.medium, margins: false, bg: TVGlass()) { AppsBody(entry: entry(TVSample.status())).foregroundStyle(.white) }
                HomeCell(look, Fam.medium, margins: false, bg: TVGlass()) { AppsBody(entry: entry(nil, reachable: false)).foregroundStyle(.white) }
            }
            ForEach(boxStates, id: \.0) { name, b in
                SheetRow("TV Box Status · \(name)") {
                    HomeCell(look, Fam.small, margins: false, bg: TVGlass()) { TVBoxBody(family: .systemSmall, entry: b).foregroundStyle(.white) }
                    HomeCell(look, Fam.medium, margins: false, bg: TVGlass()) { TVBoxBody(family: .systemMedium, entry: b).foregroundStyle(.white) }
                }
            }
        }
    }
    func large(_ look: Look) -> some View {
        Sheet("TV Screen and Remote (large) · \(look.title)", colors: look.wallpaper) {
            SheetRow("On, picture · Asleep") {
                HomeCell(look, Fam.large, margins: false, bg: TVGlass()) { RemoteBody(family: .systemLarge, entry: entry(TVSample.status(app: "com.google.android.tvlauncher"), mirror: true)).foregroundStyle(.white) }
                HomeCell(look, Fam.large, margins: false, bg: TVGlass()) { RemoteBody(family: .systemLarge, entry: entry(TVSample.status(screen: "asleep"), mirror: true)).foregroundStyle(.white) }
            }
            SheetRow("Mac not answering · Never reached") {
                HomeCell(look, Fam.large, margins: false, bg: TVGlass()) { RemoteBody(family: .systemLarge, entry: entry(TVSample.status(), reachable: false, mirror: true)).foregroundStyle(.white) }
                HomeCell(look, Fam.large, margins: false, bg: TVGlass()) { RemoteBody(family: .systemLarge, entry: entry(nil, reachable: false)).foregroundStyle(.white) }
            }
        }
    }
    var lock: some View {
        Sheet("TV · Lock Screen (vibrant)", colors: [Color(red: 0.2, green: 0.3, blue: 0.45), Color(red: 0.55, green: 0.35, blue: 0.4), Color(red: 0.85, green: 0.6, blue: 0.4)]) {
            ForEach(nowStates, id: \.0) { name, e in
                SheetRow(name) { LockCell(Fam.rectangular) { NowBody(family: .accessoryRectangular, entry: e) } }
            }
        }
    }
    var standby: some View {
        Sheet("TV · StandBy (day, night)", colors: [.black, .black]) {
            ForEach(nowStates.prefix(3), id: \.0) { name, e in
                SheetRow(name) {
                    StandByCell { NowBody(family: .systemSmall, entry: e).padding(-16).foregroundStyle(.white) }
                    StandByCell(night: true) { NowBody(family: .systemSmall, entry: e).padding(-16).foregroundStyle(.white) }
                }
            }
            SheetRow("TV Box Status") {
                StandByCell { TVBoxBody(family: .systemSmall, entry: box).padding(-16).foregroundStyle(.white) }
                StandByCell(night: true) { TVBoxBody(family: .systemSmall, entry: box).padding(-16).foregroundStyle(.white) }
            }
        }
    }
    var body: some View {
        SheetsDone(names: names).task {
            await load()
            for look in Look.allCases {
                writeSheet("tv-now-\(look.rawValue)", now(look)); names.append("tv-now-\(look.rawValue)")
                writeSheet("tv-home-\(look.rawValue)", home(look)); names.append("tv-home-\(look.rawValue)")
                writeSheet("tv-large-\(look.rawValue)", large(look)); names.append("tv-large-\(look.rawValue)")
            }
            writeSheet("tv-lock", scale: 3, lock); names.append("tv-lock")
            writeSheet("tv-standby", standby); names.append("tv-standby")
            print("sheets done")
        }
    }
}
