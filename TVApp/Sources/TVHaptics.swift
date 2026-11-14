import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The haptic vocabulary shared by every iPhone app (design manifesto, "Haptic vocabulary", 2026-11-14): six words, and a
// haptic always answers his own finger. Never on scroll, a refresh, a push, a timer or an appear; one per gesture, except the
// flick (thunk on the throw, done on the landing) and a hold (tap on touch, thunk at completion).
enum Haptic {
    case tick   // a picker, segment, tab switch, scrub step
    case snap   // a shelf landing, a sheet settling
    case tap    // a Remote key, a D-pad press, a button
    case thunk  // a hold completes, the flick's throw
    case done   // the confirmed answer: the flick landed, a send completed
    case warn   // can't reach a device
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

    // For code that has no view to hang `.haptic` on (the model, the flick's own hand). The same six feels, from generators
    // kept warm so it lands on the frame it belongs to. The system's haptics switch governs these as well.
    @MainActor static func fire(_ h: Haptic) {
        #if canImport(UIKit)
        switch h {
        case .tick: Gen.select.selectionChanged(); Gen.select.prepare()
        case .snap: Gen.soft.impactOccurred(intensity: 0.5); Gen.soft.prepare()
        case .tap: Gen.light.impactOccurred(); Gen.light.prepare()
        case .thunk: Gen.medium.impactOccurred(); Gen.medium.prepare()
        case .done: Gen.note.notificationOccurred(.success); Gen.note.prepare()
        case .warn: Gen.note.notificationOccurred(.warning); Gen.note.prepare()
        case .fail: Gen.note.notificationOccurred(.error); Gen.note.prepare()
        }
        #endif
    }
    @MainActor static func warm() {
        #if canImport(UIKit)
        Gen.light.prepare(); Gen.select.prepare(); Gen.medium.prepare(); Gen.note.prepare(); Gen.soft.prepare()
        #endif
    }

    #if canImport(UIKit)
    @MainActor private enum Gen {
        static let select = UISelectionFeedbackGenerator()
        static let soft = UIImpactFeedbackGenerator(style: .soft)
        static let light = UIImpactFeedbackGenerator(style: .light)
        static let medium = UIImpactFeedbackGenerator(style: .medium)
        static let note = UINotificationFeedbackGenerator()
    }
    #endif
}

extension View {
    // `trigger` must change only because of a touch.
    func haptic<T: Equatable>(_ h: Haptic, trigger: T) -> some View { sensoryFeedback(h.feedback, trigger: trigger) }
    // As above, with a say in which changes count (old, new).
    func haptic<T: Equatable>(_ h: Haptic, trigger: T, when: @escaping (T, T) -> Bool) -> some View {
        sensoryFeedback(trigger: trigger) { old, new in when(old, new) ? h.feedback : nil }
    }
}
