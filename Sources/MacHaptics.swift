import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The haptic vocabulary shared by every iPhone app (design manifesto, "Haptic vocabulary", 2026-11-14), word for word as the
// TV and Chumby apps have it (TVHaptics.swift, ChumbyHaptics.swift), behind this app's own Haptics switch in Settings. A
// haptic always answers his own finger: never on scroll, a refresh, a push, a timer or an appear; one per gesture.
enum Haptic {
    case tick   // a picker, segment, tab switch
    case snap   // a shelf landing, a sheet settling
    case tap    // a key on the session's keyboard, a button
    case thunk  // a hold completes
    case done   // the confirmed answer: the Mac did it, a send completed
    case warn   // can't reach the Mac, the Mac said no
    case fail   // an action failed for good (warn's hard form)

    var feedback: SensoryFeedback {
        switch self {
        case .tick: .selection
        case .snap: .impact(flexibility: .soft, intensity: 0.5)
        case .tap: .impact(weight: .light)
        case .thunk: .impact(weight: .medium)
        case .done: .success
        case .warn: .warning
        case .fail: .error
        }
    }

    // For code with no view to hang `.haptic` on.
    @MainActor static func fire(_ h: Haptic) {
        #if canImport(UIKit)
        guard MacPrefs.haptics else { return }
        switch h {
        case .tick: UISelectionFeedbackGenerator().selectionChanged()
        case .snap: UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
        case .tap: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .thunk: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .done: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warn: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .fail: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #endif
    }
}

extension View {
    // `trigger` must change only because of a touch (or the answer to one).
    func haptic<T: Equatable>(_ h: Haptic, trigger: T) -> some View {
        sensoryFeedback(trigger: trigger) { _, _ in MacPrefs.haptics ? h.feedback : nil }
    }
    func haptic<T: Equatable>(_ h: Haptic, trigger: T, when: @escaping (T, T) -> Bool) -> some View {
        sensoryFeedback(trigger: trigger) { old, new in MacPrefs.haptics && when(old, new) ? h.feedback : nil }
    }
}
