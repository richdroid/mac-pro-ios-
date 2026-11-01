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

// Pictures stay in memory, so scrolling back never flashes a placeholder.
@MainActor
final class ImageStore {
    static let shared = ImageStore()
    private let cache = NSCache<NSURL, TVImage>()
    func cached(_ url: URL?) -> TVImage? { url.flatMap { cache.object(forKey: $0 as NSURL) } }
    func load(_ url: URL) async -> TVImage? {
        if let i = cached(url) { return i }
        guard let (d, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200, let i = TVImage(data: d) else { return nil }
        cache.setObject(i, forKey: url as NSURL)
        return i
    }
}
struct Art<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: TVImage?
    var body: some View {
        Group {
            if let i = ImageStore.shared.cached(url) ?? loaded { content(Image(tv: i)) } else { placeholder() }
        }
        .task(id: url) { if let url { loaded = await ImageStore.shared.load(url) } }
    }
}

// The colour Mint's now-playing band takes from the cover: its most vivid pixel, held to a dark enough level for text.
enum CoverTint {
    static func of(_ image: TVImage) -> Color {
        #if canImport(UIKit)
        guard let cg = image.cgImage else { return Mint.band }
        var px = [UInt8](repeating: 0, count: 16 * 16 * 4)
        guard let c = CGContext(data: &px, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Mint.band }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        var best = (0.0, 0.0, 0.0), score = -1.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let top = max(r, g, b), low = min(r, g, b)
            let v = (top - low) * top
            if v > score { score = v; best = (r, g, b) }
        }
        let top = max(best.0, best.1, best.2)
        // A grey cover has no colour to lend.
        if score < 0.12 || top == 0 { return Mint.band }
        let k = 0.62 / top
        return Color(red: best.0 * k, green: best.1 * k, blue: best.2 * k)
        #else
        return Mint.band
        #endif
    }
}

// The soft wall behind the rows: art really shrunk to a few pixels, then stretched. Cheap, with no live blur.
struct Wall: View {
    let art: String?
    @State private var small: TVImage?
    var body: some View {
        ZStack {
            Color.black
            if let small {
                Color.clear
                    .overlay { Image(tv: small).resizable().interpolation(.high).scaledToFill().opacity(0.42) }
                    .clipped().transition(.opacity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.26), value: small)
        .task(id: art) {
            guard let art, let u = URL(string: art), let i = await ImageStore.shared.load(u) else { small = nil; return }
            #if canImport(UIKit)
            small = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in i.draw(in: CGRect(x: 0, y: 0, width: 16, height: 16)) }
            #else
            small = i
            #endif
        }
    }
}
