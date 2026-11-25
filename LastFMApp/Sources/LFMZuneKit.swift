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

    #if canImport(UIKit)
    static func uiFont(_ size: CGFloat, weight: CGFloat) -> UIFont {
        let w: Font.Weight = weight <= -0.35 ? .light : weight < 0.2 ? .regular : weight < 0.35 ? .semibold : .bold
        return UIFont(name: name(w), size: size) ?? UIFont.systemFont(ofSize: size, weight: UIFont.Weight(rawValue: weight))
    }
    #endif
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
        content
            .rotation3DEffect(.degrees(on ? 0 : -80), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.55)
            .opacity(on ? 1 : 0)
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
            .rotation3DEffect(.degrees(gone ? 50 : 0), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.55)
            .opacity(gone ? 0 : 1)
            .animation(gone ? Z.easeIn(0.25).delay(Double(order) * Z.feather) : nil, value: gone)
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
            .rotation3DEffect(.degrees(configuration.isPressed && !still ? 4 : 0), axis: (x: 0.6, y: -1, z: 0), perspective: 0.5)
            .animation(configuration.isPressed ? .easeOut(duration: 0.06) : .easeOut(duration: 0.1).delay(0.2), value: configuration.isPressed)
    }
}
