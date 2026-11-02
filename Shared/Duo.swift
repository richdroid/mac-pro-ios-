import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Two panes only when there's room side by side. Open in portrait the bars go horizontal and the fold runs across,
// so lists read better as one column, the same as on the outer display.
private struct PaneLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var paneLayout: Bool { get { self[PaneLayoutKey.self] } set { self[PaneLayoutKey.self] = newValue } } }
struct PaneReader<C: View>: View {
    @Environment(\.horizontalSizeClass) private var size
    @State private var landscape = true
    @ViewBuilder let content: () -> C
    var body: some View {
        content()
            .environment(\.paneLayout, size == .regular && landscape)
            // Measured behind the keyboard's reach, or typing in portrait would look like turning sideways.
            .background { Color.clear.ignoresSafeArea().onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { landscape = $0 } }
    }
}

// Two panes, in Apple's container: side by side when wide, stacked when tall, and clear of the fold when partly closed.
// Lying flat it would split the area left of the side bars, putting the seam off the crease, so it's told where the hinge is.
struct FoldSplit<L: View, R: View>: View {
    let left: L, right: R
    init(@ViewBuilder _ left: () -> L, @ViewBuilder right: () -> R) { self.left = left(); self.right = right() }
    var body: some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            GeometryReader { g in
                let wide = g.size.width > g.size.height
                let folded = !g.reservedRegions(kind: .division).isEmpty
                let hinge = g.reservedRegions(kind: .division, options: .includeInactive).first?.frame.midX
                let ratio: CGFloat? = wide && !folded ? hinge.map { min(max($0 / g.size.width, 0.3), 0.7) } : nil
                let gutter: CGFloat = wide && !folded ? 14 : 0
                ArrangementView {
                    left.padding(.trailing, gutter).splitArrangementLayoutRatio(ratio)
                } secondary: {
                    right.padding(.leading, gutter)
                }
                .arrangementViewStyle(.split)
            }
        } else { sideBySide }
        #else
        sideBySide
        #endif
    }
    private var sideBySide: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity)
            right.frame(maxWidth: .infinity)
        }
    }
}

// Side bar icons, every one fitted to the same box. Symbols and logos have their own natural proportions, which is
// what makes a wide display look bigger than a narrow remote.
#if canImport(UIKit)
// Sized by the shape actually drawn, not its canvas, since artwork like the Claude star has empty space around it.
private func inkBounds(_ image: UIImage) -> (CGImage, CGRect)? {
    let side = 192
    let k = CGFloat(side) / max(image.size.width, image.size.height)
    let w = max(Int(image.size.width * k), 1), h = max(Int(image.size.height * k), 1)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let made: CGImage? = px.withUnsafeMutableBytes { raw in
        guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        UIGraphicsPushContext(c)
        c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
        image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        UIGraphicsPopContext()
        return c.makeImage()
    }
    guard let made else { return nil }
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 24 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= minX else { return nil }
    return (made, CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
}
// The app redraws its root often and these only need working out once.
private let iconCache = NSCache<NSString, UIImage>()
private func cachedIcon(_ key: String, fit: CGFloat, _ make: () -> UIImage?) -> UIImage {
    let id = "\(key)-\(fit)" as NSString
    if let hit = iconCache.object(forKey: id) { return hit }
    let icon = evenIcon(make(), fit: fit)
    iconCache.setObject(icon, forKey: id)
    return icon
}
private func evenIcon(_ source: UIImage?, fit: CGFloat = 25) -> UIImage {
    let canvas = fit + 2
    guard let source, let (full, ink) = inkBounds(source), let cut = full.cropping(to: ink) else { return UIImage() }
    let k = fit / max(ink.width, ink.height)
    let w = ink.width * k, h = ink.height * k
    let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
    return UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas), format: format).image { _ in
        UIImage(cgImage: cut).draw(in: CGRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h))
    }.withRenderingMode(.alwaysTemplate)
}
#endif
func tabLabel(_ title: String, _ symbol: String) -> some View {
    Label {
        Text(title)
    } icon: {
        #if canImport(UIKit)
        Image(uiImage: cachedIcon(symbol, fit: 25) { UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 60, weight: .regular)) })
        #else
        Image(systemName: symbol)
        #endif
    }
}
func tabLabel(_ title: String, asset: String, fit: CGFloat = 25) -> some View {
    Label {
        Text(title)
    } icon: {
        #if canImport(UIKit)
        Image(uiImage: cachedIcon(asset, fit: fit) { UIImage(named: asset) })
        #else
        Image(asset)
        #endif
    }
}

// Reading a value off a chart that sits in a scrolling page: rest a finger on it for a moment, then slide. A touch on its
// way somewhere else, like a scroll, moves off too soon to count, so it scrolls as normal.
struct HoldToScrub: ViewModifier {
    var onChange: (CGPoint?) -> Void
    @GestureState private var holding = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(LongPressGesture(minimumDuration: 0.28, maximumDistance: 8)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($holding) { v, state, _ in if case .second = v { state = true } }
                .onChanged { v in if case .second(true, let drag?) = v { onChange(drag.location) } })
            // Clears by itself if the touch ends or the system takes it away.
            .onChange(of: holding) { _, now in
                #if canImport(UIKit)
                if now { UISelectionFeedbackGenerator().selectionChanged() }
                #endif
                if !now { onChange(nil) }
            }
    }
}
extension View { func holdToScrub(_ onChange: @escaping (CGPoint?) -> Void) -> some View { modifier(HoldToScrub(onChange: onChange)) } }
