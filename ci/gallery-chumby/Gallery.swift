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
    func ringCard(_ s: ChumbyRingAttributes.ContentState, stale: Bool = false) -> some View {
        RingLockCard(state: s, stale: stale).frame(width: 370)
            .background(RingCardLook.sea.opacity(0.82), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
    func island(_ s: ChumbyRingAttributes.ContentState) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                RingOctopus(snoozed: s.snoozed).frame(width: 40)
                VStack(spacing: 1) {
                    Text(RingCardLook.headline(s, stale: false)).font(RingCardLook.face(13)).foregroundStyle(s.snoozed ? RingCardLook.soft : ChumbyPalette.hex(0xffb38f))
                    Text(s.title).font(RingCardLook.face(18)).foregroundStyle(.white).lineLimit(2)
                }
                .frame(maxWidth: .infinity)
                if s.snoozed, let again = s.again { RingCountdown(until: again).font(RingCardLook.face(17)).foregroundStyle(.white).frame(width: 60) } else { Color.clear.frame(width: 40) }
            }
            RingKeys(snoozed: s.snoozed, height: 42)
        }
        .padding(.horizontal, 18).padding(.vertical, 16).frame(width: 370)
        .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
    }
    func compact(_ s: ChumbyRingAttributes.ContentState) -> some View {
        HStack {
            RingOctopus(snoozed: s.snoozed, color: s.snoozed ? .white : ChumbyPalette.orange).frame(width: 24, height: 22)
            Spacer(minLength: 126)
            if s.snoozed, let again = s.again { RingCountdown(until: again).font(RingCardLook.face(14)).foregroundStyle(.white).frame(maxWidth: 44) }
            else { Image(systemName: "alarm.waves.left.and.right.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(ChumbyPalette.orange) }
        }
        .padding(.horizontal, 12).frame(height: 37).fixedSize()
        .background(.black, in: Capsule())
    }
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
            case 4:
                // The ringing alarm's Lock Screen card as iOS frames it: ringing, snoozed, a Stop that didn't land, an alarm
                // with no name, and one nothing has reached in half an hour.
                ringCard(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 40, snoozed: false))
                ringCard(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 120, snoozed: true, until: Date().timeIntervalSince1970 + 431))
                ringCard(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 40, snoozed: false, problem: "Didn’t stop. Try again."))
                ringCard(.init(name: "Morning shift at the shop", sound: "Pandora: Today’s Hits Radio", at: Date().timeIntervalSince1970 - 120, snoozed: true, until: Date().timeIntervalSince1970 + 431))
                ringCard(.init(name: "", sound: "Beep", at: Date().timeIntervalSince1970 - 40, snoozed: false))
                ringCard(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 2400, snoozed: false), stale: true)
            case 5:
                // The Dynamic Island, drawn from the card's own pieces as iOS lays them out (a plain app can't show the
                // real one): expanded ringing and snoozed, then compact and minimal.
                island(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 40, snoozed: false))
                island(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 120, snoozed: true, until: Date().timeIntervalSince1970 + 431))
                compact(.init(name: "Work", sound: "Beep", at: Date().timeIntervalSince1970 - 40, snoozed: false))
                compact(.init(name: "Work", sound: "Beep", at: Date().timeIntervalSince1970 - 40, snoozed: true, until: Date().timeIntervalSince1970 + 431))
                HStack { Capsule().fill(.black).frame(width: 126, height: 37); RingOctopus(snoozed: false, color: ChumbyPalette.orange).frame(width: 22, height: 20).frame(width: 37, height: 37).background(.black, in: Circle()) }
            case 6:
                // A press on its way and its answers (RingDesk, 11-18): Stopping… and Snoozing… with the keys dimmed but live,
                // a press the Chumby hasn't confirmed, and the snooze by the Chumby's own time.
                ringCard(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 40, snoozed: false, working: "Stopping…"))
                ringCard(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 40, snoozed: false, working: "Snoozing…"))
                ringCard(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 40, snoozed: false, problem: "Sent. The Chumby hasn’t confirmed yet."))
                ringCard(.init(name: "Work", sound: "Pandora: Today’s Hits", at: Date().timeIntervalSince1970 - 60, snoozed: true, until: Date().timeIntervalSince1970 + 538))
            default:
                HStack(spacing: 14) { card(158, 158) { AlarmBody(family: .systemSmall, entry: e) }; card(158, 158) { AlarmBody(family: .systemSmall, entry: skipped) } }
                HStack(spacing: 14) { card(158, 158) { AlarmBody(family: .systemSmall, entry: lost) }; card(158, 158) { BuddyBody(entry: e) } }
                card(338, 158) { ChumbyStatusBody(family: .systemMedium, entry: e) }
                HStack(spacing: 14) { card(158, 158) { ChumbyStatusBody(family: .systemSmall, entry: e) }; card(158, 158) { ChumbyStatusBody(family: .systemSmall, entry: lost) } }
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(page >= 4 ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.34), Color(red: 0.05, green: 0.06, blue: 0.12)], startPoint: .top, endPoint: .bottom)) : page == 3 ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.86, green: 0.55, blue: 0.72), Color(red: 0.72, green: 0.42, blue: 0.62)], startPoint: .top, endPoint: .bottom)) : page == 2 ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.35), Color(red: 0.35, green: 0.25, blue: 0.4)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color(white: 0.8)))
        }
    } }
}
