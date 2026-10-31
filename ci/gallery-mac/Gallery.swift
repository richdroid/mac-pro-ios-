import SwiftUI
import WidgetKit
// Widgets at real sizes for the cloud build's screenshots. Never shipped.
func card<C: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
    c().padding(16).frame(width: w, height: h).foregroundStyle(.white).background(GraphiteBackground()).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
}
@main struct GalleryApp: App {
    let e = MacEntry(date: Date(), snapshot: .sample)
    var body: some Scene { WindowGroup {
        ScrollView { VStack(spacing: 14) {
            HStack(spacing: 14) { card(158, 158) { StatusBody(family: .systemSmall, entry: e) }; card(158, 158) { TempBody(family: .systemSmall, entry: e) }; }
            card(158, 158) { ClaudeBody(entry: e) }
            card(338, 158) { StatusBody(family: .systemMedium, entry: e) }
            // How the glyph looks on a clear Home Screen.
            HStack(spacing: 20) { CylinderGlyph().fill(.white, style: FillStyle(eoFill: true)).frame(width: 62, height: 100); CylinderGlyph().fill(.white, style: FillStyle(eoFill: true)).frame(width: 34, height: 55) }.padding(16).frame(width: 338).background(Color(red: 0.86, green: 0.5, blue: 0.68)).clipShape(RoundedRectangle(cornerRadius: 24))
            card(338, 158) { TempBody(family: .systemMedium, entry: e) }
            card(338, 158) { AppsBody(entry: e) }
        }.padding(10) }.background(Color(white: 0.8))
    } }
}
