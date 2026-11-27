import AppIntents
import SwiftUI
import WidgetKit

struct MacScreenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "MacScreenControl") {
            ControlWidgetButton(action: MacOpenScreenIntent()) { Label("Mac Screen", systemImage: "desktopcomputer") }
        }.displayName("Mac Pro Screen").description("Opens straight into the Mac’s screen.")
    }
}
struct MacDisplayOffControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "MacDisplayOffControl") {
            ControlWidgetButton(action: MacDisplayOffIntent()) { Label("Mac Display Off", systemImage: "display") }
        }.displayName("Mac Pro Display Off").description("Darkens the display. The Mac keeps running.")
    }
}
