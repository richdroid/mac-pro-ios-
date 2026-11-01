import SwiftUI
import WidgetKit
// Widgets at real sizes for the cloud build's screenshots. Never shipped.
func card<C: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
    c().padding(16).frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
}
@main struct GalleryApp: App {
    var e: MacEntry { MacEntry(date: Date(), state: .sample) }
    var body: some Scene { WindowGroup {
        ScrollView { VStack(spacing: 12) {
            card(338, 158) { StatusView(forced: .systemMedium, entry: e) }
            HStack(spacing: 12) { card(158, 158) { StatusView(forced: .systemSmall, entry: e) }; card(158, 158) { TempView(forced: .systemSmall, entry: e) } }
            card(338, 158) { TempView(forced: .systemMedium, entry: e) }
            HStack(spacing: 12) { card(158, 158) { ClaudeView(entry: e) } }
        }.padding(10) }.background(Color(white: 0.8))
    } }
}
