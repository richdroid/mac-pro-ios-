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
    // Seeded from the last launch, so the section is there when the tab opens, not a moment later.
    @Published private(set) var available = UserDefaults.standard.bool(forKey: "macMusic.available")
    @Published private(set) var busy: String?
    @Published private(set) var say: String?
    @Published private(set) var answered = 0
    @Published private(set) var refused = 0
    // A switch shows what was asked for until the Mac answers.
    @Published var asked: [String: Bool] = [:]
    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "macMusic.speakerID"), let name = d.string(forKey: "macMusic.speakerName") { speaker = .init(id: id, name: name, connected: nil) }
    }

    func read(_ model: AppModel) async {
        async let n: MacMusicNow? = try? model.api.macFeed("/api/mac/music/now", timeout: 15)
        async let a: MacAudioList? = try? model.api.macFeed("/api/mac/audio", timeout: 25)
        let (gotNow, gotAudio) = await (n, a)
        guard busy == nil, let gotNow else { return }   // a press began meanwhile: its own read follows
        // A bridge without the music session answers without one: nothing to drive.
        available = gotNow.session != nil
        UserDefaults.standard.set(available, forKey: "macMusic.available")
        if gotNow != now { now = gotNow }
        if let gotAudio {
            let s = gotAudio.outputs.first { $0.id == gotAudio.preferred }
            if s != speaker { speaker = s }
            UserDefaults.standard.set(s?.id, forKey: "macMusic.speakerID"); UserDefaults.standard.set(s?.name, forKey: "macMusic.speakerName")
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
        busy = nil
        await read(model)
        asked = [:]
        // The Mac's answer stays a few seconds, as the card's does, then goes.
        let said = say
        Task { try? await Task.sleep(for: .seconds(5)); if busy == nil, say == said { say = nil } }
    }
    func lyrics(_ model: AppModel, _ on: Bool) async { await act(model, "lyrics", on, "/api/mac/music/session", ["on": on]) }
    func speaker(_ model: AppModel, _ on: Bool) async {
        guard let s = speaker else { return }
        // The speaker off while Lyrics is on ends the music (which lets the speaker go), not Music playing to nothing.
        if !on, now?.session?.on == true { await act(model, "speaker", false, "/api/mac/music/session", ["on": false]); return }
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
        guard lyricsOn else { return "Full screen on the Mac, through the speaker" }
        if store.now?.session?.speakerConnected == false { return store.now?.session?.speakerSay ?? "The speaker didn’t connect" }
        if let t = store.now?.title, store.now?.state == "playing" { return [t, store.now?.artist].compactMap { $0 }.joined(separator: " · ") }
        return "AirPlay a song to Mac Pro · turns off after 2 minutes"
    }
    private var speakerNote: String {
        if store.busy == "speaker" { return "Asking the Mac…" }
        if store.speaker?.connected == true { return "Connected to the Mac" }
        return lyricsOn ? "Not connected" : "Free for your other devices"
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
                        row(speakerName, speakerNote, "hifispeaker")
                    }
                    .accessibilityIdentifier("switch.speaker")
                }
            } header: { Text("Music") } footer: { if let s = store.say { Text(s) } }
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
