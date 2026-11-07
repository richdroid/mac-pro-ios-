import Foundation
import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
struct Film: Identifiable, Hashable {
    let slug: String, title: String, year: String, poster: String, note: String
    var imdb = ""
    var id: String { slug + note }
    var media: MediaItem { MediaItem(title: title, subtitle: note.isEmpty ? year : note, art: poster, id: imdb, kind: "movie", slug: slug) }
}

// Observed property by property: a view redraws only for what it actually reads, so a status reading that changes the
// position doesn't redraw every key and card in every tab.
@MainActor @Observable
final class TVModel {
    var status: TVStatus?
    // True until the first answer since launch. Until then the status is the one kept from last time: good for laying
    // out the pages, but not for saying what's playing, where it's got to, or whether it's paused.
    var staleStatus = true
    let mirrorStore = MirrorStore()
    // The TV's screen on the Remote: on unless he's turned it off, and kept that way.
    var mirrorLive = UserDefaults.standard.object(forKey: "mirrorLive") as? Bool ?? true
    #if os(iOS)
    let live = LiveMirror()
    #endif
    // Where the Remote's picture of the TV is on the display, while it's there. Not published: only read, never drawn.
    @ObservationIgnored var mirrorSlot: CGRect?
    @ObservationIgnored private var mirrorViewers = 0
    // The poster standing in on the Remote's picture for a film just flicked, until the TV's own word catches up.
    private(set) var standInArt: String?
    @ObservationIgnored private var standInUntil = Date.distantPast
    var standInNow: String? { standInUntil > Date() ? standInArt : nil }
    func standIn(_ art: String) { standInArt = art; standInUntil = Date().addingTimeInterval(30) }
    // When a flick's controls last handed over to the Remote, so its keys can settle in after the screen lands.
    var remoteArrival = Date.distantPast
    // When the flick's screen actually starts its move onto the Remote's picture, which the keys follow closely.
    @ObservationIgnored var remoteMoveAt = Date.distantPast
    // While a flick's screen is moving onto the Remote's picture: that picture stays hidden under it until the screen has
    // landed, or the two showed at once, the one below peeking out under the one moving.
    // Nothing on the Remote starts while a flick's screen is coming onto it (the mirror connecting, its still being
    // fetched): any of it on the main thread during the move was a visible hitch (r26). It starts the moment the move ends.
    var flickHandoff = false {
        didSet { if oldValue && !flickHandoff { warmMirror(); if mirrorLive && mirrorViewers > 0 && !liveShowing { Task { await loadMirror() } } } }
    }
    // The side bar's width, so a show's page opened over everything can leave it uncovered and in reach.
    var railWidth: CGFloat = 0
    // The flick screen is on a show's or a stream's page (not the card): the side bar stays usable, and a tab leaves it.
    var flickChoosing = false
    // The flick's stage is up over a page (not yet moving onto the Remote): the page steps out of sight under it, so its
    // rows never ghost through the stage's fade (r18).
    var flickCovering = false
    // A film's colour kept on the pages behind after the flick closes, until something else is playing.
    @ObservationIgnored var moodArt: String?
    func keepMood(until art: String) { moodArt = art }
    var reachable = true
    var watchlist: [Film] = []
    var friends: [Film] = []
    var recommended: [Film] = []
    var flicking: FlickTarget?
    @ObservationIgnored private var lastFlick: (id: String, at: Date)?
    // The colour of wherever you are: an app's own, or whatever you've picked. Nil lets what's playing set it.
    var mood: Color?
    // The cover of the last thing flicked, for when the TV's player has none of its own to show.
    var lastArt: String?
    var lastArtPkg: String?
    @ObservationIgnored var lastArtTitle: String?
    // A picture for what an app is playing: its real poster if the Mac found one, else the cover of what was flicked to
    // it if that's still what's on, else the app's own banner. Never the cover of something that played before.
    // The cover for the Dynamic Island: what's on per this reading (the poster, the thumbnail or the album), never the app's
    // own icon, which the island draws as its glyph instead.
    func islandArt(_ s: TVStatus) -> String? {
        let a = s.session.flatMap { $0.pkg == "com.codex.musicwebtv" ? nil : picture(for: $0) } ?? s.music?.art
        return a?.contains("/api/tv/icon") == true ? nil : a
    }
    // A real picture of what's playing, never the app's own banner: the backgrounds and the pictures of what's on use
    // this (r21: the Remote's background was a blown-up STREMIO wordmark, and YouTube's picture a white banner).
    func poster(for s: TVStatus.Session) -> String? {
        picture(for: s).flatMap { $0.contains("/api/tv/icon") ? nil : $0 }
    }
    // The picture behind every page: what's on, and never a banner; with none, the last real one stays.
    var ambienceArt: String? { nowArt.flatMap { $0.contains("/api/tv/icon") ? nil : $0 } }
    func picture(for s: TVStatus.Session) -> String? {
        if let a = s.art, !a.isEmpty { return a }
        if s.pkg == lastArtPkg, let a = lastArt, let t = lastArtTitle, let now = s.description.first,
           TVStatus.Session.sameName(now, t) || TVStatus.Session.sameName(s.showName, t) { return a }
        return url("/api/tv/icon?pkg=\(s.pkg)&v=2")?.absoluteString
    }
    // The flick screen brings itself in and out, so the system's slide stays out of it. Whatever was being typed into is
    // done with: the keyboard never stays up over what a search led to (Richard, 2026-11-05).
    func flick(_ target: FlickTarget) {
        Keyboard.dismiss()
        // One at a time. And a send that goes by itself (next episode, an episode picked from the list) taken twice within
        // three seconds is the same tap, never a second start.
        guard flicking == nil else { return }
        if target.autoplay {
            if let l = lastFlick, l.id == target.item.id, Date().timeIntervalSince(l.at) < 3 { return }
            lastFlick = (target.item.id, Date())
        }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { flicking = target }
    }
    // The thing on a card is what the TV is playing now (the same film, or the episode named on the card): tapping it goes
    // straight to the Remote, with nothing thrown, prepared or sent, and asked to play if it's paused (r17 item 6). A show
    // without an episode on its card still opens its page, which says "On the TV".
    func isOnTV(_ item: MediaItem, _ source: MediaSource) -> Bool {
        if item.isYouTube {
            guard !staleStatus, videoIsCurrent, let s = status?.session, s.pkg == "com.google.android.youtube.tv", let now = s.description.first else { return false }
            return TVStatus.Session.sameName(now, item.title)
        }
        guard source == .stremio, let ref = item.stremioRef else { return false }
        if ref.type == "series" { guard let v = ref.video else { return false }; return isOn(imdb: ref.imdb, title: item.title, episode: v) }
        return isOn(imdb: ref.imdb, title: item.title, episode: nil)
    }
    // The one answer to "is this what the TV's playing now", for the card's tap, the show page's key and the throw itself
    // (r20: the throw's own check lacked both of these, and could resend an episode or swallow a film).
    // Only on a fresh reading: the status kept from the last launch said a film was on that had long finished, and a throw
    // was swallowed as "already on" (r19). A show's episode is the series lookup's when that's done, otherwise the session's
    // own season and episode and show name (r19: a race offered to resume what was on). `episode` is Stremio's "tt…:s:e".
    func isOn(imdb: String, title: String, episode: String?) -> Bool {
        guard !staleStatus, videoIsCurrent, let s = status?.session, s.pkg == "com.stremio.one" else { return false }
        if let episode {
            if let on = NextUp.shared.series, on.imdb == imdb { return episode == on.current }
            let parts = episode.split(separator: ":")
            guard parts.count == 3, let se = s.seasonEpisode, s.isShow(title) else { return false }
            return Int(parts[1]) == se.season && Int(parts[2]) == se.episode
        }
        guard let now = s.description.first, !now.isEmpty else { return false }
        return TVStatus.Session.sameName(now, title)
    }
    // A YouTube card from Continue watching: the video opens in YouTube on the TV where he left it, the way a pasted link
    // does, and the Remote comes up to show it. Under half a minute in isn't worth resuming: it starts from the top.
    func openYouTube(_ item: MediaItem) {
        Keyboard.dismiss()
        let at = item.resume ?? 0
        send("https://www.youtube.com/watch?v=\(item.id)" + (at >= 30 ? "&t=\(at)" : ""))
        tab = 0
    }
    func showOnRemote() {
        Keyboard.dismiss()
        tick()
        if status?.session?.playing == false { holdPlay(true); key("resume") }
        tab = 0
    }
    func closeFlick() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { flicking = nil }
    }
    // A start the flick sent, kept here rather than by the flick screen, which closes as he lands on the Remote: the
    // Remote's picture shows it (the poster, the light lapping its edge) until the TV plays it or says no.
    struct Starting: Equatable {
        var title: String
        var art: String
        var line: String?
        var phase: String?
        var since = Date()
        var failed = false
        var played = false
        var token: String?
    }
    var starting: Starting?
    // What to reopen for "Choose another", with the streams that didn't start set apart.
    @ObservationIgnored var startingTarget: FlickTarget?
    @ObservationIgnored var startingAvoid: Set<String> = []
    func beginStart(_ s: Starting, target: FlickTarget) {
        startingTarget = target
        withAnimation(.easeOut(duration: 0.2)) { starting = s }
    }
    func startPhase(_ p: String) {
        guard starting != nil else { return }
        starting?.phase = p
    }
    // Playing: the light finishes its lap, then the picture is the TV's own again. The yes is felt here.
    func startPlayed() {
        guard let st = starting, !st.failed, !st.played else { return }
        // ⏯ said pause all through the start; it goes on saying so until a reading taken after this agrees, so the first
        // status after the start (which can still say not playing) can't flip it to ▶ for a moment (r21).
        holdPlay(true)
        // The light finishes its lap and the picture becomes the TV's own (the Remote reads `played`).
        withAnimation(.easeOut(duration: 0.3)) { starting?.played = true }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            startEndedAt = Date()
            withAnimation(.easeOut(duration: 0.3)) { starting = nil }
            // The live mirror only now the film plays: before, it showed the launcher behind the starting poster (r24).
            if !mirrorLive { setMirror(true) }
            await load()
        }
    }
    // Nothing would start, the fallbacks included: the poster stays, dimmed, with one way on.
    func startFailed(tokens: [String]) {
        guard let st = starting, !st.failed, !st.played else { return }
        startingAvoid.formUnion(tokens)
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
        withAnimation(.easeOut(duration: 0.25)) { starting?.failed = true }
    }
    // Called off from the Remote (holding ⏯), or done with after a failure.
    func clearStart() { startEndedAt = Date(); withAnimation(.easeOut(duration: 0.25)) { starting = nil } }
    // When a start last ended: the Remote keeps the bar's and episode line's places for a while after, until the TV's own
    // reading of what's on has caught up, so nothing drops out and back in at playing (r24: the pad jumped 10 pt).
    var startEndedAt = Date.distantPast
    // The failed one's stream list, with the ones that didn't start set apart.
    func chooseAnother() {
        guard var t = startingTarget else { clearStart(); return }
        clearStart()
        t.streamsFirst = true
        t.avoid = startingAvoid
        t.ready = false; t.autoplay = false
        flick(t)
    }
    // Sound from the phone that isn't music. Mint's last song is still in the status then, but it isn't what's playing.
    var otherAirPlay: Bool { status?.airplay?.active == true && status?.airplay?.kind != "music" }
    var nowMusic: TVStatus.Music? { otherAirPlay ? nil : status?.music }
    // The cover of what's on, for the wall behind every page and the Playing tab's icon. Nothing while the phone plays
    // something of its own, rather than the cover of whatever played before.
    var nowArt: String? {
        if otherAirPlay { return nil }
        if videoIsCurrent, let s = status?.session { return picture(for: s) }
        return status?.music?.art
    }
    // Whether another app's player, rather than Mint, is what's on. A paused player only counts if it's the app in
    // front, or a song would lose out to something long since left.
    var videoIsCurrent: Bool {
        guard let s = status?.session, s.pkg != "com.codex.musicwebtv" else { return false }
        return s.playing || nowMusic == nil || s.pkg == status?.app
    }
    // A film playing, which the TV's screenshot leaves black: it never captures protected video.
    var filmOnScreen: Bool { !staleStatus && videoIsCurrent && status?.session?.playing == true }
    // Opening an app's page, or going to another tab, leaves whatever field was being typed into.
    var browsing: MediaSource? { didSet { if browsing != nil { Keyboard.dismiss() } } }
    // Play or pause as pressed, shown at once and held over the status until the TV itself has answered: let go when it
    // agrees, or when a reading taken after the press says otherwise. Never on a timer alone, since the TV can take a few
    // seconds to say, and a glyph that flips back makes him press again (r17: two presses, and the phone said the
    // opposite of the TV). Eight seconds at most.
    private(set) var playHeld: (playing: Bool, at: Date)?
    func holdPlay(_ playing: Bool) {
        let at = Date()
        playHeld = (playing, at)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if let self, let h = self.playHeld, h.at == at { self.playHeld = nil }
        }
        // Asked again often until the TV agrees, so the clock frozen at the press moves to where the TV really stopped
        // while it's still paused, not at the next press (r19: resume jumped the clock from 0:05 to 0:09).
        Task { [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, let h = self.playHeld, h.at == at else { return }
                await self.load()
            }
        }
    }
    // The TV's ⏯: the glyph flips at once, then the key that does what the glyph now says (pause or play), never the
    // toggle, so a press made on an old picture can't do the opposite. The toggle only when it isn't known what's on.
    // The Remote's button and the build's pause flow both come here.
    func togglePlay(shown: Bool?) {
        guard let p = shown else { key("play"); return }
        holdPlay(!p)
        key(p ? "pause" : "resume")
    }
    // What a play key should say: the press, while it's held, else what the TV reports.
    func shownPlaying(_ reported: Bool?) -> Bool? { playHeld?.playing ?? reported }
    // A status that settles a held press: it agrees, or it was read on the TV after the press and still says otherwise.
    func settlePlayHold(_ s: TVStatus) {
        guard let h = playHeld, let now = s.session?.playing ?? s.music?.playing else { return }
        if now == h.playing { playHeld = nil; return }
        let read = (s.session?.sampledAt ?? s.music?.sampledAt).map { Date(timeIntervalSince1970: $0 / 1000) }
        // Only a reading taken well after the press can say it didn't land: the box takes 2.2 s, and a reading from before
        // the flip let go of the press and left a stale "paused" (r18).
        if let read, read.timeIntervalSince(h.at) > 3 { playHeld = nil }
    }
    // One answer for a song's state wherever it's shown, the Remote's mini player and Playing alike (r21: one said ended,
    // the other playing). Said to be playing but already past its end: an old report, shown stopped there.
    func songEnded(_ m: TVStatus.Music) -> Bool {
        m.duration > 0 && m.playing && m.position + Date().timeIntervalSince1970 * 1000 - m.sampledAt >= m.duration
    }
    func songPlaying(_ m: TVStatus.Music) -> Bool? { staleStatus ? nil : (songEnded(m) ? false : m.playing) }
    // Mint's song is what's on: playing, or Mint is the app in front. A film or show on the TV, playing or paused in
    // front, is never shown beside a song left over from before.
    var musicIsCurrent: Bool {
        guard let m = nowMusic, !videoIsCurrent else { return false }
        return m.playing || status?.app == "com.codex.musicwebtv"
    }
    var toast: String?
    var filmsNote: String? = "Loading your films…"
    // Browse used to be tab 4; the apps' banners lead there now.
    var tab = { let t = UserDefaults.standard.integer(forKey: "tab"); return t == 4 ? 1 : t }() { didSet { if tab != oldValue { Keyboard.dismiss() } } }
    var address: String { didSet { UserDefaults.standard.set(address, forKey: "address") } }
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastKeyAt = Date.distantPast
    @ObservationIgnored private var lastTouch = Date()
    @ObservationIgnored private var keyChain: Task<Void, Never>?
    @ObservationIgnored private var filmsLoaded = false
    @ObservationIgnored private var bannersWarm = false
    private static var cacheFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tv.json") }

    init() {
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        address = stored.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : stored
        // Open with what was last known; the live state replaces it moments later. A small file, read before the first
        // frame on purpose, so the app opens showing what it knew rather than empty.
        if let d = try? Data(contentsOf: Self.cacheFile) { status = try? JSONDecoder().decode(TVStatus.self, from: d) }
        // The apps' banners kept from last time, decoded off the main thread now, so the Remote's tiles have them early
        // without anything reading the disk while drawing.
        warmBanners()
    }
    func warmBanners() {
        let urls = (status?.apps ?? []).filter(\.hasIcon).compactMap { url("/api/tv/icon?pkg=\($0.pkg)&v=2") }
        ImageStore.shared.warm(urls)
    }
    func url(_ path: String) -> URL? { URL(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) }
    func start() {
        stop()
        #if canImport(UIKit)
        Haptics.warm()
        #endif
        // Nobody looking, nothing polled. Status steps aside just after a key, so it never competes with one.
        loops = [
            Task { [weak self] in
                while !Task.isCancelled {
                    // Not while a flick is up: every refresh redraws the pages behind it, which shows as stutter in the flick.
                    // Its control screen keeps itself current.
                    if let self, self.flicking == nil, Date().timeIntervalSince(self.lastKeyAt) > 1.5 { await self.load() }
                    // What's playing changes under you, so the Playing tab keeps closer watch.
                    // The Remote shows play/pause and what's on: every second there, as a check costs the bridge 20-400 ms
                    // (Richard, 2026-11-07: "playing and not playing dont update fast enough", "doesnt update based on
                    // whats on screen" at 5 s).
                    try? await Task.sleep(nanoseconds: self?.tab == 0 ? 1_000_000_000 : self?.tab == 2 ? 2_500_000_000 : 5_000_000_000)
                }
            },
            // Still pictures, only while the screen is on show and the live stream isn't. Never switched off by itself
            // while he's looking at it.
            Task { [weak self] in
                while !Task.isCancelled {
                    if let self, self.mirrorLive, self.mirrorViewers > 0 {
                        // The film's poster stands in for it, and a frame from before it started mustn't show after.
                        // Nor does the box record its screen during a film: it's black anyway, and the box is small.
                        if self.filmOnScreen {
                            if self.mirrorStore.image != nil { self.mirrorStore.set(nil) }
                            #if os(iOS)
                            self.live.stop()
                            #endif
                        } else {
                            self.warmMirror()
                            if !self.liveShowing { await self.loadMirror() }
                        }
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            },
        ]
        if mirrorLive && mirrorViewers > 0 { warmMirror() }
    }
    func stop() {
        loops.forEach { $0.cancel() }; loops = []
        #if os(iOS)
        live.stop()
        #endif
    }
    var liveShowing: Bool {
        #if os(iOS)
        live.showing
        #else
        false
        #endif
    }
    // The live stream started early, as the Remote comes up, so its first picture is there by the time it's looked at.
    func warmMirror() {
        #if os(iOS)
        if mirrorLive && !filmOnScreen && !flickHandoff { live.start(url("/api/tv/screen-live")) }
        #endif
    }
    // The Remote's picture of the TV coming on and off the screen.
    func mirrorShown(_ on: Bool) {
        mirrorViewers = max(0, mirrorViewers + (on ? 1 : -1))
        if on {
            warmMirror()
            if mirrorLive && !liveShowing && !flickHandoff { Task { await loadMirror() } }
        } else if mirrorViewers == 0 {
            mirrorSlot = nil
            #if os(iOS)
            live.stop(after: 5)
            #endif
        }
    }
    // One reading at a time: the loop, a key, a tab change and a send each asked for their own, overlapping, and each
    // could redraw. Whoever asks while one is on its way waits for that one.
    @ObservationIgnored private var loading: Task<Void, Never>?
    func load() async {
        if let l = loading { await l.value; return }
        let t = Task { await reload() }
        loading = t
        await t.value
        loading = nil
    }
    private func reload() async {
        guard let u = url("/api/tv/status") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 8; r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(TVStatus.self, from: d) else { if !Task.isCancelled { reachable = false }; return }
        if !reachable { reachable = true }
        #if os(iOS)
        await TVIsland.sync(s, art: islandArt(s))
        #endif
        if s != status {
            status = s
            // Every app's banner fetched once, as soon as the list first comes, so the Apps tab and the Remote's tiles
            // never wait on one.
            if !bannersWarm, let apps = s.apps, !apps.isEmpty {
                bannersWarm = true
                for a in apps where a.hasIcon { if let u = url("/api/tv/icon?pkg=\(a.pkg)&v=2") { Task { _ = await ImageStore.shared.load(u) } } }
            }
            // A start this phone sent, followed through the Mac's own word too, for when its line of news was cut off.
            if starting != nil, let last = s.lastStart, last.token == nil || last.token == starting?.token {
                if last.result == "playing" || last.result == "ok" { startPlayed() }
                else if last.result == "failed" { startFailed(tokens: [last.token].compactMap { $0 }) }
            }
            // Kept for the next launch, written off the main thread.
            if s.online { let file = Self.cacheFile; Task.detached(priority: .utility) { try? d.write(to: file, options: .atomic) } }
        }
        settlePlayHold(s)
        if staleStatus { staleStatus = false }
        PhonePlayer.shared.follow(s)
        NextUp.shared.follow(s)
    }
    // His choice, kept from one visit and one launch to the next.
    func setMirror(_ on: Bool) {
        lastTouch = Date()
        mirrorLive = on
        UserDefaults.standard.set(on, forKey: "mirrorLive")
        if on {
            warmMirror()
            Task { await loadMirror() }
        } else {
            #if os(iOS)
            live.stop()
            #endif
        }
    }
    // A still of the TV's screen. After a key, the first one taken after it, so the press shows rather than the frame
    // from before it.
    func loadMirror(after: Date? = nil) async {
        guard let u = url("/api/tv/shot" + (after.map { "?after=\(Int($0.timeIntervalSince1970 * 1000))" } ?? "")) else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 10; r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        // Decoded whole off the main thread, then handed over ready to draw. UIImage.byPreparingForDisplay, called from
        // here, set up its decoder on the main thread, which logged an error and waited on a lock each time: about a third
        // of a second blocked every 1.5 s while the still mirror ran (profiled 2026-11-06), the stall under the flick's
        // catch and much of "the app is SLOW".
        guard let i = await Task.detached(priority: .userInitiated, operation: { Self.decoded(d) }).value else { return }
        mirrorStore.set(i)
    }
    // A picture decoded now, on whatever thread calls this, so drawing it later costs nothing.
    nonisolated static func decoded(_ d: Data) -> TVImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: .zero)
        #endif
    }
    func loadFilms(force: Bool = false) async {
        if filmsLoaded && !force { return }
        guard let u = url("/api/tv/letterboxd" + (force ? "?fresh=1" : "")), let (d, resp) = try? await URLSession.shared.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { filmsNote = "Can’t reach your films. Pull down to try again."; return }
        filmsLoaded = true
        filmsNote = j["signedIn"] as? Bool == false ? "Sign in to Letterboxd on the TV." : nil
        func list(_ key: String, _ note: ([String: String]) -> String) -> [Film] {
            // A friend can log the same film twice; show it once.
            var seen = Set<String>()
            return ((j[key] as? [[String: String]]) ?? []).compactMap { r in
                guard let slug = r["film_slug"], !slug.isEmpty else { return nil }
                let f = Film(slug: slug, title: r["film_title"] ?? slug, year: r["film_year"] ?? "", poster: r["poster_url"] ?? "", note: note(r), imdb: r["imdb_id"] ?? "")
                return seen.insert(f.id).inserted ? f : nil
            }
        }
        watchlist = list("watchlist") { r in
            let n = Int(r["friends_count"] ?? "") ?? 0, a = Double(r["friends_rating_avg"] ?? "") ?? 0
            return n > 0 && a > 0 ? String(format: "★ %.1f · %d friends", a, n) : (r["film_year"] ?? "")
        }
        friends = list("friends") { r in
            let who = r["friend_name"] ?? "", rating = Double(r["rating"] ?? "") ?? 0
            return rating > 0 ? who + String(format: " ★ %.1f", rating) : who
        }
        struct Recs: Decodable { struct One: Decodable { let title, year, slug, imdb, art, why: String }; let films: [One] }
        if let d = await TVBridge.data(url("/api/tv/recs"), timeout: 10), let r = try? JSONDecoder().decode(Recs.self, from: d) {
            recommended = r.films.map { Film(slug: $0.slug, title: $0.title, year: $0.year, poster: $0.art, note: $0.why, imdb: $0.imdb) }
        }
    }
    func say(_ t: String) {
        toast = t
        toastTask?.cancel()
        toastTask = Task { [weak self] in try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { self?.toast = nil } }
    }
    func tick() {
        #if canImport(UIKit)
        Haptics.light.impactOccurred(); Haptics.light.prepare()
        #endif
    }
    private func request(_ path: String, _ body: [String: Any]) -> URLRequest? {
        guard let u = url("/api/tv/" + path), let base = URL(string: address) else { return nil }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 30
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }
    // Each key leaves the moment it's pressed, numbered, and the Mac plays them in that order. Waiting for each answer
    // before sending the next made a quick run of presses reach the TV a round trip late per press.
    func key(_ name: String, long: Bool = false, repeating: Bool = false) {
        lastKeyAt = Date(); lastTouch = Date()
        if !repeating { tick() }
        // A hold can't get ahead of the connection, so lifting your finger stops the TV promptly.
        if repeating && repeatPending { return }
        keySeq += 1
        guard var r = request("key", ["key": name, "long": long, "repeat": repeating, "seq": keySeq, "session": Self.keySession]) else { return }
        r.timeoutInterval = 3
        if repeating { repeatPending = true }
        // Keys don't wait for each other, but they do wait for text still being typed, so Enter can't beat the words.
        let typing = keyChain
        Task { [weak self] in
            await typing?.value
            defer { if repeating { self?.repeatPending = false } }
            let result = try? await URLSession.shared.data(for: r)
            if (result?.1 as? HTTPURLResponse)?.statusCode != 200, !repeating { self?.say("The TV didn’t get that") }
        }
        // Outside the chain, so a slow picture never holds up the next press. The live stream shows the press by
        // itself; without it, the first still taken after the press is asked for straight away.
        if mirrorLive && !repeating && mirrorViewers > 0 && !liveShowing {
            mirrorSoon?.cancel()
            let pressed = Date()
            mirrorSoon = Task { [weak self] in await self?.loadMirror(after: pressed) }
        }
        // With it, a press that brings no new picture says the stream has stuck, and it's joined again.
        #if os(iOS)
        if mirrorLive && !repeating && mirrorViewers > 0 && liveShowing { live.pressed() }
        #endif
    }
    // Typing into the TV: what was deleted, then what was added, in order with the keys around it. Nothing is dropped
    // for being late, or the box on the TV would end up different from the field on the phone.
    func type(deleting n: Int, adding text: String) {
        lastKeyAt = Date(); lastTouch = Date()
        let sends = Array(repeating: request("key", ["key": "del"]), count: n) + [text.isEmpty ? nil : request("text", ["text": text])]
        let before = keyChain
        keyChain = Task { [weak self] in
            await before?.value
            for case var r? in sends {
                r.timeoutInterval = 6
                let result = try? await URLSession.shared.data(for: r)
                if (result?.1 as? HTTPURLResponse)?.statusCode != 200 { self?.say("The TV didn’t get that"); return }
            }
        }
    }
    @ObservationIgnored private var repeatPending = false
    // The order keys were pressed in, and which launch of the app they came from, so the Mac can put them back in order.
    @ObservationIgnored private var keySeq = 0
    private static let keySession = UUID().uuidString.prefix(8).description
    @ObservationIgnored private var mirrorSoon: Task<Void, Never>?
    // Nothing is said when it works: what changes on the TV, or on the button pressed, says that. Only a failure is told.
    func post(_ path: String, _ body: [String: Any] = [:]) {
        guard let r = request(path, body) else { return }
        lastTouch = Date()
        Task {
            let result = try? await URLSession.shared.data(for: r)
            if (result?.1 as? HTTPURLResponse)?.statusCode != 200 { say("The TV didn’t get that") }
            else { try? await Task.sleep(nanoseconds: 800_000_000); await load() }
        }
    }
    // Links, search words, or anything else from the phone. The Mac decides where it goes.
    func send(_ text: String) {
        guard let r = request("send", ["text": text]) else { return }
        tick()
        Task {
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { say("The TV didn’t get that"); return }
            // Only a link the TV can't open needs saying, since then there's something else to do.
            if !["apple", "words", "youtube", "film", "imdb"].contains(j["kind"] as? String ?? "") { say("That link can’t open on the TV. Try AirPlay.") }
        }
    }
}

// The still mirror changes every 1.5 s. Only the mirror should redraw when it does. When the picture was taken, so an
// old one can be shown as old.
@MainActor
final class MirrorStore: ObservableObject {
    @Published private(set) var image: TVImage?
    @Published private(set) var at = Date.distantPast
    func set(_ i: TVImage?) { image = i; if i != nil { at = Date() } }
}

// A half-typed link outlives unfolding, which rebuilds the layout.
@MainActor
final class SendDraft: ObservableObject {
    static let shared = SendDraft()
    @Published var text = ""
    // For the build's real-data flows: ask the search field for the keyboard, and the first result found, as the
    // field and the results grid would offer them to a finger.
    @Published var focusRequest = 0
    var firstResult: (item: MediaItem, source: MediaSource)?
}

// Puts the keyboard away from wherever it is, for the moments that leave a field behind: a flick, a page opened, a tab.
enum Keyboard {
    @MainActor static func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

#if canImport(UIKit)
// Made once and kept warm, so a press buzzes the moment it lands rather than after the generator wakes up.
@MainActor enum Haptics {
    static let light: UIImpactFeedbackGenerator = { let g = UIImpactFeedbackGenerator(style: .light); g.prepare(); return g }()
    static func warm() { light.prepare() }
}
#endif

// The flick's whole set of touches and nothing else (§2.5a C9): lift, the one detent, charged, the impact, caught, and
// the outcome on the Remote. Each generator made once and kept warm, so the hit lands on the frame it belongs to.
@MainActor enum FlickHaptic {
    #if canImport(UIKit)
    private static let soft = { let g = UIImpactFeedbackGenerator(style: .soft); g.prepare(); return g }()
    private static let rigid = { let g = UIImpactFeedbackGenerator(style: .rigid); g.prepare(); return g }()
    private static let medium = { let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); return g }()
    private static let heavy = { let g = UIImpactFeedbackGenerator(style: .heavy); g.prepare(); return g }()
    private static let note = { let g = UINotificationFeedbackGenerator(); g.prepare(); return g }()
    static func warm() { soft.prepare(); rigid.prepare(); medium.prepare(); heavy.prepare(); note.prepare() }
    static func lift() { soft.impactOccurred(intensity: 0.5); soft.prepare() }
    static func detent() { rigid.impactOccurred(intensity: 0.45); rigid.prepare() }
    static func charged() { medium.impactOccurred(intensity: 0.8); medium.prepare() }
    static func impact() { heavy.impactOccurred(intensity: 1); heavy.prepare() }
    static func caught() { rigid.impactOccurred(intensity: 0.6); rigid.prepare() }
    static func putBack() { soft.impactOccurred(intensity: 0.6); soft.prepare() }
    static func settle() { soft.impactOccurred(intensity: 0.35); soft.prepare() }
    static func error() { note.notificationOccurred(.error); note.prepare() }
    #else
    static func warm() {}
    static func lift() {}
    static func detent() {}
    static func charged() {}
    static func impact() {}
    static func caught() {}
    static func putBack() {}
    static func settle() {}
    static func error() {}
    #endif
}
