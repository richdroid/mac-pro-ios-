import SwiftUI
#if os(iOS)
import ActivityKit
#endif
#if canImport(UIKit)
import UIKit
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
                     snoozed: (d["snoozed"] as? NSNumber)?.boolValue ?? false, until: (d["until"] as? NSNumber)?.doubleValue,
                     snooze: (d["snooze"] as? NSNumber)?.intValue)
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
// Put up over whatever is showing (a tab, an alarm's editor, a picker): it is presented from the frontmost page itself,
// since a cover hung on the app's root can't come up while another cover is. `model.ringScreen` says whether it should be
// up; this makes it so, and is asked again whenever the app comes forward.
@MainActor enum RingPresenter {
    #if canImport(UIKit)
    private static weak var shown: UIViewController?
    static func sync(_ model: ChumbyModel) {
        if !model.ringScreen {
            if let s = shown, !s.isBeingDismissed { s.dismiss(animated: true) }
            shown = nil
            return
        }
        guard shown == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.keyWindow, var top = window.rootViewController else { return }
        // The frontmost page; an alert is never presented from (the page under it is).
        while let next = top.presentedViewController, !next.isBeingDismissed, !(next is UIAlertController) { top = next }
        guard top.presentedViewController == nil else { return }
        let host = UIHostingController(rootView: RingScreen().environmentObject(model))
        host.modalPresentationStyle = .fullScreen
        shown = host
        top.present(host, animated: true)
    }
    #else
    static func sync(_ model: ChumbyModel) {}
    #endif
}

// Where the Duo's fold crosses this page, in the page's own space: nil folded, or on a phone with no fold.
struct RingFold: Equatable {
    var crease: CGRect?
    #if os(iOS)
    @MainActor static func read(_ g: GeometryProxy) -> RingFold {
        if #available(iOS 27.1, *) {
            guard g.reservedRegions(kind: .division).isEmpty else { return RingFold() }
            return RingFold(crease: g.reservedRegions(kind: .division, options: .includeInactive).first?.frame)
        }
        return RingFold()
    }
    #else
    @MainActor static func read(_ g: GeometryProxy) -> RingFold { RingFold() }
    #endif
}

struct RingScreen: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    // Everything the page says, kept while the alarm is there, so its words hold still as it closes.
    struct Shown: Equatable { var name: String; var sound: String; var snoozed: Bool; var until: Date?; var at: Date? }
    @State private var frozen: Shown?
    @State private var rattle = OctoRattle()
    @State private var sawRing = false
    @State private var stopping = false
    @State private var snoozing = false
    @State private var nothing = false
    // The Chumby's readings as the page opened: one more is the first it has heard since.
    @State private var readingsAtOpen: Int?
    // "Reaching the Chumby…" only once nothing has come for 1.5 s: the page never opens on it, and a line that comes and
    // goes within half a second can't be read (gate, 11-22: 0.3 s on opening).
    @State private var reachSaid = false

    var live: Shown? {
        guard let r = model.sys.ringing else { return nil }
        // When it began: the Chumby's own note of its newest ring, when that is this alarm's.
        let at = model.state.rang.flatMap { $0.name == r.name && Date().timeIntervalSince1970 - $0.t < 7200 ? Date(timeIntervalSince1970: $0.t) : nil } ?? model.ringHint?.rang
        return Shown(name: r.name, sound: r.sound, snoozed: r.snoozed, until: model.snoozeEnds, at: at)
    }
    var hinted: Shown? { model.ringHint.map { Shown(name: $0.name, sound: $0.sound, snoozed: $0.snoozed, until: $0.again, at: $0.rang) } }
    var shown: Shown? { live ?? frozen ?? hinted }
    var dark: Bool { scheme == .dark }
    // Out of reach: the page says so and offers no key that can't land (as the small card does).
    var away: Bool { model.unreachable && !stopping }
    var failure: String? { ChumbyModel.pose == "ringfail" ? "Didn’t stop. \(ChumbyWords.notAnswering)." : model.failed("ring") }
    func close() { model.ringHint = nil; model.ringScreen = false }

    var status: String {
        if nothing { return "Nothing is ringing now" }
        if stopping { return "Stopping…" }
        // A press from here, the card or the notification, until the Chumby confirms it (the same words everywhere).
        if let w = model.ringWorking { return w }
        if away { return model.reachWords }
        guard let s = shown else { return reachSaid ? "Reaching the Chumby…" : " " }
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
    // From the alarm the page shows (the Chumby's reading or the tap's word), so it comes with the alarm's name, not after.
    var snoozeLength: String? {
        guard let n = shown?.name, let m = model.state.alarms.first(where: { $0.name == n })?.snooze, Int(m) != nil else { return nil }
        return "\(m) min"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { g in
                let fold = RingFold.read(g).crease
                // Half the crease and a little air on each side of it, as the app's two panes keep (never less than 24).
                let air: CGFloat = fold.map { min(max(24, min($0.width, $0.height) / 2 + 4), 40) } ?? 0
                Group {
                    if let c = fold, c.width >= c.height {
                        // Open and upright (how he holds it): the fold runs across. The clock has the upper half and the
                        // keys the lower, one column of one width, gathered at the fold from either side (centred in their
                        // halves, the two floated apart over a band of bare sea), nothing on the crease.
                        let top = max(c.midY - air, 0), column = min(g.size.width - 40, 500)
                        VStack(spacing: 0) {
                            face(big: min(column * 0.24, top * 0.3, 128)).frame(width: column)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).frame(height: top)
                            Color.clear.frame(height: air * 2)
                            keys.frame(width: column).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    } else if let c = fold {
                        // Open flat: the fold runs down. The clock left of it, the keys right of it. The columns start
                        // inside the page's 20 pt side padding, so that is taken off the left one: measured from the
                        // reader's edge it ran 20 pt into the hinge's band (gate, 11-22: right edge 472, fold 455–495).
                        let left = max(c.midX - air - 20, 0)
                        HStack(spacing: 0) {
                            face(big: min(g.size.height * 0.26, left * 0.24, 104)).frame(maxWidth: .infinity, maxHeight: .infinity).frame(width: left)
                            Color.clear.frame(width: air * 2)
                            keys.frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if g.size.width > g.size.height {
                        // Folded and on its side.
                        HStack(spacing: 24) {
                            face(big: min(g.size.height * 0.24, 88)).frame(maxWidth: .infinity)
                            keys.frame(maxWidth: 400).frame(maxWidth: .infinity)
                        }
                    } else {
                        // Folded and upright: the clock over the keys, the keys in the thumb's reach.
                        VStack(spacing: 0) {
                            Spacer(minLength: 8)
                            face(big: min(g.size.width * 0.24, g.size.height * 0.15, 104))
                            Spacer(minLength: 16)
                            keys.frame(maxWidth: 460)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                .frame(width: g.size.width, height: g.size.height)
            }
            .background { SeaBackground().ignoresSafeArea() }
            .font(.custom("Trebuchet MS", size: 16))
            .foregroundStyle(ChumbyPalette.ink(dark))
            // The way out without touching the alarm is the system's own item, at the top of the side column where Close
            // goes on the Duo, as on every page of the app. It had a bar across the top: the clock and Wi-Fi then stood
            // in a row while the page was up and jumped back into their column as it left (gate, 11-22).
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { close() } label: { Label("Close", systemImage: "xmark") } }
            }
        }
        .tint(ChumbyPalette.acc(dark))
        .task { try? await Task.sleep(nanoseconds: 1_500_000_000); reachSaid = true }
        .onAppear {
            if readingsAtOpen == nil { readingsAtOpen = model.ringReadings }
            if let l = live { sawRing = true; frozen = l }
        }
        // Gone by any road (closed here, or the page under it put away): the model is told, so it can come up again.
        .onDisappear { if model.ringScreen { model.ringHint = nil; model.ringScreen = false } }
        .onChange(of: live) { _, l in
            if let l { sawRing = true; nothing = false; frozen = l }
            // Over (stopped here, on the Chumby, or played out): the page has nothing left to offer.
            else if sawRing && !stopping { close() }
        }
        // Opened from a tap, and the first reading taken since says nothing is ringing (stopped on the Chumby meanwhile,
        // or an old notification): said, then out of the way. Decided by a reading, never by a clock: on a slow link the
        // page waits, saying it is reaching the Chumby, with the keys there to be used.
        .onChange(of: model.ringReadings) { _, n in
            guard n > (readingsAtOpen ?? n), model.sys.ringing == nil, !sawRing, !stopping, !nothing, ChumbyModel.pose.isEmpty else { return }
            withAnimation(.snappy) { nothing = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if model.sys.ringing == nil { close() }
            }
        }
        // For the build's film: the ringing page itself, snoozed and then stopped, on a stand-in that answers as the Chumby does.
        .task {
            guard ChumbyModel.pose == "ringpagedemo" else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000); snooze()
            try? await Task.sleep(nanoseconds: 5_000_000_000); stop()
        }
        .task(id: model.sys.ringing != nil) {
            // Still going twenty seconds on with no card on the Lock Screen: the app puts one there.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled, let r = model.sys.ringing, !model.unreachable, let s = live {
                let m = model.state.alarms.first { $0.name == r.name }.flatMap { Int($0.snooze) }
                RingLink.ensure(.init(name: title == "Alarm" ? "" : title, sound: r.sound, at: (s.at ?? Date()).timeIntervalSince1970, snoozed: r.snoozed, until: s.until?.timeIntervalSince1970, snooze: m))
            }
        }
    }

    // The clock and the alarm, on the app's own card, so every word has the same ground under it whatever the sea is
    // doing behind (bare on the light sea, the orange and the grey lines fell to about 2.5:1 over its coral and mint).
    func face(big: CGFloat) -> some View {
        let quiet = shown?.snoozed == true || nothing || away
        return VStack(spacing: 4) {
            // He rattles while it rings and sleeps through a snooze.
            // His rattle dies away over a quarter second when the alarm is snoozed or stopped, and his eyes close with
            // it: before, he stopped dead at whatever angle he had reached and snapped upright in one frame.
            TimelineView(.animation(paused: still)) { ctx in
                let m = rattle.step(ctx.date.timeIntervalSinceReferenceDate, on: !(quiet || still))
                OctopusMark(color: ChumbyPalette.oct(dark), blink: 0.08 + 0.92 * m.amp)
                    .frame(width: big * 0.8)
                    .rotationEffect(.degrees(sin(m.phase) * 7 * m.amp), anchor: .bottom)
                    .offset(y: -3 * abs(sin(m.phase / 2)) * m.amp)
            }
            .frame(height: big * 0.7)
            .accessibilityHidden(true)
            .padding(.bottom, 8)
            // One line that changes hands: the old words are gone before the new ones come. A Stop or Snooze the Chumby
            // didn't take is said here, in the line's own place, so the page never grows past the display.
            ZStack {
                if let f = failure, !stopping {
                    Label(f, systemImage: "exclamationmark.circle.fill").font(.custom("Trebuchet MS", size: 17).weight(.bold))
                        .foregroundStyle(ChumbyPalette.warn(dark)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .id("failure")
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)), removal: .opacity.animation(.easeOut(duration: 0.1))))
                } else {
                    // The word cross-fades in place: the new one is on its way up as the old one goes, so the line is
                    // never blank (gate, 11-20: it stood empty for two frames as a Snooze was confirmed).
                    Text(status).id(status)
                        .font(.custom("Trebuchet MS", size: 20).weight(.bold))
                        .foregroundStyle(quiet || stopping || shown == nil ? ChumbyPalette.sub(dark) : ChumbyPalette.warn(dark))
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2)), removal: .opacity.animation(.easeOut(duration: 0.14))))
                }
            }
            .animation(.easeOut(duration: 0.2), value: status)
            .animation(.easeOut(duration: 0.2), value: failure)
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
            // The alarm's two lines keep their room while the first reading is on its way (the page opened with no word
            // of the ring yet): the card is its full size from the start, so nothing on it moves when they arrive. Before,
            // the card grew under "Reaching the Chumby…" as it left, and those words crossed the clock for three frames
            // (film, 11-20).
            let reaching = shown == nil && !nothing && !away
            if shown != nil || reaching {
                Text(reaching ? " " : title).font(.custom("Trebuchet MS", size: 26).weight(.bold)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
                if reaching || !detail.isEmpty {
                    Text(reaching ? " " : detail).font(.custom("Trebuchet MS", size: 17)).foregroundStyle(ChumbyPalette.sub(dark)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .card()
        // One piece: when the page makes room (the Snooze key leaving as a snooze is confirmed) the card and every
        // line on it move together. Without it each line found its own way, and for five frames the old status stood
        // at the old height over the new one, with the alarm's name drawn twice (film, 11-20, folded).
        .geometryGroup()
    }

    @ViewBuilder var keys: some View {
        let snoozed = shown?.snoozed == true
        VStack(spacing: 14) {
            if !snoozed && !nothing && !away {
                Button { snooze() } label: {
                    // The symbol and the word are one piece: when the snooze's length arrives beside them they move over
                    // together (as a Label, the word jumped and the symbol slid across it; film, 11-20).
                    HStack(spacing: 8) {
                        HStack(spacing: 8) { Image(systemName: "water.waves"); Text("Snooze") }.geometryGroup()
                        // Its room is kept while the first reading is on its way, as the card's lines are.
                        if let m = snoozeLength ?? (shown == nil ? "9 min" : nil) {
                            Text(m).fontWeight(.regular).foregroundStyle(ChumbyPalette.sub(dark)).opacity(snoozeLength == nil ? 0 : 1).transition(.opacity)
                        }
                    }
                    .geometryGroup()
                    .animation(ChumbyModel.ringSpring, value: snoozeLength)
                    .accessibilityElement(children: .combine)
                    .font(.custom("Trebuchet MS", size: 22).weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(snoozing || stopping)
                .opacity(model.ringWorking == "Snoozing…" ? 0.45 : 1)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            // "Stop" in every state, as every other place says it: stopping a snoozed alarm ends it for good.
            if !nothing && !away { SlideToStop(busy: stopping) { stop() }.transition(.opacity) }
        }
        .animation(ChumbyModel.ringSpring, value: snoozed)
        .animation(.snappy, value: nothing)
        .animation(.snappy, value: away)
    }

    func stop() {
        guard !stopping else { return }
        withAnimation(.easeOut(duration: 0.2)) { stopping = true }
        Task {
            // "Stopping…" is held long enough to be read, however quickly the Chumby answers.
            async let held: Void? = try? await Task.sleep(nanoseconds: 600_000_000)
            let ok = await model.ringOffTask().value
            _ = await held
            // Taken: the page goes with the key still at the far end (springing it back as the page leaves read as a
            // Stop undone). Not taken: the key returns, ready to slide again, and the status line says why.
            if ok { close() } else { withAnimation(.easeOut(duration: 0.2)) { stopping = false } }
        }
    }
    func snooze() {
        guard !snoozing else { return }
        snoozing = true
        Task { _ = await model.ringSnoozeTask().value; snoozing = false }
    }
}

// Stop, slid: the gel slab of Home's Skip in the app's orange, with a white key that is dragged to its far end. A tap
// does nothing, a slide let go short springs back, and only the whole run (or a decided flick toward it) stops the
// alarm. One haptic, the thunk as it lands (ChumbyModel.ringOffTask gives it).
struct SlideToStop: View {
    var busy = false
    let done: () -> Void
    // Where the finger has the key, kept as plain state and sent back by an explicit spring when let go short: the
    // gesture's own reset (GestureState's resetTransaction) put it back at the start in one frame under a real finger
    // (gate 4, 11-21, dbg-ringslide ~40.85 s). `touching` only notices a touch the system took away (a call, the
    // Control Centre), which ends the gesture with no onEnded, so the key goes back then too.
    @State private var pull: CGFloat = 0
    @GestureState private var touching = false
    @State private var landed = false
    static let back = Animation.spring(response: 0.32, dampingFraction: 0.78)
    // Home from wherever the finger left it, on the next turn of the run loop: a slow slide let go short reaches here
    // through the gesture's own ending or its cancel, and inside that transaction the spring was dropped and the key
    // was home in one frame (gate, 11-22: p-ringslide 45.07 → 45.08). Out of it, the spring always runs.
    func goHome() {
        DispatchQueue.main.async {
            guard !landed, !busy, pull != 0 else { return }
            var t = Transaction(animation: Self.back); t.disablesAnimations = false
            withTransaction(t) { pull = 0 }
        }
    }
    static let height: CGFloat = 76, key: CGFloat = 60, inset: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            let run = max(g.size.width - Self.key - Self.inset * 2, 1)
            // A Stop on its way that wasn't slid here (pressed on the Lock Screen or Home's card, with this page up) takes
            // the key across all the same: the bar never says "Slide to stop" under a card that says "Stopping…".
            let k = landed || busy ? 1 : min(max(pull / run, 0), 1)
            ZStack(alignment: .leading) {
                ChumbyGel(colors: [0xff8f5e, 0xfc5825, 0xdc4410], rim: 0x9c2c08)
                Text("Slide to stop").font(.custom("Trebuchet MS", size: 20).weight(.bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.leading, Self.key + Self.inset * 2).padding(.trailing, 16)
                    .frame(maxWidth: .infinity)
                    .opacity(1 - Double(k) * 1.8)
                RoundedRectangle(cornerRadius: 19, style: .continuous).fill(.white)
                    .shadow(color: ChumbyPalette.hex(0x9c2c08).opacity(0.35), radius: 3, y: 2)
                    .overlay {
                        // Landed, it holds the stop mark (the status line says "Stopping…"); a spinner here left the
                        // page with one turning on the key.
                        Image(systemName: k > 0.02 ? "stop.fill" : "chevron.right.2").font(.system(size: 22, weight: .heavy)).foregroundStyle(ChumbyPalette.orange)
                    }
                    .frame(width: Self.key, height: Self.key)
                    .padding(.leading, Self.inset)
                    .offset(x: k * run)
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: busy)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($touching) { _, t, _ in t = true }
                    .onChanged { v in
                        guard !landed, !busy else { return }
                        // 1:1 under the finger, never animated.
                        var plain = Transaction(); plain.disablesAnimations = true
                        withTransaction(plain) { pull = v.translation.width }
                    }
                    .onEnded { v in
                        guard !landed, !busy else { return }
                        // The whole run, or a flick already past halfway that would carry it there.
                        let far = v.translation.width / run, carried = v.predictedEndTranslation.width / run
                        if far >= 0.8 || (far >= 0.45 && carried >= 1) {
                            // From where the finger left it on to the end: not back to the start and out again.
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { landed = true }
                            done()
                        } else {
                            // Short: back to the start over a third of a second, "Slide to stop" fading in as it goes.
                            goHome()
                        }
                    }
            )
        }
        .frame(height: Self.height)
        // Back from a Stop the Chumby didn't take: the key returns to its start, ready to be slid again.
        .onChange(of: busy) { _, b in if !b { withAnimation(Self.back) { landed = false; pull = 0 } } }
        // A touch the system took away: the key goes home as it does when let go short.
        .onChange(of: touching) { _, t in if !t, !landed, !busy, pull != 0 { goHome() } }
        .accessibilityElement()
        .accessibilityLabel("Stop the alarm")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !busy { done() } }
    }
}

// The ringing page's octopus: his rattle's phase carried frame to frame, its reach eased in and out.
final class OctoRattle {
    private var last: TimeInterval?
    private var phase = 0.0, amp = 0.0
    func step(_ t: TimeInterval, on: Bool) -> (phase: Double, amp: Double) {
        guard let was = last else { last = t; amp = on ? 1 : 0; return (phase, amp) }
        let dt = min(max(t - was, 0), 1.0 / 20)
        last = t
        if amp > 0.001 || on { phase = (phase + dt * 2 * .pi / 0.32).truncatingRemainder(dividingBy: 4 * .pi) }
        amp += ((on ? 1 : 0) - amp) * (1 - exp(-dt / 0.25))
        if !on, amp < 0.001 { amp = 0 }
        return (phase, amp)
    }
}
