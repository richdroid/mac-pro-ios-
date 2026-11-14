import AppIntents
import Foundation

enum TVMusicKind: String, AppEnum {
    case song, album, playlist, artist, station
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Kind of music"
    static var caseDisplayRepresentations: [TVMusicKind: DisplayRepresentation] = [.song: "Song", .album: "Album", .playlist: "Playlist", .artist: "Artist", .station: "Station"]
}

struct PlayOnTV: AppIntent {
    static var title: LocalizedStringResource = "Play on the TV"
    static var description = IntentDescription("Finds music in Mint Music and plays it on the TV.")
    @Parameter(title: "What to play", requestValueDialog: "What should play?") var query: String
    @Parameter(title: "Kind", default: .song) var kind: TVMusicKind
    @Parameter(title: "Shuffle", default: false) var shuffle: Bool
    func perform() async throws -> some IntentResult { try await TVBridge.post("music", ["query": query, "kind": kind.rawValue, "shuffle": shuffle]); return .result() }
}
struct SendToTV: AppIntent {
    static var title: LocalizedStringResource = "Send to the TV"
    static var description = IntentDescription("Opens a link on the TV, or searches for words.")
    @Parameter(title: "Link or words") var text: String
    func perform() async throws -> some IntentResult {
        let d = try await TVBridge.post("send", ["text": text])
        guard (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["ok"] as? Bool == true else { throw TVIntentError.cantOpen }
        return .result()
    }
}
struct TVKeyIntent: AppIntent {
    static var title: LocalizedStringResource = "Press a TV Remote Button"
    static var description = IntentDescription("Any button on the TV’s remote.")
    @Parameter(title: "Button") var button: TVKey
    func perform() async throws -> some IntentResult { try await TVBridge.post("key", ["key": button.rawValue]); return .result() }
}
enum TVKey: String, AppEnum {
    case up, down, left, right, ok, back, home, menu, play, next, previous, rewind, forward, volup, voldown, mute, sleep, wake
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Remote button"
    static var caseDisplayRepresentations: [TVKey: DisplayRepresentation] = [.up: "Up", .down: "Down", .left: "Left", .right: "Right", .ok: "Select", .back: "Back", .home: "Home", .menu: "Menu", .play: "Play or Pause", .next: "Next", .previous: "Previous", .rewind: "Rewind", .forward: "Fast Forward", .volup: "Volume Up", .voldown: "Volume Down", .mute: "Mute", .sleep: "Sleep", .wake: "Wake"]
}
struct TVWhatsOnIntent: AppIntent {
    static var title: LocalizedStringResource = "What’s on the TV"
    static var description = IntentDescription("What the TV is showing or playing.")
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let s = await TVBridge.status(), s.online else { throw TVIntentError.noAnswer }
        var text = "The TV is asleep."
        if s.screen != "asleep" {
            let app = s.apps?.first { $0.pkg == s.app }?.name ?? "the home screen"
            if let n = s.session, n.playing, n.pkg != "com.codex.musicwebtv", let what = n.description.first { text = "\(what), on \(s.apps?.first { $0.pkg == n.pkg }?.name ?? app)." }
            else if let m = s.music, m.playing { text = "\(m.title) by \(m.artist), in Mint Music." }
            else { text = "The TV is on \(app)." }
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
struct TVShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FlickToTV(), phrases: ["Flick to the \(.applicationName)", "Send this to the \(.applicationName)"], shortTitle: "Flick to TV", systemImageName: "airplayaudio")
        AppShortcut(intent: TVWhatsOnIntent(), phrases: ["What’s on the \(.applicationName)"], shortTitle: "What’s On", systemImageName: "tv")
        AppShortcut(intent: PlayOnTV(), phrases: ["Play something on the \(.applicationName)"], shortTitle: "Play on TV", systemImageName: "play.circle")
        AppShortcut(intent: TVOpenOnTV(), phrases: ["Open \(\.$app) on the \(.applicationName)"], shortTitle: "Open App", systemImageName: "square.grid.2x2")
        AppShortcut(intent: TVPower(), phrases: ["Turn the \(.applicationName) on or off", "Toggle the \(.applicationName)"], shortTitle: "On or Off", systemImageName: "power")
        AppShortcut(intent: TVKeyIntent(), phrases: ["Press a button on the \(.applicationName)"], shortTitle: "Remote Button", systemImageName: "av.remote")
        AppShortcut(intent: ResumeOnIPhone(), phrases: ["Resume on this phone in \(.applicationName)", "Carry on watching in \(.applicationName)"], shortTitle: "Resume on This Phone", systemImageName: "iphone")
        AppShortcut(intent: PlayOnIPhone(), phrases: ["Play something on this phone with \(.applicationName)"], shortTitle: "Play on This Phone", systemImageName: "play.rectangle")
        AppShortcut(intent: SendToTV(), phrases: ["Send a link to the \(.applicationName)"], shortTitle: "Send Link", systemImageName: "link")
    }
}
