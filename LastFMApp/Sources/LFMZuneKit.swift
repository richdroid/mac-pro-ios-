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
    // Leaving is quicker than arriving: 20 ms apart, so the whole menu is gone in 0.4 s before the hub is pushed.
    static let featherOut = 0.02

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
                        AppTitle(text: title ?? hubName ?? "rotation").frame(height: ceil(20 * min(max(k, 0.9), 1.3)) + 2, alignment: .top).turnstile(0)
                        Text(first.header).font(.zune(size: 54 * min(max(k, 0.9), 1.2), .light)).tracking(-1).foregroundStyle(.white)
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
            .font(.zune(size: 18, .regular)).tracking(0.6)
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
    func body(content: Content) -> some View {
        let on = shown || still || arrived
        // At rest the turn is exactly nothing (no angle, no perspective): a projection left on a resting page made
        // every page a 3D layer, and home drew at 12-29 fps under the Back drag (gate 2b, item 3).
        // No fade: WP7 cuts opacity in at 0.01 s, and a page held at 0 through a busy first frame showed as a blank page
        // under its head (gate 3: now playing empty for a second).
        content
            .rotation3DEffect(.degrees(on ? 0 : -80), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: on ? 0 : 0.55)
            .onAppear {
                guard !shown else { return }
                withAnimation(Z.easeOut(0.35).delay(Double(index) * Z.feather)) { shown = true }
            }
    }
}
private struct TurnstileArrivedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    // Set for a page restored (a build's pose, a link opening deep): no swing, it's simply there.
    var turnstileArrived: Bool { get { self[TurnstileArrivedKey.self] } set { self[TurnstileArrivedKey.self] = newValue } }
}
extension View {
    func turnstile(_ index: Int) -> some View { modifier(TurnstileIn(index: index)) }
}

// Turnstile forward out [S4]: 0° to 50° about the left edge in 0.25 s, exponential ease in; feathered 50 ms apart with
// the tapped item last, as Windows Phone leaves a list.
struct TurnstileOut: ViewModifier {
    let index: Int
    let count: Int
    let chosen: Int?
    @Environment(\.accessibilityReduceMotion) private var still
    func body(content: Content) -> some View {
        let gone = chosen != nil && !still
        // The order of leaving: everything else from the top, the chosen word last.
        let order = chosen.map { index == $0 ? count : (index < $0 ? index : index - 1) } ?? 0
        content
            .rotation3DEffect(.degrees(gone ? 50 : 0), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: gone ? 0.55 : 0)
            .opacity(gone ? 0 : 1)
            .animation(gone ? Z.easeIn(0.25).delay(Double(order) * Z.featherOut) : nil, value: gone)
    }
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
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        let on = pressed && !still
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
            .animation(on ? .easeOut(duration: 0.05) : .easeOut(duration: 0.1).delay(0.2), value: on)
            #if canImport(UIKit)
            // A UIKit recogniser that recognises beside everything and never cancels the button's touch.
            .gesture(TouchDown { at = $0 })
            #endif
    }
}
#if canImport(UIKit)
// The finger's first point, for the tilt: a press of no duration that recognises beside everything and never cancels the
// button's touch.
private struct TouchDown: UIGestureRecognizerRepresentable {
    let down: (CGPoint) -> Void
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
        if g.state == .began, let p { down(p) }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
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

// WP7's pivot and panorama paging: the page follows the finger 1:1; let go, a flick (any throw that would carry the
// page a quarter of the way on) turns one page in its direction, otherwise the nearer page wins; never more than one
// page per swipe. The settle is the scroll's own deceleration, an exponential ease out like WP7's.
struct WPPaging: ScrollTargetBehavior {
    let width: CGFloat
    let count: Int
    let release: () -> CGFloat
    let chosen: (Int) -> Void
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let w = max(width, 1)
        let from = (context.originalTarget.rect.minX / w).rounded()
        let at = release() / w
        let natural = target.rect.minX / w
        let carry = natural - at
        var to: CGFloat
        if abs(carry) > 0.25 { to = carry > 0 ? at.rounded(.down) + 1 : at.rounded(.up) - 1 } else { to = at.rounded() }
        to = max(from - 1, min(from + 1, to))
        to = max(0, min(CGFloat(count - 1), to))
        target.rect.origin.x = to * w
        chosen(Int(to))
    }
}

// A start tile's clock (WP7's live tiles): one tile moves at a time, a few seconds apart, in a shuffled round, so the
// start screen is alive without ever moving all at once; nothing moves while he's scrolling or the screen is covered.
@MainActor @Observable final class TileClock {
    static let shared = TileClock()
    private(set) var turns: [String: Int] = [:]
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
                if let id = round.popLast(), !Store.shared.scrolling, !NavTransit.shared.inFlight { self.turns[id, default: 0] += 1 }
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
                    Group { if face % 2 == 0 { front() } else { back() } }
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
                Text(name).font(.zune(size: 17, .regular)).foregroundStyle(.white).lineLimit(1)
                    .shadow(color: .black.opacity(motion == .peek || fill == .clear ? 0.5 : 0), radius: 3)
                    .padding(.leading, 10).padding(.bottom, 6)
            }
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: angle == 0 ? 0 : 0.6)
        }
        .clipShape(Rectangle())
        .onAppear { clock.join(id) }
        .onDisappear { clock.leave(id) }
        .onChange(of: clock.turns[id] ?? 0) { _, _ in turn() }
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
