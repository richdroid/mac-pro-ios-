import SwiftUI

@main
struct LastFMApp: App {
    @Environment(\.scenePhase) private var phase
    init() {
        LaunchLog.mark("app init")
        // The build's mock lives in an evening, so its day is full whatever hour the build runs.
        if LastFM.mockMode { Clock.pinEvening() }
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .onChange(of: phase) { _, p in if p == .active { Store.shared.start() } else { Store.shared.stop() } }
                .onAppear { LaunchLog.mark("root appeared"); Store.shared.start() }
        }
    }
}

// Five tabs: Now, Charts, Library, You and Discover. System tabs, so the Duo puts them on the side folded and open flat,
// and across the foot open upright. Each tab keeps its own stack of pages.
struct RootView: View {
    @State private var tab = Pose.tab
    @State private var tops: [Int: Int] = [:]
    var body: some View {
        PaneReader {
            TabView(selection: TabReset.binding($tab) { t in tops[t, default: 0] += 1 }) {
                Tab(value: 0) {
                    TabPage(tab: 0, active: tab == 0, top: tops[0, default: 0]) { NowTab(top: $0) }
                } label: { tabLabel("now", "waveform") }
                Tab(value: 1) {
                    TabPage(tab: 1, active: tab == 1, top: tops[1, default: 0]) { ChartsTab(top: $0) }
                } label: { tabLabel("charts", "chart.bar.xaxis") }
                Tab(value: 2) {
                    TabPage(tab: 2, active: tab == 2, top: tops[2, default: 0]) { LibraryTab(top: $0) }
                } label: { tabLabel("library", "square.stack") }
                Tab(value: 3) {
                    TabPage(tab: 3, active: tab == 3, top: tops[3, default: 0]) { YouTab(top: $0) }
                } label: { tabLabel("you", "person.crop.circle") }
                Tab(value: 4) {
                    TabPage(tab: 4, active: tab == 4, top: tops[4, default: 0]) { DiscoverTab(top: $0) }
                } label: { tabLabel("discover", "sparkles") }
            }
            .tint(.white)
        }
        .onAppear { TabTour.run([0, 1, 2, 3, 4]) { tab = $0 } }
    }
}

// A tab's own stack: its root page over the shared backdrop (only the tab on screen drifts), the fades under the bars,
// and the artist, album and track pages pushed on it. Tapping the tab again goes back to its root, then to the top.
struct TabPage<C: View>: View {
    let tab: Int
    let active: Bool
    let top: Int
    @ViewBuilder let content: (Int) -> C
    @Namespace private var space
    @State private var path: [Go] = []
    @State private var scrollTop = 0
    private var store: Store { Store.shared }
    var body: some View {
        NavigationStack(path: $path) {
            content(scrollTop)
                .modifier(BarFade())
                .background { Backdrop(ref: store.hero?.art, moving: active && store.nowPlaying != nil) }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Go.self) { g in RoutePage(go: g, space: space) }
        }
        .environment(\.zoomSpace, space)
        .environment(\.openRoute) { g in path.append(g) }
        .onChange(of: top) { _, _ in if path.isEmpty { scrollTop += 1 } else { path.removeAll() } }
        .task {
            // The build's poses: a page up over its tab.
            guard active, ["detail", "track", "artist", "album"].contains(Pose.name) else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let h = store.hero else { return }
            switch Pose.name {
            case "artist": path.append(Go(route: .artist(store.insights.week.first?.name ?? h.artist), zoom: nil))
            case "album": path.append(Go(route: .album(h.artist, h.album), zoom: nil))
            default: path.append(Go(route: .track(h), zoom: tab == 0 ? "hero|\(h.id)" : nil))
            }
        }
    }
}
