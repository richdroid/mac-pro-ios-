import SwiftUI
import WidgetKit
import UIKit
// Widgets at real sizes for the cloud build's screenshots. Never shipped.
func card<C: View, B: View>(_ w: CGFloat, _ h: CGFloat, _ bg: B, @ViewBuilder _ c: () -> C) -> some View {
    c().foregroundStyle(.white).frame(width: w, height: h).background(bg).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
}
@main struct GalleryApp: App {
    let e = TVProvider.sample
    var off: TVEntry { TVEntry() }
    // "-page island", "island-open1", "island-open2", "island-lock0", "island-lock1": the Live Activity as the island
    // and the Lock Screen show it (TVIslandGallery), every state: a show playing, a song paused, out of date, a film
    // with a long name, a video's wide still, and nothing known but the name. The covers are drawn here, then shrunk by
    // the app's own code, so what's judged is the cover at the size and weight the card really carries.
    static func poster(_ w: CGFloat, _ h: CGFloat, _ a: UIColor, _ b: UIColor, _ word: String) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f).image { c in
            let g = CGGradient(colorsSpace: nil, colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
            c.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
            UIColor.white.withAlphaComponent(0.85).setFill()
            c.cgContext.fillEllipse(in: CGRect(x: w * 0.52, y: h * 0.1, width: w * 0.34, height: w * 0.34))
            UIColor.black.withAlphaComponent(0.55).setFill()
            let hill = UIBezierPath(); hill.move(to: CGPoint(x: 0, y: h * 0.72))
            hill.addCurve(to: CGPoint(x: w, y: h * 0.6), controlPoint1: CGPoint(x: w * 0.3, y: h * 0.45), controlPoint2: CGPoint(x: w * 0.6, y: h * 0.8))
            hill.addLine(to: CGPoint(x: w, y: h)); hill.addLine(to: CGPoint(x: 0, y: h)); hill.close(); hill.fill()
            let font = UIFont.systemFont(ofSize: min(w, h) * 0.2, weight: .black)
            (word as NSString).draw(in: CGRect(x: w * 0.08, y: h * 0.76, width: w * 0.84, height: h * 0.22), withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
    }
    static func island(_ page: String, _ real: [String: UIImage]) -> some View {
        let now = Date()
        func made(_ title: String, _ sub: String, _ app: String, playing: Bool, at: Double?, of: Double?, art: UIImage?) -> (TVIslandAttributes.ContentState, String) {
            var st = TVIslandAttributes.ContentState(title: title, subtitle: sub, app: app, playing: playing)
            if let at, let of {
                st.progress = at / of; st.length = of
                if playing { st.start = now.addingTimeInterval(-at); st.end = now.addingTimeInterval(of - at) }
            }
            st.art = art.flatMap(TVIsland.shrink)
            let size = st.art.map { d in String(format: " · cover %.1f KB ", Double(d.count) / 1000) + (d.count > 8 && String(decoding: d[4..<8], as: UTF8.self) == "ftyp" ? "heic" : "jpeg") } ?? ""
            return (st, size)
        }
        let show = made("Twin Peaks", "S1 E3 · Zen, or the Skill to Catch a Killer", "Stremio", playing: true, at: 600, of: 2815, art: real["show"] ?? poster(400, 600, .systemOrange, .systemRed, "PEAKS"))
        let song = made("Come Together", "The Beatles", "Mint", playing: false, at: 39, of: 259, art: real["album"] ?? poster(600, 600, .systemTeal, .systemIndigo, "ROAD"))
        let film = made("The Assassination of Jesse James by the Coward Robert Ford", "", "Stremio", playing: true, at: 4210, of: 9600, art: real["film"] ?? poster(400, 600, .darkGray, .brown, "JESSE"))
        let video = made("Every Frame a Painting: The Art of Editing", "Tony Zhou", "YouTube", playing: true, at: 95, of: 540, art: real["video"] ?? poster(640, 360, .systemPurple, .systemBlue, "EDITING"))
        let bare = made("Sample Film", "", "Stremio", playing: true, at: nil, of: nil, art: nil)
        let nolen = made("Twin Peaks", "S1 E3 · Zen, or the Skill to Catch a Killer", "Stremio", playing: true, at: nil, of: nil, art: real["show"] ?? poster(400, 600, .systemOrange, .systemRed, "PEAKS"))
        let all: [(name: String, state: TVIslandAttributes.ContentState, stale: Bool)] = [
            ("A show, playing" + show.1, show.0, false), ("A song, paused" + song.1, song.0, false), ("Out of date" + show.1, show.0, true),
            ("A film, long name" + film.1, film.0, false), ("A video, wide still" + video.1, video.0, false), ("No cover, no length", bare.0, false),
            ("A show with no running time" + nolen.1, nolen.0, false),
        ]
        let lock = page.contains("lock")
        let part = Int(String(page.last ?? "0")) ?? 0
        let per = lock ? 3 : 2
        let shown = Array(all.dropFirst(part * per).prefix(per))
        return Group {
            if page == "island-art" {
                // The real covers as the card carries them (shrunk by the app's own code), at the card's size and three
                // times it, so what HEIC at 2.3 KB does to faces and lettering is seen, not assumed.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach([("show", show), ("album", song), ("film", film), ("video", video)], id: \.0) { pair in
                        HStack(alignment: .bottom, spacing: 14) {
                            IslandCover(state: pair.1.0, height: 48)
                            IslandCover(state: pair.1.0, height: 144)
                            Text(pair.0 + (real[pair.0] == nil ? " (drawn: not fetched)" : " (real)") + pair.1.1).font(.caption2).foregroundStyle(.white)
                        }
                    }
                }
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.black.ignoresSafeArea())
            } else {
                TVIslandGallery(states: shown, lock: lock).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(LinearGradient(colors: lock ? [Color(hex: 0x35507A), Color(hex: 0x8A4B6B), Color(hex: 0xD89A5B)] : [Color(white: 0.75), Color(white: 0.62)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
        }
    }
    var body: some Scene { WindowGroup {
        if let page = UserDefaults.standard.string(forKey: "page"), page.hasPrefix("island") { IslandPage(page: page) } else {
        ScrollView { VStack(spacing: 14) {
            HStack(spacing: 14) { card(158, 158, WidgetWall(image: e.wall)) { NowBody(family: .systemSmall, entry: e) }; card(158, 158, WidgetWall(image: nil)) { NowBody(family: .systemSmall, entry: off) } }
            card(338, 158, WidgetWall(image: e.wall)) { NowBody(family: .systemMedium, entry: e) }
            card(338, 158, Color(hex: 0x14181C)) { RemoteBody(family: .systemMedium, entry: e) }
            card(338, 158, Color(hex: 0x14181C)) { AppsBody(entry: e) }
            card(338, 158, Color(hex: 0x14181C)) { TVBoxBody(family: .systemMedium, entry: TVBoxProvider.sample) }
            HStack(spacing: 14) { card(158, 158, Color(hex: 0x14181C)) { TVBoxBody(family: .systemSmall, entry: TVBoxProvider.sample) }; card(158, 158, Color(hex: 0x14181C)) { TVBoxBody(family: .systemSmall, entry: TVBoxEntry()) } }
            card(338, 354, Color(hex: 0x14181C)) { RemoteBody(family: .systemLarge, entry: e) }
        }.padding(10).scaleEffect(0.6, anchor: .top).frame(height: 680, alignment: .top) }.background(Color(white: 0.8))
        }
    } }
}

// The island pages, with real covers fetched as the build runs (a poster, an album and a video's still, from their
// public addresses; nothing of anyone's is kept in the repo): drawn ones stand in for any that don't come in 6 s.
struct IslandPage: View {
    let page: String
    @State private var real: [String: UIImage] = [:]
    @State private var ready = false
    static let poster = ["show": "https://images.metahub.space/poster/medium/tt0098936/img", "film": "https://images.metahub.space/poster/medium/tt0443680/img",
                         "video": "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg"]
    static func fetch(_ address: String) async -> Data? {
        guard let u = URL(string: address) else { return nil }
        var r = URLRequest(url: u); r.timeoutInterval = 6
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }
    var body: some View {
        Group { if ready { GalleryApp.island(page, real) } else { Color.black } }
            .task {
                var got: [String: UIImage] = [:]
                for (name, address) in Self.poster { if let d = await Self.fetch(address), let i = UIImage(data: d) { got[name] = i } }
                // An album's cover, found by name in the public catalogue.
                if let d = await Self.fetch("https://itunes.apple.com/search?term=abbey+road+beatles&entity=album&limit=1"),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let first = (j["results"] as? [[String: Any]])?.first,
                   let small = first["artworkUrl100"] as? String, let a = await Self.fetch(small.replacingOccurrences(of: "100x100", with: "600x600")), let i = UIImage(data: a) { got["album"] = i }
                real = got; ready = true
            }
    }
}
