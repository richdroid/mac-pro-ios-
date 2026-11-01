#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

// What's playing on the TV, in the Dynamic Island, with a play and pause button.
struct TVIslandAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String
        var app: String
        var playing: Bool
    }
}

enum TVIsland {
    static let apps = ["com.codex.musicwebtv": "Mint Music", "com.google.android.youtube.tv": "YouTube", "com.google.android.youtube.tvmusic": "YouTube Music", "com.stremio.one": "Stremio"]

    static func state(_ s: TVStatus) -> TVIslandAttributes.ContentState? {
        guard s.online, let session = s.session, let app = apps[session.pkg] else { return nil }
        // A sleeping TV with nothing playing has nothing to offer. Music can carry on with the screen off.
        if s.screen == "asleep" && !session.playing { return nil }
        // Nor does a paused player you've since left, which Android keeps reporting as active.
        if !session.playing && s.app != session.pkg { return nil }
        if session.pkg == "com.codex.musicwebtv", let m = s.music {
            return .init(title: m.title, subtitle: m.artist, app: app, playing: session.playing)
        }
        return .init(title: session.description.first ?? app, subtitle: session.description.dropFirst().first ?? app, app: app, playing: session.playing)
    }

    // Starts only for something actually playing, and goes away once the TV has moved on.
    static func sync(_ status: TVStatus) async {
        let current = Activity<TVIslandAttributes>.activities.first
        guard let next = state(status) else {
            if status.online { await current?.end(nil, dismissalPolicy: .immediate) }
            return
        }
        if let current {
            if current.content.state != next { await current.update(ActivityContent(state: next, staleDate: nil)) }
        } else if next.playing, ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: TVIslandAttributes(), content: ActivityContent(state: next, staleDate: nil), pushType: nil)
        }
    }
}

struct TVIslandPlayPause: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or pause the TV"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult {
        // The button changes at once; the TV's own answer follows.
        if let current = Activity<TVIslandAttributes>.activities.first {
            var flipped = current.content.state
            flipped.playing.toggle()
            await current.update(ActivityContent(state: flipped, staleDate: nil))
        }
        try await TVBridge.post("key", ["key": "play"])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let s = await TVBridge.status() { await TVIsland.sync(s) }
        return .result()
    }
}
#endif
