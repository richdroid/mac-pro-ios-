import AppIntents
import SwiftUI
import WidgetKit

// The ringing alarm's card: on the Lock Screen and in the Dynamic Island while a Chumby alarm rings or snoozes, with the
// Chumby's own Snooze and Stop (Richard, 2026-11-14: "i should be able to turn an alarm off from my phone"). Started and
// ended by the Mac's push; the keys run ChumbyRingActions in the app. Drawn in the app's own hand: the octopus, Trebuchet,
// the deep sea under white words, the orange of the app's Stop.
enum RingCardLook {
    static let sea = ChumbyPalette.hex(0x061a3f), navy = ChumbyPalette.hex(0x1f2f5c)
    static let soft = Color.white.opacity(0.72)
    static func face(_ size: CGFloat, bold: Bool = true) -> Font { .custom("Trebuchet MS", size: size).weight(bold ? .bold : .regular) }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    // "Ringing", "Snoozed until 2:49 PM", and for a card nothing has reached in a long while, only what is known.
    // Each time is said once: a snooze's end is the countdown beside it, and a stale card's time is its headline.
    static func headline(_ s: ChumbyRingAttributes.ContentState, stale: Bool) -> String {
        if stale { return "Rang at \(time(s.rang))" }
        if let w = s.working { return w }
        // The countdown beside it is a length, never a clock time: "Snoozed" over a bare "7:02" read as 7:02 (gate, 11-17).
        if s.snoozed { return s.until.map { Date(timeIntervalSince1970: $0) > Date() } == true ? "Snoozed, rings in" : "Snoozed" }
        return "Ringing"
    }
    // Under the name, whole or not at all (never cut short): the time it's for and what it plays, then the sound alone.
    static func details(_ s: ChumbyRingAttributes.ContentState, stale: Bool) -> [String] {
        let at = s.name.isEmpty || stale ? "" : time(s.rang)
        let forms = [[at, s.sound].filter { !$0.isEmpty }.joined(separator: " · "), s.sound, at].filter { !$0.isEmpty }
        // Each form once (a nameless or stale card has only the sound, twice over): ViewThatFits keys them by their words.
        return forms.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

// The octopus: awake and orange-eyed while it rings, eyes shut through a snooze.
struct RingOctopus: View {
    let snoozed: Bool
    var color: Color = .white
    var body: some View { OctopusMark(color: color, eyes: RingCardLook.navy, blink: snoozed ? 0.08 : 1) }
}

// How long until a snooze rings again, counting down by itself.
struct RingCountdown: View {
    let until: Date
    var body: some View {
        // Drawn only while there is time left. (A card can't redraw itself at the end: if the Mac's word that it rings
        // again is late, the clock rests at 0:00 until it comes.)
        if until > Date() {
            Text(timerInterval: Date()...until, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}
// The line under the name: the fullest form that fits whole.
struct RingDetail: View {
    let forms: [String]
    var body: some View {
        if !forms.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(forms, id: \.self) { Text($0).lineLimit(1).fixedSize() }
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }
}

// Snooze and Stop, each a whole capsule: Stop in the app's orange and the wider of the two, alone once it's snoozed.
struct RingKeys: View {
    let snoozed: Bool
    var height: CGFloat = 46
    // A key pressed and not yet answered: both dim, so the press is seen to have landed. They stay pressable: a second
    // press joins the first (RingDesk), and a card whose app was ended mid-press must never be left with dead keys.
    var working = false
    var body: some View { keys.opacity(working ? 0.45 : 1) }
    // The CI gallery draws the card in a plain app, where the Lock Screen's intent keys have nothing to run in.
    #if GALLERY
    func key<L: View>(_ intent: some AppIntent, @ViewBuilder _ label: () -> L) -> some View { Button {} label: { label() } }
    #else
    func key<L: View>(_ intent: some AppIntent, @ViewBuilder _ label: () -> L) -> some View { Button(intent: intent) { label() } }
    #endif
    var keys: some View {
        HStack(spacing: 10) {
            if !snoozed {
                key(ChumbyRingSnoozeIntent()) {
                    Label("Snooze", systemImage: "water.waves").font(RingCardLook.face(17)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(Color.white.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            key(ChumbyRingStopIntent()) {
                Label("Stop", systemImage: "stop.fill").font(RingCardLook.face(17)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: height)
                    .background(ChumbyPalette.orange, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

struct RingLockCard: View {
    let state: ChumbyRingAttributes.ContentState
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RingOctopus(snoozed: state.snoozed || stale).frame(width: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(RingCardLook.headline(state, stale: stale)).font(RingCardLook.face(14))
                        .foregroundStyle(state.snoozed || stale ? RingCardLook.soft : ChumbyPalette.hex(0xffb38f))
                    // The name whole: smaller before a second line, never an ellipsis.
                    Text(state.title).font(RingCardLook.face(22)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                    RingDetail(forms: RingCardLook.details(state, stale: stale)).font(RingCardLook.face(14, bold: false)).foregroundStyle(RingCardLook.soft)
                }
                Spacer(minLength: 4)
                if state.snoozed, !stale, let again = state.again {
                    RingCountdown(until: again).font(RingCardLook.face(22)).foregroundStyle(.white).frame(maxWidth: 76)
                }
            }
            if let p = state.problem, !stale {
                Label(p, systemImage: "exclamationmark.circle.fill").font(RingCardLook.face(14, bold: false))
                    .foregroundStyle(ChumbyPalette.warn(true)).fixedSize(horizontal: false, vertical: true)
            }
            // A card nothing has reached in half an hour can't say what the Chumby is doing: no keys that may do nothing.
            if !stale { RingKeys(snoozed: state.snoozed, working: state.working != nil) }
        }
        .padding(16)
    }
}

#if os(iOS)
struct ChumbyRingActivityWidget: Widget {
    static let opens = URL(string: "chumbyapp://ring")
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChumbyRingAttributes.self) { context in
            RingLockCard(state: context.state, stale: context.isStale)
                .activityBackgroundTint(RingCardLook.sea.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.opens)
        } dynamicIsland: { context in
            let s = context.state, quiet = s.snoozed || context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RingOctopus(snoozed: quiet).frame(width: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(RingCardLook.headline(s, stale: context.isStale)).font(RingCardLook.face(13))
                            .foregroundStyle(quiet ? RingCardLook.soft : ChumbyPalette.hex(0xffb38f)).lineLimit(1)
                        Text(s.title).font(RingCardLook.face(18)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.snoozed, !context.isStale, let again = s.again {
                        RingCountdown(until: again).font(RingCardLook.face(17)).foregroundStyle(.white).frame(maxWidth: 60).padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if let p = s.problem, !context.isStale {
                            Text(p).font(RingCardLook.face(13, bold: false)).foregroundStyle(ChumbyPalette.warn(true)).fixedSize(horizontal: false, vertical: true)
                        }
                        if !context.isStale { RingKeys(snoozed: s.snoozed, height: 42, working: s.working != nil) }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                RingOctopus(snoozed: quiet, color: quiet ? .white : ChumbyPalette.ring).frame(width: 24, height: 22)
            } compactTrailing: {
                if s.snoozed, !context.isStale, let again = s.again {
                    RingCountdown(until: again).font(RingCardLook.face(14)).foregroundStyle(.white).frame(maxWidth: 44)
                } else {
                    Image(systemName: "alarm.waves.left.and.right.fill").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(quiet ? RingCardLook.soft : ChumbyPalette.ring)
                }
            } minimal: {
                RingOctopus(snoozed: quiet, color: quiet ? .white : ChumbyPalette.ring).frame(width: 22, height: 20)
            }
            .keylineTint(ChumbyPalette.ring)
            .widgetURL(Self.opens)
        }
    }
}
#endif
