import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The Zune pass (2026-11-24, lastfm.md §27): Zune's face, its accent, and Windows Phone 7's motion as the Silverlight
// Toolkit wrote it down. Richard: "mirror the zune aesthetic as much as possible, access documentation even".
//
// Type: Selawik, Microsoft's open-source face made to the metrics of Segoe UI (SIL OFL 1.1, bundled unmodified in
// LastFMApp/Fonts with its licence), in Zune's weights: Light for the huge words and figures, Semilight for titles,
// Regular for text, Semibold for the small capitals. Every text style maps onto it at the system's own sizes, scaled
// with Dynamic Type; glyphs it lacks (other scripts) fall back to the system's.
extension Z {
    // Zune's accent: magenta into orange (WP7 magenta D80073 and orange FA6800, the nearest documented values; Zune's own
    // hex wasn't found). For marks only: live, scrobbled, the streak. It never fills.
    static let magenta = Color(red: 0.85, green: 0.0, blue: 0.45)
    static let orange = Color(red: 0.98, green: 0.41, blue: 0.0)
    // ONE accent, WP7's way (Richard, 2026-11-25): Zune's magenta, flat. Kept as a gradient type so every mark that
    // paints with it stays as it is; both ends are the same colour.
    static let accent = LinearGradient(colors: [magenta, magenta], startPoint: .leading, endPoint: .trailing)
    // Second lines, Zune's "subtle" colour: the same face, dimmer.
    static let subtle = Color.white.opacity(0.6)

    // WP7's motion [S4]: ExponentialEase, exponent 6. Ease out for what arrives (fast start, long settle), ease in for
    // what leaves.
    static func easeOut(_ d: Double = 0.35) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: d) }
    static func easeIn(_ d: Double = 0.25) -> Animation { .timingCurve(0.7, 0, 0.84, 0, duration: d) }
    static let feather = 0.05
    // How long home's turnstile out spreads its parts' starts over, first to last (the tapped one). 0.06 s, so the
    // tapped part is gone 0.31 s after the tap and the hub is pushed then (gate on build 71: 420 ms of wait and a bare
    // backdrop before the hub turned in).
    static let leaveSpread = 0.06
    // Home waits this long after a tap before the hub is pushed: the tapped part's swing (0.25 s, ease in) all but over.
    static let leaveWait = 0.3

    #if canImport(UIKit)
    static func uiFont(_ size: CGFloat, weight: CGFloat) -> UIFont {
        let w: Font.Weight = weight <= -0.35 ? .light : weight < 0.2 ? .regular : weight < 0.35 ? .semibold : .bold
        return UIFont(name: name(w), size: size) ?? UIFont.systemFont(ofSize: size, weight: UIFont.Weight(rawValue: weight))
    }
    #endif
}

extension String {
    // Selawik has no narrow no-break space (iOS puts one before AM and PM), so the fallback drew a wide hole: "7:01  AM"
    // (gate 1, item 11). Plain spaces in every time the app sets.
    var plainSpaces: String { replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
}

// A hub's pivot in every posture, one rule (gate 1, item 7): folded and open upright, the pivot under the hub's small
// capitals; open flat, the small capitals once at the top left, the first page in the left pane under its own huge name,
// and the rest as a pivot in the right pane, its names level with that name. Nothing crosses the fold.
struct HubPivot: View {
    var title: String? = nil
    @Binding var page: Int
    let panels: [Panel]
    @Environment(\.paneLayout) private var pane
    @Environment(\.hubName) private var hubName
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1
    var body: some View {
        if pane, panels.count > 1, let first = panels.first {
            FoldSplit {
                Page {
                    VStack(alignment: .leading, spacing: 0) {
                        AppTitle(text: title ?? hubName ?? Home.title).frame(height: ceil(20 * min(max(k, 0.9), 1.3)) + 2, alignment: .top).turnstile(0)
                        Text(first.header).font(.zuneLower(size: 58 * min(max(k, 0.9), 1.2))).tracking(-1).foregroundStyle(.white)
                            .lineLimit(1).fixedSize().padding(.leading, S.margin - 2).turnstile(0)
                            .accessibilityAddTraits(.isHeader)
                        first.content.padding(.top, S.head * 2)
                    }
                    .padding(.top, S.head)
                }
                .turnstile(0)
            } right: {
                Pager(.pivot, title: " ", page: Binding(get: { max(page, panels[1].id) }, set: { page = $0 }), top: 0, panels: Array(panels.dropFirst()))
            }
        } else {
            Pager(.pivot, title: title, page: $page, top: 0, panels: panels)
        }
    }
}

// What the first frame of a page doesn't need (a ring of covers, cards below the first screen): drawn half a second
// after the page has turned in, so the push's first frames stay light (gate 2b: hubs stalled 1-1.5 s as they opened).
struct Later<C: View>: View {
    var delay: Double = 0.5
    @ViewBuilder let content: () -> C
    @State private var on = false
    var body: some View {
        Group { if on { content() } }
            .task { if !on { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); on = true } }
    }
}

// The application title that sits over every page in Windows Phone 7: small capitals, hung from the page's edge
// (20 px caps in the theme; recalled position 12 from the top). Here it names where he is: ROTATION on home, the hub's
// name over its pages.
struct AppTitle: View {
    let text: String
    var body: some View {
        // WP7's application title: PhoneTextNormalStyle, 20 px in capitals, regular weight, white.
        Text(text.uppercased())
            .font(.zuneCaps(size: 18)).tracking(0.6)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.leading, S.margin)
            .accessibilityAddTraits(.isHeader)
    }
}

// Turnstile forward in [S4]: the page swings in about its left edge from −80° to flat in 0.35 s with exponential ease
// out; its parts feathered one after another 50 ms apart (recalled), so the page assembles from the hinge. Once per
// arrival: a return by Back finds it as it was.
struct TurnstileIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.turnstileArrived) private var arrived
    @Environment(\.turnstileUntil) private var until
    func body(content: Content) -> some View {
        // Made after its page's arrival (a pivot page built at rest, a lazy row scrolled to, the page a wrap lands on): it is
        // simply there. The entrance plays once per arrival (gate on build 71: a wrap flick's page turned in again).
        let on = shown || still || arrived || Date() > until
        // At rest the turn is exactly nothing (no angle, no perspective): a projection left on a resting page made
        // every page a 3D layer, and home drew at 12-29 fps under the Back drag (gate 2b, item 3).
        // No fade: WP7 cuts opacity in at 0.01 s, and a page held at 0 through a busy first frame showed as a blank page
        // under its head (gate 3: now playing empty for a second).
        content
            .rotation3DEffect(.degrees(on ? 0 : -80), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: on ? 0 : 0.55)
            .onAppear {
                guard !shown, Date() <= until else { return }
                // Begun once the page's first frames are on screen: begun in the same update as a hub's first build, the
                // swing was mostly over by the time that frame landed, and the turnstile read as a cut (run 63 gate).
                // Not at launch: there the screen must be whole in its first frame (launch-warm), as it was.
                let swing = { withAnimation(Z.easeOut(0.35).delay(Double(index) * Z.feather)) { shown = true } }
                if FirstFrames.launching { swing() } else { FirstFrames.shared.after(swing) }
            }
    }
}

// Runs what's waiting once the page's first frame is on screen and the next one came on time, or after 0.12 s at most: a
// page's first frame is its costliest, so an entrance begun after it is seen whole, and no later (gate on build 71: two
// on-time frames or 0.3 s held a bare backdrop after every push). One display link for every waiter, only while someone
// waits.
@MainActor final class FirstFrames: NSObject {
    static let shared = FirstFrames()
    // The app's first seconds (read first by home's own turnstile, as the app comes up).
    private static let born = Date()
    static var launching: Bool { Date().timeIntervalSince(born) < 3 }
    private var waiting: [() -> Void] = []
    #if canImport(UIKit)
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0, began: CFTimeInterval = 0, onTime = 0
    #endif
    func after(_ run: @escaping () -> Void) {
        #if canImport(UIKit)
        waiting.append(run)
        guard link == nil else { return }
        began = CACurrentMediaTime(); last = 0; onTime = 0
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        #else
        run()
        #endif
    }
    #if canImport(UIKit)
    @objc private func tick(_ l: CADisplayLink) {
        let period = max(l.targetTimestamp - l.timestamp, 1.0 / 120)
        if last > 0 { onTime = l.timestamp - last < period * 1.5 ? onTime + 1 : 0 }
        last = l.timestamp
        // A turnstile begun inside a stall shows only its last few frames (gate on build 76: about 5 frames of 0.35 s).
        // Four on time and a tenth of a second at least: the render server draws a hub's first frame after the main
        // thread has moved on (run 77: the turn-in showed one frame).
        guard (onTime >= 4 && CACurrentMediaTime() - began > 0.1) || CACurrentMediaTime() - began > 0.6 else { return }
        l.invalidate(); link = nil
        let ready = waiting; waiting = []
        ready.forEach { $0() }
    }
    #endif
}
private struct TurnstileArrivedKey: EnvironmentKey { static let defaultValue = false }
private struct TurnstileUntilKey: EnvironmentKey { static let defaultValue = Date.distantFuture }
extension EnvironmentValues {
    // Until when a part made on this page still turns in: a pivot sets its arrival plus a moment, so pages and rows made
    // later never replay the entrance.
    var turnstileUntil: Date { get { self[TurnstileUntilKey.self] } set { self[TurnstileUntilKey.self] = newValue } }
    // Set for a page restored (a build's pose, a link opening deep): no swing, it's simply there.
    var turnstileArrived: Bool { get { self[TurnstileArrivedKey.self] } set { self[TurnstileArrivedKey.self] = newValue } }
}
extension View {
    func turnstile(_ index: Int) -> some View { modifier(TurnstileIn(index: index)) }
}

// Turnstile forward out [S4]: 0° to 50° about the left edge in 0.25 s, exponential ease in; feathered 50 ms apart with
// the tapped item last, as Windows Phone leaves a list.
// What home's tap chose (its place in Home.keys), read only by the turnstiles: as a value handed down, a tap worked out
// every tile and word on home again in the first frame of the turnstile.
@MainActor @Observable final class HomeLeave {
    static let shared = HomeLeave()
    var chosen: Int?
    // Everything gone, set without animation a frame before the push: a hub's first build stalls the main thread, and
    // SwiftUI's fades froze half-way through it (run 77 films: two words held at 15 % for 0.6 s). Black instead, WP7's own
    // dark moment between the leave and the turn-in (study §3).
    var cleared = false
}
struct TurnstileOut: ViewModifier {
    let index: Int
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var still
    func body(content: Content) -> some View {
        let chosen = HomeLeave.shared.chosen
        // A negative index takes no part (a section whose parts leave on their own).
        let gone = chosen != nil && !still && index >= 0
        let word = chosen.map(HomeLeave.isWord) ?? false
        let me = chosen == index
        // Tiles (WP7's start screen, guide p.65): the others turn away, the tapped one last. A menu word (WP7's music hub,
        // study §3, measured): the tapped word lifts away first, up and to the right, in about 0.1 s; then the title,
        // background and headers turn out; the other words go last.
        let order = chosen.map { index == $0 ? count : (index < $0 ? index : index - 1) } ?? 0
        // The tapped tile held a beat after the rest have turned (gate on build 78: tapped-last wasn't visible).
        let delay = word ? HomeLeave.wordLead + Double(index) / Double(max(count, 1)) * HomeLeave.wordSpread
                         : (me ? Z.leaveSpread + HomeLeave.tileHold : Double(order) / Double(max(count, 1)) * Z.leaveSpread)
        let lift = gone && word && me
        content
            .rotation3DEffect(.degrees(gone && !lift ? 50 : 0), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: gone && !lift ? 0.55 : 0)
            .offset(x: lift ? 36 : 0, y: lift ? -22 : 0)
            .opacity(gone ? 0 : 1)
            .animation(gone ? (lift ? Z.easeIn(HomeLeave.liftTime) : Z.easeIn(0.25).delay(delay)) : nil, value: gone)
    }
}
extension HomeLeave {
    nonisolated static let liftTime = 0.12
    nonisolated static let wordLead = 0.03
    nonisolated static let tileHold = 0.1
    nonisolated static let wordSpread = 0.12
    nonisolated static func isWord(_ i: Int) -> Bool { Home.keys.indices.contains(i) && Home.keys[i].hasPrefix("w-") }
    // From the tap to the push: everything gone (a word's leave: its lead, the spread, a swing; a tile's: the spread and
    // its swing), so nothing on screen freezes while the hub is made.
    nonisolated static func wait(_ i: Int) -> Double { isWord(i) ? wordLead + wordSpread + 0.25 + 0.01 : Z.leaveSpread + tileHold + 0.25 + 0.01 }
}

// Windows Phone's tilt [S4, S5]: what's pressed tips toward the finger (up to 0.3 rad at a corner) and sinks (25 px of
// depression at the centre, (1 − |offset|) × 25), with no change of colour; it comes back 200 ms after it's let go, over
// 100 ms. Where the finger is comes from a touch-down recogniser beside the button's own (it never takes the touch, and a
// scroll or a move of more than a few points lets the tilt go).
struct Tilt: ButtonStyle {
    var depth: CGFloat = 0.955
    func makeBody(configuration: Configuration) -> some View { TiltBody(label: configuration.label, pressed: configuration.isPressed) }
}
private struct TiltBody<L: View>: View {
    let label: L
    let pressed: Bool
    @State private var at: CGPoint?
    @State private var size: CGSize = .zero
    // The finger has travelled: a swipe begun on the tile, not a press. The tilt lets go at once (WP7 drops it as a pan
    // starts); held through its 0.2 s release, a tile stayed tipped while the panorama or pivot moved off under it.
    @State private var travelled = false
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        let on = pressed && !still && !travelled
        // Where the finger is, as −1…1 across and down from the centre; the centre if it isn't known.
        let p = at ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = size.width > 0 ? max(-1, min(1, (p.x - size.width / 2) / (size.width / 2))) : 0
        let dy = size.height > 0 ? max(-1, min(1, (p.y - size.height / 2) / (size.height / 2))) : 0
        let off = min(1, sqrt(dx * dx + dy * dy) / sqrt(2) * 1.25)
        // The sink: 25 px into the screen at the centre, read as a scale at WP7's perspective (a 480 px screen at 1000 px).
        let sink = 1 - (1 - off) * 25 / 1000 * min(3, max(1, 480 / max(size.width, 120)))
        label
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .scaleEffect(on ? sink : 1)
            // The press tips the side under the finger in: a rotation about the axis at right angles to the finger's offset.
            .rotation3DEffect(.radians(on ? 0.3 * off : 0), axis: (x: -dy, y: dx, z: 0), perspective: on ? 0.5 : 0)
            .animation(on ? .easeOut(duration: 0.05) : .easeOut(duration: 0.1).delay(travelled ? 0 : 0.2), value: on)
            #if canImport(UIKit)
            // A UIKit recogniser that recognises beside everything and never cancels the button's touch.
            .gesture(TouchDown(down: { at = $0; travelled = false }, moved: { travelled = true }))
            #endif
    }
}
// The last press on a tilting tile or word travelled more than 10 pt: a swipe begun on it, never a tap (gate on build 71:
// a quick flick across home's menu words open flat opened History). Read by whatever the press would open.
@MainActor enum TouchTravel { static var swiped = false }
#if canImport(UIKit)
// The finger's first point, for the tilt: a press of no duration that recognises beside everything and never cancels the
// button's touch.
private struct TouchDown: UIGestureRecognizerRepresentable {
    let down: (CGPoint) -> Void
    var moved: () -> Void = {}
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0
        g.allowableMovement = 12
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        g.delegate = context.coordinator
        return g
    }
    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        let p: CGPoint? = context.converter.localLocation
        // Travel is read in the window: the tile moves with a scroll, so under its own finger it barely moves at all.
        let w = g.location(in: nil)
        if g.state == .began, let p { context.coordinator.from = w; context.coordinator.gone = false; TouchTravel.swiped = false; down(p) }
        // More than 10 pt from where it came down: a swipe, said once.
        if g.state == .changed, let f = context.coordinator.from, !context.coordinator.gone, hypot(w.x - f.x, w.y - f.y) > 10 {
            context.coordinator.gone = true; TouchTravel.swiped = true; moved()
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var from: CGPoint?
        var gone = false
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

// WP7's buttons: a square outline, 2 pt of white, black inside (no glass, no capsule).
extension View {
    func wpButton() -> some View {
        self.background(Color.black).overlay { Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 2) }.contentShape(Rectangle())
    }
}

// Where the system's navigation bar is when it runs across the top (the Duo open upright, the one posture with
// horizontal bars, where Back sits at the top left): in window points, or nil when the bars are on the side strip.
// Read from the stack's own bar, so a page's small capitals sit on Back's row and its huge names start right under it,
// never a bar's height lower (Richard, 2026-11-25: "i also dont like that its artificially lowered").
enum TopBar {
    @MainActor static func across() -> CGRect? {
        #if canImport(UIKit)
        guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let n = nav(w.rootViewController) else { return nil }
        let b = n.navigationBar
        guard !n.isNavigationBarHidden, !b.isHidden, b.window != nil else { return nil }
        let f = b.convert(b.bounds, to: nil)
        return f.width > f.height * 3 && f.height > 20 && f.minY < 140 ? f : nil
        #else
        return nil
        #endif
    }
    #if canImport(UIKit)
    @MainActor private static func nav(_ v: UIViewController?) -> UINavigationController? {
        guard let v else { return nil }
        if let n = v as? UINavigationController { return n }
        for c in v.children { if let n = nav(c) { return n } }
        return nav(v.presentedViewController)
    }
    #endif
    // Where a page's small capitals go: on Back's row (beside it) when the bar runs across the top, else WP7's top
    // margin, about 24 pt from the top of the screen (the clock is on the side strip there). `top` is the safe area's
    // top as the page sees it.
    @MainActor static func caps(top: CGFloat, height: CGFloat, pushed: Bool) -> (y: CGFloat, lead: CGFloat, below: CGFloat) {
        if let b = across() {
            // Beside Back on its row (Back is a 44 pt button from the margin); on home, at the margin.
            return (b.midY - height / 2, pushed ? 64 : 0, b.maxY - 2)
        }
        let y = top < 44 ? max(18, top - 8) : top + 4
        return (y, 0, y + height)
    }
}

// WP7's pivot and panorama paging: the page follows the finger 1:1; let go, the release VELOCITY decides (WP7's
// pivot): a flick faster than `flick` pages per second turns one page in its direction, however short; anything slower
// lands on the nearer page (a drag must pass half a page). Half a page a second is the throw build 63 turned on, so the
// decisions are 63's. Never more than one page per swipe. The velocity is read back from the projected carry: UIKit
// projects a throw by v * r / (1 - r) / 1000 (r the deceleration rate per ms, FastSettle's 0.99).
// The landing is not the scroll's: on a release the scroll is told to stop where the finger left it, and the page chosen
// is reached by PageLander's fixed 0.35 s exponential ease out (gate on build 71: UIKit's deceleration to the adjusted
// target took 1.5-2 s to rest, 90 % in the first half second and then a creep; WP7 lands in about 0.35 s).
struct WPPaging: ScrollTargetBehavior {
    let width: CGFloat
    let count: Int
    let motion: PagerMotion
    // Pages per second at release that count as a flick.
    var flick: CGFloat = 0.5
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Asked on the main thread, as the scroll's own delegate is.
        let original = context.originalTarget.rect.minX
        target = MainActor.assumeIsolated { decide(target, original) }
    }
    @MainActor private func decide(_ given: ScrollTarget, _ original: CGFloat) -> ScrollTarget {
        var target = given
        let w = max(width, 1)
        let from = (original / w).rounded()
        let x = motion.offset
        let at = x / w
        // The scroll's velocity at the lift, or the finger's own over the drag's last 0.1 s when that is faster.
        let lift = (target.rect.minX - x) / FastSettle.projection
        let drag = motion.dragVelocity(at: x)
        let v = abs(drag) > abs(lift) ? drag : lift
        var to: CGFloat
        if abs(v) > flick * w { to = v > 0 ? at.rounded(.down) + 1 : at.rounded(.up) - 1 } else { to = at.rounded() }
        to = max(from - 1, min(from + 1, to))
        to = max(0, min(CGFloat(count - 1), to))
        // A finger let go: the scroll stops where it is and the lander takes it to the page (when it can reach the scroll).
        if motion.phase == .interacting, motion.lander.ready {
            target.rect.origin.x = x
            // Only the release itself decides: asked again before the phase moves on, the target is the stopped one and
            // reads as no velocity at all (profile run 10: folded flicks recorded at 0 page/s and sprang back).
            if !motion.decided { motion.released(slot: Int(to), x: x, v: v, w: w) }
        } else {
            target.rect.origin.x = to * w
            if motion.phase == .interacting, !motion.decided { motion.released(slot: Int(to), x: x, v: v, w: w) }
        }
        return target
    }
}

// The landing, WP7's way: from where the finger left the page to the page chosen in 0.35 s, ExponentialEase (exponent 6)
// EaseOut as the Silverlight toolkit's transitions [S4]. Since build 77 (Richard, 11-26: "the animations rn r very rough")
// it is Core Animation's: the scroll's offset is animated by a property animator in the render server, on the cubic that
// matches WP7's curve (Z.easeOut's), so no frame of a landing waits on the main thread. What follows the scroll (a pivot's
// names, the panorama's title and background) is told the target once, as the landing starts, and animated by SwiftUI on
// the same curve and duration: nothing is laid out again in the landing's frames. A finger that starts dragging again
// stops it where it is on screen and takes over at once.
@MainActor final class PageLander: NSObject {
    #if canImport(UIKit)
    weak var scroll: UIScrollView?
    #endif
    // The landing running (its number, so a stopped one's completion is ignored), and where it goes.
    private var running: (id: Int, to: CGFloat)?
    private var serial = 0
    private var done: (() -> Void)?
    // Told as a landing starts (its target offset and the curve it runs on), and as it ends or is stopped (its owner syncs
    // what follows the scroll).
    var starts: ((CGFloat, Animation) -> Void)?
    var ends: (() -> Void)?
    static let duration = 0.35
    var ready: Bool {
        #if canImport(UIKit)
        return scroll != nil
        #else
        return false
        #endif
    }
    var active: Bool { running != nil }
    // Where the scroll is now (the landing's target while one runs: the model value).
    var offset: CGFloat? {
        #if canImport(UIKit)
        return scroll?.contentOffset.x
        #else
        return nil
        #endif
    }
    static func ease(_ t: Double) -> Double { let k = 6.0; return (1 - exp(-k * t)) / (1 - exp(-k)) }
    // Lands on x; `done` once it rests there. False when there is no scroll to drive.
    // Since build 83 a Core Animation basic animation on the scroll's bounds asking for up to 120 Hz (an iPhone runs a
    // property animator's frames at 60 unless asked: a 120 Hz drag then landed at half the rate).
    //
    // Build 84 (gate on 83: one landing held five still frames, then jumped a quarter page in one): a Core Animation
    // animation's clock starts when its transaction is committed, and the lift's commit also carries that frame's layout
    // (the tick, the names told their target), so a busy lift drew nothing until the landing was well under way. The
    // landing now starts on the next display frame after the lift, in a transaction of its own, so it is seen from its
    // first frame whatever the lift cost. And it carries the finger's speed (WP7 eased a slow drag off and snapped a
    // flick): `velocity` (points a second at the release) sets the curve's opening slope to match it, between WP7's
    // exponent-6 snap for a flick and a gentle ease out for a page let go at rest; nil is a tapped name, WP7's curve.
    @discardableResult func land(to x: CGFloat, velocity: CGFloat? = nil, done: @escaping () -> Void) -> Bool {
        #if canImport(UIKit)
        guard let sv = scroll else { return false }
        let from = current(sv)
        cancel(sv)
        self.done = done
        if abs(x - from) < 0.5 {
            sv.setContentOffset(CGPoint(x: x, y: sv.contentOffset.y), animated: false)
            finish(); return true
        }
        serial += 1
        let id = serial
        running = (id, x)
        let curve = Self.curve(distance: abs(x - from), velocity: velocity)
        pending = { [weak self] in self?.begin(id: id, from: from, to: x, curve: curve) }
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        }
        return true
        #else
        return false
        #endif
    }
    // The landing's curve: WP7's (0.16, 1, 0.3, 1) when the finger was fast or unknown; its first control point moved out
    // as the release slows, so the landing opens at about the finger's own speed (at most 0.6: a gentle ease out).
    struct Curve { let x1: Double; let duration: Double }
    static func curve(distance d: CGFloat, velocity v: CGFloat?) -> Curve {
        guard let v, d > 1 else { return Curve(x1: 0.16, duration: duration) }
        // Opening slope of (x1, 1, 0.3, 1) is 1 / x1 of the mean speed d / T.
        let T = duration
        let mean = Double(d) / T
        let x1 = min(0.6, max(0.16, mean / max(Double(abs(v)), 1)))
        // Slower releases a little longer, so the gentle curve isn't hurried.
        return Curve(x1: x1, duration: T + (x1 - 0.16) * 0.15)
    }
    #if canImport(UIKit)
    private var pending: (() -> Void)?
    private var link: CADisplayLink?
    @objc private func tick() {
        link?.invalidate(); link = nil
        let p = pending; pending = nil
        p?()
    }
    private func begin(id: Int, from: CGFloat, to x: CGFloat, curve: Curve) {
        guard let sv = scroll, running?.id == id else { return }
        starts?(x, .timingCurve(curve.x1, 1, 0.3, 1, duration: curve.duration))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running?.id == id else { return }
                self.running = nil
                self.finish()
            }
        }
        sv.contentOffset = CGPoint(x: x, y: sv.contentOffset.y)
        let a = CABasicAnimation(keyPath: "bounds.origin.x")
        a.fromValue = from
        a.toValue = x
        a.duration = curve.duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: Float(curve.x1), 1, 0.3, 1)
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        sv.layer.add(a, forKey: "land")
        CATransaction.commit()
        // Out at once to the render server: nothing else of this turn rides in the landing's first frame.
        CATransaction.flush()
    }
    // Where the scroll shows now: mid-landing, the frame on screen rather than the model's target.
    private func current(_ sv: UIScrollView) -> CGFloat {
        guard running != nil, pending == nil, let p = sv.layer.presentation() else { return sv.contentOffset.x }
        return p.bounds.origin.x
    }
    // A landing taken off where it is on screen.
    private func cancel(_ sv: UIScrollView) {
        guard running != nil else { return }
        let at = current(sv)
        running = nil
        // A landing not yet begun: nothing moved, nothing to take off.
        if pending != nil { pending = nil; link?.invalidate(); link = nil; return }
        sv.layer.removeAnimation(forKey: "land")
        sv.setContentOffset(CGPoint(x: at, y: sv.contentOffset.y), animated: false)
    }
    #endif
    // Put at x at once, no landing (the carousel dealt round under a page at rest).
    func jump(to x: CGFloat) {
        #if canImport(UIKit)
        guard let sv = scroll else { return }
        sv.setContentOffset(CGPoint(x: x, y: sv.contentOffset.y), animated: false)
        #endif
    }
    // A finger on it again: the landing stops where it is on screen (the next release lands from there).
    func stop() {
        #if canImport(UIKit)
        if running != nil, let sv = scroll { cancel(sv); ends?() }
        #endif
        done = nil
    }
    private func finish() {
        ends?()
        let d = done; done = nil
        d?()
    }
}

// A start tile's clock (WP7's live tiles): one tile moves at a time, a few seconds apart, in a shuffled round, so the
// start screen is alive without ever moving all at once; nothing moves while he's scrolling or the screen is covered.
// One tile's turns, observed by that tile alone: a turn redraws one tile, never the whole start screen.
@MainActor @Observable final class TileTurn { var count = 0 }
@MainActor @Observable final class TileClock {
    static let shared = TileClock()
    @ObservationIgnored private var turns: [String: TileTurn] = [:]
    func turn(_ id: String) -> TileTurn { if let t = turns[id] { return t }; let t = TileTurn(); turns[id] = t; return t }
    @ObservationIgnored private var live: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var holders = 0
    func join(_ id: String) { if !live.contains(id) { live.append(id) } }
    func leave(_ id: String) { live.removeAll { $0 == id } }
    func start() {
        holders += 1
        // The build's stills (-tilesStill) show every tile's front; its films let them turn.
        guard task == nil, !UIAccessibilityReduceMotion.on, !UserDefaults.standard.bool(forKey: "tilesStill") else { return }
        task = Task { @MainActor [weak self] in
            // The first turn a moment after the start screen is up (WP7's tiles start turning a few seconds in).
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            var round: [String] = []
            while !Task.isCancelled, let self {
                if round.isEmpty { round = self.live.shuffled() }
                if let id = round.popLast(), !Store.shared.scrolling, !NavTransit.shared.inFlight { self.turn(id).count += 1 }
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2.2...3.6) * 1_000_000_000))
            }
        }
    }
    func stop() { holders = max(0, holders - 1); if holders == 0 { task?.cancel(); task = nil } }
}
enum UIAccessibilityReduceMotion {
    @MainActor static var on: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        false
        #endif
    }
}

// A live tile [WP7]: square (1×1) or wide (2×1), flat colour or a cover, its name small at the foot-left (12 from the
// left, 6 from the foot). Its faces take turns as the tile clock says: a flip about the tile's horizontal axis (the
// front out to 90° in 0.25 s easing in, the back in from −90° in 0.35 s easing out, the turnstile's own timings, §27.1),
// or a peek, where the picture slides up to show the words under it and slides back on the next turn.
struct LiveTile<Front: View, Back: View>: View {
    enum Motion { case flip, peek }
    let id: String
    let name: String
    var motion: Motion = .flip
    var fill: Color = Z.magenta
    @ViewBuilder let front: () -> Front
    @ViewBuilder let back: () -> Back
    @State private var face = 0
    @State private var angle: Double = 0
    private var clock: TileClock { TileClock.shared }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                fill
                switch motion {
                case .flip:
                    // Both faces built from the start (a face built at the flip's midpoint decoded its picture inside
                    // the animation); the turn only swaps which one shows.
                    ZStack {
                        front().opacity(face % 2 == 0 ? 1 : 0)
                        back().opacity(face % 2 == 1 ? 1 : 0)
                    }
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
                case .peek:
                    // The picture over the words; on a peek it rises to show the lower half's words.
                    ZStack(alignment: .top) {
                        back().frame(width: g.size.width, height: g.size.height)
                        front().frame(width: g.size.width, height: g.size.height).clipped()
                            .offset(y: face % 2 == 0 ? 0 : -g.size.height * 0.5)
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                    .clipped()
                }
                // Over a picture, a low shade under the name instead of a shadow (WP7's tiles have none; a text shadow was
                // drawn off screen in every frame the start screen moved).
                if motion == .peek || fill == .clear {
                    LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 34).frame(maxWidth: .infinity).allowsHitTesting(false)
                }
                Text(name).font(.zune(size: 17, .regular)).foregroundStyle(.white).lineLimit(1)
                    .padding(.leading, 10).padding(.bottom, 6)
            }
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: angle == 0 ? 0 : 0.6)
        }
        .clipShape(Rectangle())
        .onAppear { clock.join(id) }
        .onDisappear { clock.leave(id) }
        .onChange(of: clock.turn(id).count) { _, _ in turn() }
        .accessibilityElement(children: .combine)
    }
    private func turn() {
        switch motion {
        case .peek:
            withAnimation(Z.easeOut(0.5)) { face += 1 }
        case .flip:
            withAnimation(Z.easeIn(0.25)) { angle = 90 } completion: {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { face += 1; angle = -90 }
                withAnimation(Z.easeOut(0.35)) { angle = 0 }
            }
        }
    }
}

// WP7's application bar [S6]: a strip along the foot of a page that has actions, in the theme's chrome (#1F1F1F on the
// dark theme), with up to four round outlined icon buttons centred in it and "•••" at its right. The dots raise the bar
// to show each button's name under it, in lowercase; a tap anywhere else, or on a button, lowers it again. Only pages
// with actions of their own have one (Richard, 2026-11-25: "make this work as a zune windows phone app").
struct AppBar<Buttons: View>: View {
    @Binding var open: Bool
    @ViewBuilder let buttons: () -> Buttons
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 28) { buttons() }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            Button { withAnimation(Z.easeOut(0.25)) { open.toggle() } } label: {
                Text("•••").font(.system(size: 13, weight: .bold)).tracking(1).foregroundStyle(.white)
                    .frame(width: 52, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide the button names" : "Show the button names")
        }
        .frame(height: open ? 84 : 60, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.122).ignoresSafeArea(edges: .bottom))
        .environment(\.appBarOpen, open)
    }
}
private struct AppBarOpenKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var appBarOpen: Bool { get { self[AppBarOpenKey.self] } set { self[AppBarOpenKey.self] = newValue } }
}
// One of the bar's buttons: the icon in a 2 pt white ring (48 px on WP7), its name under it when the bar is raised.
struct AppBarIcon: View {
    let icon: String
    let label: String
    var dim = false
    @Environment(\.appBarOpen) private var open
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular))
                .frame(width: 40, height: 40)
                .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
            if open { Text(label.lowercased()).font(.zune(size: 13)).lineLimit(1).fixedSize() }
        }
        .foregroundStyle(.white.opacity(dim ? 0.4 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

// A WP7 panorama stops at its ends: no rubber band past the first or last section. Set on the horizontal scroll the
// view sits in (its first enclosing UIScrollView), from a zero-size view inside the scroll's content.
struct NoBounce: View {
    var body: some View {
        #if canImport(UIKit)
        NoBounceProbe().frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        #else
        Color.clear.frame(width: 0, height: 0)
        #endif
    }
}
#if canImport(UIKit)
private struct NoBounceProbe: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Once laid in its scroll (the next turn of the run loop, when the hierarchy is whole).
            DispatchQueue.main.async { [weak self] in
                var v = self?.superview
                while let s = v {
                    if let sv = s as? UIScrollView { sv.bounces = false; sv.alwaysBounceHorizontal = false; return }
                    v = s.superview
                }
            }
        }
    }
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ v: Probe, context: Context) {}
}
#endif

// Art as WP7 lays it inside a pivot or a hub (the music hub's "new"): a grid of squares, three across folded and four
// with room, two rows and the rest a tap away. Never a sideways strip inside a pivot: a sideways drag there scrolled the
// strip instead of turning the pivot (run 60, pivot-wrap: "on repeat" scrolled 1-2-3 → 5-6-7 and lately never turned).
struct TileGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Int, Item, CGFloat) -> Cell
    @Environment(\.pageWidth) private var page
    @State private var all = false
    var body: some View {
        let cols = page >= 560 ? 4 : 3
        let w = floor((max(page, 240) - S.margin * 2 - S.gap * CGFloat(cols - 1)) / CGFloat(cols))
        let shown = all ? items : Array(items.prefix(cols * 2))
        VStack(alignment: .leading, spacing: S.gap) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: S.gap, alignment: .top), count: cols), alignment: .leading, spacing: S.gap) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { k, e in cell(k, e, w) }
            }
            if items.count > cols * 2 {
                Button { withAnimation(Z.easeOut(0.35)) { all.toggle() } } label: {
                    Text(all ? "Show fewer" : "Show all \(items.count)").font(.zune(.subheadline, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44).wpButton()
                }
                .buttonStyle(Press())
            }
        }
        .padding(.horizontal, S.margin)
    }
}

// The window's bounds, for what must reach the screen's foot however its container is laid out: a pushed hub stopped
// ~17 pt short of the bottom edge with a black band over its last row (run 61 gate, blocking 2), safe area or not.
enum Win {
    @MainActor static var bounds: CGRect {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds ?? .zero
        #else
        .zero
        #endif
    }
    // How far below this reader's frame the window goes on: the foot it must still cover.
    @MainActor static func foot(_ g: GeometryProxy) -> CGFloat {
        let w = bounds
        guard w.height > 0 else { return g.safeAreaInsets.bottom }
        return max(g.safeAreaInsets.bottom, w.maxY - g.frame(in: .global).maxY)
    }
}

// A picture that covers the whole screen behind a page: laid out at the page's size plus the side insets and the foot,
// moved up and left by the insets (inside a background, ignoring the safe area left it short of the side strip and the
// foot: run 60/61, now playing black down its right quarter).
struct ScreenBleed<C: View>: View {
    @ViewBuilder let content: (CGSize) -> C
    var body: some View {
        GeometryReader { g in
            // The whole window from wherever this reader sits in it: the insets alone still left the home indicator's
            // strip black under the last row upright and folded (run 62, history and now playing).
            let i = g.safeAreaInsets, f = g.frame(in: .global), w = Win.bounds
            let x = w.width > 0 ? max(0, f.minX - w.minX) : i.leading, y = w.height > 0 ? max(0, f.minY - w.minY) : i.top
            let size = CGSize(width: max(g.size.width + i.leading + i.trailing, w.width > 0 ? w.maxX - f.minX + x : 0),
                              height: max(g.size.height + i.top + Win.foot(g), w.height > 0 ? w.maxY - f.minY + y : 0))
            content(size).frame(width: size.width, height: size.height).clipped()
                .offset(x: -x, y: -y)
        }
    }
}

// WP7's list ends (Richard, 2026-11-25: "model it exactly off of zune"): pulled past its top or foot, a Windows Phone list
// compresses, squeezed toward the far edge of the screen, instead of sliding away from the edge as iOS's rubber band
// does, and lets go when the finger does. The system's own pull (its distance, its damping, its spring back) is read
// from the scroll and shown as that squeeze: the content is held at its edge and scaled about the screen's far edge, so
// the near edge still moves the distance the pull would have moved it. Nothing is read or redrawn while the list
// scrolls inside its ends; the scroll indicator shows while it moves, as WP7's thin bar did.
struct WPScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var ends = ScrollEnds()
    var body: some View {
        // One stack, as the scroll lays its content out itself (its default spacing and alignment): the squeeze is of the
        // whole, never of each piece.
        ScrollView(.vertical) { VStack { content() }.modifier(Compressed(ends: ends)) }
            .onScrollGeometryChange(for: ScrollEnds.Pull.self) { ScrollEnds.Pull($0) } action: { _, p in ends.pull = p }
    }
}
@MainActor @Observable final class ScrollEnds {
    var pull = Pull.none
    struct Pull: Equatable {
        // How far past an end (plus at the top, minus at the foot), and where the screen's far edge is in the content.
        var by: CGFloat = 0, far: CGFloat = 0, height: CGFloat = 1
        static let none = Pull()
        init() {}
        init(_ g: ScrollGeometry) {
            let top = -(g.contentOffset.y + g.contentInsets.top)
            let end = max(-g.contentInsets.top, g.contentSize.height + g.contentInsets.bottom - g.containerSize.height)
            let foot = g.contentOffset.y - end
            guard g.contentSize.height > 1, top > 0.5 || foot > 0.5 else { return }
            height = g.contentSize.height
            if top > 0.5 { by = top; far = g.visibleRect.maxY + top }
            else { by = -foot; far = max(0, g.visibleRect.minY - foot) }
        }
    }
}
private struct Compressed: ViewModifier {
    let ends: ScrollEnds
    func body(content: Content) -> some View {
        let p = ends.pull
        // The near edge moves the pull's distance; everything between it and the far edge is squeezed (never past a
        // fifth: a long pull flattens no more). The same modifiers at rest, as nothing (one structure: a pull's start
        // never rebuilds the list).
        let span = p.by > 0 ? max(p.far, 1) : max(p.height - p.far, 1)
        // Build 81 pass (gate on 78: the list squashed to 80 % in film, a squash rather than WP7's slight compression):
        // half the pull's share of the span, never past 8 %.
        let s = p.by == 0 ? 1 : max(0.92, 1 - 0.5 * abs(p.by) / span)
        content
            .scaleEffect(x: 1, y: s, anchor: UnitPoint(x: 0.5, y: min(1, p.far / max(p.height, 1))))
            .offset(y: -p.by)
    }
}

// WP7's pivot and panorama settle: once the finger lifts, the page eases into place quickly (an exponential ease out,
// as every Silverlight toolkit transition is, [S4]) rather than drifting in on iOS's long default deceleration. The
// scroll's own deceleration, set to the system's fast rate: its decay is exponential, the same family, and short.
struct FastSettle: View {
    // Seconds of release velocity the scroll projects at the rate set here (UIKit: r / (1 - r) / 1000, r per ms).
    static let rate: CGFloat = 0.99
    static let projection: CGFloat = rate / (1 - rate) / 1000
    // Handed the scroll, to land its pages itself.
    var lander: PageLander? = nil
    // A pivot: iOS 26's back swipe from anywhere on the page waits for the pivot's own drag to fail (build 76: a rightward
    // drag in a pivot open flat popped to home). The system's edge swipe is untouched.
    var pivot = false
    var body: some View {
        #if canImport(UIKit)
        FastSettleProbe(lander: lander, pivot: pivot).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        #else
        Color.clear.frame(width: 0, height: 0)
        #endif
    }
}
#if canImport(UIKit)
private struct FastSettleProbe: UIViewRepresentable {
    let lander: PageLander?
    let pivot: Bool
    final class Probe: UIView {
        weak var lander: PageLander?
        var pivot = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                var v = self?.superview
                while let s = v {
                    if let sv = s as? UIScrollView {
                        sv.decelerationRate = UIScrollView.DecelerationRate(rawValue: FastSettle.rate)
                        self?.lander?.scroll = sv
                        if self?.pivot == true { Self.yield(sv) }
                        return
                    }
                    v = s.superview
                }
            }
        }
        private static func yield(_ sv: UIScrollView) {
            var r: UIResponder? = sv
            while let n = r, !(n is UINavigationController) { r = n.next }
            guard let nav = r as? UINavigationController else { return }
            if #available(iOS 26.0, *) { nav.interactiveContentPopGestureRecognizer?.require(toFail: sv.panGestureRecognizer) }
        }
    }
    func makeUIView(context: Context) -> Probe { let p = Probe(); p.lander = lander; p.pivot = pivot; return p }
    func updateUIView(_ v: Probe, context: Context) {}
}
#endif
