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
    static func headline(_ s: ChumbyRingAttributes.ContentState, stale: Bool) -> String {
        if stale { return "Rang at \(time(s.rang))" }
        if s.snoozed { return s.again.map { "Snoozed until \(time($0))" } ?? "Snoozed" }
        return "Ringing"
    }
    // Under the name: the time it's for (unless that is the name) and what it plays.
    static func detail(_ s: ChumbyRingAttributes.ContentState) -> String {
        [s.name.isEmpty ? "" : time(s.rang), s.sound].filter { !$0.isEmpty }.joined(separator: " · ")
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
        if until > Date() {
            Text(timerInterval: Date()...until, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

// Snooze and Stop, each a whole capsule: Stop in the app's orange and the wider of the two, alone once it's snoozed.
struct RingKeys: View {
    let snoozed: Bool
    var height: CGFloat = 46
    var body: some View {
        HStack(spacing: 10) {
            if !snoozed {
                Button(intent: ChumbyRingSnoozeIntent()) {
                    Label("Snooze", systemImage: "water.waves").font(RingCardLook.face(17)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(Color.white.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Button(intent: ChumbyRingStopIntent()) {
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
                    Text(state.title).font(RingCardLook.face(22)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                    let d = RingCardLook.detail(state)
                    if !d.isEmpty { Text(d).font(RingCardLook.face(14, bold: false)).foregroundStyle(RingCardLook.soft).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if state.snoozed, !stale, let again = state.again {
                    RingCountdown(until: again).font(RingCardLook.face(22)).foregroundStyle(.white).frame(maxWidth: 76)
                }
            }
            if let p = state.problem, !stale {
                Label(p, systemImage: "exclamationmark.circle.fill").font(RingCardLook.face(14, bold: false))
                    .foregroundStyle(ChumbyPalette.warn(true)).lineLimit(2)
            }
            // A card nothing has reached in half an hour can't say what the Chumby is doing: no keys that may do nothing.
            if !stale { RingKeys(snoozed: state.snoozed) }
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
                        Text(s.title).font(RingCardLook.face(18)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.snoozed, !context.isStale, let again = s.again {
                        RingCountdown(until: again).font(RingCardLook.face(17)).foregroundStyle(.white).frame(maxWidth: 60).padding(.trailing, 4)
                    } else {
                        Text(RingCardLook.time(s.rang)).font(RingCardLook.face(15)).foregroundStyle(RingCardLook.soft).padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if let p = s.problem, !context.isStale {
                            Text(p).font(RingCardLook.face(13, bold: false)).foregroundStyle(ChumbyPalette.warn(true)).lineLimit(2)
                        }
                        if !context.isStale { RingKeys(snoozed: s.snoozed, height: 42) }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                RingOctopus(snoozed: quiet, color: quiet ? .white : ChumbyPalette.orange).frame(width: 24, height: 22)
            } compactTrailing: {
                if s.snoozed, !context.isStale, let again = s.again {
                    RingCountdown(until: again).font(RingCardLook.face(14)).foregroundStyle(.white).frame(maxWidth: 44)
                } else {
                    Image(systemName: "alarm.waves.left.and.right.fill").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(quiet ? RingCardLook.soft : ChumbyPalette.orange)
                }
            } minimal: {
                RingOctopus(snoozed: quiet, color: quiet ? .white : ChumbyPalette.orange).frame(width: 22, height: 20)
            }
            .keylineTint(ChumbyPalette.orange)
            .widgetURL(Self.opens)
        }
    }
}
#endif
