import SwiftUI
import WidgetKit
// Widgets at real sizes for the cloud build's screenshots, in colour and as they look on a clear Home Screen. Never shipped.
func card<C: View>(_ w: CGFloat, _ h: CGFloat, clear: Bool = false, @ViewBuilder _ c: () -> C) -> some View {
    c().padding(16).frame(width: w, height: h).foregroundStyle(.white)
        .background { if clear { Color(red: 0.84, green: 0.48, blue: 0.66) } else { GraphiteBackground() } }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
}
@main struct GalleryApp: App {
    let e = MacEntry(date: Date(), snapshot: .sample)
    var body: some Scene { WindowGroup {
        ScrollView { VStack(spacing: 12) {
            card(338, 158) { StatusBody(family: .systemMedium, entry: e) }
            card(338, 158, clear: true) { StatusBody(family: .systemMedium, entry: e, flat: true) }
            HStack(spacing: 12) { card(158, 158) { StatusBody(family: .systemSmall, entry: e) }; card(158, 158, clear: true) { StatusBody(family: .systemSmall, entry: e, flat: true) } }
            card(338, 158) { TempBody(family: .systemMedium, entry: e) }
            HStack(spacing: 12) { card(158, 158) { TempBody(family: .systemSmall, entry: e) }; card(158, 158) { ClaudeBody(entry: e) } }
        }.padding(10) }.background(Color(white: 0.8))
    } }
}
