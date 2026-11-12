import SwiftUI
import WidgetKit
// Widgets at real sizes for the cloud build's screenshots. Never shipped. Four screens (-page 0, 1, 2, 3), so nothing sits
// below the capture: the Home Screen widgets, then Your Chumby in each state, then tinted and Lock Screen renders, then
// Your Chumby on a clear Home Screen as his phone draws it.
func card<C: View>(_ w: CGFloat, _ h: CGFloat, sea: Bool = true, @ViewBuilder _ c: () -> C) -> some View {
    c().padding(16).frame(width: w, height: h)
        .environment(\.colorScheme, .dark).foregroundStyle(sea ? ChumbyPalette.ink(true) : .white)
        .background { if sea { SeaFor() } else { Color.white.opacity(0.16) } }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
}
// A Lock Screen accessory at its real size, on a dark wallpaper, flattened as the Lock Screen draws it.
func accessory<C: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
    c().frame(width: w, height: h).foregroundStyle(.white).environment(\.widgetRenderingMode, .vibrant).environment(\.colorScheme, .dark)
}
// A clear or tinted Home Screen as the system draws it, at its harshest: every colour to white, keeping only how opaque
// it is. The app can't flatten a render the way the Home Screen does, so the tinted shots looked fine while his phone
// showed a blank white night button (2026-11-05); this shows what's left once the colours are gone.
extension View { func flattened() -> some View { self.colorMultiply(.black).colorInvert() } }
@main struct GalleryApp: App {
    let e = ChumbyProvider.sample
    var off: ChumbyEntry { ChumbyEntry(date: Date()) }
    var skipped: ChumbyEntry {
        var s = ChumbyProvider.sample
        s.skipped = SkippedAlarm(name: "Work", at: (s.nextAt ?? Date()).timeIntervalSince1970, when: "weekday")
        s.nextAt = s.nextAt.map { Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0 }
        return s
    }
    var night: ChumbyEntry { var s = skipped; s.sys.night = 1; return s }
    var nightOnly: ChumbyEntry { var s = ChumbyProvider.sample; s.sys.night = 1; return s }
    var playing: ChumbyEntry { var s = ChumbyProvider.sample; s.playing = true; return s }
    var lost: ChumbyEntry { var s = ChumbyEntry(date: Date()); s.lastSeen = Date().addingTimeInterval(-25 * 60); return s }
    var page: Int { UserDefaults.standard.integer(forKey: "page") }
    var body: some Scene { WindowGroup {
        if UserDefaults.standard.bool(forKey: "sheets") { ChumbySheets() } else {
        VStack(spacing: 14) {
            switch page {
            case 1:
                card(338, 158) { RemoteBody(entry: e) }
                card(338, 158) { RemoteBody(entry: night) }
                card(338, 158) { RemoteBody(entry: playing) }
                card(338, 158) { RemoteBody(entry: lost) }
            case 3:
                // His Home Screen (2026-11-05): a pink clear-mode wallpaper. Day, night (lit button) and night with a skip.
                card(338, 158, sea: false) { RemoteBody(entry: e).flattened() }.environment(\.widgetRenderingMode, .accented)
                card(338, 158, sea: false) { RemoteBody(entry: nightOnly).flattened() }.environment(\.widgetRenderingMode, .accented)
                card(338, 158, sea: false) { RemoteBody(entry: night).flattened() }.environment(\.widgetRenderingMode, .accented)
            case 2:
                // A tinted (clear) Home Screen flattens every colour to one tone over the wallpaper.
                HStack(spacing: 14) {
                    card(158, 158, sea: false) { AlarmBody(family: .systemSmall, entry: e) }.environment(\.widgetRenderingMode, .accented)
                    card(158, 158, sea: false) { AlarmBody(family: .systemSmall, entry: skipped) }.environment(\.widgetRenderingMode, .accented)
                }
                card(338, 158, sea: false) { RemoteBody(entry: e) }.environment(\.widgetRenderingMode, .accented)
                HStack(spacing: 14) {
                    accessory(76, 76) { AlarmBody(family: .accessoryCircular, entry: e) }
                    accessory(170, 76) { AlarmBody(family: .accessoryRectangular, entry: e) }
                }
                HStack(spacing: 14) {
                    accessory(76, 76) { AlarmBody(family: .accessoryCircular, entry: skipped) }
                    accessory(170, 76) { AlarmBody(family: .accessoryRectangular, entry: skipped) }
                }
                accessory(300, 24) { AlarmBody(family: .accessoryInline, entry: e) }
            default:
                HStack(spacing: 14) { card(158, 158) { AlarmBody(family: .systemSmall, entry: e) }; card(158, 158) { AlarmBody(family: .systemSmall, entry: skipped) } }
                HStack(spacing: 14) { card(158, 158) { AlarmBody(family: .systemSmall, entry: lost) }; card(158, 158) { BuddyBody(entry: e) } }
                card(338, 158) { ChumbyStatusBody(family: .systemMedium, entry: e) }
                HStack(spacing: 14) { card(158, 158) { ChumbyStatusBody(family: .systemSmall, entry: e) }; card(158, 158) { ChumbyStatusBody(family: .systemSmall, entry: lost) } }
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(page == 3 ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.86, green: 0.55, blue: 0.72), Color(red: 0.72, green: 0.42, blue: 0.62)], startPoint: .top, endPoint: .bottom)) : page == 2 ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.35), Color(red: 0.35, green: 0.25, blue: 0.4)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color(white: 0.8)))
        }
    } }
}
