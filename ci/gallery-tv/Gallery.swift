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
    // "-page island": the Live Activity as it shows on the Lock Screen and in the island (TVIslandGallery).
    var island: some View {
        let cover = UIImage(systemName: "film.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        let art = { () -> Data? in
            let r = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96))
            return r.image { c in
                UIColor(red: 0.55, green: 0.18, blue: 0.12, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
                cover?.draw(in: CGRect(x: 16, y: 32, width: 32, height: 32))
            }.jpegData(compressionQuality: 0.7)
        }()
        let now = Date()
        var on = TVIslandAttributes.ContentState(title: "Sample Show", subtitle: "S2 E3 · The Third One", app: "Stremio", playing: true)
        on.art = art; on.start = now.addingTimeInterval(-600); on.end = now.addingTimeInterval(715)
        var off = on; off.playing = false; off.start = nil; off.end = nil; off.progress = 0.46
        return TVIslandGallery(playing: on, paused: off).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color(white: 0.8))
    }
    var body: some Scene { WindowGroup {
        if UserDefaults.standard.string(forKey: "page") == "island" { island } else {
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
