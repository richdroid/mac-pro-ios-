import SwiftUI
import WidgetKit
// Widgets at real sizes for the cloud build's screenshots. Never shipped.
func card<C: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
    c().padding(16).frame(width: w, height: h)
        // What the widget's container draws on a real Home Screen.
        .background(ZStack { LinearGradient(colors: [Color(white: 0.17), Color(white: 0.05)], startPoint: .top, endPoint: .bottom); RadialGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.74).opacity(0.28), .clear], center: .center, startRadius: 10, endRadius: 170) })
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
