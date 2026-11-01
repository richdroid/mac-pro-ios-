import AppIntents
import Foundation
#if os(iOS)
import MediaPlayer
#endif

enum FlickRequest {
    static let airPlay = Notification.Name("tvFlickAirPlay")
    @MainActor static var wantsAirPlay = false
}

enum TVMusicKind: String, AppEnum {
    case song, album, playlist, artist, station
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Kind of music"
    static var caseDisplayRepresentations: [TVMusicKind: DisplayRepresentation] = [.song: "Song", .album: "Album", .playlist: "Playlist", .artist: "Artist", .station: "Station"]
}

// A flick without looking: assign it to the Action Button. Apple Music goes straight across; anything else opens AirPlay.
struct FlickToTV: AppIntent {
    static var title: LocalizedStringResource = "Flick to the TV"
    static var description = IntentDescription("Sends what’s playing on this iPhone to the TV.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        #if os(iOS)
        let player = MPMusicPlayerController.systemMusicPlayer
        if MPMediaLibrary.authorizationStatus() == .authorized, player.playbackState == .playing, let item = player.nowPlayingItem, let title = item.title {
            player.pause()
            try await TVBridge.post("flick", ["title": title, "artist": item.artist ?? ""])
            return .result()
        }
        #endif
        try? await TVBridge.post("music-now")
        FlickRequest.wantsAirPlay = true
        NotificationCenter.default.post(name: FlickRequest.airPlay, object: nil)
        return .result()
    }
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
    func perform() async throws -> some IntentResult { try await TVBridge.post("send", ["text": text]); return .result() }
}
struct TVShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FlickToTV(), phrases: ["Flick to \(.applicationName)", "Send this to the \(.applicationName)"], shortTitle: "Flick to TV", systemImageName: "airplayaudio")
        AppShortcut(intent: PlayOnTV(), phrases: ["Play something on the \(.applicationName)"], shortTitle: "Play on TV", systemImageName: "play.circle")
        AppShortcut(intent: TVPower(), phrases: ["Turn the \(.applicationName) on or off", "Toggle the \(.applicationName)"], shortTitle: "TV On or Off", systemImageName: "power")
    }
}
