import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The pebble (Richard, 2026-11-20: "i want to be in control of my flick i am flicking the content with my finger thats how it
// should be", "like im flicking a pebble to the tv"). Whatever he picks up is a card under his finger, point for point, from
// the moment it is in his hand; let go moving up fast enough, or above the commit line, it leaves with his own speed and
// direction through the lip at the top of the screen, which is the TV. Let go any other way, it springs home carrying his
// release speed and nothing is sent. Nothing moves the card but his finger, the spring home and the flight after his release.

enum ThrowRules {
    // An upward release at least this fast throws from anywhere.
    static let throwSpeed: CGFloat = 700
    // Above the commit line, a release moving down faster than this is put back.
    static let downCancel: CGFloat = 200
    // The commit line: this share of the screen's height above the card's rest.
    static let commitShare: CGFloat = 0.3
    // The flight never dawdles, and is gone within this long.
    static let floorSpeed: CGFloat = 1600
    static let flightMax: Double = 0.22
    // The size at the lip, against 1 at rest.
    static let lipScale: CGFloat = 0.7
    static let maxTilt: Double = 6
}

// Every haptic, decision and flight of the hand, timed, for the build's films (never on his phone: only under a pose or
// -handLog YES). Written to Caches/hand-log.txt, which CI collects beside each film.
@MainActor enum HandLog {
    static let on = UserDefaults.standard.string(forKey: "pose") != nil || UserDefaults.standard.bool(forKey: "handLog")
    private static let start = Date()
    private static var lines: [String] = []
    private static var file: URL? { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("hand-log.txt") }
    static func note(_ s: String) {
        guard on else { return }
        let t = String(format: "%.3f", Date().timeIntervalSince(start))
        lines.append(t + " " + s)
        if lines.count % 4 == 1 { flush() } else { Task { @MainActor in try? await Task.sleep(nanoseconds: 300_000_000); flush() } }
    }
    static func flush() {
        guard let file else { return }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

// The hand's own haptics, in the brief's words: a soft pick-up, a rigid tick over the commit line and a lighter one back,
// a heavy thud at the lip, a light tap when the TV says it has it.
@MainActor enum HandFeel {
    #if canImport(UIKit)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    #endif
    static func pickUp() {
        #if canImport(UIKit)
        soft.impactOccurred(intensity: 0.5); soft.prepare(); rigid.prepare(); heavy.prepare()
        #endif
        HandLog.note("haptic pickup soft 0.5")
    }
    static func over(_ up: Bool) {
        #if canImport(UIKit)
        if up { rigid.impactOccurred(intensity: 0.8); rigid.prepare() } else { light.impactOccurred(intensity: 0.5); light.prepare() }
        #endif
        HandLog.note("haptic commit-\(up ? "up rigid 0.8" : "down light 0.5")")
    }
    static func thud() {
        #if canImport(UIKit)
        heavy.impactOccurred(); heavy.prepare()
        #endif
        HandLog.note("haptic throw heavy")
    }
    static func confirmed() {
        #if canImport(UIKit)
        light.impactOccurred(); light.prepare()
        #endif
        HandLog.note("haptic tv-confirmed light")
    }
}

// The lip's part in a carry, shared by the whole app: how near the card is (0 at rest, 1 at the lip), whether it is over
// the commit line, where the lip is on the screen, and the picture and colour of what last landed.
@MainActor @Observable final class Hand {
    static let shared = Hand()
    var glow: CGFloat = 0
    var committed = false
    var carrying = false
    @ObservationIgnored var lipFrame: CGRect = .zero
    @ObservationIgnored var screen: CGRect = .zero
    // What just landed: the lip takes its picture and colour for a moment.
    var landed: (title: String, art: String, tint: Color?, at: Date)?
    // A lifted item (a poster on a shelf, a row): drawn over everything at the finger by HandOverlay.
    var lifted: Lifted?
    struct Lifted: Equatable {
        let id: String
        let art: String
        let wide: Bool
        let rect: CGRect
        static func == (a: Lifted, b: Lifted) -> Bool { a.id == b.id && a.rect == b.rect }
    }
    let liftCarry = Carry(lifted: true)
    func land(title: String, art: String, tint: Color?) {
        withAnimation(.easeOut(duration: 0.18)) { landed = (title, art, tint, Date()) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if let l = landed, Date().timeIntervalSince(l.at) >= 1.5 { withAnimation(.easeOut(duration: 0.4)) { landed = nil } }
        }
    }
}

// One card's physics: where it is against its rest, its size and tilt, and what his release means. The title page's card
// and a lifted poster both use it; neither moves except through it.
@MainActor @Observable final class Carry {
    enum Phase { case rest, held, flying, gone, returning }
    var offset: CGSize = .zero
    var scale: CGFloat = 1
    var tilt: Double = 0
    var opacity: Double = 1
    var phase = Phase.rest
    // The card's rest, in the window's space, measured where it is drawn.
    @ObservationIgnored var rest: CGRect = .zero
    @ObservationIgnored let lifted: Bool
    @ObservationIgnored private var over = false
    @ObservationIgnored private var downAt = Date()
    @ObservationIgnored private var firstMoveLogged = false
    init(lifted: Bool = false) { self.lifted = lifted }
    var liftScale: CGFloat { lifted ? 1.04 : 1.03 }
    private var restCenter: CGPoint { CGPoint(x: rest.midX, y: rest.midY) }
    private var lipY: CGFloat { let l = Hand.shared.lipFrame; return l.height > 0 ? l.midY : 30 }
    private var screenH: CGFloat { let s = Hand.shared.screen; return s.height > 0 ? s.height : 800 }
    var commitY: CGFloat { restCenter.y - ThrowRules.commitShare * screenH }
    // 0 at rest, 1 with the card's middle at the lip.
    func progress(_ dy: CGFloat) -> CGFloat {
        let span = max(1, restCenter.y - lipY)
        return min(1, max(0, -dy / span))
    }
    // The finger came down on it: in the hand at once.
    func down() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { phase = .held; offset = .zero; tilt = 0; opacity = 1 }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.8)) { scale = liftScale }
        over = false; downAt = Date(); firstMoveLogged = false
        Hand.shared.carrying = true
        HandFeel.pickUp()
        HandLog.note("down rest=\(Int(rest.midX)),\(Int(rest.midY)) commitY=\(Int(commitY)) lipY=\(Int(lipY))")
    }
    // The finger moved: the card's middle moves exactly as far, both ways. Returns whether the commit line was crossed.
    func move(_ d: CGSize, velocity v: CGSize, finger: CGPoint? = nil) {
        guard phase == .held else { return }
        let p = progress(d.height)
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            offset = d
            scale = liftScale * (1 - (1 - ThrowRules.lipScale) * p)
            tilt = max(-ThrowRules.maxTilt, min(ThrowRules.maxTilt, Double(v.width) / 2000 * ThrowRules.maxTilt))
        }
        Hand.shared.glow = p
        let now = restCenter.y + d.height < commitY
        if now != over {
            over = now
            Hand.shared.committed = now
            HandFeel.over(now)
        }
        if HandLog.on {
            if !firstMoveLogged { firstMoveLogged = true; HandLog.note(String(format: "first-move %.3f s after down", Date().timeIntervalSince(downAt))) }
            let c = CGPoint(x: restCenter.x + d.width, y: restCenter.y + d.height)
            if let f = finger { HandLog.note(String(format: "carry card=%.1f,%.1f finger=%.1f,%.1f", c.x, c.y, f.x, f.y)) }
            else { HandLog.note(String(format: "carry card=%.1f,%.1f d=%.1f,%.1f", c.x, c.y, d.width, d.height)) }
        }
    }
    enum Outcome { case thrown, back }
    // What his release means, by the brief's rule.
    func judge(_ v: CGSize) -> Outcome {
        let above = restCenter.y + offset.height < commitY
        if v.height <= -ThrowRules.throwSpeed { return .thrown }
        if above && v.height < ThrowRules.downCancel { return .thrown }
        return .back
    }
    // Let go and not thrown: home on a spring that starts at his release speed. Nothing is sent and nothing is said.
    func springHome(_ v: CGSize, then: (() -> Void)? = nil) {
        let o = offset
        let d2 = o.width * o.width + o.height * o.height
        let rel = d2 > 1 ? Double(-(v.width * o.width + v.height * o.height) / d2) : 0
        phase = .returning
        Hand.shared.carrying = false
        withAnimation(.easeOut(duration: 0.2)) { Hand.shared.glow = 0 }
        if over { over = false; Hand.shared.committed = false }
        HandLog.note(String(format: "release back v=%.0f,%.0f", v.width, v.height))
        withAnimation(.interpolatingSpring(Spring(response: 0.35, dampingRatio: 0.82), initialVelocity: rel)) {
            offset = .zero; scale = 1; tilt = 0
        } completion: { [weak self] in
            guard let self, self.phase == .returning else { return }
            self.phase = .rest
            then?()
        }
    }
    // Thrown: on with his own speed and direction (never slower, gone within 220 ms), out through the top. `landed` runs as
    // it leaves, with the thud.
    func fly(_ v: CGSize, landed: @escaping () -> Void) {
        phase = .flying
        Hand.shared.carrying = false
        if over { over = false; Hand.shared.committed = false }
        var dx = v.width, dy = v.height
        let sp = sqrt(dx * dx + dy * dy)
        // Let go nearly still above the line: straight up at the lip.
        if sp < 120 || dy > -60 { dx = 0; dy = -1 }
        let len = sqrt(dx * dx + dy * dy)
        dx /= len; dy /= len
        let center = CGPoint(x: restCenter.x + offset.width, y: restCenter.y + offset.height)
        let h = rest.height * scale
        // How far until the card's foot is past the lip's top, along his direction.
        let exitY = min(Hand.shared.lipFrame.minY, 0) - h / 2 - 8
        let dist = max(40, (center.y - exitY) / max(0.2, -dy))
        let speed = max(sp, ThrowRules.floorSpeed)
        var dur = Double(dist / speed)
        if dur > ThrowRules.flightMax { dur = ThrowRules.flightMax }
        let flown = dist
        let to = CGSize(width: offset.width + dx * flown, height: offset.height + dy * flown)
        HandLog.note(String(format: "release thrown v=%.0f,%.0f speed=%.0f flight=%.0fpt %.3fs (%.0f pt/s)", v.width, v.height, sp, flown, dur, Double(flown) / dur))
        withAnimation(.easeOut(duration: 0.15)) { Hand.shared.glow = 1 }
        withAnimation(.linear(duration: dur)) {
            offset = to; scale = scale * 0.82
        } completion: { [weak self] in
            guard let self else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { self.phase = .gone; self.opacity = 0 }
            HandFeel.thud()
            HandLog.note("gone")
            withAnimation(.easeOut(duration: 0.3)) { Hand.shared.glow = 0 }
            landed()
        }
    }
    // Back at its place, unseen, then faded in: the page's card is still the page's after a throw.
    func reappear(after s: Double = 0.5) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            guard phase == .gone else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { offset = .zero; scale = 1; tilt = 0 }
            phase = .rest
            withAnimation(.easeOut(duration: 0.3)) { opacity = 1 }
        }
    }
    // A throw the TV refused: the card drops back out of the lip to its place.
    func dropBack() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { offset = CGSize(width: 0, height: -(restCenter.y - lipY)); scale = ThrowRules.lipScale; opacity = 1; phase = .returning }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { offset = .zero; scale = 1 } completion: { [weak self] in self?.phase = .rest }
        HandLog.note("drop-back")
    }
}

// A card in a velocity sampler's terms: the speed of the last ~70 ms of a finger's travel, for a recogniser that has no
// velocity of its own (the long press that lifts a poster).
struct VelocityTrack {
    private var samples: [(t: Double, p: CGPoint)] = []
    mutating func add(_ p: CGPoint, at t: Double) {
        samples.append((t, p))
        samples.removeAll { t - $0.t > 0.12 }
    }
    var velocity: CGSize {
        guard let last = samples.last, let first = samples.first(where: { last.t - $0.t <= 0.08 }), last.t - first.t > 0.008 else { return .zero }
        let dt = CGFloat(last.t - first.t)
        return CGSize(width: (last.p.x - first.p.x) / dt, height: (last.p.y - first.p.y) / dt)
    }
    mutating func reset() { samples.removeAll() }
}

// What a throw sends. The one place a card turns into something on the TV.
@MainActor enum Thrower {
    // A Stremio title at an episode or a film, with the stream the card carries.
    static func sendStream(_ model: TVModel, item: MediaItem, stream: StremioStream, list: [StremioStream], velocity: CGSize, avoid: Set<String> = [], startOver: Bool? = nil) {
        if model.isOnTV(item, .stremio) {
            HandLog.note("send already-on")
            if model.status?.session?.playing == false { model.holdPlay(true); model.key("resume") }
            return
        }
        FlickClock.begin()
        HandLog.note("send play-stream \(stream.token) \(item.stremioRef?.video ?? item.stremioRef?.imdb ?? item.id)")
        if startOver == true, let r = item.stremioRef { ShelfSend.restart = r.imdb + "/" + (r.video ?? "") }
        model.startStream(item: item, stream: stream, list: list, receipt: nil, velocity: velocity)
    }
    // What a card that isn't a Stremio title sends: a YouTube video where he left it, anything else as it is.
    static func plainTarget(_ item: MediaItem, _ source: MediaSource) -> FlickTarget {
        if item.isYouTube {
            let at = item.resume ?? 0
            return FlickTarget(item: item, source: source, send: ("send", ["text": "https://www.youtube.com/watch?v=\(item.id)" + (at >= 30 ? "&t=\(at)" : "")]), lands: "com.google.android.youtube.tv")
        }
        return FlickTarget(item: item, source: source)
    }
    // Anything else: a YouTube video, a link, a song, a title with no stream list. Sent as it is.
    static func sendPlain(_ model: TVModel, target: FlickTarget) {
        let item = target.item
        let order: (String, [String: Any])
        if let s = target.send { order = s }
        else if item.isYouTube {
            let at = item.resume ?? 0
            order = ("send", ["text": "https://www.youtube.com/watch?v=\(item.id)" + (at >= 30 ? "&t=\(at)" : "")])
        } else if target.source == .mint {
            order = ("mint-open", ["link": item.id, "title": item.title, "subtitle": item.subtitle, "art": item.art, "kind": item.kind, "play": true])
        } else if let ref = item.stremioRef {
            order = ("stremio-open", item.id.hasPrefix("stremio:") ? ["id": item.id] : ["type": ref.type, "id": ref.imdb])
        } else {
            order = ("film", ["slug": item.slug ?? ""])
        }
        HandLog.note("send \(order.0)")
        FlickClock.begin()
        let video = item.isYouTube || target.lands != nil || order.0 == "send"
        if video { model.beginStart(.init(title: item.title, art: item.art, line: nil), target: target) }
        Task { @MainActor in
            do {
                _ = try await TVBridge.post(order.0, order.1, timeout: 60)
                target.sent?()
                if video { model.startPlayed() } else { HandFeel.confirmed() }
                FlickClock.current.mark("answer"); FlickClock.current.finished()
            } catch {
                if video { model.clearStart() }
                model.say("The TV didn’t get that")
                FlickClock.current.mark("failed"); FlickClock.current.finished()
            }
            await model.load()
        }
    }
    // A Stremio title thrown from anywhere but its page: the best stream (the one he used last for it if known), found now
    // if it isn't in hand. A show not at an episode goes at its next one.
    static func sendBest(_ model: TVModel, item: MediaItem, velocity: CGSize) {
        guard let ref = item.stremioRef else { sendPlain(model, target: FlickTarget(item: item, source: .stremio)); return }
        Task { @MainActor in
            var it = item
            var video: String? = ref.type == "series" ? ref.video : ref.imdb
            if ref.type == "series", video == nil {
                guard let m = await NextUp.meta(ref.imdb), let e = TitleState.resumeEpisode(item: item, meta: m, model: model) else {
                    model.say("Couldn’t find an episode to play"); return
                }
                video = e.id
                it = MediaItem(title: item.title, subtitle: "S\(e.season) E\(e.episode)", art: item.art, id: NextUp.link(ref.imdb, e.id), kind: "series", progress: item.progress)
            }
            guard let v = video else { return }
            var list = StreamCache.shared.inHand(type: ref.type, imdb: ref.imdb, video: v) ?? []
            if list.isEmpty { list = await StreamCache.shared.streams(type: ref.type, imdb: ref.imdb, video: v) ?? [] }
            guard let s = TitleState.preferred(list, key: ref.imdb + "/" + (ref.type == "series" ? v : "")) else {
                Hand.shared.lifted = nil
                model.say("No streams found for \(item.title)")
                return
            }
            sendStream(model, item: it, stream: s, list: list, velocity: velocity)
        }
    }
}

// A poster or row inside a scroller: pressed and held still for 0.15 s, it lifts into the hand, and from that frame it is the
// same card as on a title page. Any 10 pt of travel before then is the page's scroll, and it never lifts. Once lifted, the
// scroll views around it are held still until it's let go.
struct Liftable: ViewModifier {
    @Environment(TVModel.self) private var model
    let item: MediaItem
    let source: MediaSource
    // A wide still (an episode row's), rather than a poster.
    var wide = false
    // The picture that lifts, when it isn't the item's own art (an episode's still).
    var art: String? = nil
    // What a throw does, when it isn't the item's own best stream (an episode on its show's page).
    var onThrow: ((CGSize) -> Void)? = nil
    // What letting go where it was does, when it isn't opening the item's page.
    var onTap: (() -> Void)? = nil
    // Where the picture is, when it isn't the whole of the view this is on.
    var rect: (() -> CGRect)? = nil
    @State private var place = FrameBox()
    @State private var far = false
    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { place.rect = $0 }
            .modifier(HiddenWhileLifted(id: liftID))
            .gesture(LiftRecognizer(began: { began() }, moved: { moved($0, $1) }, ended: { ended($0) }))
            .accessibilityAction(named: "Play on the TV") { send(CGSize(width: 0, height: -2000)) }
        #else
        content
        #endif
    }
    var liftID: String { item.id + (wide ? "#w" : "") }
    func began() {
        var r = rect?() ?? .zero
        if r.width < 4 { r = place.rect ?? .zero }
        guard r.width > 4, Hand.shared.lifted == nil else { return }
        far = false
        if source == .stremio, !item.isYouTube { StreamCache.shared.prefetch(item); Prepare.arm(); NextUp.prefetch(item) }
        let c = Hand.shared.liftCarry
        c.rest = r
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { Hand.shared.lifted = .init(id: liftID, art: art ?? item.art, wide: wide || item.isYouTube, rect: r) }
        c.down()
        HandLog.note("touch owner=lift \(item.title)")
    }
    func send(_ v: CGSize) {
        if let onThrow { onThrow(v) }
        else if model.isOnTV(item, source) { HandLog.note("send already-on") }
        else if source == .stremio, !item.isYouTube, item.stremioRef != nil { Thrower.sendBest(model, item: item, velocity: v) }
        else { Thrower.sendPlain(model, target: Thrower.plainTarget(item, source)) }
    }
    func moved(_ d: CGSize, _ v: CGSize) {
        if abs(d.width) > 10 || abs(d.height) > 10 { far = true }
        Hand.shared.liftCarry.move(d, velocity: v)
    }
    func ended(_ v: CGSize) {
        let c = Hand.shared.liftCarry
        guard c.phase == .held, Hand.shared.lifted?.id == liftID else { return }
        // The tap iOS may report with this release is this release, not a second action.
        ShelfHand.shared.handledAt = Date()
        let down: () -> Void = {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { Hand.shared.lifted = nil }
        }
        if c.judge(v) == .thrown {
            send(v)
            let tint = ImageStore.shared.cachedBand(URL(string: item.art))
            c.fly(v) { Hand.shared.land(title: item.title, art: item.art, tint: tint); down() }
        } else {
            // Let go without having moved: put back, and that was a tap.
            let tapped = !far
            c.springHome(v) { down() }
            if tapped {
                HandLog.note("lift let go still: tap")
                if let onTap { onTap() } else { FlickCardButton.tap(model, item, source, held: true) }
            }
        }
    }
}
// The item's own place is empty while it is in the hand. Read here, in a view of its own, so a lift redraws this and not
// every card on the page.
private struct HiddenWhileLifted: ViewModifier {
    let id: String
    func body(content: Content) -> some View { content.opacity(Hand.shared.lifted?.id == id ? 0 : 1) }
}
extension View {
    func liftable(_ item: MediaItem, _ source: MediaSource, wide: Bool = false, onThrow: ((CGSize) -> Void)? = nil) -> some View {
        modifier(Liftable(item: item, source: source, wide: wide, onThrow: onThrow))
    }
}

#if canImport(UIKit)
// The press that lifts: the system's long press at 0.15 s with 10 pt of slop, so a finger that moves first was scrolling and
// the scroll has it. It doesn't cancel the item's own tap (a press let go without moving is a tap). Once it begins it holds
// every scroll view above it still, by turning their pans off and on (which ends any scroll they had started).
struct LiftRecognizer: UIGestureRecognizerRepresentable {
    let began: () -> Void
    let moved: (CGSize, CGSize) -> Void
    let ended: (CGSize) -> Void
    final class Coordinator {
        var start: CGPoint = .zero
        var track = VelocityTrack()
        var held: [UIScrollView] = []
    }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.15
        g.allowableMovement = 10
        g.cancelsTouchesInView = true
        return g
    }
    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        let c = context.coordinator
        let p = g.location(in: nil)
        let t = CACurrentMediaTime()
        switch g.state {
        case .began:
            c.start = p; c.track.reset(); c.track.add(p, at: t)
            var v: UIView? = g.view
            c.held = []
            while let s = v { if let sv = s as? UIScrollView, sv.isScrollEnabled { c.held.append(sv) }; v = s.superview }
            for s in c.held { s.panGestureRecognizer.isEnabled = false; s.panGestureRecognizer.isEnabled = true; s.isScrollEnabled = false }
            began()
        case .changed:
            c.track.add(p, at: t)
            moved(CGSize(width: p.x - c.start.x, height: p.y - c.start.y), c.track.velocity)
        case .ended, .cancelled, .failed:
            c.track.add(p, at: t)
            for s in c.held { s.isScrollEnabled = true }
            c.held = []
            ended(g.state == .ended ? c.track.velocity : .zero)
        default: break
        }
    }
}
#endif

// The lifted item, drawn over everything where his finger has it.
struct HandOverlay: View {
    var body: some View {
        let hand = Hand.shared
        ZStack {
            if let l = hand.lifted {
                let c = hand.liftCarry
                Art(url: URL(string: l.art)) { $0.resizable().scaledToFill() } placeholder: { CoverWait() }
                    .frame(width: l.rect.width, height: l.rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: l.wide ? 10 : 8, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
                    .scaleEffect(c.scale)
                    .rotationEffect(.degrees(c.tilt))
                    .opacity(c.opacity)
                    .position(x: l.rect.midX + c.offset.width, y: l.rect.midY + c.offset.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
