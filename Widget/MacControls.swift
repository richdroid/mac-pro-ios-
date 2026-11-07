import AppIntents
import SwiftUI
import WidgetKit

struct MacScreenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "MacScreenControl") {
            ControlWidgetButton(action: MacOpenScreenIntent()) { Label("Mac Screen", systemImage: "macwindow") }
        }.displayName("Mac Pro Screen").description("Opens straight into the Mac’s screen.")
    }
}
struct MacDisplayOffControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "MacDisplayOffControl") {
            ControlWidgetButton(action: MacDisplayOffIntent()) { Label("Mac Display Off", systemImage: "moon.fill") }
        }.displayName("Mac Pro Display Off").description("Darkens the display. The Mac keeps running.")
    }
}
struct MacRenewControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "MacRenewControl") {
            ControlWidgetButton(action: MacRenewAppsIntent()) { Label("Renew Apps", systemImage: "arrow.clockwise") }
        }.displayName("Renew iPhone Apps").description("Signs and reinstalls your apps. Same Wi-Fi as the Mac.")
    }
}
