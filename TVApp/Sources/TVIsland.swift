#if os(iOS)
import ActivityKit
import AppIntents
import Foundation
import ImageIO
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
        // When it was paused, kept across readings while it stays paused: five minutes on, the card goes.
        var pausedSince: Date?
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
    // Paused this long, the card leaves the island and the Lock Screen (Richard, 2026-11-10: "the dynamic island and like
    // now playing should leave once it has been paused for like 5 mins"). Nothing can wake the app at that moment (no push
    // with a free Apple ID), so it goes at the first chance after: the app open, the island's button, the grace after
    // leaving, or the background refresh asked for at that time (TVBackground.schedule). Until then it reads as stale.
    static let pausedFor: TimeInterval = 300
    static func pausedOut(_ st: TVIslandAttributes.ContentState, at now: Date = Date()) -> Bool {
        guard !st.playing, let since = st.pausedSince else { return false }
        return now.timeIntervalSince(since) >= pausedFor
    }
    // Whether the Mac has said it pushes this card's changes as they happen (its answer to island-state): then the card
    // is as true as the Mac's own reading, and only goes stale when what it shows has run out.
    // Kept between launches: starting false each time, a card he had just paused went stale (dimmed, its keys gone) 90 s
    // into every launch in which nothing else changed. Asked again on each launch's first reading (`asked`).
    static var pushed = UserDefaults.standard.bool(forKey: "islandPushed") { didSet { if pushed != oldValue { UserDefaults.standard.set(pushed, forKey: "islandPushed") } } }
    private static var asked = false
    // Without pushes: stale after 90 s, and never later than the moment a pause runs out. With them: when the film or
    // song would have ended (two minutes' grace), four hours on for something with no length, or as the
    // pause runs out.
    static func staleDate(_ st: TVIslandAttributes.ContentState) -> Date {
        if !st.playing, let since = st.pausedSince { return min(pushed ? .distantFuture : Date().addingTimeInterval(staleAfter), since.addingTimeInterval(pausedFor)) }
        guard pushed else { return Date().addingTimeInterval(staleAfter) }
        // No running time known: four hours, longer than anything runs; the Mac's pushes end the card when it stops.
        return st.end.map { max($0.addingTimeInterval(120), Date().addingTimeInterval(staleAfter)) } ?? Date().addingTimeInterval(4 * 3600)
    }
    // What the card now shows, handed to the Mac with the cover the phone made for it, so the Mac's pushes can carry the
    // same cover; a Mac from before this doesn't know the address, and nothing changes.
    static func tell(_ id: String, _ st: TVIslandAttributes.ContentState) {
        asked = true
        guard !sample, let d = try? JSONEncoder().encode(st), let j = try? JSONSerialization.jsonObject(with: d) else { return }
        Task {
            let a = try? await TVBridge.post("island-state", ["id": id, "state": j], timeout: 10)
            let live = (a.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["live"] as? Bool == true
            if live != pushed { pushed = live }
        }
    }

    static func state(_ s: TVStatus) -> TVIslandAttributes.ContentState? {
        guard s.online, s.airplay?.active != true else { return nil }
        // Mint's song, with its album, when Mint is what's on (or nothing else is).
        // Said to be playing but already past its end: an old report (the Mac keeps Mint's last song), shown as stopped,
        // as the app's own pages do, so it never puts a song's card up over nothing.
        let ended = s.music.map { $0.duration > 0 && $0.playing && $0.position + Date().timeIntervalSince1970 * 1000 - $0.sampledAt >= $0.duration } ?? false
        if let m = s.music, s.session == nil || s.session?.pkg == mint, (m.playing && !ended) || s.app == mint, !(s.screen == "asleep" && !(m.playing && !ended)) {
            // A card with no name says nothing: none until there is one.
            guard !m.title.isEmpty else { return nil }
            var st = TVIslandAttributes.ContentState(title: clip(m.title), subtitle: clip(m.artist), app: "Mint", playing: m.playing && !ended)
            timing(&st, position: m.position, sampledAt: m.sampledAt, duration: m.duration)
            return st
        }
        guard let session = s.session, let app = apps[session.pkg] else { return nil }
        // A sleeping TV with nothing playing has nothing to offer.
        if s.screen == "asleep" && !session.playing { return nil }
        // Nor does a paused player you've since left, which Android keeps reporting as active.
        if !session.playing && s.app != session.pkg { return nil }
        // The show's name over its episode ("S3 E4 · Notapusy"), a video over its channel, a film alone: the same words as
        // the Playing tab's, never the app doing the playing.
        let title = session.showName
        let under = session.episodeLine ?? session.channel ?? ""
        guard !title.isEmpty else { return nil }
        var st = TVIslandAttributes.ContentState(title: clip(title), subtitle: under == title ? "" : clip(under), app: app, playing: session.playing)
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

    // An activity's whole state is 4 KB at most, the cover in it included (as base64, a third bigger than its bytes), so
    // a long episode name is cut before it can push a card's update over the limit, which iOS then drops without a word.
    static func clip(_ t: String) -> String { t.count > 70 ? String(t.prefix(69)) + "…" : t }
    // The cover, shrunk to a thumbnail the activity can carry. HEIC first: at these sizes it keeps a poster's faces and
    // lettering where the 96 px JPEG it replaces was a smear at the size the Lock Screen draws it (Richard, 2026-11-10:
    // "dynamic island is not fixed its ugly as is"). The biggest that fits in 2.3 KB, from 168 px on its longer side
    // down; JPEG where the phone can't write HEIC. Made once per cover.
    static let thumbBytes = 2300
    private static var thumbs: [String: Data] = [:]
    nonisolated static func heic(_ image: UIImage, quality: Double) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
    nonisolated static func shrink(_ image: UIImage) -> Data? {
        let longer = max(image.size.width, image.size.height, 1)
        func scaled(_ side: Double) -> UIImage {
            let k = min(1, side / longer)
            let size = CGSize(width: max(1, (image.size.width * k).rounded()), height: max(1, (image.size.height * k).rounded()))
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
            return UIGraphicsImageRenderer(size: size, format: f).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        for side in [168.0, 144, 120, 96] {
            let small = scaled(side)
            for q in [0.6, 0.45, 0.3] { if let d = heic(small, quality: q), d.count <= thumbBytes { return d } }
        }
        for side in [104.0, 88, 72, 56] {
            let small = scaled(side)
            for q in [0.7, 0.55, 0.4] { if let j = small.jpegData(compressionQuality: q), j.count <= thumbBytes { return j } }
        }
        return nil
    }
    static func thumbnail(_ url: String?) async -> (Data, String)? {
        guard let url, let u = URL(string: url) else { return nil }
        if let d = thumbs[url] { return (d, url) }
        guard let image = await ImageStore.shared.load(u) else { return nil }
        let data: Data? = await Task.detached(priority: .utility) { shrink(image) }.value
        guard let data else { return nil }
        if thumbs.count > 12 { thumbs.removeAll() }
        thumbs[url] = data
        return (data, url)
    }

    // Starts only for something actually playing, and goes away once the TV has moved on.
    // The build's sample TV answers on this phone itself: nothing there is really playing, so nothing goes in the island.
    // Except in the build's "island" pose, which is there to film the real card: the island, opened, and the Lock Screen.
    static var sample: Bool { ["127.0.0.1", "localhost"].contains { TVBridge.address.contains($0) } && UserDefaults.standard.string(forKey: "pose") != "island" }
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
    // A play or pause pressed on the card, held for four seconds against readings that still say otherwise: the Mac's
    // answer just after a press is often from before it, and taking it flipped the glyph back under his thumb.
    static var pressed: (playing: Bool, until: Date)?
    // `art` is the cover's address when the app knows it; nil keeps the cover already shown for the same title.
    static func sync(_ status: TVStatus, art: String? = nil) async {
        if let p = pressed {
            if p.until < Date() { pressed = nil }
            else if let said = state(status), said.playing != p.playing { return }
        }
        // The build's sample TV: nothing there is really playing, so nothing stays up.
        for old in shown where sample { await old.end(nil, dismissalPolicy: .immediate) }
        if sample { return }
        // One gone stale (the app was closed while it played) is brought up to date below, in place, or taken down if the
        // TV has stopped: ending it and starting another made the card vanish and come back on every return after 90 s.
        let all = shown, current = all.first
        for extra in all.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        if let current { listen(current) }
        guard var next = state(status) else {
            if status.online { await current?.end(nil, dismissalPolicy: .immediate) }
            return
        }
        // The cover rides along: new art when there is some, else the one already shown, if it's still the same thing.
        // A pause keeps the moment it began; playing clears it.
        if !next.playing { next.pausedSince = (current?.content.state.playing == false ? current?.content.state.pausedSince : nil) ?? Date() }
        if pausedOut(next) { await current?.end(nil, dismissalPolicy: .immediate); return }
        if let t = await thumbnail(art) { next.art = t.0; next.artKey = t.1 }
        else if let old = current?.content.state, old.title == next.title { next.art = old.art; next.artKey = old.artKey }
        if let current {
            let changed = !same(current.content.state, next)
            if changed || (current.content.staleDate ?? .distantPast) < Date().addingTimeInterval(staleAfter / 2) { await current.update(ActivityContent(state: next, staleDate: staleDate(next))) }
            if changed || !asked { tell(current.id, next) }
        } else if next.playing, ActivityAuthorizationInfo().areActivitiesEnabled {
            let content = ActivityContent(state: next, staleDate: staleDate(next))
            // With a push token the Mac can end it at five minutes paused even with the app closed; a build signed without
            // push (no aps-environment) can't ask for one, and gets the card all the same.
            if let made = (try? Activity.request(attributes: TVIslandAttributes(), content: content, pushType: .token))
                ?? (try? Activity.request(attributes: TVIslandAttributes(), content: content, pushType: nil)) { listen(made); tell(made.id, next) }
        }
    }

    // Each card's push token goes to the Mac as soon as iOS hands it over, and again whenever iOS changes it. Listened to
    // once per card.
    private static var listening: Set<String> = []
    static func listen(_ a: Activity<TVIslandAttributes>) {
        guard !sample, listening.insert(a.id).inserted else { return }
        Task {
            for await t in a.pushTokenUpdates {
                let hex = t.map { String(format: "%02x", $0) }.joined()
                try? await TVBridge.post("island-token", ["id": a.id, "token": hex, "bundle": Bundle.main.bundleIdentifier ?? ""], timeout: 10)
            }
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
            flipped.pausedSince = flipped.playing ? nil : Date()
            // The bar stops where it is, or runs on from there.
            if let len = flipped.length, let p = before?.progress {
                let at = before?.start.map { min(max(Date().timeIntervalSince($0), 0), len) } ?? p * len
                flipped.progress = at / max(len, 1)
                flipped.start = flipped.playing ? Date().addingTimeInterval(-at) : nil
                flipped.end = flipped.start?.addingTimeInterval(len)
            }
            TVIsland.pressed = (flipped.playing, Date().addingTimeInterval(4))
            await current.update(ActivityContent(state: flipped, staleDate: TVIsland.staleDate(flipped)))
        }
        // The key that does what the glyph said, as the app's own ⏯ sends it, never the toggle: pressed on a card a few
        // seconds behind the TV, a toggle did the opposite. The toggle only when nothing says what's on.
        do { try await TVBridge.post("key", ["key": before.map { $0.playing ? "pause" : "resume" } ?? "play"]) }
        catch {
            TVIsland.pressed = nil
            if let current, let before { await current.update(ActivityContent(state: before, staleDate: TVIsland.staleDate(before))) }
            throw error
        }
        // The TV's word once it agrees (asked at 1.5 s), and whatever it says once the press's four seconds are up.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let s = await TVBridge.status() { await TVIsland.sync(s, art: TVIsland.art(s)) }
        if let p = TVIsland.pressed, TVIsland.live?.content.state.playing == p.playing {
            try? await Task.sleep(nanoseconds: 2_700_000_000)
            TVIsland.pressed = nil
            if let s = await TVBridge.status() { await TVIsland.sync(s, art: TVIsland.art(s)) }
        }
        return .result()
    }
}
// The two keys either side of the bar: ten seconds back or on in a film, show or video, the song before or after in
// Mint. The same sends as the app's own transport makes for each (Stremio's player takes its jumps through the Mac).
struct TVIslandSkip: LiveActivityIntent {
    static var title: LocalizedStringResource = "Skip on the TV"
    static var isDiscoverable = false
    @Parameter(title: "Forward") var forward: Bool
    init() {}
    init(forward: Bool) { self.forward = forward }
    func perform() async throws -> some IntentResult {
        let current = TVIsland.live, before = current?.content.state
        switch before?.app {
        case "Mint": try await TVBridge.post("key", ["key": forward ? "next" : "previous"])
        case "YouTube": try await TVBridge.post("key", ["key": forward ? "forward" : "rewind"])
        default:
            // The bar moves at once, by the ten seconds asked for, and the TV's own word follows.
            if let current, var moved = before, let len = moved.length, len > 0 {
                let at = moved.start.map { Date().timeIntervalSince($0) } ?? (moved.progress ?? 0) * len
                let to = min(max(at + (forward ? 10 : -10), 0), len)
                moved.progress = to / len
                if moved.playing { moved.start = Date().addingTimeInterval(-to); moved.end = moved.start?.addingTimeInterval(len) }
                await current.update(ActivityContent(state: moved, staleDate: TVIsland.staleDate(moved)))
            }
            do { try await TVBridge.post("player-seek", ["steps": forward ? 1 : -1], timeout: 30) }
            catch {
                if let current, let before { await current.update(ActivityContent(state: before, staleDate: TVIsland.staleDate(before))) }
                throw error
            }
        }
        // With the cover of whatever is on now: a song skipped to has its own, and without it the card fell to a glyph.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if let s = await TVBridge.status() { await TVIsland.sync(s, art: TVIsland.art(s)) }
        return .result()
    }
}
#endif
