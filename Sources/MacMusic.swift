import SwiftUI

// Music on the Mac (Richard, 2026-11-25: "with the airplay thing i want it to make the bluetooth connection open apple
// music lyrics on its own … and disconnect when music is done so i can use the speaker with other devices", "controlled
// by phone"). AirPlaying to "Mac Pro" does all of it by itself; these two switches on the Dashboard tab are for doing it
// by hand: Lyrics (the speaker, the display and Apple Music's full-screen lyrics for what plays, or off: Music stops, the
// speaker is let go, the display goes back as it was) and the speaker itself. The display is the Switches' own.
// Bridge: GET /api/mac/music/now (its session), GET /api/mac/audio (preferred), POST /api/mac/music/session { on },
// POST /api/mac/audio/select { id }, POST /api/mac/audio/disconnect { id }. Hidden on a bridge without them (404).

struct MacMusicNow: Decodable, Equatable {
    struct Session: Decodable, Equatable { var on: Bool; var speaker: String?; var speakerConnected: Bool?; var speakerSay: String? }
    var state: String?; var title: String?; var artist: String?; var session: Session?
}
struct MacAudioList: Decodable, Equatable {
    struct Output: Decodable, Equatable { let id: String; let name: String; var connected: Bool? }
    var outputs: [Output]; var preferred: String?
}

@MainActor
final class MacMusicStore: ObservableObject {
    static let shared = MacMusicStore()
    @Published private(set) var now: MacMusicNow?
    @Published private(set) var speaker: MacAudioList.Output?
    @Published private(set) var available = false
    @Published private(set) var busy: String?
    @Published private(set) var say: String?
    @Published private(set) var answered = 0
    @Published private(set) var refused = 0
    // A switch shows what was asked for until the Mac answers.
    @Published var asked: [String: Bool] = [:]

    func read(_ model: AppModel) async {
        guard let n: MacMusicNow = try? await model.api.macFeed("/api/mac/music/now", timeout: 15) else { return }
        // A bridge without the music session answers without one: nothing to drive.
        available = n.session != nil
        if n != now { now = n }
        if let a: MacAudioList = try? await model.api.macFeed("/api/mac/audio", timeout: 25) {
            let s = a.outputs.first { $0.id == a.preferred }
            if s != speaker { speaker = s }
        }
    }
    func loop(_ model: AppModel) async {
        while !Task.isCancelled {
            if busy == nil { await read(model) }
            try? await Task.sleep(for: .seconds(10))
        }
    }
    private func act(_ model: AppModel, _ key: String, _ want: Bool, _ path: String, _ body: [String: Any]) async {
        guard busy == nil else { return }
        busy = key; asked[key] = want; say = nil
        let a = try? await model.api.macDo(path, body, timeout: 45)
        say = a?.say ?? a?.error ?? "Couldn’t reach the Mac."
        if a?.done == true { answered += 1 } else { refused += 1 }
        await read(model)
        busy = nil; asked = [:]
    }
    func lyrics(_ model: AppModel, _ on: Bool) async { await act(model, "lyrics", on, "/api/mac/music/session", ["on": on]) }
    func speaker(_ model: AppModel, _ on: Bool) async {
        guard let s = speaker else { return }
        await act(model, "speaker", on, on ? "/api/mac/audio/select" : "/api/mac/audio/disconnect", ["id": s.id])
    }
}

struct MacMusicSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = MacMusicStore.shared

    private func row(_ title: String, _ note: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(macBlue) }
    }
    private var lyricsOn: Bool { store.now?.session?.on == true }
    private var lyricsNote: String {
        if store.busy == "lyrics" { return "Asking the Mac…" }
        if lyricsOn, let t = store.now?.title, store.now?.state == "playing" { return "\(t) · Apple Music’s lyrics, full screen" }
        return lyricsOn ? "On, waiting for a song" : "Speaker, display and Apple Music’s lyrics, full screen"
    }
    // "HK Invoke_C20142" → "HK Invoke": the name without the serial macOS adds.
    private var speakerName: String {
        let n = store.speaker?.name ?? "Speaker"
        if let r = n.range(of: #"_[0-9A-F]{4,}$"#, options: .regularExpression) { return String(n[..<r.lowerBound]) }
        return n
    }

    var body: some View {
        if store.available {
            Section {
                Toggle(isOn: Binding(get: { store.asked["lyrics"] ?? lyricsOn }, set: { w in Task { await store.lyrics(model, w) } })) {
                    row("Lyrics", lyricsNote, "quote.bubble")
                }
                .accessibilityIdentifier("switch.lyrics")
                if store.speaker != nil {
                    Toggle(isOn: Binding(get: { store.asked["speaker"] ?? (store.speaker?.connected == true) }, set: { w in Task { await store.speaker(model, w) } })) {
                        row(speakerName, store.busy == "speaker" ? "Asking the Mac…" : store.speaker?.connected == true ? "Connected to the Mac" : "Free for your other devices", "hifispeaker")
                    }
                    .accessibilityIdentifier("switch.speaker")
                }
            } header: { Text("Music") } footer: {
                if let s = store.say { Text(s) } else { Text("AirPlay to Mac Pro does this by itself, and lets the speaker go when the music is done.") }
            }
            .disabled(store.busy != nil || model.stale)
            .haptic(.done, trigger: store.answered)
            .haptic(.warn, trigger: store.refused)
        }
    }
}

// The section's reads run while the Dashboard is up (its own task, apart from the Console remote's).
struct MacMusicLoop: ViewModifier {
    var on = true
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View { content.task(id: on) { if on { await MacMusicStore.shared.loop(model) } } }
}
