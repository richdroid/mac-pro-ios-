import SwiftUI

// The iPhone Duo open has a fold at its physical centre. System bars move by themselves, so the
// content region is lopsided: measure from the real centre and leave the crease empty.
enum Duo { static let foldGap: CGFloat = 48 }
private struct ScreenWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues { var screenWidth: CGFloat { get { self[ScreenWidthKey.self] } set { self[ScreenWidthKey.self] = newValue } } }

struct FoldSplit<L: View, R: View>: View {
    @Environment(\.screenWidth) private var screen
    let left: L, right: R
    init(@ViewBuilder _ left: () -> L, @ViewBuilder right: () -> R) { self.left = left(); self.right = right() }
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            let centre = (screen > 0 ? screen : f.maxX + f.minX) / 2
            let l = max(0, centre - Duo.foldGap / 2 - f.minX), r = max(0, f.maxX - centre - Duo.foldGap / 2)
            HStack(spacing: Duo.foldGap) {
                left.frame(width: l)
                right.frame(width: r)
            }
            .frame(width: f.width, height: f.height, alignment: .leading)
        }
    }
}

struct ScreenMeasure<C: View>: View {
    let content: C
    init(@ViewBuilder _ content: () -> C) { self.content = content() }
    var body: some View {
        GeometryReader { g in
            content.environment(\.screenWidth, g.size.width + g.safeAreaInsets.leading + g.safeAreaInsets.trailing)
        }
    }
}
