import SwiftUI
import Metal

@main
struct LastFMApp: App {
    @Environment(\.scenePhase) private var phase
    init() {
        LaunchLog.mark("app init")
        _ = FirstFrames.launching
        // The build's mock lives in an evening, so its day is full whatever hour the build runs.
        if LastFM.mockMode { Clock.pinEvening() }
        // The scrobbler's catch-up on background refresh: registered before launch ends, as BGTaskScheduler asks.
        Scrobbler.registerBackground()
        // The first page with a chart (a Canvas) made SwiftUI load Metal and open the GPU on the main thread, inside that
        // page's push: 693 ms of the first hub's opening in the profile films (MTLCreateSystemDefaultDevice under dyld,
        // RenderBox's shared device). Opened here, off the main thread, while home comes up; later it is only looked up.
        DispatchQueue.global(qos: .utility).async { _ = MTLCreateSystemDefaultDevice() }
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .onChange(of: phase) { _, p in
                    if p == .active {
                        Store.shared.start(); Taste.shared.show(); Task { await Taste.shared.refresh() }
                        LFMAccount.shared.refresh()
                        if LFMAccount.shared.state == .waiting { Task { await LFMAccount.shared.finish() } }
                        Scrobbler.shared.start()
                    } else if p == .background {
                        Store.shared.stop(); Scrobbler.shared.stop()
                    }
                }
                .onAppear {
                    LaunchLog.mark("root appeared"); Store.shared.start()
                    #if canImport(UIKit)
                    HitchLog.shared.start()
                    #endif
                }
        }
    }
}

// Where a push goes: a hub of the menu (with the section it opens on), or an artist, album or track.
enum Hub: String, Hashable, Sendable, CaseIterable {
    case nowPlaying, profile, charts, library, discover, history, scrobbling
    // Its word on home and its name in the small capitals over its pages.
    var word: String {
        switch self {
        case .nowPlaying: return "now playing"
        case .profile: return "profile"
        case .charts: return "charts"
        case .library: return "library"
        case .discover: return "discover"
        case .history: return "history"
        case .scrobbling: return "scrobbling"
        }
    }
    // Home's menu, in Zune HD's order of use: him, the charts and his collection, what's next, what's been, the scrobbler.
    static let menu: [Hub] = [.profile, .charts, .library, .discover, .history, .scrobbling]
}
enum Nav: Hashable, Sendable {
    case hub(Hub, Int?)
    case page(Go)
}

// One navigation model (Richard, 2026-11-24: "The back button should work more consistently"; "I want the menus to make
// sense … just make it a Zune app"). Zune HD's home is the root: the song on now as a tile, then the menu as huge words.
// Every hub and every artist, album and track page is pushed on this one stack, so Back is always the system's, in the
// same place for the posture (the Duo's side strip folded and open flat, the top bar open upright), with the edge swipe
// and the long press for history; no tab bar, no hidden bars, no hand-made Back.
struct RootView: View {
    @State private var path: [Nav] = RootView.posed()
    @State private var opener = OpenRoute()
    @Namespace private var space
    private var links: Links { Links.shared }
    private var store: Store { Store.shared }
    var body: some View {
        let stack = $path
        opener.go = { g in stack.wrappedValue.append(.page(g)) }
        opener.hub = { h, panel in
            // Home's words swing away first (HomeView); from anywhere else the page simply turns in.
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { stack.wrappedValue.append(.hub(h, panel)) }
        }
        return PaneReader {
            NavigationStack(path: $path) {
                HomeView()
                    .holdsWhileMoving("home")
                    .navigationDestination(for: Nav.self) { n in
                        switch n {
                        case .hub(let h, let panel): HubView(hub: h, panel: panel)
                        case .page(let g): RoutePage(go: g, space: space)
                        }
                    }
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
            .environment(\.zoomSpace, space)
            .environment(\.openRoute, opener)
            .tint(.white)
        }
        .onOpenURL { links.open($0) }
        .onChange(of: links.go) { _, g in
            guard let g else { return }
            links.go = nil
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { path = g }
        }
        .task {
            // The build's poses: a page up over its hub.
            guard ["detail", "track", "artist", "album"].contains(Pose.name) else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let h = store.hero else { return }
            switch Pose.name {
            case "artist": path.append(.page(Go(route: .artist(store.insights.week.first?.name ?? h.artist), zoom: nil)))
            case "album": path.append(.page(Go(route: .album(h.artist, h.album), zoom: nil)))
            default: path.append(.page(Go(route: .track(h), zoom: nil)))
            }
        }
    }

    // Where the build opens (-hub name -panel n; the older -tab/-panel pairs map onto the hubs). With neither: home.
    static func posed() -> [Nav] {
        let d = UserDefaults.standard
        // Launch arguments arrive as strings.
        func int(_ k: String) -> Int? { d.string(forKey: k).flatMap { Int($0) } ?? (d.object(forKey: k) as? Int) }
        if let h = d.string(forKey: "hub") {
            if h == "home" { return [] }
            if let hub = Hub(rawValue: h) { return [.hub(hub, int("panel"))] }
            return []
        }
        guard let tab = int("tab") else { return [] }
        let panel = int("panel") ?? 0
        switch tab {
        case 0:
            switch panel {
            case 1: return [.hub(.nowPlaying, nil)]
            case 2: return [.hub(.profile, 1)]
            case 3: return [.hub(.profile, 2)]
            default: return [.hub(.profile, 0)]
            }
        case 1: return [.hub(.charts, nil)]
        case 2: return [.hub(.library, nil)]
        case 3: return [.hub(.discover, nil)]
        default: return []
        }
    }
}

// A hub's page, pushed: its pivot (or page) under the small capitals that name it.
struct HubView: View {
    let hub: Hub
    let panel: Int?
    var body: some View {
        Group {
            switch hub {
            case .nowPlaying: NowPlayingHub(start: panel ?? 0)
            case .profile: ProfileHub(start: panel ?? 0)
            case .charts: ChartsTab(top: 0)
            case .library: LibraryTab(top: 0)
            case .discover: DiscoverHub(start: panel ?? 0)
            case .history: HistoryHub(start: panel ?? 0)
            case .scrobbling: ScrobbleHub(start: panel ?? 0)
            }
        }
        .environment(\.hubName, hub == .nowPlaying ? nil : hub.word)
        .background { if hub == .nowPlaying { NowBackdrop(song: Store.shared.shown) } else { Backdrop(ref: Store.shared.shown?.art) } }
        // Under the edge swipe UIKit re-insets the page in every frame, and both pages were laid out again and their type
        // redrawn each frame of the drag (profile films: 41-48 fps through the swipe). Held at rest size while it moves.
        .holdsWhileMoving("hub")
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}
private struct HubNameKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    // The small capitals over a hub's pivot (WP7's application title): the hub's own name.
    var hubName: String? { get { self[HubNameKey.self] } set { self[HubNameKey.self] = newValue } }
}
