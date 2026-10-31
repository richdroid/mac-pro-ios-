import SwiftUI
import WidgetKit
// Widgets at real sizes for the cloud build's screenshots. Never shipped.
func card<C: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
    c().padding(16).frame(width: w, height: h).background(SeaFor()).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
}
@main struct GalleryApp: App {
    let e = ChumbyProvider.sample
    var off: ChumbyEntry { ChumbyEntry(date: Date()) }
    var body: some Scene { WindowGroup {
        ScrollView { VStack(spacing: 14) {
            HStack(spacing: 14) { card(158, 158) { AlarmBody(family: .systemSmall, entry: e) }; card(158, 158) { BuddyBody(entry: e) }; card(158, 158) { AlarmBody(family: .systemSmall, entry: off) } }
            card(338, 158) { RemoteBody(entry: e) }
            card(338, 158) { RightNowBody(entry: e) }
            card(338, 158) { RightNowBody(entry: off) }
        }.padding(10) }.background(Color(white: 0.8))
    } }
}
