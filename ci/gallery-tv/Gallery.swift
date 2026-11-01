import SwiftUI
import WidgetKit
// Widgets at real sizes for the cloud build's screenshots. Never shipped.
func card<C: View, B: View>(_ w: CGFloat, _ h: CGFloat, _ bg: B, @ViewBuilder _ c: () -> C) -> some View {
    c().foregroundStyle(Mint.text).padding(16).frame(width: w, height: h).background(bg).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
}
@main struct GalleryApp: App {
    let e = TVProvider.sample
    var off: TVEntry { TVEntry() }
    var body: some Scene { WindowGroup {
        ScrollView { VStack(spacing: 14) {
            HStack(spacing: 14) { card(158, 158, e.tint) { NowBody(family: .systemSmall, entry: e) }; card(158, 158, Mint.band) { NowBody(family: .systemSmall, entry: off) } }
            card(338, 158, e.tint) { NowBody(family: .systemMedium, entry: e) }
            card(338, 158, Mint.plane) { RemoteBody(family: .systemMedium, entry: e) }
            card(338, 158, Color.black) { AppsBody(entry: e) }
            card(338, 354, Mint.plane) { RemoteBody(family: .systemLarge, entry: e) }
        }.padding(10) }.background(Color(white: 0.8))
    } }
}
