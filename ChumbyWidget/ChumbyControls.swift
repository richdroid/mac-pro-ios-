import AppIntents
import SwiftUI
import WidgetKit

struct ChumbyNextControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyNextControl") {
            ControlWidgetButton(action: ChumbyNextIntent()) { Label("Next Widget", systemImage: "forward.fill") }
        }.displayName("Chumby Next Widget").description("Skips to the next widget.")
    }
}
struct ChumbyNightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyNightControl") {
            ControlWidgetButton(action: ChumbyGoodnightIntent()) { Label("Goodnight", systemImage: "moon.fill") }
        }.displayName("Chumby Goodnight").description("Puts the Chumby in night mode.")
    }
}
struct ChumbyMorningControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyMorningControl") {
            ControlWidgetButton(action: ChumbyMorningIntent()) { Label("Good Morning", systemImage: "sun.max.fill") }
        }.displayName("Chumby Good Morning").description("Ends night mode and brightens the screen.")
    }
}
struct ChumbyStopControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyStopControl") {
            ControlWidgetButton(action: ChumbyStopMusicIntent()) { Label("Stop Music", systemImage: "stop.fill") }
        }.displayName("Chumby Stop Music").description("Stops whatever it’s playing.")
    }
}
struct ChumbyNapControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyNapControl") {
            ControlWidgetButton(action: ChumbyNapIntent(minutes: 20)) { Label("20-Minute Nap", systemImage: "zzz") }
        }.displayName("Chumby 20-Minute Nap").description("Sets a one-off alarm in 20 minutes.")
    }
}
struct ChumbyOpenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ChumbyOpenControl") {
            ControlWidgetButton(action: ChumbyOpenIntent()) { Label("Chumby", systemImage: "hand.tap.fill") }
        }.displayName("Open Chumby")
    }
}
