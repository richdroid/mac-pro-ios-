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
    // The commit line: this share of the screen's height above the card's rest, but never more than this share of the
    // way to the lip, so a card resting low on the page can still reach it (the line sat at or above the lip for them).
    static let commitShare: CGFloat = 0.3
    static let commitReach: CGFloat = 0.55
    // The flight never dawdles, and is gone within this long.
    static let floorSpeed: CGFloat = 1600
    static let flightMax: Double = 0.22
    // The size at the lip, against 1 at rest.
    static let lipScale: CGFloat = 0.7
    // What a thrown card shrinks to as it lands: the lip's own picture.
    static let lipPicture = CGSize(width: 64, height: 40)
    static let maxTilt: Double = 6
}

// Every haptic, decision and flight of the hand, timed, for the build's films (never on his phone: only under a pose or
// -handLog YES). Written to Caches/hand-log.txt, which CI collects beside each film.
@MainActor enum HandLog {
    static let on = UserDefaults.standard.string(forKey: "pose") != nil || UserDefaults.standard.bool(forKey: "handLog")
    private static let start = Date()
    private static var lines: [String] = []
    private static var pending = false
    private static var file: URL? { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("hand-log.txt") }
    static func note(_ s: String) {
        guard on else { return }
        let t = String(format: "%.3f", Date().timeIntervalSince(start))
        lines.append(t + " " + s)
        // One write at most every half second, never one per line: the log must not cost the carry a frame.
        guard !pending else { return }
        pending = true
        Task { @MainActor in try? await Task.sleep(nanoseconds: 500_000_000); pending = false; flush() }
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
    var commitY: CGFloat { restCenter.y - min(ThrowRules.commitShare * screenH, ThrowRules.commitReach * max(0, restCenter.y - lipY)) }
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
        // Let go with the card in the lip is a throw, however slowly it got there.
        let lip = Hand.shared.lipFrame
        if lip.height > 0, lip.contains(CGPoint(x: restCenter.x + offset.width, y: restCenter.y + offset.height)) { return .thrown }
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
    // Thrown: on with his own speed (never slower, gone within 220 ms) into the lip, shrinking to the lip's picture, where it
    // lands with the thud. It flew off the top of the screen before, past the lip it was meant to land in. `landed` runs as
    // it lands.
    func fly(_ v: CGSize, landed: @escaping () -> Void) {
        phase = .flying
        Hand.shared.carrying = false
        if over { over = false; Hand.shared.committed = false }
        let sp = sqrt(v.width * v.width + v.height * v.height)
        let center = CGPoint(x: restCenter.x + offset.width, y: restCenter.y + offset.height)
        let lip = Hand.shared.lipFrame
        // Where it lands: the lip's middle line, along his direction (straight up when let go nearly still or downward),
        // kept inside the lip's ends.
        var dx = v.width, dy = v.height
        if sp < 120 || dy > -60 { dx = 0; dy = -1 }
        let rise = max(0, center.y - lipY)
        var x = center.x + (dy < 0 ? dx / -dy * rise : 0)
        if lip.width > 0 { x = min(max(x, lip.minX + ThrowRules.lipPicture.width / 2 + 8), lip.maxX - ThrowRules.lipPicture.width / 2 - 8) }
        let to = CGSize(width: offset.width + x - center.x, height: offset.height + lipY - center.y)
        let ddx = to.width - offset.width, ddy = to.height - offset.height
        let dist = max(1, sqrt(ddx * ddx + ddy * ddy))
        let speed = max(sp, ThrowRules.floorSpeed)
        let dur = min(Double(dist / speed), ThrowRules.flightMax)
        let small = rest.width > 0 && rest.height > 0 ? min(ThrowRules.lipPicture.width / rest.width, ThrowRules.lipPicture.height / rest.height) : ThrowRules.lipScale
        HandLog.note(String(format: "release thrown v=%.0f,%.0f speed=%.0f flight=%.0fpt %.3fs to lip %.0f,%.0f", v.width, v.height, sp, dist, dur, x, lipY))
        withAnimation(.easeOut(duration: 0.15)) { Hand.shared.glow = 1 }
        withAnimation(.easeOut(duration: dur)) {
            offset = to; scale = small; tilt = 0
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
    // The card's view went with it still in the hand (its row scrolled away, the page closed): at rest, nothing sent.
    func drop() {
        guard phase == .held || phase == .returning else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { offset = .zero; scale = 1; tilt = 0; opacity = 1; phase = .rest }
        Hand.shared.carrying = false
        Hand.shared.glow = 0
        if over { over = false; Hand.shared.committed = false }
        HandLog.note("dropped: view gone")
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
        // The lip has the title from the release on, while the stream is looked for: never the TV's old state first.
        model.beginStart(.init(title: item.title, art: item.art, line: nil, note: "Finding the stream…"), target: FlickTarget(item: item, source: .stremio))
        let lineage = model.startingTarget?.lineage
        // A newer start (or one called off) owns the lip by the time an answer comes: this one says nothing over it.
        let ours = { model.startingTarget?.lineage == lineage && model.starting != nil }
        Task { @MainActor in
            var it = item
            var video: String? = ref.type == "series" ? ref.video : ref.imdb
            if ref.type == "series", video == nil {
                guard let m = await NextUp.meta(ref.imdb), let e = TitleState.resumeEpisode(item: item, meta: m, model: model) else {
                    if ours() { model.failStart("No episode to play") }
                    return
                }
                video = e.id
                it = MediaItem(title: item.title, subtitle: "S\(e.season) E\(e.episode)", art: item.art, id: NextUp.link(ref.imdb, e.id), kind: "series", progress: item.progress)
            }
            guard let v = video else { if ours() { model.failStart("Nothing to play") }; return }
            var list = StreamCache.shared.inHand(type: ref.type, imdb: ref.imdb, video: v) ?? []
            if list.isEmpty { list = await StreamCache.shared.streams(type: ref.type, imdb: ref.imdb, video: v) ?? [] }
            guard ours() else { return }
            guard let s = TitleState.preferred(list, key: ref.imdb + "/" + (ref.type == "series" ? v : "")) else {
                Hand.shared.lifted = nil
                model.failStart("No streams found")
                return
            }
            // The episode he's up to is already on: nothing to start.
            if model.isOnTV(it, .stremio) { model.clearStart() }
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
    // Whether the whole view leaves its place while lifted; a row whose still lifts hides only that still (HiddenInHand).
    var hides = true
    // On a sideways shelf, a drag that starts upward lifts at once, without the hold (the shelf only scrolls sideways, so
    // up can only mean the TV). Lists keep the hold: up there is the page's scroll.
    var quickUp = true
    @State private var place = FrameBox()
    @State private var far = false
    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { place.rect = $0 }
            .modifier(HiddenWhileLifted(id: hides ? liftID : ""))
            .gesture(LiftRecognizer(quickUp: quickUp, began: { began($0) }, moved: { moved($0, $1) }, ended: { ended($0) }))
            .accessibilityAction(named: "Play on the TV") { send(CGSize(width: 0, height: -2000)) }
            // Gone while in the hand: the scrolls it held still move again, and nothing is left floating at the finger.
            .onDisappear {
                guard Hand.shared.lifted?.id == liftID else { return }
                LiftHold.release()
                Hand.shared.liftCarry.drop()
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { Hand.shared.lifted = nil }
            }
        #else
        content
        #endif
    }
    var liftID: String { item.id + (wide ? "#w" : "") }
    func began(_ finger: CGPoint) {
        var r = rect?() ?? .zero
        if r.width < 4 { r = place.rect ?? .zero }
        guard r.width > 4, Hand.shared.lifted == nil else {
            HandLog.note("lift refused \(item.title): \(r.width > 4 ? "another in the hand" : "no place")")
            return
        }
        far = false
        if source == .stremio, !item.isYouTube { StreamCache.shared.prefetch(item); Prepare.arm(); NextUp.prefetch(item) }
        let c = Hand.shared.liftCarry
        c.rest = r
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { Hand.shared.lifted = .init(id: liftID, art: art ?? item.art, wide: wide || item.isYouTube, rect: r) }
        c.down()
        HandLog.note("touch owner=lift \(item.title)")
        // The proof the card starts under the finger: both in the window's space, the overlay's (HandOverlay ignores the
        // safe area and draws in the window's frame).
        HandLog.note(String(format: "pickup finger=%.1f,%.1f card=%.1f,%.1f", finger.x, finger.y, r.midX, r.midY))
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
    func body(content: Content) -> some View { content.opacity(!id.isEmpty && Hand.shared.lifted?.id == id ? 0 : 1) }
}
extension View {
    func liftable(_ item: MediaItem, _ source: MediaSource, wide: Bool = false, quickUp: Bool = true, onThrow: ((CGSize) -> Void)? = nil) -> some View {
        modifier(Liftable(item: item, source: source, wide: wide, onThrow: onThrow, quickUp: quickUp))
    }
}

#if canImport(UIKit)
// The scroll views a lift holds still, one lift at a time. Freed when the lift ends, and also when the recognizer or the
// lifted view goes first, so a page is never left unable to scroll.
@MainActor enum LiftHold {
    static var held: [UIScrollView] = []
    static func hold(from view: UIView?) {
        release()
        var v = view
        while let s = v { if let sv = s as? UIScrollView, sv.isScrollEnabled { held.append(sv) }; v = s.superview }
        for s in held { s.panGestureRecognizer.isEnabled = false; s.panGestureRecognizer.isEnabled = true; s.isScrollEnabled = false }
    }
    static func release() {
        for s in held { s.isScrollEnabled = true }
        held = []
    }
}
#else
@MainActor enum LiftHold { static func release() {} }
#endif

#if canImport(UIKit)
// The long press, plus the shelf's quick lift: on a shelf that scrolls only sideways, 10 pt of travel upward, within 30° of
// straight up, begins it at once. Any other first 10 pt fails it as before, and the scroll has the touch.
final class LiftPress: UILongPressGestureRecognizer {
    var quickUp = false
    // Where the finger came down and where it is, each read off the touch itself in its window's space. The recognizer's
    // own location(in: nil) came back turned half round on the open Duo (CI 7347f14: touch 82,783 read 586,168 on a
    // 669 x 951 window, and a finger going up carried the card down), so it isn't used.
    private(set) var from: CGPoint?
    private(set) var now: CGPoint?
    // The view the touch landed on. The recognizer's own view isn't inside the page's scroll views (SwiftUI puts it
    // elsewhere), so the shelf and the scrolls to hold are found from here.
    private(set) weak var touched: UIView?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if from == nil, let t = touches.first {
            let p = t.location(in: t.window)
            from = p; now = p; touched = t.view
            HandLog.note(String(format: "lift touch %.0f,%.0f quickUp=%@ shelf=%@", p.x, p.y, quickUp ? "yes" : "no", Self.onShelf(t.view) ? "yes" : "no"))
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { now = t.location(in: t.window) }
        if state == .possible, quickUp, let f = from, let p = now {
            let dx = p.x - f.x, dy = p.y - f.y
            if dx * dx + dy * dy > 64, dy < 0, abs(dx) <= -dy * 0.577, Self.onShelf(touched) {
                HandLog.note("lift quick-up")
                state = .began
                return
            }
        }
        let was = state
        super.touchesMoved(touches, with: event)
        if was == .possible, state == .failed { HandLog.note("lift failed: moved before the hold") }
    }
    // Only a scroll that has begun can keep the lift from beginning (moved first, the touch is the scroll's). The card's
    // own press, and SwiftUI's gestures around it, can't: on the shelf films no lift ever began under a held finger
    // (CI 5226eb3). The tap after a lift is the card's to ignore (ShelfHand.handledAt), and the lift cancels the press's
    // touch as it begins.
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer && other.view is UIScrollView
    }
    // The scrolls wait for the quick lift to be ruled out (10 pt, or the hold), so an upward drag on a shelf is the hand's
    // and not the page's. The recognizer's own answer, not a delegate's: SwiftUI's gesture bridge owns the delegate.
    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        guard quickUp, other is UIPanGestureRecognizer, other.view is UIScrollView else { return false }
        return Self.onShelf(touched)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { now = t.location(in: t.window) }
        super.touchesEnded(touches, with: event)
    }
    override func reset() { super.reset(); from = nil; now = nil; touched = nil }
    // The nearest scroll view around it scrolls sideways and not up and down.
    static func onShelf(_ view: UIView?) -> Bool {
        var v = view
        while let s = v {
            if let sv = s as? UIScrollView { return sv.contentSize.width > sv.bounds.width + 1 && sv.contentSize.height <= sv.bounds.height + 1 }
            v = s.superview
        }
        return false
    }
}

// The press that lifts: the system's long press at 0.15 s with 10 pt of slop, so a finger that moves first was scrolling and
// the scroll has it (on a shelf, unless it moved up: LiftPress). It doesn't cancel the item's own tap (a press let go
// without moving is a tap). Once it begins it holds every scroll view above it still (LiftHold).
struct LiftRecognizer: UIGestureRecognizerRepresentable {
    var quickUp = false
    let began: (CGPoint) -> Void
    let moved: (CGSize, CGSize) -> Void
    let ended: (CGSize) -> Void
    final class Coordinator {
        var start: CGPoint = .zero
        var track = VelocityTrack()
        var lifting = false
        // Torn down mid-lift (the view gone with the card in the hand): the held scrolls move again.
        deinit { if lifting { MainActor.assumeIsolated { LiftHold.release() } } }
    }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> LiftPress {
        let g = LiftPress()
        g.minimumPressDuration = 0.15
        g.allowableMovement = 10
        g.cancelsTouchesInView = true
        g.quickUp = quickUp
        return g
    }
    func updateUIGestureRecognizer(_ g: LiftPress, context: Context) { g.quickUp = quickUp }
    func handleUIGestureRecognizerAction(_ g: LiftPress, context: Context) {
        let c = context.coordinator
        let p = g.now ?? g.location(in: nil)
        let t = CACurrentMediaTime()
        switch g.state {
        case .began:
            HandLog.note("lift press began")
            // From where the finger came down, so a quick lift's first 10 pt are the card's too, point for point.
            c.start = g.from ?? p; c.track.reset(); c.track.add(p, at: t)
            c.lifting = true
            LiftHold.hold(from: g.touched ?? g.view)
            began(c.start)
            if p != c.start { moved(CGSize(width: p.x - c.start.x, height: p.y - c.start.y), c.track.velocity) }
        case .changed:
            c.track.add(p, at: t)
            moved(CGSize(width: p.x - c.start.x, height: p.y - c.start.y), c.track.velocity)
        case .ended, .cancelled, .failed:
            if g.state != .ended { HandLog.note("lift press \(g.state == .cancelled ? "cancelled" : "failed")") }
            c.track.add(p, at: t)
            c.lifting = false
            LiftHold.release()
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
