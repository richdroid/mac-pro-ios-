import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import MediaPlayer
#endif

// Ten-second jumps in Stremio, added up. Its player takes seconds to move, so taps made meanwhile are counted, the bar
// moves by them at once, and they go to the TV together once the tapping stops. The TV answers with where the player
// really is, which the bar takes on in the same moment it lets go of that send's taps, so it never counts them twice.
@MainActor
final class SeekQueue: ObservableObject {
    static let shared = SeekQueue()
    // Taps the TV hasn't confirmed yet, sent or not, and which film they're for.
    @Published private(set) var pending = 0
    // Up once a jump has gone unconfirmed for longer than a glance, so a quick one never flickers a spinner.
    @Published private(set) var spinning = false
    // Where the player said it was after the last jump, and when. Trusted over the status for a moment, since a status
    // asked just after can still have the old spot.
    @Published private(set) var adopted: (ms: Double, at: Date)?
    private var film = ""
    private var unsent = 0
    private var generation = 0
    private var wait: Task<Void, Never>?
    private var chain: Task<Void, Never>?
    private var spin: Task<Void, Never>?
    private static let hold: TimeInterval = 3
    private static func key(_ s: TVStatus.Session?) -> String { s?.description.joined(separator: "\n") ?? "" }
    // How far the bar is ahead of where the TV is known to be, in ms.
    func offset(for s: TVStatus.Session?) -> Double { Self.key(s) == film ? Double(pending) * 10000 : 0 }
    // The player's own answer, carried on while it plays, for as long as it's held.
    func held(for s: TVStatus.Session?, at date: Date) -> Double? {
        guard Self.key(s) == film, let a = adopted, date.timeIntervalSince(a.at) < Self.hold else { return nil }
        return a.ms + (s?.playing == true ? date.timeIntervalSince(a.at) * 1000 : 0)
    }
    // A jump to a spot, answered by the TV with where it landed.
    func adopt(_ ms: Double, for s: TVStatus.Session?) {
        let k = Self.key(s)
        if k != film { reset(k) }
        adopted = (ms, Date())
    }
    private func reset(_ k: String) {
        film = k; pending = 0; unsent = 0; generation += 1; adopted = nil
        spin?.cancel(); spinning = false
    }
    func add(_ step: Int, for s: TVStatus.Session?, model: TVModel) {
        let k = Self.key(s)
        if k != film { reset(k) }
        model.tick()
        pending += step; unsent += step
        settled()
        wait?.cancel()
        wait = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { self?.flush(model) }
        }
    }
    // The spinner waits a beat after the first unconfirmed tap, and goes as soon as nothing is left unconfirmed.
    private func settled() {
        if pending == 0 { spin?.cancel(); spin = nil; if spinning { spinning = false }; return }
        guard spin == nil, !spinning else { return }
        spin = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.spin = nil
            if self.pending != 0 { self.spinning = true }
        }
    }
    // One send for the lot, after the one before it has landed. The bridge takes up to a minute's worth at a time.
    private func flush(_ model: TVModel) {
        while unsent != 0 {
            let n = max(-60, min(60, unsent)), gen = generation, before = chain, session = model.status?.session
            unsent -= n
            chain = Task { [weak self] in
                await before?.value
                var answer: [String: Any]?
                var failed = false
                // A slow TV gets two more goes before it counts as a failure.
                for attempt in 0..<3 {
                    do {
                        let d = try await TVBridge.post("player-seek", ["steps": n], timeout: 30)
                        answer = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                        break
                    } catch is TVBridge.Slow where attempt < 2 {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                    } catch { failed = true; break }
                }
                guard let self, self.generation == gen else { return }
                if failed {
                    // Back to where the TV really is, at once, with the feel of a no.
                    Haptic.fire(.fail)
                    self.pending -= n
                    model.say("Couldn’t move it")
                } else if let ms = (answer?["position"] as? NSNumber)?.doubleValue {
                    // Where it landed, and this send's taps let go, together. Later taps stay on top of it.
                    self.adopted = (ms, Date())
                    self.pending -= n
                    Task { await model.load() }
                } else {
                    await model.load()
                    if self.generation == gen { self.pending -= n }
                }
                self.settled()
            }
        }
    }
}

// The series a Stremio player is on, and the episode after the one on screen, ready to flick.
@MainActor
final class NextUp: ObservableObject {
    static let shared = NextUp()
    // The show on, and the episode of it that's playing, for its episode list over the Remote and Playing.
    struct Series: Equatable { let imdb: String, title: String, art: String, current: String }
    @Published private(set) var next: MediaItem?
    @Published private(set) var previous: MediaItem?
    @Published private(set) var series: Series?
    private var key = ""
    private static var metas: [String: StremioMeta] = [:]
    static func remember(_ m: StremioMeta, for imdb: String) { metas[imdb] = m }
    static func meta(_ imdb: String) async -> StremioMeta? {
        if let m = metas[imdb] { return m }
        // One request per show, whoever asks while it's on its way.
        if let t = asking[imdb] { return await t.value }
        let t = Task { () -> StremioMeta? in
            guard let d = await TVBridge.data(TVBridge.url("/api/tv/stremio-meta?type=series&id=\(imdb)"), timeout: 15) else { return nil }
            return await Task.detached(priority: .userInitiated) { () -> StremioMeta? in
                guard let m = try? JSONDecoder().decode(StremioMeta.self, from: d), !m.episodes.isEmpty else { return nil }
                return m
            }.value
        }
        asking[imdb] = t
        let m = await t.value
        asking[imdb] = nil
        if let m { metas[imdb] = m }
        return m
    }
    private static var asking: [String: Task<StremioMeta?, Never>] = [:]
    static func cached(_ imdb: String) -> StremioMeta? { metas[imdb] }
    // A show's Continue watching tile on screen: its episodes asked for now, so the show's page (and the Remote's and
    // Playing's lists, if it's put on) find them waiting rather than grey for a few seconds (review of dfd490e, speed 4).
    static func prefetch(_ item: MediaItem) {
        guard let ref = item.stremioRef, ref.type == "series", metas[ref.imdb] == nil, asking[ref.imdb] == nil else { return }
        Task { _ = await meta(ref.imdb) }
    }
    // In order, specials left out unless that's where you are.
    static func after(_ e: StremioEpisode, in episodes: [StremioEpisode]) -> StremioEpisode? {
        let order = episodes.filter { $0.season > 0 || e.season == 0 }.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        guard let i = order.firstIndex(of: e), i + 1 < order.count else { return nil }
        return order[i + 1]
    }
    nonisolated static func link(_ imdb: String, _ video: String) -> String { "stremio:///detail/series/\(imdb)/" + video.replacingOccurrences(of: ":", with: "%3A") }
    // Asked again after a flick, which may have changed what's known.
    func forget() { key = "" }
    // Everything known about the show on, dropped, so it's worked out again from nothing: the build's realnext pose, to
    // show ⏭ pressed before the next episode is known (r21: forgetting only the key left `series` and `next` set).
    func forgetAll() {
        key = ""
        if series != nil { series = nil }
        if next != nil { next = nil }
        if previous != nil { previous = nil }
        Self.metas.removeAll()
    }
    private struct SearchAnswer: Decodable { let rows: [MediaRow] }
    func follow(_ s: TVStatus?) {
        guard let p = s?.session, p.pkg == "com.stremio.one", p.description.count > 1 || p.seasonEpisode != nil else {
            key = ""
            if next != nil { next = nil }
            if previous != nil { previous = nil }
            if series != nil { series = nil }
            return
        }
        let k = p.description.joined(separator: "\n") + "\(p.season ?? -1)/\(p.episode ?? -1)"
        guard k != key else { return }
        key = k
        Task { [weak self] in
            let found = await Self.resolve(p)
            guard let self, self.key == k else { return }
            // Not found yet (Stremio's rows not in, say): asked again on the next reading rather than given up on.
            if found == nil { self.key = "" }
            if found?.next != self.next { self.next = found?.next }
            if found?.previous != self.previous { self.previous = found?.previous }
            if found?.series != self.series { self.series = found?.series }
        }
    }
    // An episode of the show on, as a card to flick: the one after, the one before, or any picked from its list.
    static func item(_ s: Series, _ e: StremioEpisode) -> MediaItem {
        MediaItem(title: s.title, subtitle: "S\(e.season) E\(e.episode) · \(e.name)", art: s.art, id: link(s.imdb, e.id), kind: "series")
    }
    // The one before, in order, specials left out unless that's where you are.
    static func before(_ e: StremioEpisode, in episodes: [StremioEpisode]) -> StremioEpisode? {
        let order = episodes.filter { $0.season > 0 || e.season == 0 }.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        guard let i = order.firstIndex(of: e), i > 0 else { return nil }
        return order[i - 1]
    }
    private static func resolve(_ p: TVStatus.Session) async -> (next: MediaItem?, previous: MediaItem?, series: Series)? {
        let show = p.showName, on = p.description.count > 1 ? p.description[1] : ""
        // The same show by name, exactly ("You" is not "Young Sheldon"; r21).
        func same(_ t: String) -> Bool { TVStatus.Session.sameName(show, t) }
        // Which series: one flicked from here, or one on Stremio's own Continue watching.
        var imdb: String?, title = show, art = "", known: String?
        if let r = RecentFlicks.shared.list.first(where: { $0.type == "series" && same($0.title) }) {
            imdb = r.imdb; title = r.title; art = r.art; known = r.video
        } else if let i = BrowseStore.shared(.stremio).rows.first(where: { $0.title == "Continue watching" })?.items.first(where: { $0.stremioRef?.type == "series" && same($0.title) }), let ref = i.stremioRef {
            imdb = ref.imdb; title = i.title; art = i.art; known = ref.video
        } else if let i = BrowseStore.shared(.stremio).rows.flatMap(\.items).first(where: { $0.stremioRef != nil && same($0.title) }), let ref = i.stremioRef {
            // Any of Stremio's own rows naming the show, whatever kind its card says it is: the real bridge's
            // "Show - S02E03 - Title" plus its season and episode is enough to find the rest (r18).
            imdb = ref.imdb; title = i.title; art = i.art; known = ref.video
        }
        // Nowhere on this phone yet: Stremio's own search by the show's name (r19: "Sample Series" never resolved, so ⏭
        // dimmed and the episode line never came).
        if imdb == nil, !show.isEmpty, p.seasonEpisode != nil,
           let d = await TVBridge.data(TVBridge.url(MediaSource.stremio.endpoint(show)), timeout: 10),
           let a = try? JSONDecoder().decode(SearchAnswer.self, from: d),
           let i = a.rows.flatMap(\.items).first(where: { $0.stremioRef?.type == "series" && same($0.title) }), let ref = i.stremioRef {
            imdb = ref.imdb; title = i.title; art = i.art
        }
        guard let imdb, let meta = await meta(imdb) else { return nil }
        // The episode on screen by its name in what the TV reports, the longest name that fits, else the one last sent.
        let named = meta.episodes.filter { $0.name.count > 2 && on.localizedCaseInsensitiveContains($0.name) }.max { $0.name.count < $1.name.count }
        // The Mac's own season and episode first, when it says them.
        let said = p.seasonEpisode.flatMap { se in meta.episodes.first { $0.season == se.season && $0.episode == se.episode } }
        guard let current = said ?? named ?? meta.episodes.first(where: { $0.id == known }) else { return nil }
        let found = Series(imdb: imdb, title: title, art: art, current: current.id)
        return (after(current, in: meta.episodes).map { item(found, $0) }, before(current, in: meta.episodes).map { item(found, $0) }, found)
    }
}

// What was flicked from this phone lately, kept on the phone, newest first.
struct RecentFlick: Codable, Identifiable, Hashable {
    let title: String, art: String, imdb: String, type: String
    var video: String?
    var episode: String?
    var at: Date
    var id: String { imdb }
    var item: MediaItem {
        let link = video.map { NextUp.link(imdb, $0) } ?? imdb
        return MediaItem(title: title, subtitle: episode ?? when, art: art, id: link, kind: type)
    }
    // A day rather than a count of minutes, which would go stale while the page is open.
    var when: String {
        let c = Calendar.current
        if c.isDateInToday(at) { return "Today" }
        if c.isDateInYesterday(at) { return "Yesterday" }
        if let d = c.dateComponents([.day], from: c.startOfDay(for: at), to: c.startOfDay(for: Date())).day, d < 7 { return at.formatted(.dateTime.weekday(.wide)) }
        return at.formatted(.dateTime.day().month())
    }
}
@MainActor
final class RecentFlicks: ObservableObject {
    static let shared = RecentFlicks()
    @Published private(set) var list: [RecentFlick]
    init() { list = (UserDefaults.standard.data(forKey: "recentFlicks")).flatMap { try? JSONDecoder().decode([RecentFlick].self, from: $0) } ?? [] }
    // A series keeps only where it's got to; anything flicked again moves to the front.
    func add(_ f: RecentFlick) {
        list = Array(([f] + list.filter { $0.imdb != f.imdb }).prefix(8))
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: "recentFlicks") }
    }
}

// The song this phone is playing, for when it's the one AirPlaying to the TV: then its own player is the one to drive.
@MainActor
final class PhonePlayer: ObservableObject {
    static let shared = PhonePlayer()
    struct Song: Equatable { var title: String, artist: String, album: String, duration: Double, id: UInt64 }
    @Published private(set) var song: Song?
    @Published private(set) var art: TVImage?
    @Published private(set) var playing = false
    @Published private(set) var drives = false
    private var last: TVStatus?
    private var asked = false
    private var watching = false
    var position: Double {
        #if os(iOS)
        MPMusicPlayerController.systemMusicPlayer.currentPlaybackTime
        #else
        0
        #endif
    }
    private static func musicAirPlay(_ s: TVStatus?) -> Bool { s?.airplay?.active == true && s?.airplay?.kind == "music" }
    func follow(_ s: TVStatus?) {
        last = s
        guard Self.musicAirPlay(s) else { if drives { drives = false }; return }
        #if os(iOS)
        // Asked the first time it's needed: music going from a phone to the TV.
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            if !asked { asked = true; MPMediaLibrary.requestAuthorization { _ in Task { @MainActor in PhonePlayer.shared.follow(PhonePlayer.shared.last) } } }
            return
        }
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        watch()
        #endif
        refresh()
    }
    func refresh() {
        #if os(iOS)
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        let player = MPMusicPlayerController.systemMusicPlayer, item = player.nowPlayingItem
        let next = item.map { Song(title: $0.title ?? "", artist: $0.artist ?? "", album: $0.albumTitle ?? "", duration: $0.playbackDuration, id: $0.persistentID) }
        if next != song { song = next; art = item?.artwork?.image(at: CGSize(width: 600, height: 600)) }
        let p = player.playbackState == .playing
        if p != playing { playing = p }
        #endif
        let tv = last?.music?.title ?? ""
        let same = song.map { !tv.isEmpty && $0.title.caseInsensitiveCompare(tv) == .orderedSame } ?? false
        // Once it's the phone's it stays so through a skip, which the phone shows before the TV does.
        let now = Self.musicAirPlay(last) && song != nil && (same || drives)
        if now != drives { drives = now }
    }
    #if os(iOS)
    private func watch() {
        guard !watching else { return }
        watching = true
        MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications()
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in PhonePlayer.shared.refresh() } }
        }
    }
    #endif
    func toggle() {
        #if os(iOS)
        let player = MPMusicPlayerController.systemMusicPlayer
        if playing { player.pause() } else { player.play() }
        // The button answers at once; the player's own word follows.
        playing.toggle()
        #endif
    }
    func next() {
        #if os(iOS)
        MPMusicPlayerController.systemMusicPlayer.skipToNextItem()
        #endif
    }
    // Back to the start of the song first, as any player does, then to the one before.
    func previous() {
        #if os(iOS)
        let player = MPMusicPlayerController.systemMusicPlayer
        if player.currentPlaybackTime > 3 { player.skipToBeginning() } else { player.skipToPreviousItem() }
        #endif
    }
    func seek(to seconds: Double) {
        #if os(iOS)
        MPMusicPlayerController.systemMusicPlayer.currentPlaybackTime = seconds
        #endif
    }
}

// Whether any AirPlay device is in reach. Away from home there's none, so nothing offers AirPlay then.
@MainActor
final class AirPlayReach: ObservableObject {
    static let shared = AirPlayReach()
    @Published private(set) var inReach = false
    private let detector = AVRouteDetector()
    private var users = 0
    init() {
        NotificationCenter.default.addObserver(forName: .AVRouteDetectorMultipleRoutesDetectedDidChange, object: detector, queue: .main) { _ in
            Task { @MainActor in AirPlayReach.shared.update() }
        }
    }
    private func update() { let r = detector.multipleRoutesDetected; if r != inReach { inReach = r } }
    // Looking costs battery, so only while something on screen needs to know.
    func begin() { users += 1; detector.isRouteDetectionEnabled = true; update() }
    func end() { users = max(0, users - 1); if users == 0 { detector.isRouteDetectionEnabled = false } }
    // The first look takes the detector a moment.
    func check() async -> Bool {
        begin(); defer { end() }
        for _ in 0..<20 where !inReach { try? await Task.sleep(nanoseconds: 100_000_000); update() }
        return inReach
    }
}

// A cover that crossfades to the next once that has loaded, rather than swapping in a frame or flashing its placeholder.
struct Cover<Placeholder: View>: View {
    let url: URL?
    // The phone's own picture, which has no address, and what it's a picture of.
    var image: TVImage? = nil
    var key: String? = nil
    var mode: ContentMode = .fit
    // Rounded at the picture's own edges, which for a fitted picture aren't the frame's.
    var radius: CGFloat = 0
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var shown: (id: String, image: TVImage)?
    var wanted: String { key ?? url?.absoluteString ?? "" }
    var body: some View {
        // The first time, whatever's already to hand, with no fade.
        let now = shown ?? (image ?? ImageStore.shared.cached(url)).map { (wanted, $0) }
        ZStack {
            if let now {
                Image(tv: now.image).resizable().aspectRatio(contentMode: mode)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .id(now.id).transition(.opacity)
            }
            else { placeholder().transition(.opacity) }
        }
        .task(id: wanted) {
            var next = image
            if next == nil, let url { next = await ImageStore.shared.load(url) }
            guard !Task.isCancelled, shown?.id != wanted else { return }
            if shown == nil, next != nil, now != nil { shown = next.map { (wanted, $0) }; return }
            withAnimation(.easeInOut(duration: 0.25)) { shown = next.map { (wanted, $0) } }
        }
    }
}

// The bar to slide along or tap, for a film on the TV or a song on this phone. In whatever units it's given.
struct ScrubBar: View {
    let value: Double?
    let total: Double
    var enabled = true
    var busy = false
    // Where the TV is known to be, when the bar is ahead of it by jumps on their way, and whether to show they're slow.
    var confirmed: Double? = nil
    var spinning = false
    // Where the finger is, while it's on the bar.
    @Binding var scrub: Double?
    // A tick under the finger every this much.
    var tickEvery: Double
    // The time under the finger, in a bubble that follows it while it slides.
    var label: ((Double) -> String)? = nil
    let commit: (Double) -> Void
    @State private var across: Bool?
    var body: some View {
        GeometryReader { g in
            // A player's bar: thick enough to see from arm's length, and thicker still under the finger.
            let thick: CGFloat = scrub == nil ? 8 : 14
            let at = { (x: CGFloat) in total * min(1, max(0, Double(x / max(g.size.width, 1)))) }
            ProgressTrack(fraction: total > 0 ? (scrub ?? value).map { $0 / total } : nil, thick: thick, fill: busy ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(TVLook.accent),
                          confirmed: total > 0 && scrub == nil ? confirmed.map { $0 / total } : nil, spinning: spinning && scrub == nil)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: thick)
                .contentShape(Rectangle())
                // Only a sideways slide moves it, so scrolling the page past it never does.
                .gesture(DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        guard enabled else { return }
                        if across == nil { across = abs(v.translation.width) > abs(v.translation.height) }
                        if across == true { scrub = at(v.location.x) }
                    }
                    .onEnded { _ in
                        if across == true, let t = scrub { commit(t) }
                        scrub = nil; across = nil
                    })
                .onTapGesture { p in if enabled { commit(at(p.x)) } }
                .overlay(alignment: .topLeading) {
                    if let label, let t = scrub, total > 0 {
                        let x = g.size.width * CGFloat(min(1, max(0, t / total)))
                        Text(label(t)).font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                            .fixedSize()
                            .position(x: min(max(x, 28), max(g.size.width - 28, 28)), y: -14)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: scrub == nil)
        }
        .frame(height: 28)
        .haptic(.tick, trigger: scrub.map { Int($0 / tickEvery) }, when: { $0 != nil && $1 != nil })
    }
}

// Where the bar will be, before there's anything to show on it: the same height, an empty track, no numbers. A note
// can say what the TV is doing meanwhile.
struct ProgressPlaceholder: View {
    var note: String? = nil
    var body: some View {
        VStack(spacing: 0) {
            ProgressTrack(fraction: nil).frame(height: 28)
            Text(note ?? "0:00").font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(TVLook.accent).opacity(note == nil ? 0 : 1)
                .contentTransition(.opacity)
                .padding(.top, -5)
        }
        .accessibilityHidden(note == nil)
    }
}

// A round glass button that does something here, rather than press a key on the TV.
// The transport's and the pad's keys: glass tinted with the page's own wall colour, one value for every key on the page,
// so a row reads as one set over any art and belongs to the page (purple glass on Mint, the poster's tone on a film).
// Clear glass took whatever lay under each key, so over a film ⏮ looked red and ⏭ purple; a neutral charcoal made them
// dead holes on Mint's purple (gate 276, item 10, the designer's ruling).
struct KeyGlass: ViewModifier {
    @Environment(TVModel.self) var model
    @ObservedObject private var store = AmbienceStore.shared
    func body(content: Content) -> some View {
        let wall = model.mood ?? store.band ?? Color(hex: 0x4A1A5C)
        // 80 %: at half, a wall of several colours still came through each key (third pass, the YouTube wall).
        // And a solid disc of that colour under the key's face, so no wall, however busy, reaches through (fourth pass).
        let tone = wall.mix(with: .black, by: 0.45)
        content.background(Circle().fill(tone))
            .glassEffect(.regular.tint(tone.opacity(0.8)).interactive(), in: Circle())
    }
}
extension View { func keyGlass() -> some View { modifier(KeyGlass()) } }
struct GlassButton: View {
    @Environment(TVModel.self) var model
    let icon: String, label: String
    var size: CGFloat = 54
    let action: () -> Void
    var body: some View {
        Button { model.tick(); action() } label: {
            Image(systemName: icon).font(.system(size: size * 0.36, weight: .medium)).frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain).keyGlass().accessibilityLabel(label)
    }
}

// Tapping a tab's button while on it: the tab's page goes back to its top. Each scrolling page on a tab takes this on.
private struct BackToTopKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues { var backToTop: Int { get { self[BackToTopKey.self] } set { self[BackToTopKey.self] = newValue } } }
private struct BackToTop: ViewModifier {
    @Environment(\.backToTop) private var top
    @Environment(\.pageScroll) private var pageScroll
    var posed = true
    @State private var position = ScrollPosition(edge: .top)
    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            // How far the page has scrolled, for its title to go up with it.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                if let pageScroll, abs(pageScroll.y - y) > 0.25 { pageScroll.y = y }
            }
            // Every tab's scrolling page takes this, so it's where the page's top fade goes too, and where it says it's moving.
            .topFade()
            .modifier(ScrollMoving())
            .onChange(of: top) { _, _ in withAnimation(.snappy) { position.scrollTo(edge: .top) } }
            // Animated, like a drag, so the bar follows it and folds the title as a real scroll would.
            .task { if posed { await PoseScroll.apply { position.scrollTo(y: $0) } } }
    }
}
// Unfolded, the side that isn't the page's list (Status's picture of the box) passes false, so the build's scrolled
// shot has one pane scrolled and the other not, which is when a band under the bar would differ between them.
extension View { func backToTop(posed: Bool = true) -> some View { modifier(BackToTop(posed: posed)) } }
// The build's shots of a page scrolled a little way ("-scroll 40"), to show what sits under the bar then.
enum PoseScroll {
    static let offset: CGFloat? = { let v = UserDefaults.standard.double(forKey: "scroll"); return v > 0 ? v : nil }()
    // Asked again as the page fills: at 0.9 s it was often still too short to scroll, so the shot stayed at the top (r17).
    @MainActor static func apply(_ to: (CGFloat) -> Void) async {
        guard let y = offset else { return }
        for wait in [900, 1600, 2500] as [UInt64] {
            try? await Task.sleep(nanoseconds: wait * 1_000_000)
            if Task.isCancelled { return }
            withAnimation { to(y) }
        }
    }
}
private struct PoseScrolled: ViewModifier {
    @State private var position = ScrollPosition(edge: .top)
    func body(content: Content) -> some View {
        if let y = PoseScroll.offset {
            content.scrollPosition($position).task { _ = y; await PoseScroll.apply { position.scrollTo(y: $0) } }
        } else { content }
    }
}
extension View { func poseScroll() -> some View { modifier(PoseScrolled()) } }

// A whole row as its own page, opened from its heading. As a value, so tapping the tab again can close it.
enum RowRoute: Hashable {
    case media(MediaRow, MediaSource)
    case films(String, [Film])
    // A title's details, pushed like any page, with the system's Back (Richard, 2026-11-08, folded, a show's details:
    // "looks fucked doesnt go edge to edge and no back button"; it was a sheet, drawn as an inset card with no Back).
    case info(MediaItem, MediaSource)
    @ViewBuilder var page: some View {
        switch self {
        case .media(let row, let source): MediaList(row: row, source: source)
        case .films(let title, let films): FilmList(title: title, films: films)
        case .info(let item, let source): TitleInfoPage(item: item, source: source)
        }
    }
}

// ⏮ in Stremio, as any player does it: back to the start of the episode or film, and pressed again near the start, the
// episode before, when there is one. A film only ever goes back to its start. Through the same seek as Start over.
@MainActor
enum StremioBack {
    static func press(_ model: TVModel) {
        guard let s = model.status?.session else { return }
        let q = SeekQueue.shared, now = Date()
        var at = q.held(for: s, at: now) ?? (s.position ?? 0)
        if q.held(for: s, at: now) == nil, s.playing, let t = s.sampledAt { at += max(0, now.timeIntervalSince1970 * 1000 - t) }
        at += q.offset(for: s)
        if at < 10000, let prev = NextUp.shared.previous {
            model.flick(FlickTarget(item: prev, source: .stremio, ready: true, autoplay: true))
            return
        }
        // The bar is at the start the moment it's pressed, and held there until the player says where it landed.
        q.adopt(0, for: s)
        Task {
            do {
                let d = try await TVBridge.post("player-seek-to", ["ms": 0], timeout: 60)
                if let ms = ((try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["position"] as? NSNumber)?.doubleValue { q.adopt(ms, for: s) }
            } catch {
                Haptic.fire(.fail)
                model.say("Couldn’t go back to the start")
            }
            await model.load()
        }
    }
}

// What Stremio's catalogue knows of each episode beyond the bridge's list: its own description and its running time,
// and the show's running time for episodes without one. Asked once a show, in the background, and kept.
@MainActor
enum SeriesInfo {
    struct Info { var about: [String: String] = [:], minutes: [String: Int] = [:], show: Int? }
    private static var known: [String: Info] = [:]
    static func cached(_ imdb: String) -> Info? { known[imdb] }
    static func load(_ imdb: String) async -> Info? {
        if let i = known[imdb] { return i }
        guard let d = await TVBridge.data(URL(string: "https://v3-cinemeta.strem.io/meta/series/\(imdb).json"), timeout: 10, cached: true) else { return nil }
        let info = await Task.detached(priority: .utility) { parse(d) }.value
        if let info { known[imdb] = info }
        return info
    }
    // "2h 3min", "123 min", "22": minutes.
    nonisolated static func minutes(_ t: Any?) -> Int? {
        if let n = t as? NSNumber { return n.intValue > 0 ? n.intValue : nil }
        guard let t = t as? String else { return nil }
        func number(before unit: String) -> Int {
            guard let r = t.range(of: "\\d+\\s*" + unit, options: .regularExpression) else { return 0 }
            return Int(t[r].prefix { $0.isNumber }) ?? 0
        }
        let h = number(before: "h"), m = number(before: "min")
        if h + m > 0 { return h * 60 + m }
        return Int(t.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }
    nonisolated private static func parse(_ d: Data) -> Info? {
        guard let meta = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["meta"] as? [String: Any] else { return nil }
        var info = Info(show: minutes(meta["runtime"]))
        for v in (meta["videos"] as? [[String: Any]]) ?? [] {
            guard let id = v["id"] as? String else { continue }
            if let o = (v["overview"] as? String) ?? (v["description"] as? String), !o.isEmpty { info.about[id] = o }
            if let m = minutes(v["runtime"]) { info.minutes[id] = m }
        }
        return info
    }
}

extension StremioEpisode {
    // Its own name, without the "Episode 2" a catalogue puts in front of it or in place of one (gate 276).
    var ownName: String? { Wording.episodeName(name, number: episode) }
}

// MARK: - Seasons as a pivot (Richard, 2026-11-14: "swiping between seasons a la zune")
// How far a finger has pulled the episode list sideways, shared so the headers slide along in step with the rows even where
// the headers are held apart from them (the sheet over the Remote).
@Observable @MainActor final class SeasonSwipe {
    static let shared = SeasonSwipe()
    var dx: CGFloat = 0
    // The last moment a finger was pulling sideways: a row lifted at the end of that pull is the pull's, never a tap (a button
    // fires on any release inside it, however far the finger travelled).
    var pulledAt = Date.distantPast
    // Which way the season on is leaving: with the next one, forward.
    var forward = true
    var justPulled: Bool { Date().timeIntervalSince(pulledAt) < 0.45 }
}
// The season headers as a Zune pivot: the one he's on large and bright in the middle, the seasons either side of it
// peeking in at the edges, dimmed and cut by the edge on purpose. A tap on one moves there; swiping the episodes moves
// them along (SeasonSwipeRows). Each landing is a tick.
struct SeasonPivot: View {
    let seasons: [Int]
    @Binding var selected: Int
    // The big title's size; the sheet's header, under a show name, is smaller so it never outranks it.
    var size: CGFloat = 26
    var swipe = SeasonSwipe.shared
    @State private var widths: [Int: CGFloat] = [:]
    @State private var span: CGFloat = 0
    static func name(_ s: Int) -> String { s == 0 ? "Specials" : "Season \(s)" }
    static func move(_ seasons: [Int], _ selected: Binding<Int>, to s: Int) {
        guard s != selected.wrappedValue, seasons.contains(s) else { return }
        Haptic.fire(.tick)
        let from = seasons.firstIndex(of: selected.wrappedValue) ?? 0, to = seasons.firstIndex(of: s) ?? 0
        // The direction is set first, a turn before the change, so the rows that leave know which way to go.
        SeasonSwipe.shared.forward = to > from
        Task { @MainActor in withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { selected.wrappedValue = s } }
    }
    private let gap: CGFloat = 18, small: CGFloat = 0.62
    private var height: CGFloat { size * 1.5 }
    private func width(_ i: Int) -> CGFloat { (widths[seasons[i]] ?? size * 3.2) }
    // Each title's middle and size with season `k` chosen: it in the middle at full size, the one either side with its
    // middle near the edge (the edge cuts about a fifth of it), the rest beyond at the small size's own spacing.
    private func layout(_ k: Int) -> [(x: CGFloat, scale: CGFloat)] {
        seasons.indices.map { i in
            if i == k { return (span / 2, 1) }
            var x = span / 2
            let step = i > k ? 1 : -1
            var j = k
            while j != i {
                let n = j + step
                let near = abs(n - k) == 1
                let a = j == k ? width(j) : width(j) * small, bw = width(n) * small
                let d = near ? max((a + bw) / 2 + gap, span / 2 - bw * 0.2 + (j == k ? 0 : 0)) : (a + bw) / 2 + gap
                x += CGFloat(step) * (near ? d : d)
                j = n
            }
            return (x, small)
        }
    }
    var body: some View {
        let k = seasons.firstIndex(of: selected) ?? 0
        let f = span > 0 ? max(-1, min(1, -swipe.dx / span)) : 0
        let n = f > 0 ? k + 1 : k - 1
        let t = seasons.indices.contains(n) ? abs(f) : 0
        let here = layout(k), there = seasons.indices.contains(n) ? layout(n) : here
        ZStack {
            ForEach(Array(seasons.enumerated()), id: \.element) { i, s in
                let x = here[i].x + (there[i].x - here[i].x) * t
                let sc = here[i].scale + (there[i].scale - here[i].scale) * t
                let lit = (sc - small) / (1 - small)
                Text(Self.name(s)).font(.system(size: size, weight: .bold)).lineLimit(1).fixedSize()
                    .foregroundStyle(.white.opacity(0.38 + 0.62 * lit))
                    .scaleEffect(sc * (size >= 26 ? 1.15 : 1))
                    .background(GeometryReader { g in Color.clear.onAppear { widths[s] = g.size.width }.onChange(of: g.size.width) { _, w in widths[s] = w } })
                    .padding(.vertical, 12).contentShape(Rectangle())
                    .position(x: x, y: height / 2)
                    .accessibilityElement().accessibilityLabel(Self.name(s))
                    .accessibilityAddTraits(i == k ? [.isButton, .isSelected, .isHeader] : .isButton)
                    .onTapGesture { Self.move(seasons, $selected, to: s) }
            }
        }
        .frame(maxWidth: .infinity).frame(height: max(height, 44))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { span = $0 }
        // The edge fades the peeking titles out instead of cutting a letter square.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07), .init(color: .black, location: 0.93), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Seasons")
    }
}
// The episodes of the season on: they follow the finger as it pulls, the headers slide in step, and let go past a third of
// the way or fast, the season on leaves the way the finger went and the next comes in behind it, with a tick.
struct SeasonSwipeRows: ViewModifier {
    let seasons: [Int]
    @Binding var season: Int
    var swipe = SeasonSwipe.shared
    @GestureState private var active = false
    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
                .id(season)
                .transition(.asymmetric(insertion: .move(edge: swipe.forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: swipe.forward ? .leading : .trailing).combined(with: .opacity)))
        }
        .offset(x: swipe.dx * 0.6)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .updating($active) { _, s, _ in s = true }
                .onChanged { g in
                    guard ShelfHand.shared.item == nil, seasons.count > 1 else { return }
                    guard abs(g.translation.width) > abs(g.translation.height) * 1.4 else { if swipe.dx != 0 { swipe.dx = 0 }; return }
                    swipe.pulledAt = Date()
                    let k = seasons.firstIndex(of: season) ?? 0
                    // Past either end, it gives, but only a little.
                    let blocked = (g.translation.width > 0 && k == 0) || (g.translation.width < 0 && k == seasons.count - 1)
                    swipe.dx = blocked ? g.translation.width * 0.2 : g.translation.width
                }
                .onEnded { g in
                    if abs(g.translation.width) > 16 { swipe.pulledAt = Date() }
                    defer { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { swipe.dx = 0 } }
                    guard ShelfHand.shared.item == nil, seasons.count > 1, abs(g.translation.width) > abs(g.translation.height) * 1.4 else { return }
                    let k = seasons.firstIndex(of: season) ?? 0
                    let far = abs(g.predictedEndTranslation.width) > 140 || abs(g.translation.width) > 70
                    guard far else { return }
                    let to = g.translation.width < 0 ? k + 1 : k - 1
                    if seasons.indices.contains(to) { SeasonPivot.move(seasons, $season, to: seasons[to]) }
                }
        )
        // A pull the scroll view took over lets go without an end: the headers and rows come home all the same.
        .onChange(of: active) { _, on in if !on, swipe.dx != 0 { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { swipe.dx = 0 } } }
    }
}

// An episode's row, held anywhere on it, lifts its picture and throws it to the TV: the stream he'd most likely pick, as
// a shelf's card sends. The tap stays as it was.
struct EpisodeFlick: ViewModifier {
    let item: MediaItem?
    var onThrow: (() -> Void)?
    var onTap: (() -> Void)?
    @State private var place = FrameBox()
    func body(content: Content) -> some View {
        if let item {
            content.measured(place)
                .modifier(ShelfFlick(item: item, source: .stremio, width: 56, rect: { [place] in
                    // The picture that comes up is the poster's size, at the row's leading edge.
                    let r = place.rect ?? .zero
                    return CGRect(x: r.minX + 8, y: r.midY - 42, width: 56, height: 84)
                }, onThrow: onThrow, onTap: onTap))
        } else { content }
    }
}

// One episode list for everywhere a show is picked from: the series page, and over the Remote and Playing while it's on.
// Seasons as numbers after the word, then the episodes: a still, its number and name, how long it runs, a tick once
// watched, and the bar of how far in on the one he's on. The list scrolls itself to that one.
struct EpisodePicker: View {
    let episodes: [StremioEpisode]
    @Binding var season: Int
    // The one he's on, what to call it ("Resume", "Up next", "Playing"), and how far into it.
    let current: String?
    let currentLabel: String
    var progress: Double?
    // The one after it, marked "Up next", while one is playing.
    var after: String? = nil
    var info: SeriesInfo.Info?
    // The row that's on its way to the TV, with the light running round it.
    var busy: String?
    let choose: (StremioEpisode) -> Void
    // Every row lifts and throws to the TV like a shelf's card: what it sends, and, on the flick page itself, the page's
    // own throw for it.
    var flickItem: ((StremioEpisode) -> MediaItem)? = nil
    var onThrow: ((StremioEpisode) -> Void)? = nil
    // The season chips and the rows, or one of them, for a list whose chips stay put over its scrolling rows.
    enum Part { case all, header, rows }
    var part = Part.all
    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    var currentEpisode: StremioEpisode? { current.flatMap { id in episodes.first { $0.id == id } } }
    // Before the one he's on, in order, he's seen; the one he's on once it's all but done.
    func watched(_ e: StremioEpisode) -> Bool {
        guard let c = currentEpisode, e.season > 0 else { return false }
        if e == c { return currentLabel != "Playing" && (progress ?? 0) > 0.9 }
        return (e.season, e.episode) < (c.season, c.episode)
    }
    var header: some View {
        // One season has nothing to swipe to: its name stands alone, still large.
        SeasonPivot(seasons: seasons, selected: $season, size: part == .header ? 22 : 26)
    }
    // In a narrow pane the still gives way to the name, so a name is never cut to "Episod…" (r19).
    @State private var narrow = false
    var thumb: CGFloat { narrow ? 80 : 112 }
    func row(_ e: StremioEpisode) -> some View {
        let on = e.id == current
        let mins = info?.minutes[e.id] ?? e.runtime ?? info?.show
        let about = info?.about[e.id] ?? e.overview
        return Button { guard !SeasonSwipe.shared.justPulled, Date().timeIntervalSince(ShelfHand.shared.handledAt) >= 0.35 else { return }; choose(e) } label: {
            HStack(spacing: 12) {
                Art(url: URL(string: e.thumb)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                    .frame(width: thumb, height: thumb * 9 / 16)
                    .overlay(alignment: .bottomLeading) {
                        // How far into it he is, as on Stremio's own cards. The still's width is fixed, so no reader.
                        if on, let p = progress, p > 0 {
                            ZStack(alignment: .leading) { Color.white.opacity(0.25); TVLook.accent.frame(width: thumb * min(p, 1)) }.frame(height: 3)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    // Which one, always in the same place over its name, as the Apple TV app sets them; the name whole,
                    // up to three lines, never cut to "Fi…" (r26), or nothing when it has none of its own (gate 276).
                    // With no name of its own, the number is its title (third pass: a caption alone read as a missing title).
                    let number = e.season == 0 ? "Special \(e.episode)" : "Episode \(e.episode)"
                    if e.ownName != nil { Text(number).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(e.ownName ?? number).font(.subheadline.weight(.semibold)).lineLimit(3).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    // What it's about, in one line, so the row says more than its number.
                    if let about, !about.isEmpty { Text(about).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    HStack(spacing: 6) {
                        if on { Text(currentLabel).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(TVLook.accent, in: Capsule()).foregroundStyle(.black) }
                        else if e.id == after { Text("Up next").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(.white.opacity(0.2), in: Capsule()).foregroundStyle(.white) }
                        if let mins { Text("\(mins) min") }
                        // Watched, said in the line under the name rather than in a column of its own at the row's end,
                        // which took the name's room and cut a long one short (r28: Episode 2, "…Home f…").
                        if watched(e) { Label("Watched", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon) }
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.white.opacity(on ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { if busy == e.id { LoadingRing(radius: 14) } }
            .contentShape(Rectangle())
        }
        // The press asks for its streams, so the list is on its way before the tap lands.
        .buttonStyle(PressCard(onPress: { StreamCache.shared.prefetch(episode: e.id) }))
        .disabled(busy != nil)
        .modifier(EpisodeFlick(item: flickItem?(e), onThrow: onThrow.map { f in { f(e) } }, onTap: { choose(e) }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if part != .rows { header.padding(.bottom, part == .all ? 2 : 0) }
            if part != .header {
                VStack(alignment: .leading, spacing: 10) { ForEach(episodes.filter { $0.season == season }) { e in row(e).id(e.id) } }
                    .modifier(SeasonSwipeRows(seasons: seasons, season: $season))
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 330 } action: { narrow = $0 }
        // The episode the list rests on, still the same a second later: its link is resolved on the TV, so picking it
        // finds it answering rather than paying the cold 7 to 13 s.
        .task(id: restsOn) {
            guard part != .header, let id = restsOn, let imdb = id.split(separator: ":").first, imdb.hasPrefix("tt") else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { Warm.ask(type: "series", imdb: String(imdb), video: id) }
        }
    }
    // The one he'd pick from here: the episode he's on, or the one after it while that one plays.
    var restsOn: String? { currentLabel == "Playing" ? after : current }
}

// Something on its way: a light running round the card's whole rounded edge (Richard, 2026-11-05: "the loading like
// light bar should go all around the card"). One stroke along the edge itself, its stretch moving round; nothing else
// redraws, and nothing is measured.
struct LoadingRing: View {
    var radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var still
    // 1.4 s a lap, set by one clock: each ring starts where the reference clock has every ring in its lap, then runs at the
    // same rate, so the flick's TV handing its light to the Remote's picture is one unbroken light, never one that stops
    // and starts again at the left (r21). The lap is the shape's own animation, drawn by the render loop: a TimelineView per
    // ring rebuilt every ring's view 60 times a second, and a shadow per ring was an offscreen pass each frame (review of
    // dfd490e, speed 1).
    static let lap = 1.4
    static func phaseNow() -> CGFloat { CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: lap) / lap) }
    @State private var phase: CGFloat = LoadingRing.phaseNow()
    @State private var running = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 2)
            // Its glow, a wider faint stroke under it rather than a blur.
            RunningEdge(radius: radius, phase: still ? 0.1 : phase)
                .stroke(TVLook.accent.opacity(0.28), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            RunningEdge(radius: radius, phase: still ? 0.1 : phase)
                .stroke(TVLook.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        // Only the lap itself takes this animation, and only the once it's set going.
        .animation(running ? .linear(duration: Self.lap).repeatForever(autoreverses: false) : nil, value: phase)
        .onAppear {
            guard !still, !running else { return }
            let from = Self.phaseNow()
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { phase = from }
            running = true
            // A tick on, so the start isn't swallowed by the frame the ring arrives in.
            Task { @MainActor in phase = from + 1 }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Loading")
    }
}
// The one line under the Remote's picture while a start runs: what the TV is doing, in his terms. Two lines on a plain
// start ("Sending to the TV…", then "Loading the stream…"), never the name of the app doing the work, and a second try's
// reason held until that try's player is up, so it can be read. "Still" counts from the step, not from the send.
enum StartingWords {
    static func line(_ s: TVModel.Starting, now: Date) -> String {
        let inStep = now.timeIntervalSince(s.phaseAt)
        switch s.phase {
        case "waking": return "Waking the TV…"
        case "player":
            if inStep >= 8 { return "Still loading…" }
            return s.tryKind == "retry" ? "Loading the next stream…" : "Loading the stream…"
        case "playing": return "Playing"
        default:
            switch s.tryKind {
            case "retry": return "That stream didn’t start. Trying the next…"
            case "again": return "Trying that stream again…"
            case "covered": return "Something else came up on the TV. Starting again…"
            default: return "Sending to the TV…"
            }
        }
    }
}
// A quarter of a rounded edge, starting a given way round it, carried on over the start when it runs past the end.
struct RunningEdge: Shape {
    var radius: CGFloat
    var phase: CGFloat
    var length: CGFloat = 0.24
    var animatableData: CGFloat { get { phase } set { phase = newValue } }
    func path(in rect: CGRect) -> Path {
        let edge = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect.insetBy(dx: 1.25, dy: 1.25))
        let from = phase.truncatingRemainder(dividingBy: 1), to = from + length
        var p = edge.trimmedPath(from: from, to: min(to, 1))
        if to > 1 { p.addPath(edge.trimmedPath(from: 0, to: to - 1)) }
        return p
    }
}

// Under the picture of a show while it plays: which episode it is, and the way to the rest of them. One tap, the whole
// line (Richard, 2026-11-05: "there should be an episode picker in the interface i just showed").
struct EpisodesLine: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var nextUp = NextUp.shared
    @State private var open = false
    // How far down the screen the line sits, so the list above it can stop below the page's title: grown to the top, it
    // covered "Remote" all but a sliver of its R, which read as a stray letter (r27, r28).
    @State private var lineTop: CGFloat = 0
    var body: some View {
        // A start under way: its own episode, read from the start, never the one still reported from before it (2026-11-08:
        // the next episode thrown, and the line under its poster still named the last one until the TV caught up). The
        // picker waits for the TV's word on the new show.
        if let st = model.starting, !st.played {
            if let line = st.line {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle.portrait").foregroundStyle(.secondary)
                    Text(line).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16).frame(height: 46)
                .glassEffect(.regular, in: Capsule())
                .opacity(model.flickHandoff ? 0 : 0.7)
                .transition(.opacity)
                .accessibilityLabel("Starting \(line)")
            }
        } else if model.videoIsCurrent, let s = model.status?.session, s.pkg == "com.stremio.one", let line = s.episodeLine, nextUp.series != nil {
          Group {
            Button { model.tick(); open = true } label: {
                // Where the whole line doesn't fit (folded, beside the side bar), the word "Episodes" gives way before the
                // episode's own name does (r33: "S1 E…  Episod/es").
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle.portrait").foregroundStyle(TVLook.accent)
                        Text(line).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                        Spacer(minLength: 8)
                        Text("Episodes").font(.subheadline.weight(.semibold)).foregroundStyle(TVLook.accent)
                        Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(TVLook.accent)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle.portrait").foregroundStyle(TVLook.accent)
                        Text(line).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(TVLook.accent)
                    }
                    .accessibilityLabel("Episodes, \(line)")
                }
                .padding(.horizontal, 16).frame(height: 46).contentShape(Capsule())
            }
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { lineTop = $0 }
            // Out of the way while a flick's screen moves onto the picture above it, like the bar.
            .opacity(model.flickHandoff ? 0 : 1)
            .transition(.opacity)
            // Over the page, sized to it, not a page of its own: tap outside or pull it down and it's gone.
            .popover(isPresented: $open, arrowEdge: .bottom) {
                EpisodeSheet { open = false }
                    // Clear of the title and its line under it (about 70 pt from the top, with the arrow), and over the whole
                    // TV picture beneath, never leaving its top edge peeking out (r30): it always opens upward. Only above
                    // a line lower than 340 pt was it capped before, and open the line sits at about 330, so the list still
                    // reached the top and a sliver of "Remote" showed beside it (r29). Folded it's a sheet, where this is ignored.
                    .frame(idealWidth: 440, idealHeight: min(560, max(220, lineTop - 92)))
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium, .large])
            }
          }
          // The build's shot of the episodes over the Remote ("-pose episodes").
          .task { if UserDefaults.standard.string(forKey: "pose") == "episodes" { try? await Task.sleep(nanoseconds: 3_000_000_000); open = true } }
        }
    }
}

// The show on the TV, its episodes, the one playing marked and in view and the next marked up next. A pick goes to the
// TV the way the next-episode key does; the one already playing is never sent again. Inside whatever scrolls it.
struct ShowEpisodes: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var nextUp = NextUp.shared
    var titled = false
    // Brought into view on its own only where the list is all that scrolls (the sheet, the open right pane). Inside a page
    // that also holds the film, scrolling to it took the whole page down and cut the picture off (r17).
    var bringsIntoView = true
    // The show's name and the season chips held at the top, only the rows scrolling under them (the sheet over the Remote):
    // scrolled to the episode playing, the name and the chips had gone off the top, and the grabber sat over a cut row
    // (review of dfd490e, tv-episodes).
    var pinsHeader = false
    var picked: () -> Void = {}
    @State private var meta: StremioMeta?
    @State private var info: SeriesInfo.Info?
    @State private var season = 0
    @State private var busy: String?
    func picker(_ meta: StremioMeta, _ s: NextUp.Series, _ part: EpisodePicker.Part) -> some View {
        EpisodePicker(episodes: meta.episodes, season: $season, current: s.current, currentLabel: "Playing",
                      after: nextUp.next?.stremioRef?.video, info: info, busy: busy, choose: { e in
            guard e.id != s.current else { picked(); return }
            busy = e.id
            model.flick(FlickTarget(item: NextUp.item(s, e), source: .stremio, ready: true, autoplay: true))
            Task { try? await Task.sleep(nanoseconds: 250_000_000); busy = nil; picked() }
        }, flickItem: { NextUp.item(s, $0) }, part: part)
    }
    @ViewBuilder var title: some View {
        if titled, let s = nextUp.series { Text(s.title).font(.title2.weight(.bold)).lineLimit(2) }
    }
    @ViewBuilder func rows(_ part: EpisodePicker.Part) -> some View {
        if let meta, let s = nextUp.series { picker(meta, s, part) }
        else { ForEach(0..<5, id: \.self) { i in PlaceholderRow(delay: Double(i) * 0.12, thumb: true) } }
    }
    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if pinsHeader {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            title
                            if let meta, let s = nextUp.series { picker(meta, s, .header) }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) { rows(.rows) }
                                .padding(.horizontal, 20).padding(.bottom, 20)
                        }
                        .contentMargins(.top, 4, for: .scrollContent)
                        // The rows fade under the chips rather than being cut at a hard edge.
                        .mask {
                            VStack(spacing: 0) {
                                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                                Color.black
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        title
                        rows(.all)
                    }
                }
            }
            // The episodes fade in over their waiting rows, which they replace in place, rather than cutting in (the
            // 2026-11-10 motion pass).
            .settledAnimation(.easeOut(duration: 0.25), value: meta == nil)
            .task(id: nextUp.series) {
                guard let s = nextUp.series else { return }
                info = SeriesInfo.cached(s.imdb)
                guard let m = await NextUp.meta(s.imdb) else { return }
                season = m.episodes.first { $0.id == s.current }?.season ?? m.episodes.first?.season ?? 0
                meta = m
                if bringsIntoView {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(s.current, anchor: .center) }
                }
                if info == nil { let i = await SeriesInfo.load(s.imdb); withAnimation(.easeOut(duration: 0.2)) { info = i } }
            }
        }
    }
}
// The same, over the Remote: tap outside or pull it down and it's gone.
struct EpisodeSheet: View {
    let close: () -> Void
    var body: some View {
        // An opaque enough backdrop and its own top inset, so nothing of the page under it (the "Remote" title) shows at its
        // top edge (r20).
        // The show's name and the seasons held at the top, 28 pt down so the grabber is clear of them, and only the rows
        // scroll, under them, so no row's words ever sit under the grabber. The same 20 pt each side: the side bar's inset
        // isn't the sheet's, and kept, it left a 95 pt strip on the right (review of dfd490e, tv-episodes).
        ShowEpisodes(titled: true, pinsHeader: true, picked: close)
            .frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 28)
            .ignoresSafeArea(.container, edges: [.leading, .trailing, .bottom])
        // Opaque: the material let the Remote's title show through as a stray "F" behind its top, open (r27).
        .presentationBackground(Color(white: 0.12))
        // One corner shape all round, whether it's a popover or a sheet (r21: one square corner, one round).
        .presentationCornerRadius(28)
    }
}

// What's on, when it's a film or a show: the episode's own still (else the poster), the show's name over the episode's,
// what the episode is about, the bar, and the one transport. Stop is a hold on play, as on the Remote.
struct PlayingVideo: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var nextUp = NextUp.shared
    @Environment(\.paneLayout) private var panes
    let session: TVStatus.Session
    let stale: Bool
    let ended: Bool
    @State private var still: String?
    @State private var about: String?
    // The episode's own name from the show's list, when the TV's line has none ("S1 E2" alone) or a placeholder.
    @State private var ownName: (season: Int, episode: Int, name: String)?
    @State private var pictureCap: CGFloat = 300
    var series: NextUp.Series? { session.pkg == "com.stremio.one" ? nextUp.series : nil }
    var body: some View {
        let name = session.showName
        // An episode: which one in the small line over the title ("Sample Series · S1 E2"), and the episode's own name as
        // the title, whole (up to three lines, never cut: r26), as its row names it. With no name of its own, the show's
        // name is the title and "S1 E2" the line over it (gate 276: the hero said "Episode 2", its row "Episode 2: The
        // One…"; then, joined into one title, the name was cut to "…Long We…").
        let se = session.seasonEpisode
        let own: String? = {
            guard session.episodeLine != nil, let se else { return nil }
            // Only the name of this very episode: a moment after a change, the list may still be the last one's.
            if let o = ownName, o.season == se.season, o.episode == se.episode { return o.name }
            // Else whatever the TV's own line names it, after its "S1 E2 · ".
            guard let line = session.episodeLine, let r = line.range(of: " · ") else { return nil }
            return Wording.episodeName(String(line[r.upperBound...]), number: se.episode)
        }()
        let which = se.map { "S\($0.season) E\($0.episode)" }
        let over: String? = session.episodeLine == nil ? nil : own != nil ? [name, which ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") : name.isEmpty ? nil : which
        let title = session.episodeLine == nil ? name : own ?? (name.isEmpty ? which ?? "" : name)
        VStack(alignment: .leading, spacing: 14) {
            // One 16:9 picture, never taller than about 38 % of the page, so the title, the bar and the keys are all on the
            // first screen (r19: a portrait poster filled the page and pushed everything under the fold). The episode's
            // still fills it; otherwise the poster sits on a blur of itself, as on the Remote.
            // The 16:9 box comes first and the art fills it: a fill-mode picture sized its own container to the art's shape
            // (r20: a portrait slab 67 % of the page tall, with the keys drawn over it).
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let still, !still.isEmpty {
                        Cover(url: URL(string: still), mode: .fill) { Color.white.opacity(0.06) }
                    } else if let art = session.art, !art.isEmpty, session.pkg == "com.google.android.youtube.tv" {
                        // A video's own still is already 16:9: it fills the picture.
                        Cover(url: URL(string: art), mode: .fill) { Color.white.opacity(0.06) }
                    } else if let poster = model.poster(for: session) {
                        PosterOnBlur(url: URL(string: poster))
                    } else if session.pkg != "com.stremio.one", let banner = model.picture(for: session) {
                        // Still looking the video up (the Mac's search can take half a minute, or miss): YouTube's own banner
                        // on a blur of itself, never an empty box (r35). Stremio's banner never stands for what's on.
                        PosterOnBlur(url: URL(string: banner))
                    } else {
                        NoPicture()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: pictureCap, alignment: .leading)
            // The page's own height, read once from the container, for the cap.
            .background {
                Color.clear.containerRelativeFrame(.vertical) { h, _ in h }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in let c = h * 0.38; if abs(c - pictureCap) > 1 { pictureCap = c } }
                    .hidden()
            }
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            .opacity(stale ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 3) {
                // The show above, the episode as the title; a film is its own title. A video is its own title too, its
                // channel under it (r35: the channel was the title and the video's name the small line over it).
                if let over { Text(over).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1) }
                Text(title).font(.title2.weight(.bold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let channel = session.channel { Text(channel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                // A tap opens the rest of the words in place, and closes them again.
                if let about { ExpandingText(text: about, lines: panes ? 4 : 3, font: .footnote).padding(.top, 4) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
            if session.position != nil || session.pkg == "com.stremio.one" { VideoProgress(session: session, live: !stale, alone: .leading) }
            Transport(ended: ended).padding(.top, 2)
        }
        .task(id: series) {
            guard let s = series, let m = await NextUp.meta(s.imdb), let e = m.episodes.first(where: { $0.id == s.current }) else { still = nil; about = nil; ownName = nil; return }
            withAnimation(.easeOut(duration: 0.25)) { still = e.thumb; ownName = e.ownName.map { (e.season, e.episode, $0) } }
            let info = await SeriesInfo.load(s.imdb)
            withAnimation(.easeOut(duration: 0.25)) { about = info?.about[e.id] }
        }
    }
}
