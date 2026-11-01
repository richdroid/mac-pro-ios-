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
            .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { landscape = $0 }
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
private func evenIcon(_ source: UIImage?, fit: CGFloat = 26) -> UIImage {
    let canvas = fit + 4
    guard let source, source.size.width > 0, source.size.height > 0 else { return UIImage() }
    let k = fit / max(source.size.width, source.size.height)
    let w = source.size.width * k, h = source.size.height * k
    let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
    return UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas), format: format).image { _ in
        source.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h))
    }.withRenderingMode(.alwaysTemplate)
}
#endif
func tabLabel(_ title: String, _ symbol: String) -> some View {
    Label {
        Text(title)
    } icon: {
        #if canImport(UIKit)
        Image(uiImage: evenIcon(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 60, weight: .regular))))
        #else
        Image(systemName: symbol)
        #endif
    }
}
func tabLabel(_ title: String, asset: String, fit: CGFloat = 26) -> some View {
    Label {
        Text(title)
    } icon: {
        #if canImport(UIKit)
        Image(uiImage: evenIcon(UIImage(named: asset), fit: fit))
        #else
        Image(asset)
        #endif
    }
}
