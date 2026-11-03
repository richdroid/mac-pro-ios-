import AVFoundation
import SwiftUI
#if os(iOS)
import MediaPlayer
#endif

// Ten-second jumps in Stremio, added up. Its player takes a few seconds to move, so taps made meanwhile are counted, the
// bar moves by them at once, and they go to the TV together once the tapping stops.
@MainActor
final class SeekQueue: ObservableObject {
    static let shared = SeekQueue()
    // Taps the TV's own report doesn't show yet, and which film they're for.
    @Published private(set) var pending = 0
    private var film = ""
    private var unsent = 0
    private var generation = 0
    private var wait: Task<Void, Never>?
    private var chain: Task<Void, Never>?
    private static func key(_ s: TVStatus.Session?) -> String { s?.description.joined(separator: "\n") ?? "" }
    // How far the bar is ahead of the TV's report, in ms.
    func offset(for s: TVStatus.Session?) -> Double { Self.key(s) == film ? Double(pending) * 10000 : 0 }
    func add(_ step: Int, for s: TVStatus.Session?, model: TVModel) {
        let k = Self.key(s)
        if k != film { film = k; pending = 0; unsent = 0; generation += 1 }
        model.tick()
        pending += step; unsent += step
        wait?.cancel()
        wait = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { self?.flush(model) }
        }
    }
    // One send for the lot, after the one before it has landed. The bridge takes up to a minute's worth at a time.
    private func flush(_ model: TVModel) {
        while unsent != 0 {
            let n = max(-60, min(60, unsent)), gen = generation, before = chain
            unsent -= n
            chain = Task { [weak self] in
                await before?.value
                do { try await TVBridge.post("player-seek", ["steps": n], timeout: 30); await model.load() }
                catch { model.say("Couldn’t move it") }
                // In the TV's own report now, or never sent: either way the bar stops carrying it.
                if let self, self.generation == gen { self.pending -= n }
            }
        }
    }
}

// The series a Stremio player is on, and the episode after the one on screen, ready to flick.
@MainActor
final class NextUp: ObservableObject {
    static let shared = NextUp()
    @Published private(set) var next: MediaItem?
    private var key = ""
    private static var metas: [String: StremioMeta] = [:]
    static func remember(_ m: StremioMeta, for imdb: String) { metas[imdb] = m }
    static func meta(_ imdb: String) async -> StremioMeta? {
        if let m = metas[imdb] { return m }
        guard let d = await TVBridge.data(TVBridge.url("/api/tv/stremio-meta?type=series&id=\(imdb)"), timeout: 15),
              let m = try? JSONDecoder().decode(StremioMeta.self, from: d), !m.episodes.isEmpty else { return nil }
        metas[imdb] = m
        return m
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
    func follow(_ s: TVStatus?) {
        guard let p = s?.session, p.pkg == "com.stremio.one", p.description.count > 1 else {
            key = ""
            if next != nil { next = nil }
            return
        }
        let k = p.description.joined(separator: "\n")
        guard k != key else { return }
        key = k
        Task { [weak self] in
            let found = await Self.resolve(p)
            if let self, self.key == k, found != self.next { self.next = found }
        }
    }
    private static func resolve(_ p: TVStatus.Session) async -> MediaItem? {
        let show = p.description[0], on = p.description[1]
        func same(_ t: String) -> Bool { !t.isEmpty && (show.localizedCaseInsensitiveContains(t) || t.localizedCaseInsensitiveContains(show)) }
        // Which series: one flicked from here, or one on Stremio's own Continue watching.
        var imdb: String?, title = show, art = "", known: String?
        if let r = RecentFlicks.shared.list.first(where: { $0.type == "series" && same($0.title) }) {
            imdb = r.imdb; title = r.title; art = r.art; known = r.video
        } else if let i = BrowseStore.shared(.stremio).rows.first(where: { $0.title == "Continue watching" })?.items.first(where: { $0.stremioRef?.type == "series" && same($0.title) }), let ref = i.stremioRef {
            imdb = ref.imdb; title = i.title; art = i.art; known = ref.video
        }
        guard let imdb, let meta = await meta(imdb) else { return nil }
        // The episode on screen by its name in what the TV reports, the longest name that fits, else the one last sent.
        let named = meta.episodes.filter { $0.name.count > 2 && on.localizedCaseInsensitiveContains($0.name) }.max { $0.name.count < $1.name.count }
        guard let current = named ?? meta.episodes.first(where: { $0.id == known }), let n = after(current, in: meta.episodes) else { return nil }
        return MediaItem(title: title, subtitle: "S\(n.season) E\(n.episode) · \(n.name)", art: art, id: link(imdb, n.id), kind: "series")
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
        return MediaItem(title: title, subtitle: episode ?? at.formatted(.relative(presentation: .named)), art: art, id: link, kind: type)
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
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var shown: (id: String, image: TVImage)?
    var wanted: String { key ?? url?.absoluteString ?? "" }
    var body: some View {
        // The first time, whatever's already to hand, with no fade.
        let now = shown ?? (image ?? ImageStore.shared.cached(url)).map { (wanted, $0) }
        ZStack {
            if let now { Image(tv: now.image).resizable().aspectRatio(contentMode: mode).id(now.id).transition(.opacity) }
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
    // Where the finger is, while it's on the bar.
    @Binding var scrub: Double?
    // A tick under the finger every this much.
    var tickEvery: Double
    let commit: (Double) -> Void
    @State private var across: Bool?
    var body: some View {
        GeometryReader { g in
            let thick: CGFloat = scrub == nil ? 6 : 10
            let at = { (x: CGFloat) in total * min(1, max(0, Double(x / max(g.size.width, 1)))) }
            ProgressTrack(fraction: total > 0 ? (scrub ?? value).map { $0 / total } : nil, thick: thick, fill: busy ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(TVLook.accent))
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
        }
        .frame(height: 28)
        .sensoryFeedback(.selection, trigger: scrub.map { Int($0 / tickEvery) })
    }
}

// Where the bar will be, before there's anything to show on it: the same height, an empty track, no numbers.
struct ProgressPlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            ProgressTrack(fraction: nil).frame(height: 28)
            Text("0:00").font(.caption.monospacedDigit().weight(.medium)).hidden()
        }
        .accessibilityHidden(true)
    }
}

// A round glass button that does something here, rather than press a key on the TV.
struct GlassButton: View {
    @EnvironmentObject var model: TVModel
    let icon: String, label: String
    var size: CGFloat = 54
    let action: () -> Void
    var body: some View {
        Button { model.tick(); action() } label: {
            Image(systemName: icon).font(.system(size: size * 0.36, weight: .medium)).frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel(label)
    }
}

// Tapping a tab's button while on it: the tab's page goes back to its top. Each scrolling page on a tab takes this on.
private struct BackToTopKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues { var backToTop: Int { get { self[BackToTopKey.self] } set { self[BackToTopKey.self] = newValue } } }
private struct BackToTop: ViewModifier {
    @Environment(\.backToTop) private var top
    @State private var position = ScrollPosition(edge: .top)
    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: top) { _, _ in withAnimation(.snappy) { position.scrollTo(edge: .top) } }
    }
}
extension View { func backToTop() -> some View { modifier(BackToTop()) } }

// A whole row as its own page, opened from its heading. As a value, so tapping the tab again can close it.
enum RowRoute: Hashable {
    case media(MediaRow, MediaSource)
    case films(String, [Film])
    @ViewBuilder var page: some View {
        switch self {
        case .media(let row, let source): MediaList(row: row, source: source)
        case .films(let title, let films): FilmList(title: title, films: films)
        }
    }
}
