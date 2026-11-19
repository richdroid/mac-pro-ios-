import SwiftUI
import WidgetKit

// Continue on iPhone (TVWidget/PhoneWidget.swift) at its real sizes, in each look, as PNG sheets written with the TV
// sheets ("-sheets YES"): one film, two, three, a long title, a missing poster, a wide still where a poster belongs, and
// nothing played yet. The posters are drawn here (a tall 2:3 one and a wide 16:9 still), so no network is needed.
// "Tinted" is the sheet's approximation (the whole render desaturated); on a real tinted Home Screen the posters keep
// their colour (widgetAccentedRenderingMode(.fullColor)), which only the system can draw.
enum PhoneSheets {
    @MainActor static func art(_ w: CGFloat, _ h: CGFloat, _ top: Color, _ bottom: Color, _ label: String) -> TVImage? {
        let r = ImageRenderer(content: ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            Text(label).font(.system(size: min(w, h) / 4, weight: .heavy)).foregroundStyle(.white.opacity(0.85))
        }.frame(width: w, height: h))
        r.scale = 1
        #if canImport(UIKit)
        return r.uiImage
        #else
        return r.nsImage
        #endif
    }
    typealias Item = PhoneShelfEntry.Item
    @MainActor static func items() -> (tall: Item, wide: Item, long: Item, bare: Item, episode: Item) {
        let tall = Item(type: "movie", imdb: "tt0000001", video: "tt0000001", name: "Heat", line: "", progress: 0.42, left: 5880,
                        poster: art(240, 360, Color(red: 0.75, green: 0.3, blue: 0.2), Color(red: 0.15, green: 0.1, blue: 0.2), "2:3"))
        let wide = Item(type: "series", imdb: "tt0000002", video: "tt0000002:1:3", name: "Twin Peaks", line: "S1 E3", progress: 0.7, left: 840,
                        poster: art(400, 225, Color(red: 0.2, green: 0.5, blue: 0.4), Color(red: 0.05, green: 0.15, blue: 0.2), "16:9"))
        let long = Item(type: "movie", imdb: "tt0000003", video: "tt0000003", name: "The Assassination of Jesse James by the Coward Robert Ford",
                        line: "", progress: 0.15, left: 8460,
                        poster: art(240, 360, Color(red: 0.6, green: 0.55, blue: 0.3), Color(red: 0.1, green: 0.1, blue: 0.1), "2:3"))
        let bare = Item(type: "movie", imdb: "tt0000004", video: "tt0000004", name: "No Poster", line: "", progress: 0.9, left: 420, poster: nil)
        let episode = Item(type: "series", imdb: "tt0000005", video: "tt0000005:2:1", name: "Severance", line: "S2 E1", progress: 0.05, left: 0,
                           poster: art(240, 360, Color(red: 0.25, green: 0.35, blue: 0.7), Color(red: 0.05, green: 0.05, blue: 0.15), "2:3"))
        return (tall, wide, long, bare, episode)
    }
    @MainActor static func sheet(_ look: Look) -> some View {
        let i = items()
        let states: [(String, [Item])] = [
            ("One film", [i.tall]),
            ("Two: a poster and a wide still", [i.wide, i.tall]),
            ("Three: long title, missing poster, episode with no time", [i.long, i.bare, i.episode]),
            ("Three posters", [i.tall, i.episode, i.long]),
            ("Missing poster first", [i.bare, i.tall]),
            ("Wide still first", [i.wide]),
            ("Nothing played yet", []),
        ]
        return Sheet("Continue on iPhone · \(look.title)", colors: look.wallpaper) {
            ForEach(states, id: \.0) { name, list in
                SheetRow(name) {
                    HomeCell(look, Fam.small, bg: TVGlass()) { PhoneShelfView(entry: PhoneShelfEntry(items: list), sheetFamily: .systemSmall) }
                    HomeCell(look, Fam.medium, bg: TVGlass()) { PhoneShelfView(entry: PhoneShelfEntry(items: list), sheetFamily: .systemMedium) }
                }
            }
        }
    }
    @MainActor static func write() -> [String] {
        Look.allCases.map { look in
            let name = "tv-phone-\(look.rawValue)"
            writeSheet(name, sheet(look))
            return name
        }
    }
}
