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
                    #if canImport(UIKit)
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    #endif
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
    let commit: (Double) -> Void
    @State private var across: Bool?
    var body: some View {
        GeometryReader { g in
            let thick: CGFloat = scrub == nil ? 6 : 10
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
        }
        .frame(height: 28)
        .sensoryFeedback(.selection, trigger: scrub.map { Int($0 / tickEvery) })
    }
}

// Where the bar will be, before there's anything to show on it: the same height, an empty track, no numbers. A note
// can say what the TV is doing meanwhile.
struct ProgressPlaceholder: View {
    var note: String? = nil
    var body: some View {
        VStack(spacing: 6) {
            ProgressTrack(fraction: nil).frame(height: 28)
            Text(note ?? "0:00").font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(TVLook.accent).opacity(note == nil ? 0 : 1)
                .contentTransition(.opacity)
        }
        .accessibilityHidden(note == nil)
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
    var posed = true
    @State private var position = ScrollPosition(edge: .top)
    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: top) { _, _ in withAnimation(.snappy) { position.scrollTo(edge: .top) } }
            // Animated, like a drag, so the bar follows it and folds the title as a real scroll would.
            .task { if posed, let y = PoseScroll.offset { try? await Task.sleep(nanoseconds: 900_000_000); withAnimation { position.scrollTo(y: y) } } }
    }
}
// Unfolded, the side that isn't the page's list (Status's picture of the box) passes false, so the build's scrolled
// shot has one pane scrolled and the other not, which is when a band under the bar would differ between them.
extension View { func backToTop(posed: Bool = true) -> some View { modifier(BackToTop(posed: posed)) } }
// The build's shots of a page scrolled a little way ("-scroll 40"), to show what sits under the bar then.
enum PoseScroll {
    static let offset: CGFloat? = { let v = UserDefaults.standard.double(forKey: "scroll"); return v > 0 ? v : nil }()
}
private struct PoseScrolled: ViewModifier {
    @State private var position = ScrollPosition(edge: .top)
    func body(content: Content) -> some View {
        if let y = PoseScroll.offset {
            content.scrollPosition($position).task { try? await Task.sleep(nanoseconds: 900_000_000); withAnimation { position.scrollTo(y: y) } }
        } else { content }
    }
}
extension View { func poseScroll() -> some View { modifier(PoseScrolled()) } }

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
