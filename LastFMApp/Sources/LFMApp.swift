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

// Two tabs for now, Now and You; Charts, Discover and Library join them as they're built, and none shows before it is.
// System tabs, so the Duo puts them on the side folded and open flat, and across the foot open upright.
struct RootView: View {
    @State private var tab = Pose.tab
    @State private var tops: [Int: Int] = [:]
    private var store: Store { Store.shared }
    var body: some View {
        PaneReader {
            TabView(selection: TabReset.binding($tab) { t in tops[t, default: 0] += 1 }) {
                Tab(value: 0) {
                    TabPage(active: tab == 0) { NowTab(top: tops[0, default: 0]) }
                } label: { tabLabel("now", "waveform") }
                Tab(value: 1) {
                    TabPage(active: tab == 1) { YouTab(top: tops[1, default: 0]) }
                } label: { tabLabel("you", "person.crop.circle") }
            }
            .tint(.white)
        }
        .onAppear { TabTour.run([0, 1]) { tab = $0 } }
    }
}

// A tab's own page: its stack, the shared backdrop (only the tab on screen drifts), the fades under the bars, and the
// song page that grows out of whichever cover was tapped.
struct TabPage<C: View>: View {
    let active: Bool
    @ViewBuilder let content: () -> C
    @Namespace private var space
    @State private var opened: Scrobble?
    private var store: Store { Store.shared }
    var body: some View {
        NavigationStack {
            content()
                .modifier(BarFade())
                .background { Backdrop(ref: store.hero?.art, moving: active && store.nowPlaying != nil) }
                .toolbar(.hidden, for: .navigationBar)
                .environment(\.zoomSpace, space)
                .environment(\.openTrack) { s in opened = s }
                .cover(item: $opened) { s in TrackPage(s: s, space: space) }
                .task {
                    // The build's pose: the song page up over Now.
                    guard Pose.name == "detail", active else { return }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    opened = store.hero
                }
        }
    }
}
