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

// Four tabs: you (Start: him, his figures, what's on, lately, his story), charts, library and discover. System tabs, so
// the Duo puts them on the side folded and open flat, and across the foot open upright. Each tab keeps its own stack of
// pages. A tick as he changes tab; links from the widgets land on the tab, section or page they name.
struct RootView: View {
    @State private var tab = Pose.tab
    @State private var tops: [Int: Int] = [:]
    private var links: Links { Links.shared }
    var body: some View {
        PaneReader {
            TabView(selection: TabReset.binding($tab) { t in tops[t, default: 0] += 1 }) {
                Tab(value: 0) {
                    TabPage(tab: 0, active: tab == 0, top: tops[0, default: 0]) { StartTab(top: $0) }
                } label: { tabLabel("you", "person.crop.circle") }
                Tab(value: 1) {
                    TabPage(tab: 1, active: tab == 1, top: tops[1, default: 0]) { ChartsTab(top: $0) }
                } label: { tabLabel("charts", "chart.bar.xaxis") }
                Tab(value: 2) {
                    TabPage(tab: 2, active: tab == 2, top: tops[2, default: 0]) { LibraryTab(top: $0) }
                } label: { tabLabel("library", "square.stack") }
                Tab(value: 3) {
                    TabPage(tab: 3, active: tab == 3, top: tops[3, default: 0]) { DiscoverTab(top: $0) }
                } label: { tabLabel("discover", "sparkles") }
            }
            .tint(.white)
            .sensoryFeedback(.tick, trigger: tab)
        }
        .onAppear { TabTour.run([0, 1, 2, 3]) { tab = $0 } }
        .onOpenURL { links.open($0) }
        .onChange(of: links.tab) { _, t in if let t { tab = t; links.tab = nil } }
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
        // A widget's link to a page: this tab's stack, from its root.
        .onChange(of: Links.shared.push) { _, ask in
            guard let ask, ask.tab == tab else { return }
            Links.shared.push = nil
            path = [ask.go]
        }
        .task {
            // The build's poses: a page up over its tab.
            guard active, ["detail", "track", "artist", "album"].contains(Pose.name) else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let h = store.hero else { return }
            switch Pose.name {
            case "artist": path.append(Go(route: .artist(store.insights.week.first?.name ?? h.artist), zoom: nil))
            case "album": path.append(Go(route: .album(h.artist, h.album), zoom: nil))
            default: path.append(Go(route: .track(h), zoom: nil))
            }
        }
    }
}
