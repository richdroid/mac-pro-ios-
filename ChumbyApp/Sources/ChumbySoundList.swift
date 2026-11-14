import SwiftUI

// A sound's value opens a page of its own on a tap, never a system Menu (Richard, 2026-11-13/14, Sounds): a Menu opened
// on a slow press-and-drag over a value and picked on release, and hopped when its anchor resized. The page is a native
// push (system Back); open flat it is the right pane, with Close. A pick writes the value and goes back.
struct PickOption: Identifiable {
    let tag: String
    let label: String
    var tone: String?          // a tone: it has a try
    var id: String { tag }
}
struct PickSection: Identifiable {
    let title: String?
    let options: [PickOption]
    var id: String { title ?? "-" }
}
// What a page opened for: one alarm's sound (its key), the calendar alarms', or the fade.
struct SoundChooser: Identifiable, Hashable {
    let id: String
    let title: String
    var calendar = false
}
struct SoundListPage: View {
    @EnvironmentObject var model: ChumbyModel
    let name: String
    let sections: [PickSection]
    let current: String
    var pane = false
    // Writes the value (the tab shows it at once); then the page goes back.
    let pick: (String) -> Void
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let close = AnyView(Button("Close") { done() }.foregroundStyle(.tint))
        Group {
            if pane {
                List { content(close: close) }
                    .pinsTitle { PageTitle(name) { close } }
            } else {
                List { content(close: nil) }.pushedPage("soundlist")
            }
        }
    }
    @ViewBuilder private func content(close: AnyView?) -> some View {
        if let close { PageTitle(name, pins: true) { close } } else { PageTitle(name) }
        if let f = model.failed("test") {
            FailNote(text: f).listRowBackground(Color.clear)
        }
        ForEach(sections) { s in
            Section {
                ForEach(s.options) { o in row(o) }
            } header: {
                if let t = s.title { Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(nil) }
            }
            .listRowBackground(GlassRow())
        }
    }
    private func row(_ o: PickOption) -> some View {
        HStack(spacing: 0) {
            Button { pick(o.tag); done() } label: {
                HStack(spacing: 12) {
                    Text(o.label).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                        .opacity(o.tag == current ? 1 : 0).frame(width: 22)
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(.primary)
            if let tone = o.tone {
                // The try answers on the Chumby and leaves the page where it is.
                Button {
                    Task { do { try await model.api?.post("test", extra: "&tone=" + ChumbyAPI.enc(tone)) } catch { model.fail("test", "Couldn’t play it. \(AlarmWriter.explain(error))") } }
                } label: {
                    Image(systemName: "play.fill").font(.body).foregroundStyle(.tint).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).disabled(model.unreachable)
                .accessibilityLabel("Try \(o.label) on the Chumby")
                .padding(.vertical, -5)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
