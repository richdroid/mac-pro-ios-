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
    // Only what plays for a long while. Songs change faster than this can be updated with the app closed, so music, and
    // anything AirPlayed from this phone, which iOS already shows, is left out.
    static let apps = ["com.google.android.youtube.tv": "YouTube", "com.stremio.one": "Stremio"]

    // A stale one still shows, so it counts too; anything past the first is a leftover and is ended.
    static var shown: [Activity<TVIslandAttributes>] { Activity<TVIslandAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale } }
    static var live: Activity<TVIslandAttributes>? { shown.first }
    // With no way to push updates, it can only say when its picture may be out of date, and soon, as a film can be
    // paused or stopped from the TV's own remote.
    static let staleAfter: TimeInterval = 90

    static func state(_ s: TVStatus) -> TVIslandAttributes.ContentState? {
        guard s.online, s.airplay?.active != true, let session = s.session, let app = apps[session.pkg] else { return nil }
        // A sleeping TV with nothing playing has nothing to offer.
        if s.screen == "asleep" && !session.playing { return nil }
        // Nor does a paused player you've since left, which Android keeps reporting as active.
        if !session.playing && s.app != session.pkg { return nil }
        // Under the title, the episode if there is one, and otherwise nothing: never the app doing the playing.
        let title = session.description.first ?? ""
        let under = session.description.dropFirst().first.map(Wording.episode) ?? ""
        return .init(title: title.isEmpty ? app : title, subtitle: under == title ? "" : under, app: app, playing: session.playing)
    }

    // Starts only for something actually playing, and goes away once the TV has moved on.
    static func sync(_ status: TVStatus) async {
        let all = shown, current = all.first
        for extra in all.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
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
