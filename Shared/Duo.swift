import SwiftUI

// Two panes, in Apple's container for this: side by side in landscape, stacked in portrait, and clear of the fold when
// partly closed. Bars are the system's own; they sit on the side or the bottom by themselves.
struct FoldSplit<L: View, R: View>: View {
    let left: L, right: R
    init(@ViewBuilder _ left: () -> L, @ViewBuilder right: () -> R) { self.left = left(); self.right = right() }
    var body: some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            ArrangementView { left } secondary: { right }.arrangementViewStyle(.split)
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
