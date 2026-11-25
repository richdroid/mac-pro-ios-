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
    static let accent = LinearGradient(colors: [magenta, orange], startPoint: .leading, endPoint: .trailing)
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
        Text(text.uppercased())
            .font(.zune(.subheadline, .semibold)).tracking(1.4)
            .foregroundStyle(.white.opacity(0.85))
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

// Windows Phone's tilt [S4, S5]: what's pressed sinks (25 px of depression at the centre) and tips toward the finger,
// with no change of colour, and comes back 200 ms after it's let go, over 100 ms. A button style can't know where the
// finger is, so it is the centre press: the sink, with the slight tip a thumb gives.
struct Tilt: ButtonStyle {
    var depth: CGFloat = 0.955
    @Environment(\.accessibilityReduceMotion) private var still
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? depth : 1)
            .rotation3DEffect(.degrees(configuration.isPressed && !still ? 4 : 0), axis: (x: 0.6, y: -1, z: 0), perspective: configuration.isPressed ? 0.5 : 0)
            .animation(configuration.isPressed ? .easeOut(duration: 0.06) : .easeOut(duration: 0.1).delay(0.2), value: configuration.isPressed)
    }
}
