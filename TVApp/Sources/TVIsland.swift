#if os(iOS)
import ActivityKit
import AppIntents
import Foundation
import UIKit

// What's playing on the TV, in the Dynamic Island, with a play and pause button.
struct TVIslandAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String
        var app: String
        var playing: Bool
        // The cover itself, small enough to ride in the activity (a few KB at most): with no shared container in this
        // build, the island can't read a file the app wrote, and it can't fetch. `artKey` says which cover it is.
        var art: Data?
        var artKey: String?
        // Where it is in what's playing, when the TV says: the bar runs on its own between updates while playing.
        var start: Date?
        var end: Date?
        var progress: Double?
        var length: Double?
    }
}

enum TVIsland {
    // Films and shows, and Mint's songs with their album art (Richard, 2026-11-05: "the dynamic island should show album
    // art or tv cover"). A song that changes while the app is closed shows as stale until it's opened again. Anything
    // AirPlayed from this phone, which iOS already shows, is left out.
    static let apps = ["com.google.android.youtube.tv": "YouTube", "com.stremio.one": "Stremio"]
    static let mint = "com.codex.musicwebtv"

    // A stale one still shows, so it counts too; anything past the first is a leftover and is ended.
    static var shown: [Activity<TVIslandAttributes>] { Activity<TVIslandAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale } }
    static var live: Activity<TVIslandAttributes>? { shown.first }
    // With no way to push updates, it can only say when its picture may be out of date, and soon, as a film can be
    // paused or stopped from the TV's own remote.
    static let staleAfter: TimeInterval = 90

    static func state(_ s: TVStatus) -> TVIslandAttributes.ContentState? {
        guard s.online, s.airplay?.active != true else { return nil }
        // Mint's song, with its album, when Mint is what's on (or nothing else is).
        if let m = s.music, s.session == nil || s.session?.pkg == mint, m.playing || s.app == mint, !(s.screen == "asleep" && !m.playing) {
            var st = TVIslandAttributes.ContentState(title: m.title.isEmpty ? "Mint" : m.title, subtitle: m.artist, app: "Mint", playing: m.playing)
            timing(&st, position: m.position, sampledAt: m.sampledAt, duration: m.duration)
            return st
        }
        guard let session = s.session, let app = apps[session.pkg] else { return nil }
        // A sleeping TV with nothing playing has nothing to offer.
        if s.screen == "asleep" && !session.playing { return nil }
        // Nor does a paused player you've since left, which Android keeps reporting as active.
        if !session.playing && s.app != session.pkg { return nil }
        // Under the title, the episode if there is one, and otherwise nothing: never the app doing the playing.
        let title = session.description.first ?? ""
        let under = session.description.dropFirst().first.map(Wording.episode) ?? ""
        var st = TVIslandAttributes.ContentState(title: title.isEmpty ? app : title, subtitle: under == title ? "" : under, app: app, playing: session.playing)
        timing(&st, position: session.position, sampledAt: session.sampledAt, duration: session.duration)
        return st
    }
    // Position and length come in ms on the Mac's clock. Playing, the bar runs from a start and end; paused, it holds.
    static func timing(_ st: inout TVIslandAttributes.ContentState, position: Double?, sampledAt: Double?, duration: Double?) {
        guard let p = position, let d = duration, d > 1000 else { return }
        let since = sampledAt.map { max(0, Date().timeIntervalSince1970 * 1000 - $0) } ?? 0
        let at = min(p + (st.playing ? since : 0), d) / 1000
        st.progress = at / (d / 1000); st.length = d / 1000
        if st.playing { st.start = Date().addingTimeInterval(-at); st.end = st.start!.addingTimeInterval(d / 1000) }
    }

    // The cover, shrunk to a thumbnail the activity can carry: about 72 px tall, as JPEG, under 2.2 KB. Made once per cover.
    private static var thumbs: [String: Data] = [:]
    static func thumbnail(_ url: String?) async -> (Data, String)? {
        guard let url, let u = URL(string: url) else { return nil }
        if let d = thumbs[url] { return (d, url) }
        guard let image = await ImageStore.shared.load(u) else { return nil }
        let data: Data? = await Task.detached(priority: .utility) { () -> Data? in
            for height in [96.0, 78.0, 64.0, 52.0] {
                let k = height / max(image.size.height, 1)
                let size = CGSize(width: max(1, (image.size.width * k).rounded()), height: height)
                let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
                let small = UIGraphicsImageRenderer(size: size, format: f).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                for q in [0.7, 0.55, 0.4] { if let j = small.jpegData(compressionQuality: q), j.count <= 2200 { return j } }
            }
            return nil
        }.value
        guard let data else { return nil }
        if thumbs.count > 12 { thumbs.removeAll() }
        thumbs[url] = data
        return (data, url)
    }

    // Starts only for something actually playing, and goes away once the TV has moved on.
    // The build's sample TV answers on this phone itself: nothing there is really playing, so nothing goes in the island.
    static var sample: Bool { ["127.0.0.1", "localhost"].contains { TVBridge.address.contains($0) } }
    // The same, give or take the bar's own drift: the start moves by milliseconds every reading, and updating the island
    // for that would spend its budget on nothing.
    static func same(_ a: TVIslandAttributes.ContentState, _ b: TVIslandAttributes.ContentState) -> Bool {
        var x = a, y = b
        let drift = abs((a.start ?? .distantPast).timeIntervalSince(b.start ?? .distantPast))
        if drift < 3 || (a.start == nil && b.start == nil) { x.start = nil; y.start = nil; x.end = nil; y.end = nil; x.progress = nil; y.progress = nil }
        return x == y
    }
    // The real picture of what's on as the Mac reports it (the poster it found, the album), never an app's icon. For a
    // reading made without the model (the background refresh); the model's islandArt adds what was last flicked.
    static func art(_ s: TVStatus) -> String? {
        let a = s.session.flatMap { $0.pkg == mint ? nil : $0.art } ?? s.music?.art
        return a?.isEmpty == false && a?.contains("/api/tv/icon") != true ? a : nil
    }
    // `art` is the cover's address when the app knows it; nil keeps the cover already shown for the same title.
    static func sync(_ status: TVStatus, art: String? = nil) async {
        // The build's sample TV: nothing there is really playing, so nothing stays up.
        for old in shown where sample { await old.end(nil, dismissalPolicy: .immediate) }
        if sample { return }
        // One gone stale (the app was closed while it played) is brought up to date below, in place, or taken down if the
        // TV has stopped: ending it and starting another made the card vanish and come back on every return after 90 s.
        let all = shown, current = all.first
        for extra in all.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        guard var next = state(status) else {
            if status.online { await current?.end(nil, dismissalPolicy: .immediate) }
            return
        }
        // The cover rides along: new art when there is some, else the one already shown, if it's still the same thing.
        if let t = await thumbnail(art) { next.art = t.0; next.artKey = t.1 }
        else if let old = current?.content.state, old.title == next.title { next.art = old.art; next.artKey = old.artKey }
        if let current {
            if !same(current.content.state, next) || (current.content.staleDate ?? .distantPast) < Date().addingTimeInterval(staleAfter / 2) { await current.update(ActivityContent(state: next, staleDate: Date().addingTimeInterval(staleAfter))) }
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
            // The bar stops where it is, or runs on from there.
            if let len = flipped.length, let p = before?.progress {
                let at = before?.start.map { min(max(Date().timeIntervalSince($0), 0), len) } ?? p * len
                flipped.progress = at / max(len, 1)
                flipped.start = flipped.playing ? Date().addingTimeInterval(-at) : nil
                flipped.end = flipped.start?.addingTimeInterval(len)
            }
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
