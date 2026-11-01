import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The launcher's own values, from its colors.xml, dimens.xml and integers.xml. dp maps to pt 1:1, since the Duo open
// (951pt) is almost exactly its 960dp canvas.
enum Mint {
    static let text = Color(hex: 0xEEEEEE), banner = Color(hex: 0x455A64), band = Color(hex: 0x37474F), plane = Color(hex: 0x263238)
    static let progress = Color(hex: 0x17FFFF), press = Color(hex: 0x4A4F51), orb = Color(hex: 0x4285F4)
    static let bannerSize = CGSize(width: 142, height: 80)
    static let radius: CGFloat = 2, gap: CGFloat = 12, rowGap: CGFloat = 36
    static let focus = Animation.easeInOut(duration: 0.15)
    static let glide = Animation.timingCurve(0.3, 0, 0.1, 1, duration: 0.32)

    static func font(_ size: CGFloat, weight: CGFloat = 400, condensed: Bool = false) -> Font {
        #if canImport(UIKit)
        // wght and wdth axes of the bundled Roboto.
        let axes: [NSNumber: NSNumber] = [2003265652: NSNumber(value: Double(weight)), 2003072104: NSNumber(value: condensed ? 75.0 : 100.0)]
        let d = UIFontDescriptor(fontAttributes: [.name: "Roboto-Regular", UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes])
        return Font(UIFont(descriptor: d, size: size))
        #else
        return .system(size: size)
        #endif
    }
    static func rowTitle() -> Font { font(18, condensed: true) }
}
extension Color { init(hex: UInt32) { self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) } }

// The launcher's flat glyph key: nothing at rest, a soft circle when pressed.
struct MintKeyStyle: ButtonStyle {
    var diameter: CGFloat = 56
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Mint.press).opacity(configuration.isPressed ? 1 : 0))
            .foregroundStyle(Mint.text)
            .contentShape(Circle())
            .animation(Mint.focus, value: configuration.isPressed)
    }
}

// The soft wall behind the rows: art shrunk to almost nothing, then stretched. Cheap, with no live blur.
struct Wall: View {
    let art: String?
    var body: some View {
        ZStack {
            Color.black
            if let art, let u = URL(string: art) {
                AsyncImage(url: u) { i in
                    i.resizable().frame(width: 6, height: 6).scaleEffect(90).opacity(0.42).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                } placeholder: { Color.clear }
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
