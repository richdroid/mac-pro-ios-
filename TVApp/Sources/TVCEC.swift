import SwiftUI

// The television behind the box, as the box hears it over HDMI-CEC (the Mac reads the box's own record of the HDMI line
// and sends what's known with each status; see TVStatus.CEC). With CEC off on the box none of this shows. With it on:
// - the television off reads as the box asleep does ("Asleep", "Wake the TV", which turns it on);
// - the television on something else reads "On PlayStation 5" on the Remote, the picture dark, with one key over the
//   pad, where "Wake the TV" sits: "Switch to Google TV";
// - the power key, play, a flick, an app opened, a link sent and AirPlay beginning all bring the television to the box
//   (the Mac does that, so the widget's and Control Center's keys are as smart);
// - what's playing is paused where it is when the television goes off or to another input (the Mac again).

// The one key over the pad while the television is on another input. It says what it's doing from the press on, until
// the television's own word changes the page under it (twelve seconds at most, then it offers itself again). Its glass
// keeps the width of its longer words, so nothing but the words changes.
struct TelevisionKey: View {
    @Environment(TVModel.self) var model
    let away: TVStatus.Away
    @State private var asked = false
    private func words(_ t: String) -> some View {
        Label(t, systemImage: "rectangle.2.swap").font(.title3.weight(.semibold)).lineLimit(1)
    }
    var body: some View {
        Button {
            model.tick(); asked = true
            model.post("tv-on")
        } label: {
            ZStack {
                words("Switch to Google TV").hidden()
                words(asked ? "Switching…" : "Switch to Google TV").contentTransition(.opacity)
            }
            .padding(.horizontal, 20).frame(height: 60)
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
        .disabled(asked)
        .animation(.easeOut(duration: 0.2), value: asked)
        .task(id: asked) {
            guard asked else { return }
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if !Task.isCancelled { asked = false }
        }
        .onChange(of: away) { _, _ in asked = false }
    }
}

// Status: one row for the television, only while something is known of it: no row with HDMI-CEC off (a switch he set
// himself, and nothing to do about it from here), and none before the television has been heard from.
struct TelevisionRow: View {
    let status: TVStatus?
    static func value(_ c: TVStatus.CEC?) -> String? {
        guard let c, c.enabled else { return nil }
        let tv = c.tv ?? "", input = c.input ?? ""
        if tv == "off" || tv == "sleeping" { return "Off" }
        if tv == "waking" { return "Coming on" }
        if input == "other" { return c.source?.isEmpty == false ? "On \(c.source!)" : "On another input" }
        if input == "tv" { return "On another input" }
        return tv == "on" || input == "box" ? "On" : nil
    }
    var body: some View {
        let value = Self.value(status?.cec)
        // The row fades in when the television's word comes after the box's numbers (the card around it eases with it).
        Group {
            if let value {
                HStack {
                    Text(status?.cec?.brand.map { "\($0) TV" } ?? "Television")
                    Spacer()
                    Text(value).foregroundStyle(.secondary).contentTransition(.opacity)
                }
                .padding(14)
                .transition(.opacity)
                Divider().transition(.opacity)
            }
        }
    }
}
