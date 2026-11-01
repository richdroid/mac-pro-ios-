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

    static var live: Activity<TVIslandAttributes>? { Activity<TVIslandAttributes>.activities.first { $0.activityState == .active } }
    // With no way to push updates, it can only say when its picture may be out of date.
    static let staleAfter: TimeInterval = 300

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
        let current = live
        guard let next = state(status) else {
            if status.online { await current?.end(nil, dismissalPolicy: .immediate) }
            return
        }
        if let current {
            if current.content.state != next || (current.content.staleDate ?? .distantPast) < Date().addingTimeInterval(staleAfter / 2) { await current.update(ActivityContent(state: next, staleDate: Date().addingTimeInterval(staleAfter))) }
        } else if next.playing, ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: TVIslandAttributes(), content: ActivityContent(state: next, staleDate: Date().addingTimeInterval(staleAfter)), pushType: nil)
        }
    }
}

struct TVIslandPlayPause: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or pause the TV"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult {
        // The button changes at once; the TV's own answer follows.
        let current = TVIsland.live, before = current?.content.state
        if let current, var flipped = before {
            flipped.playing.toggle()
            await current.update(ActivityContent(state: flipped, staleDate: Date().addingTimeInterval(TVIsland.staleAfter)))
        }
        do { try await TVBridge.post("key", ["key": "play"]) }
        catch {
            if let current, let before { await current.update(ActivityContent(state: before, staleDate: Date().addingTimeInterval(TVIsland.staleAfter))) }
            throw error
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let s = await TVBridge.status() { await TVIsland.sync(s) }
        return .result()
    }
}
#endif
