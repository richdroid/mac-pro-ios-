import SwiftUI
#if os(iOS)
import ActivityKit
#endif

// A ringing alarm, on the phone (Richard, 2026-11-14: "i feel like i should be able to turn an alarm off from my phone
// like could u have a notif go off that the alarm is ringing with details make it beautiful and full screen chumby
// esque"). Three places, one alarm:
//  - the notification (ChumbyPush.swift) and the Lock Screen card (ChumbyRingActivity.swift), both raised by the Mac's
//    push the moment it sees the Chumby ring;
//  - this file's page, full screen in the app: the time, the alarm, Snooze, and a Stop that is slid, never tapped, so a
//    thumb half asleep can't end the alarm by brushing it.
// Stop and Snooze everywhere are the Chumby's own (cmd ringoff / ringsnooze: the panel's stop and snooze).

// MARK: - The card's link to the Mac
enum RingLink {
    // What the Mac's push says is ringing ("ring" in the notification), or nil for none.
    static func state(_ any: Any?) -> ChumbyRingAttributes.ContentState? {
        guard let d = any as? [String: Any], d["over"] == nil, let name = d["name"] as? String else { return nil }
        return .init(name: name, sound: d["sound"] as? String ?? "", at: (d["at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970,
                     snoozed: (d["snoozed"] as? NSNumber)?.boolValue ?? false, until: (d["until"] as? NSNumber)?.doubleValue)
    }
    static func fromMac(_ any: Any?) async {
        guard let s = state(any) else { await ChumbyRingCard.over(); return }
        await ChumbyRingCard.show(s)
        if s.snoozed { await ChumbyRingCard.clearNotice() }
    }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    #if os(iOS)
    @MainActor private static var started = false
    @MainActor private static var heard = Set<String>()
    // Two kinds of token go to the Mac: the one that lets it start a card on this phone when an alarm rings, and each
    // card's own, which lets it change the card (snoozed, ringing again) and end it.
    @MainActor static func start() {
        guard !started, !ChumbyNotify.shared.staged else { return }
        started = true
        Task { for await t in Activity<ChumbyRingAttributes>.pushToStartTokenUpdates { await ChumbyNotify.shared.tellMac(["kind": "ring-start", "token": hex(t)]) } }
        Task { for await a in Activity<ChumbyRingAttributes>.activityUpdates { listen(a) } }
        for a in Activity<ChumbyRingAttributes>.activities { listen(a) }
    }
    @MainActor static func listen(_ a: Activity<ChumbyRingAttributes>) {
        guard a.activityState == .active || a.activityState == .stale, heard.insert(a.id).inserted else { return }
        Task {
            // One ring, one card: a newer card takes the place of any before it.
            for old in Activity<ChumbyRingAttributes>.activities where old.id != a.id && heard.contains(old.id) { await old.end(nil, dismissalPolicy: .immediate) }
            for await t in a.pushTokenUpdates { await ChumbyNotify.shared.tellMac(["kind": "ring-activity", "id": a.id, "token": hex(t)]) }
        }
    }
    // The app in front through a ring with no card (the Mac's push never came, or cards were only just allowed): the app
    // puts one up itself, so the Lock Screen has it once the phone is put down.
    @MainActor static func ensure(_ s: ChumbyRingAttributes.ContentState) {
        guard !ChumbyNotify.shared.staged, ChumbyNotify.shared.enabled, ChumbyRingCard.all.isEmpty, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: s, staleDate: Date().addingTimeInterval(31 * 60))
        if let made = try? Activity.request(attributes: ChumbyRingAttributes(id: String(Int(s.at))), content: content, pushType: .token) { listen(made) }
    }
    #else
    @MainActor static func start() {}
    @MainActor static func ensure(_ s: ChumbyRingAttributes.ContentState) {}
    #endif
}

// MARK: - The ringing page
struct RingScreen: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    // Everything the page says, kept while the alarm is there, so its words hold still as it closes.
    struct Shown: Equatable { var name: String; var sound: String; var snoozed: Bool; var until: Date?; var at: Date? }
    @State private var frozen: Shown?
    @State private var sawRing = false
    @State private var stopping = false
    @State private var snoozing = false
    @State private var nothing = false

    var live: Shown? {
        guard let r = model.sys.ringing else { return nil }
        // When it began: the Chumby's own note of its newest ring, when that is this alarm's.
        let at = model.state.rang.flatMap { $0.name == r.name && Date().timeIntervalSince1970 - $0.t < 7200 ? Date(timeIntervalSince1970: $0.t) : nil } ?? model.ringHint?.rang
        return Shown(name: r.name, sound: r.sound, snoozed: r.snoozed, until: model.snoozeEnds, at: at)
    }
    var hinted: Shown? { model.ringHint.map { Shown(name: $0.name, sound: $0.sound, snoozed: $0.snoozed, until: $0.again, at: $0.rang) } }
    var shown: Shown? { live ?? frozen ?? hinted }
    var dark: Bool { scheme == .dark }
    func close() { model.ringScreen = false }

    var status: String {
        if nothing { return "Nothing is ringing now" }
        if stopping { return "Stopping…" }
        guard let s = shown else { return "Reaching the Chumby…" }
        if model.sys.ringing == nil && !sawRing && model.unreachable { return model.reachWords }
        if s.snoozed { return s.until.map { "Snoozed until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Snoozed" }
        return "Ringing"
    }
    var title: String {
        guard let s = shown else { return "" }
        let n = s.name.hasPrefix(Alarm.calendarPrefix) ? String(s.name.dropFirst(Alarm.calendarPrefix.count)) : s.name
        return n.isEmpty ? "Alarm" : n
    }
    // "2:40 PM alarm · Pandora: Today's Hits"
    var detail: String {
        guard let s = shown else { return "" }
        return [s.at.map { "\($0.formatted(date: .omitted, time: .shortened)) alarm" } ?? "", s.sound].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var snoozeLength: String? {
        guard let r = model.sys.ringing, let m = model.state.alarms.first(where: { $0.name == r.name })?.snooze, Int(m) != nil else { return nil }
        return "\(m) min"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { g in
                // Upright: the clock over the keys, the keys in the thumb's reach. On its side or open flat: the clock on
                // the left half and the keys on the right, so nothing sits across the fold.
                let sideways = g.size.width > g.size.height
                Group {
                    if sideways {
                        HStack(spacing: 0) {
                            face(big: min(g.size.height * 0.3, 96)).frame(maxWidth: .infinity)
                            keys.frame(maxWidth: 420).frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 0) {
                            Spacer(minLength: 12)
                            face(big: min(g.size.width * 0.27, 112))
                            Spacer(minLength: 24)
                            keys.frame(maxWidth: 460)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 22)
                .frame(width: g.size.width, height: g.size.height)
            }
            .background { SeaBackground().ignoresSafeArea() }
            .foregroundStyle(ChumbyPalette.ink(dark))
            // The way out without touching the alarm is the system's own item (the Duo puts it in its side bar).
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { close() } label: { Label("Close", systemImage: "xmark") } }
            }
        }
        .onAppear { if let l = live { sawRing = true; frozen = l } }
        .onChange(of: live) { _, l in
            if let l { sawRing = true; nothing = false; frozen = l }
            // Over (stopped here, on the Chumby, or played out): the page has nothing left to offer.
            else if sawRing && !stopping { close() }
        }
        .task {
            // Opened from a tap with nothing ringing by the time the Chumby answers: said, then out of the way.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard model.sys.ringing == nil, !sawRing, !stopping, !model.unreachable, ChumbyModel.pose != "ringscreen" else { return }
            withAnimation(.snappy) { nothing = true }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if model.sys.ringing == nil { close() }
        }
        .task(id: model.sys.ringing != nil) {
            // Still going twenty seconds on with no card on the Lock Screen: the app puts one there.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled, let r = model.sys.ringing, !model.unreachable, let s = live {
                RingLink.ensure(.init(name: title == "Alarm" ? "" : title, sound: r.sound, at: (s.at ?? Date()).timeIntervalSince1970, snoozed: r.snoozed, until: s.until?.timeIntervalSince1970))
            }
        }
    }

    func face(big: CGFloat) -> some View {
        let quiet = shown?.snoozed == true || nothing
        return VStack(spacing: 4) {
            // He rattles while it rings and sleeps through a snooze.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || quiet)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let swing = quiet || still ? 0 : sin(2 * .pi * t / 0.32) * 7
                OctopusMark(color: ChumbyPalette.oct(dark), blink: quiet ? 0.08 : 1)
                    .frame(width: big * 0.92)
                    .rotationEffect(.degrees(swing), anchor: .bottom)
                    .offset(y: quiet || still ? 0 : -3 * abs(sin(2 * .pi * t / 0.64)))
            }
            .frame(height: big * 0.8)
            .accessibilityHidden(true)
            .padding(.bottom, 10)
            // One line that changes hands: the old words are gone before the new ones come.
            ZStack {
                Text(status).id(status)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)), removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
            .font(.custom("Trebuchet MS", size: 20).weight(.bold))
            .foregroundStyle(quiet || stopping || shown == nil ? ChumbyPalette.sub(dark) : ChumbyPalette.warn(dark))
            // The time now, large: the first thing wanted on waking.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let c = clockParts(ctx.date)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(c.0).font(.custom("Trebuchet MS", size: big).weight(.bold)).monospacedDigit().contentTransition(.numericText())
                    Text(c.1).font(.custom("Trebuchet MS", size: big * 0.3).weight(.bold))
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityElement(children: .combine)
            }
            if shown != nil {
                Text(title).font(.custom("Trebuchet MS", size: 28).weight(.bold)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                if !detail.isEmpty {
                    Text(detail).font(.custom("Trebuchet MS", size: 17)).foregroundStyle(ChumbyPalette.sub(dark)).lineLimit(2).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    var keys: some View {
        let snoozed = shown?.snoozed == true
        return VStack(spacing: 14) {
            if let f = model.failed("ring") { FailNote(text: f).padding(.horizontal, 16).padding(.vertical, 10).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            if !snoozed && !nothing {
                Button { snooze() } label: {
                    HStack(spacing: 8) {
                        Label("Snooze", systemImage: "water.waves").labelStyle(.titleAndIcon)
                        if let m = snoozeLength { Text(m).fontWeight(.regular).foregroundStyle(ChumbyPalette.sub(dark)) }
                    }
                    .font(.custom("Trebuchet MS", size: 22).weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(snoozing || stopping)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if !nothing {
                SlideToStop(label: snoozed ? "Slide to end the snooze" : "Slide to stop", busy: stopping) { stop() }
            }
        }
        .animation(ChumbyModel.ringSpring, value: snoozed)
        .animation(.snappy, value: nothing)
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        Task {
            let ok = await model.ringOffTask().value
            stopping = false
            if ok { close() }
        }
    }
    func snooze() {
        guard !snoozing else { return }
        snoozing = true
        Task { _ = await model.ringSnoozeTask().value; snoozing = false }
    }
}

// Stop, slid: the gel slab of Home's Skip in the app's orange, with a white key that is dragged to its far end. A tap
// does nothing, a slide let go short springs back, and only the whole run stops the alarm. One haptic, the thunk as it
// lands (ChumbyModel.ringOffTask gives it).
struct SlideToStop: View {
    var label = "Slide to stop"
    var busy = false
    let done: () -> Void
    @State private var pull: CGFloat = 0
    @State private var landed = false
    static let height: CGFloat = 76, key: CGFloat = 60, inset: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            let run = max(g.size.width - Self.key - Self.inset * 2, 1)
            let k = landed ? 1 : min(max(pull / run, 0), 1)
            ZStack(alignment: .leading) {
                ChumbyGel(colors: [0xff8f5e, 0xfc5825, 0xdc4410], rim: 0x9c2c08)
                Text(label).font(.custom("Trebuchet MS", size: 20).weight(.bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.leading, Self.key + Self.inset * 2).padding(.trailing, 16)
                    .frame(maxWidth: .infinity)
                    .opacity(1 - Double(k) * 1.8)
                RoundedRectangle(cornerRadius: 19, style: .continuous).fill(.white)
                    .shadow(color: ChumbyPalette.hex(0x9c2c08).opacity(0.35), radius: 3, y: 2)
                    .overlay {
                        if busy { ProgressView().tint(ChumbyPalette.orange) }
                        else { Image(systemName: k > 0.02 ? "stop.fill" : "chevron.right.2").font(.system(size: 22, weight: .heavy)).foregroundStyle(ChumbyPalette.orange) }
                    }
                    .frame(width: Self.key, height: Self.key)
                    .padding(.leading, Self.inset)
                    .offset(x: k * run)
            }
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in if !landed && !busy { pull = v.translation.width } }
                    .onEnded { v in
                        guard !landed, !busy else { return }
                        if v.translation.width / run >= 0.8 {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { landed = true }
                            done()
                        } else {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { pull = 0 }
                        }
                    }
            )
        }
        .frame(height: Self.height)
        // Back from a Stop the Chumby didn't take: the key returns to its start, ready to be slid again.
        .onChange(of: busy) { _, b in if !b { withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { landed = false; pull = 0 } } }
        .accessibilityElement()
        .accessibilityLabel(label == "Slide to stop" ? "Stop the alarm" : "End the snooze")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !busy { done() } }
    }
}
