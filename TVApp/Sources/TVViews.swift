import SwiftUI
#if os(iOS)
import AVKit
import MediaPlayer
#endif

@main
struct TVApp: App {
    @State private var model = TVModel()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(TVPushDelegate.self) private var pushDelegate
    #endif
    @Environment(\.scenePhase) private var phase
    init() {
        // Neither is needed for the first frame, so neither holds it up.
        #if os(iOS)
        // NavTransit watches every push and pop from the first (it holds a page's layout under the edge swipe).
        _ = NavTransit.shared
        // Long-form audio is what lets the AirPlay list move the whole phone's audio, not only this app's.
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        }
        #endif
        Task.detached(priority: .utility) { TVShortcuts.updateAppShortcutParameters() }
        // Must be known before launch finishes: the Now Playing card's occasional refresh while the app is closed.
        #if os(iOS)
        TVBackground.register()
        #endif
    }
    var body: some Scene {
        WindowGroup {
            RootView().environment(model).preferredColorScheme(.dark).tint(TVLook.accent)
                // Once, as the app comes up (initial), then on every change: not also on appear, which started it twice.
                // Inactive (Notification Centre pulled down, the app switcher, a call) keeps polling: stopping there froze
                // the Remote's picture and the Now Playing card the moment he glanced at a notification. Only leaving the
                // app hands over to the background grace (Richard, 2026-11-09: "the notif like for now playing doesnt
                // update automatically").
                .onChange(of: phase, initial: true) { _, p in
                    switch p {
                    case .active: model.start(); TVNotify.shared.share()
                    case .background: model.background()
                    default: break
                    }
                }
                .onOpenURL { u in
                    // What is playing has one home each: a film or show is the Remote's, a song Music's (widgets and the island ask for 2).
                    if u.host == "tab", let t = Int(u.lastPathComponent) { model.tab = t == 2 ? 0 : t }  // Music went (11-24): what plays is the Remote's  // 9: Status, Settings pushed
                    // The Now Playing card's next-episode key: the Remote, and that episode's streams as soon as it's
                    // known (a launch from cold has to hear from the TV first; about three seconds at most, then said).
                    if u.host == "next" {
                        model.tab = 0
                        Task {
                            // Worked out afresh from what the TV is playing now, as the Remote's own ⏭ does it: what was
                            // known before the app was put away may be the episode before's. One wait and one answer:
                            // the Remote's key shows its light for this one (`resolvingNext`) rather than starting its own.
                            // (A second tap on the card while this one is still looking is the same ask.)
                            guard !model.resolvingNext else { return }
                            model.resolvingNext = true
                            defer { model.resolvingNext = false }
                            await model.load()
                            NextUp.shared.forgetAll(); NextUp.shared.follow(model.status)
                            for _ in 0..<30 where NextUp.shared.next == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                            if let n = NextUp.shared.next { model.flick(FlickTarget(item: n, source: .stremio, ready: true, autoplay: true)) }
                            else { model.say("Couldn’t find the next episode") }
                        }
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(TVModel.self) var model
    // The build's simulator shots ask for screens a launch alone can't reach.
    func poseForShots() {
        #if os(iOS)
        HitchLog.shared.start()
        #endif
        guard let pose = UserDefaults.standard.string(forKey: "pose") else { return }
        if pose == "shelf" { return } // the shelf films land a finger on Watch themselves (tv-flick workflow)
        // Words typed into the Apps page's search: the keyboard up, as it is when he types them.
        if pose == "search" { model.tab = 6; SendDraft.shared.wantsFocus = true; SendDraft.shared.focusRequest += 1; SendDraft.shared.text = "Heat"; return }
        // The search tab opened with nothing typed (recent searches and what he's in the middle of), then typed into a key at a
        // time, as a finger does: each keystroke's first results timed in the stand-in Mac's log.
        if pose == "searchempty" { SearchStore.shared.forgetAll(); for t in ["Sample Series", "Heat"] { SearchStore.shared.remember(t) }; SearchStore.show(model, text: ""); return }
        // An app found and opened from the search: the keyboard goes and the Remote comes up, nothing left behind.
        if pose == "searchapp" {
            Task {
                SearchStore.show(model, text: "")
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                SendDraft.shared.text = "netflix"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let h = SearchStore.shared.results.top { SearchStore.shared.open(h, model: model, origin: nil) }
            }
            return
        }
        if pose.hasPrefix("searchtype") {
            let words = pose == "searchtype-show" ? "alien s1e2" : pose == "searchtype-slip" ? "haet" : "heat"
            Task {
                SearchStore.show(model, text: "")
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                for n in 1...words.count {
                    SendDraft.shared.text = String(words.prefix(n))
                    try? await Task.sleep(nanoseconds: 220_000_000)
                }
            }
            return
        }
        // The Remote's search field tapped, then words typed: the Apps page's search, keyboard up, results in.
        if pose == "remotesearch" {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                SendDraft.shared.wantsFocus = true; SendDraft.shared.focusRequest += 1; model.tab = 6
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                SendDraft.shared.text = "Heat"
            }
            return
        }
        // Words typed into Watch's own search that find one film: it's shown, under its own name (fewer than eight used to
        // come out as an empty page).
        if pose == "watchsearch" {
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); let s = BrowseStore.discover("movie"); s.query = "Heat"; s.searchSoon() }
            return
        }
        // Shown by the views themselves (the episodes over the Remote, a held scrub, the Live Activity), nothing to flick.
        if ["tour", "type", "episodes", "scrub", "island", "connection", "tvsettings", "tvapps", "settingsnav", "settingsscript", "stremiotile"].contains(pose) { return }
        // The Remote's picture hidden, then shown again, as its held menu does it: filmed, so each change is seen to fade.
        if pose == "mirror" {
            Task {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                model.setMirror(false)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                model.setMirror(true)
            }
            return
        }
        // A title's details page, pushed over Stremio's page (AppBrowse opens it once the rows are in).
        if pose == "details" { model.tab = 1; model.browsing = .stremio; return }
        // A link pasted into the Remote's field: its card comes up, and the flick's own demo throws it.
        if pose == "flick-link" || pose == "flick-link-art" {
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); model.send("https://www.youtube.com/watch?v=dQw4w9WgXcQ") }
            return
        }
        // The real-data flows (CI's /real scene): each taps through the same code a finger would.
        if pose == "realtap" {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                model.tab = 1; model.browsing = .stremio
                for _ in 0..<80 {
                    let cw = BrowseStore.shared(.stremio).rows.first { $0.title == "Continue watching" }
                    if let item = cw?.items.first(where: { $0.id == "tt1234567" || $0.stremioRef?.imdb == "tt1234567" }) { FlickCardButton.tap(model, item, .stremio); return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            return
        }
        if pose == "realsearch" {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                model.tab = 6
                try? await Task.sleep(nanoseconds: 800_000_000)
                SendDraft.shared.wantsFocus = true; SendDraft.shared.focusRequest += 1
                try? await Task.sleep(nanoseconds: 800_000_000)
                SendDraft.shared.text = "Heat"
                for _ in 0..<80 {
                    let st = SearchStore.shared
                    if let h = st.results.top ?? st.results.groups.first?.hits.first { try? await Task.sleep(nanoseconds: 1_200_000_000); st.open(h, model: model, origin: nil); return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            return
        }
        if pose == "realseries" {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                // A series opens on its episodes: the picker is the page's first step.
                for _ in 0..<80 {
                    if let item = BrowseStore.shared(.stremio).rows.flatMap(\.items).first(where: { $0.id == "tt1234567" || $0.stremioRef?.imdb == "tt1234567" }) { FlickCardButton.tap(model, item, .stremio); return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            return
        }
        // ⏭ pressed before the show's next episode is known: the light runs round the key until it throws (r20).
        if pose == "realnext" {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                NextUp.shared.forgetAll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                Transport.pressNext(model)
            }
            return
        }
        // Pause, a few seconds, play: the clock must hold at the pause and carry on from where the TV stopped, not jump.
        if pose == "realclock" {
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                model.togglePlay(shown: model.shownPlaying(model.staleStatus ? nil : model.status?.session?.playing))
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                model.togglePlay(shown: model.shownPlaying(model.staleStatus ? nil : model.status?.session?.playing))
            }
            return
        }
        if pose == "realpause" {
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                model.togglePlay(shown: model.shownPlaying(model.staleStatus ? nil : model.status?.session?.playing))
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                model.togglePlay(shown: model.shownPlaying(model.staleStatus ? nil : model.status?.session?.playing))
            }
            return
        }
        // Three quick skips on a film near its end, caught before the TV has confirmed them.
        if pose == "skip" {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for _ in 0..<3 { SeekQueue.shared.add(1, for: model.status?.session, model: model) }
            }
            return
        }
        guard pose != "browse", pose != "stremiorow" else { return }
        Task {
            // Stremio's rows asked for here (no page of its own loads them now), then the first film or show opened as
            // its page, through the card's own tap, as a finger would.
            await BrowseStore.shared(.stremio).load()
            for _ in 0..<40 {
                if let item = BrowseStore.shared(.stremio).rows.flatMap(\.items).first(where: { $0.kind == (["streams", "flickdemo", "flickdemo-stream", "blurbopen"].contains(pose) || pose.hasPrefix("flick-") ? "movie" : "series") }) {
                    // The stream flick goes as he does it most: the best stream found for him, in the hand, thrown.
                    // Through the card's own tap, as a finger would: what's already on goes to the Remote with nothing sent.
                    // "-art" poses: the tile's picture is in memory first, as on his phone, so the page's arrival is judged
                    // with its poster and ground.
                    if pose.hasSuffix("-art"), let u = URL(string: item.art) { _ = await ImageStore.shared.load(u); _ = await ImageStore.shared.band(u); if let h = ImageStore.shared.cached(u) { _ = await ImageStore.shrunk(h, 16) } }
                    FlickCardButton.tap(model, item, .stremio, ready: pose == "flickdemo-stream" || pose.hasPrefix("flick-")); return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    @State private var resets: [Int: Int] = [:]
    // Four tabs, and never a fifth (Richard, 2026-11-20: "never a more thing ever"). Watch leads. Apps is a row on the
    // Remote; the box's figures and Settings are behind the lip's gear. The values are the old ones, so links, widgets and
    // intents land where they did.
    static let railItems = [
        RailItem(value: 3, title: "Watch", symbol: "film"),
        RailItem(value: 0, title: "Remote", symbol: "av.remote"),
        RailItem(value: 6, title: "Search", symbol: "magnifyingglass"),
    ]
    private var tabBinding: Binding<Int> {
        TabReset.binding(Binding(get: { model.tab }, set: { if $0 != model.tab { Haptic.fire(.tick) }; model.tab = $0 })) { t in
            // Back to the tab's own start: anything opened on it closes, and its page goes back to the top. Nothing is
            // rebuilt, so what was loaded, and the choices made on it, stay.
            if t == 1 { model.browsing = nil }
            // The search tab tapped again: the field takes the keyboard, as Apple's own apps do.
            if t == 6 { SendDraft.shared.wantsFocus = true; SendDraft.shared.focusRequest += 1 }
            resets[t, default: 0] += 1
        }
    }
    @ViewBuilder private func tabPage(_ t: Int) -> some View {
        switch t {
        case 3: Page(title: "Watch", tab: 3, accessory: AnyView(WatchFilterKey()), retaps: resets[3, default: 0]) { FilmsTab() }
        case 0: Page(title: "Remote", tab: 0, accessory: AnyView(SpeakerKey()), retaps: resets[0, default: 0]) { RemoteTab() }
        default: Page(title: "Search", tab: 6, retaps: resets[6, default: 0]) { SearchPage() }
        }
    }
    // The Playing tab's glyph, kept here only when it changes (PlayingGlyph below works it out), so a status reading
    // never redraws the whole tab view.
    @State private var playingSymbol = "play.circle"
    var body: some View {
        let _ = SwipeLog.mark("body root")
        PaneReader {
            // The system's own tabs, placed by iOS: down the side strip folded and open in landscape, a bar along the foot
            // open upright (HIG, iPhone Duo, "Vertical controls"; Richard, 2026-11-23: "in line with latest ios
            // documentation on everything").
            TabView(selection: tabBinding) {
                ForEach(Self.railItems) { it in
                    Tab(value: it.value) {
                        tabPage(it.value).environment(\.tabInFront, model.tab == it.value)
                    } label: { it.label }
                }
            }
            .onChange(of: model.tab) { was, t in
                #if os(iOS)
                HitchLog.shared.note("tab \(was)→\(t)")
                #endif
                UserDefaults.standard.set(t, forKey: "tab")
                // Opening Playing shows what's on now, not what was on at the last look.
                if t == 2 { Task { await model.load() } }
            }
            // A poster lifted off a shelf, over everything, where his finger has it (Liftable).
            .overlay { HandOverlay() }
        }
        .background { Color.clear.ignoresSafeArea().onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { Hand.shared.screen = $0 } }
        // What follows the status lives in small views of its own, so only they redraw when it changes.
        .background { StatusFollower(playingSymbol: $playingSymbol) }
        // The Mac out of reach is the lip's to say ("Reconnecting…"); a pill here covered every page's title (tv-pass-1122).
        .overlay(alignment: .bottom) { ToastBubble() }
        .onAppear { BackFinder.start(); followRequest(); poseForShots(); TabTour.run(UserDefaults.standard.string(forKey: "tourTabs").map { $0.split(separator: ",").compactMap { Int($0) } } ?? [3, 0, 6]) { model.tab = $0 } }
        // Stremio's home, where Continue watching comes from, is asked for at launch, so every page shows the same row.
        .task {
            await BrowseStore.shared(.stremio).loadHome()
            // Watch's films asked for at launch too (the data only, no views), so its first visit is filled (tv-pass-1122).
            await BrowseStore.discover(UserDefaults.standard.string(forKey: "watchKind") ?? "movie").load()
        }
        .onReceive(NotificationCenter.default.publisher(for: FlickRequest.airPlay)) { _ in followRequest() }
    }
    // Control Center and Siri can ask before this view exists, so the request waits in a flag.
    func followRequest() {
        if FlickRequest.wantsRemote { FlickRequest.wantsRemote = false; model.tab = 0 }
        if FlickRequest.wantsAirPlay { FlickRequest.wantsAirPlay = false; model.tab = 0 }
    }
}

extension View {
    // Dimmed and still in its place while the TV sleeps: a key that does nothing then never looks live.
    func sleepDim(_ on: Bool) -> some View { opacity(on ? 0.35 : 1).allowsHitTesting(!on).accessibilityHidden(on) }
}

// Whether the tab a view is on is the one in front: what must stop when he leaves a tab (the TV's live picture, the
// AirPlay search, polling) follows this as well as its appearance.
// (tabInFront lives in TVTheme, beside SettledAnimation, which follows it too.)
// On screen: appeared, on the tab in front. Each on is matched by one off, as onAppear by onDisappear.
private struct OnScreen: ViewModifier {
    @Environment(\.tabInFront) private var front
    @State private var here = false
    let change: (Bool) -> Void
    func body(content: Content) -> some View {
        content
            .onAppear { here = true; if front { change(true) } }
            .onDisappear { here = false; if front { change(false) } }
            .onChange(of: front) { _, f in if here { change(f) } }
    }
}
extension View { func onScreen(_ change: @escaping (Bool) -> Void) -> some View { modifier(OnScreen(change: change)) } }

// Works out what the whole app follows from the status (the Playing tab's glyph, the picture behind every page) without
// RootView itself reading the status.
private struct StatusFollower: View {
    @Environment(TVModel.self) var model
    @Binding var playingSymbol: String
    // A TV for a film or show, a note for Mint, AirPlay for the phone's own sound.
    var symbol: String {
        // Not from the status kept from last time: it flipped to Mint's note on opening and back a second later (r34).
        if model.staleStatus { return playingSymbol }
        if model.otherAirPlay { return "airplayaudio" }
        if model.videoIsCurrent { return "play.tv" }
        if model.nowMusic?.playing == true { return "music.note" }
        return "play.circle"
    }
    var body: some View {
        Color.clear
            .onChange(of: symbol, initial: true) { _, s in if s != playingSymbol { playingSymbol = s } }
            // The one picture behind every page follows what's on.
            .task(id: model.ambienceArt) {
                await AmbienceStore.shared.show(model.ambienceArt)
                // A film's colour kept after its flick gives way once something else is what's on.
                if model.moodArt != nil, !(model.videoIsCurrent && model.status?.session?.pkg == "com.stremio.one") {
                    model.moodArt = nil; model.mood = nil
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
private struct ToastBubble: View {
    @Environment(TVModel.self) var model
    var body: some View {
        ZStack {
            if let t = model.toast {
                Text(t).font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 11)
                    .glassEffect(.regular, in: Capsule()).padding(.bottom, 24).transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(TVLook.press, value: model.toast)
    }
}

// The top of every page. The system's soft edge drew a frosted block behind the clock over scrolled rows, so it's off,
// and each scroll view fades its own top instead: the same fade edge to edge, side bar and panes alike.
private struct TopShade: ViewModifier {
    func body(content: Content) -> some View { content.scrollEdgeEffectHidden(true, for: .top) }
}
// The fade itself, from the very top of the display, so it reaches under the side bar and the clock too.
// `on` false: no fade, for a page at rest at its top, whose first heading would sit in it, grey (tv-pass-1122).
struct TopFade: ViewModifier {
    var on = true
    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(on ? 0 : 1), .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
                    .animation(.easeOut(duration: 0.15), value: on)
                Color.black
            }
            .ignoresSafeArea()
        }
    }
}
extension View {
    func topShade() -> some View { modifier(TopShade()) }
    // On a page's own scroll view (or the group of them), never on a whole stack, whose bar would fade with it.
    func topFade() -> some View { modifier(TopFade()) }
}

// Each tab's frame: the art behind it, its title, and the gear.
struct Page<C: View>: View {
    @Environment(TVModel.self) var model
    @Environment(\.paneLayout) private var panes
    let title: String
    // Which tab this is, so only the one showing answers an ask to push a page.
    var tab = -1
    // One key beside the page's name (Watch's filter).
    var accessory: AnyView? = nil
    var alwaysInline = false
    // The system's bar shown over the page's own heading, for a toolbar item of its own; no title in it.
    var showsBar = false
    // Taps on this tab's button while it's already showing.
    var retaps = 0
    @ViewBuilder let content: () -> C
    @State private var path = NavigationPath()
    // Where Settings sits on this stack, while it's open: the gear tapped on Settings, or on a page under it, pushed a second
    // Settings over the first (audit of 5b7b503).
    @State private var settingsAt: Int?
    func push(_ v: any Hashable) {
        if let r = v as? SettingsRoute, r == .root {
            guard settingsAt == nil else { return }
            settingsAt = path.count
        }
        path.append(v)
    }
    @State private var top = 0
    @State private var scrolled = PageScrollY()
    // With the bar shown (Status' gear), the room it takes above the heading where iOS puts its items in the side strip
    // (folded, open flat): taken back, so the heading sits where every other tab's does (gate of 96f5f42: 15 pt lower).
    // Open upright the bar is the top bar the clock already keeps clear, and costs nothing. Measured on the gate's shots:
    // 43 px at 3x (Status' words at 114 px against 71 px). Every attempt to measure it live (insets, an empty stack, the
    // heading's own frame) missed by 9 pt or more by posture, or chased its own move (gates of b01454f to bc5d7cd).
    @Environment(\.horizontalSizeClass) private var hSize
    var barRoom: CGFloat { showsBar && !(hSize == .regular && !panes) ? 43.0 / 3 : 0 }
    var body: some View {
        // The lip: the TV, along the top of this tab and of every page opened on it. Above the stack, not in it, so a push
        // moves under it and it never redraws; the stack's own bar (Back) sits beneath it, clear of the status area.
        VStack(spacing: 0) {
        Lip(tab: tab).environment(\.pagePush, PagePush(push: { push($0) }, pop: { if !path.isEmpty { path.removeLast() } }))
            // Its right end in line with the page's under it, the rail's column clear from top to foot.
            
        // The art and the edge setting sit on the stack, not the page. The fade itself is on each scroll view (backToTop).
        NavigationStack(path: $path) {
            content()
                .underFlick(warms: alwaysInline)
                .modifier(TabBarFade())
                .environment(\.backToTop, top)
                .environment(\.pageScroll, alwaysInline ? nil : scrolled)
                // The page's name, large, drawn by the page and going up with what scrolls under it, so the two never sit
                // on each other. The system's large title stayed put on the Watch tab while the rows ran up under it,
                // "Watch" printed over "Continue watching" (Richard, 2026-11-07: "look at how the watch header interacts
                // with the other text"): it can only follow a scroll view it finds at the page's root, and the pages'
                // own layouts (two panes, overlays) hid it.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !alwaysInline {
                        MovingTitle(title: title, scrolled: scrolled, accessory: accessory)
                    }
                }
                // Clear of the rail, keys, last rows and all: nothing of the page sits under the pill. Inside the stack, on
                // each page pushed too, so a pushed page's own Back strip is counted once, not added to it.
                
                // Status' page, heading and all, moved up by the bar's room as one: a move, not a new layout, so nothing
                // under it measures itself again; its foot reaches down as far.
                .padding(.bottom, -barRoom)
                .offset(y: -barRoom)
                .toolbar(showsBar ? .automatic : .hidden, for: .navigationBar)
                // Lets the page push a page of its own when asked from elsewhere (Settings, from a link or tab 9).
                .environment(\.pagePush, PagePush(push: { push($0) }, pop: { if !path.isEmpty { path.removeLast() } }))
                .navigationDestination(for: RowRoute.self) { $0.page.underFlick(barHidden: true) }
                // A title's page: its poster a card for his hand. Pushed here, so Back is the system's and returns to this
                // tab exactly as he left it.
                .navigationDestination(for: TitleRoute.self) { r in
                    if let t = TitleRoutes.target(r) { TitlePage(target: t).holdsWhileMoving("title") }
                }
                .modifier(SettingsPages(tab: tab))
                .environment(\.pagePush, PagePush(push: { push($0) }, pop: { if !path.isEmpty { path.removeLast() } }))
                .containerBackground(.clear, for: .navigation)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationTitle(title)
                // Large open as well as folded, so every page's name leads the headings under it, as in the Mac Pro app
                // (Richard, 2026-11-05). Only the Remote, which has no headings and no room to spare, keeps it in the bar.
                .navigationBarTitleDisplayMode(alwaysInline ? .inline : .large)
        }
        }
        .onChange(of: model.titleAsks) { _, _ in
            guard model.tab == tab, let t = model.titleAsk else { return }
            model.titleAsk = nil
            path.append(TitleRoutes.add(t))
        }
        .topShade()
        .background {
            ZStack {
                Ambience()
                if let g = model.titleGrounds.last(where: { $0.tab == tab }) { TitleGround(art: g.art).transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.3), value: model.titleGrounds.last(where: { $0.tab == tab })?.art)
        }
        // Over the art too, so the strip round the bars beside or under a flick's page is black like the page's own foot,
        // never a lighter band of the tab's art (open upright, under the tab bar).
        .modifier(UnderFlickGround(warms: alwaysInline))
        // A list opened from the tab closes first; once on the tab's own page, it goes to the top.
        .onChange(of: retaps) { _, _ in if path.isEmpty { top += 1 } else { path = NavigationPath() } }
        // A page opened from a search leaves the keyboard behind.
        .onChange(of: path) { was, now in
            if let at = settingsAt, now.count <= at { settingsAt = nil }
            Keyboard.dismiss()
            PageMoves.count += 1
            #if os(iOS)
            HitchLog.shared.note("\(title) \(now.count > was.count ? "push" : "pop") \(was.count)→\(now.count)")
            #endif
        }
    }
}

// Every push and pop on any tab's stack, counted: a throw waiting on its list, or the Remote's unseen build, that sees it
// change since it began knows he has moved on, and lets go.
@MainActor enum PageMoves { static var count = 0 }

// How far a tab's page has scrolled, from whichever of its scroll views moved last.
@Observable final class PageScrollY { var y: CGFloat = 0 }
// For a page that isn't a Page (Settings' lists): its scrolling read into the title's measure, as BackToTop does.
private struct FollowsScroll: ViewModifier {
    let scrolled: PageScrollY
    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
            if abs(scrolled.y - y) > 0.25 { scrolled.y = y }
        }
    }
}
private struct PageScrollKey: EnvironmentKey { static let defaultValue: PageScrollY? = nil }
extension EnvironmentValues { var pageScroll: PageScrollY? { get { self[PageScrollKey.self] } set { self[PageScrollKey.self] = newValue } } }
// A tab's large title, moving up exactly as far as the page under it has scrolled and fading as it goes, as if it were
// the page's first line. Only this redraws as the page scrolls.
private struct MovingTitle: View {
    let title: String
    let scrolled: PageScrollY
    var accessory: AnyView? = nil
    // What the display already keeps clear above the page: the clock's row open upright; nothing folded or open flat,
    // where the clock is on the side and the name sat 13 pt from the glass (Richard, 2026-11-09, Playing folded: "too
    // close to top edge"). It takes the same air from the top as from the side then, 22 pt to its cap, every tab alike.
    @State private var above: CGFloat = 0
    // Open flat the left pane's content has the display's bare edge 14 pt more air (FoldSplit's outer): the name lines up
    // with it, not 14 pt left of every card under it.
    @Environment(\.paneLayout) private var panes
    var body: some View {
        let y = max(0, scrolled.y)
        HStack(alignment: .center, spacing: 12) {
            PageHeading(title).allowsHitTesting(false)
            if let accessory { accessory.allowsHitTesting(y < 20) }
        }
            .padding(.leading, panes ? 34 : 20).padding(.trailing, 20).padding(.top, max(4, 13 - above)).padding(.bottom, 8)
            .background { Color.clear.ignoresSafeArea(edges: .top).onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { above = $0 } }
            .offset(y: -y)
            .opacity(Double(max(0, 1 - y / 44)))
    }
}
// On each scrolling part of a page: it says when it's moving (ScrollMoving).
private struct SummonsBar: ViewModifier {
    func body(content: Content) -> some View { content.modifier(ScrollMoving()) }
}
// Every scrolling page says when it's moving (BackToTop and SummonsBar carry this): the TV's polled status waits while
// one is, so no row changes height under a page pulled past its end, which snaps the page back in one move instead of
// letting it spring (Richard, 2026-11-08: "it doesnt bounce back naturally its like a sudden move back", in all apps).
// Read from the page's geometry as well as its phase (ScrollWatch, Shared): a List reports no phase, and a page held
// past its end under a still finger stays held whatever the phase says, since a reading landing then is the snap itself.
struct ScrollMoving: ViewModifier {
    @State private var track = Track()
    @MainActor final class Track {
        let watch: ScrollWatch
        init() { let id = UUID(); watch = ScrollWatch("page") { ScrollHold.set(id, moving: $0) } }
    }
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, g in track.watch.geometry(g) }
            .onScrollPhaseChange { _, phase in track.watch.phase(touching: phase != .idle) }
            .onDisappear { track.watch.stop() }
        #else
        content
        #endif
    }
}
// Which pages are moving right now. Only the polled status waits while any is, and for 4 s at most after it was last
// seen moving: his own presses, and every load they ask for, go straight through (TVModel). A page that has just gone
// idle keeps the hold half a second longer: on his phone the spring back from a pull still snapped (2026-11-09), and a
// reading landing on the phase's first idle moment, while the page is still settling, is the one way left for a row to
// change height under it. The 4 s count from the last motion, not the first: counted from the first, a few flicks down a
// long page and the pull after them used it up, and the reading landed under the pull (the Mac Pro app's CI f7bb947
// found the same there).
@MainActor
enum ScrollHold {
    private static var moving: Set<UUID> = []
    private static var since = Date.distantPast
    private static var settling: Task<Void, Never>?
    static var onRelease: (() -> Void)?
    static var holding: Bool { (!moving.isEmpty || settling != nil) && Date().timeIntervalSince(since) < 4 }
    static func set(_ id: UUID, moving now: Bool) {
        let was = !moving.isEmpty || settling != nil
        if now { moving.insert(id); settling?.cancel(); settling = nil } else { moving.remove(id) }
        if now { since = Date() }
        if was && !now && moving.isEmpty && settling == nil {
            settling = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                settling = nil
                onRelease?()
            }
        }
    }
}
struct PageHeading: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        Text(title).font(.largeTitle.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}
// An action in the page's toolbar: its glyph and its name, so the system can show either (HIG, toolbar items).
struct PageBarAction: View {
    @Environment(TVModel.self) var model
    let title: String, icon: String
    let action: () -> Void
    var body: some View {
        Button { model.tick(); action() } label: { Label(title, systemImage: icon) }
    }
}
private struct BarPage<Actions: View>: ViewModifier {
    let actions: () -> Actions
    func body(content: Content) -> some View {
        content
            // The system's own Back, laid out by iOS the Duo's way: at the top of the side strip folded and open in
            // landscape, in the top bar open in portrait, with the edge swipe (Apple's HIG for iPhone Duo, "Vertical
            // controls"). The page draws its own large heading, so the bar draws no title (each page names itself to
            // the system with toolbar(removing: .title), for Back's history menu). A page's own action (Open on TV)
            // is the system's toolbar item.
            .toolbar(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItemGroup(placement: .primaryAction) { actions() } }
    }
}
extension View {
    func summonsBar() -> some View { modifier(SummonsBar()) }
    // A page opened from a tab, with its bar. The page draws its own PageHeading at the top of what scrolls.
    func barPage<A: View>(@ViewBuilder actions: @escaping () -> A) -> some View { modifier(BarPage(actions: actions)) }
    func barPage() -> some View { modifier(BarPage(actions: { EmptyView() })) }
}

// Where the Mac is, and what it takes to reach it from away.
struct ConnectionView: View {
    @Environment(TVModel.self) var model
    @Environment(\.paneLayout) private var panes
    @State private var address = ""
    var body: some View {
        // Open flat, the page keeps to the left pane, never one card across the fold (gate 276, fifth pass).
        Group { if panes { FoldSplit { page } right: { Color.clear } } else { page } }
        // The wall behind the whole page, both panes, not only the one holding the card (sixth pass: the right half black).
        .background { Ambience() }
        // No title in the bar: the page draws its own large heading, and the system printed the title above it a second
        // time (c2db3e9's and bff5ee8's runs; emptied from outside, the page's own won). Back over this page reads "Back".
        .navigationTitle("Connection").toolbar(removing: .title).navigationBarTitleDisplayMode(.inline)
        .barPage()
        .onAppear { address = model.address }
    }
    var page: some View {
        // A glass section of the app's own, not a Form's one-row capsule (gate 276).
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading("Connection").padding(.horizontal, 4)
                // One row, so its note is its second line rather than a footer under a lone capsule (the designer's cure
                // for one-row sections, 2026-11-11).
                GlassSection(header: "Mac Pro address") {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Address", text: $address).autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                            .submitLabel(.done)
                            .onSubmit { model.address = address.trimmingCharacters(in: .whitespacesAndNewlines); model.start() }
                        Text("Works anywhere with Tailscale on, as long as the Mac is awake and can reach the TV.")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, GlassCard.inset).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .topShade().topFade()
        .summonsBar()
    }
}

// Type or paste anything: a link opens in the right app, words become a search right here.
struct SendBar: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var draft = SendDraft.shared
    @FocusState private var focused: Bool
    static func isLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.contains("://") || t.lowercased().hasPrefix("www.") || (!t.contains(" ") && t.contains(".") && t.contains("/"))
    }
    // On the Remote: the field opens the search where its results are, the Apps page, with the keyboard up. Typed into on
    // the Remote it searched nothing there, and the keyboard squeezed the pad and keys into half circles (Richard,
    // 2026-11-07: "lol when search for whatever").
    var opensSearch = false
    var link: Bool { Self.isLink(draft.text) }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: link ? "paperplane" : "magnifyingglass").foregroundStyle(.secondary).padding(.leading, 14)
                .contentTransition(.symbolEffect(.replace))
            if opensSearch {
                Button { SearchStore.show(model) } label: {
                    // Always its own words: the last search's words belong to the Search tab, not to this page.
                    Text("Search, or send a link").foregroundStyle(.tertiary)
                        .lineLimit(1).frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Search, or send a link")
            } else {
            TextField("Search, or send a link", text: $draft.text)
                .focused($focused).autocorrectionDisabled().submitLabel(link ? .send : .search)
                .hidesTabBar(while: focused, "send")
                // For the build's shots: whether the field took the keyboard, and when it let it go, in the mock's log,
                // so a search shot with no keyboard can be read (the field never focused, or lost it) rather than guessed.
                .onChange(of: focused) { _, on in
                    if UserDefaults.standard.string(forKey: "pose") != nil { Task { _ = await TVBridge.data(TVBridge.url("/api/tv/applied?what=focus&on=\(on ? 1 : 0)"), timeout: 3) } }
                }
                // Words are already being searched as they're typed, so Return only puts the keyboard away.
                .onSubmit { if link { submit() } else { focused = false } }
                // Asked for from the Remote's field (or a pose): the keyboard comes up once this page is on screen, whether
                // the page is built fresh for it or was built earlier and is only now shown. One task keyed on the request
                // does both; an `onChange` on the request was missed when the page sat built but hidden in its tab
                // (cb0319c's run: no focus at all from the Remote's field, open in portrait).
                .task(id: draft.focusRequest) {
                    guard draft.wantsFocus else { return }
                    // Asked for until the field has it, up to about four seconds, and the request is spent only then: if this
                    // field goes away first (the page rebuilt under the tab change), the next one carries on with it. Open in
                    // portrait the keyboard came up on some runs and not others (three of five missed, from the Remote's
                    // field to the Apps page), the same path his tap takes.
                    for _ in 0..<10 {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if Task.isCancelled { return }
                        focused = true
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        if focused { draft.wantsFocus = false; return }
                    }
                    draft.wantsFocus = false
                }
            }
            if draft.text.isEmpty || opensSearch {
                Button {
                    #if canImport(UIKit)
                    // A copied link goes to the TV; copied words are searched here, like typed ones.
                    if let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                        if Self.isLink(s) { model.send(s) } else if opensSearch { SearchStore.show(model, text: s) } else { draft.text = s }
                    } else if opensSearch { SearchStore.show(model) } else { focused = true }
                    #endif
                } label: { Image(systemName: "doc.on.clipboard").frame(width: 44, height: 44) }
                .buttonStyle(.plain).foregroundStyle(TVLook.accent).accessibilityLabel("Use what you copied")
            } else if link {
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(TVLook.accent).accessibilityLabel("Send to the TV")
            } else {
                Button { draft.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .frame(height: 50)
        .glassEffect(.regular, in: Capsule())
        // The glyph at the front and the key at the end follow what's typed (search, a link, nothing): the front's symbol
        // replace only runs inside an animation, and the end's key popped from clipboard to x as the first letter went in.
        .animation(.easeOut(duration: 0.2), value: link)
        .animation(.easeOut(duration: 0.2), value: draft.text.isEmpty)
    }
    func submit() { if link { model.send(draft.text); draft.text = "" } }
}

// Under a heading whose rows are the ones kept from last time because the Mac can't be asked for fresh ones: when
// they were last seen, so old rows never pass for now (the rows themselves are dimmed).
struct KeptNote: View {
    let since: Date
    static let ago: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f }()
    var body: some View {
        // Said afresh on each minute since then, so it's never left saying less than is true; under one it's "just now".
        TimelineView(.periodic(from: since, by: 60)) { ctx in
            Text(ctx.date.timeIntervalSince(since) < 60 ? "Last seen just now" : "Last seen " + Self.ago.localizedString(for: since, relativeTo: ctx.date))
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 20)
        }
        .transition(.opacity)
    }
}
struct RowTitle: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View { Text(title).font(.title3.weight(.bold)).padding(.bottom, 8) }
}

// A row's heading: tap it to see everything in that row as one scrolling list.
struct RowHeader: View {
    @Environment(\.openRow) private var openRow
    let title: String
    let route: RowRoute
    var body: some View {
        Group {
            // On a page that was itself pushed by an item (an app's page), the row opens through that page (openRow);
            // elsewhere by value on the tab's own path.
            if let openRow { Button { openRow(route) } label: { label } }
            else { NavigationLink(value: route) { label } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See all of \(title)")
    }
    var label: some View {
        HStack(spacing: 5) {
            Text(title).font(.title3.weight(.bold))
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
        .contentShape(Rectangle())
    }
}
private struct OpenRowKey: EnvironmentKey { static let defaultValue: ((RowRoute) -> Void)? = nil }
extension EnvironmentValues {
    var openRow: ((RowRoute) -> Void)? { get { self[OpenRowKey.self] } set { self[OpenRowKey.self] = newValue } }
}
// The same frame for every full list: the art behind it and the rows on top.
struct RowList<Content: View>: View {
    @Environment(TVModel.self) var model
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        List {
            PageHeading(title).listRowBackground(Color.clear).listRowSeparator(.hidden)
            content().listRowBackground(Color.clear)
        }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .summonsBar()
            .topShade().topFade()
            .background { Ambience() }
            .navigationTitle(title).toolbar(removing: .title).navigationBarTitleDisplayMode(.inline)
            .barPage()
    }
}

// MARK: - Remote
struct MirrorView: View {
    @Environment(TVModel.self) var model
    @ObservedObject var store: MirrorStore
    // Where it always has its place, it carries its own way to hide it, and the bar has no second one.
    var closable = false
    // A playing film is black on any capture of the screen, so its poster stands in, sat on a blurred copy of itself.
    // So does one just flicked, until the TV says it's playing.
    var film: URL? {
        // Mint's song: its cover, sharp on its blur, never the dark box the capture of Mint's screen often was (audit of
        // 5b7b503).
        if model.musicIsCurrent, let m = model.nowMusic, !m.art.isEmpty { return URL(string: m.art) }
        guard model.mirrorLive else { return nil }
        // Including the status kept from last time, on opening, so the first frame is the poster it'll stay, not the last
        // still of the screen swapped for the poster a moment later (r17).
        // Playing or paused: a paused film is as black on a capture as a playing one, and swapping to the capture on pause
        // (and back on play) made the picture jump with every press (r18).
        if model.videoIsCurrent, let s = model.status?.session, let p = model.poster(for: s) { return URL(string: p) }
        return model.standInNow.flatMap(URL.init(string:))
    }
    // The picture drawn, which only moves on to a new one once it's loaded, then fades in over what was there: the
    // flicked poster gives way to the TV's own without a frame of empty glass between. Unset until first drawn.
    @State private var drawn: URL??
    // Which of the pictures below is up, apart from the poster itself (that's `film`).
    var look: Int {
        if !model.mirrorLive { return 0 }
        if let s = model.starting, !s.played { return 1 }
        return model.filmOnScreen ? 2 : 3
    }
    var body: some View {
        let film = drawn ?? self.film
        ZStack {
            Color.black.opacity(0.35)
            if let film {
                PosterOnBlur(url: film)
                .id(film)
                .transition(.opacity)
            } else if let s = model.starting, !s.played {
                // While a flicked film starts, never the TV's own picture under its poster: a launcher still read through
                // PosterOnBlur's first frames (r26). Dark until the poster's in; the TV's picture only once it plays.
                NoPictureSoon()
            } else if self.film != nil {
                // A poster on its way (a film following a show): the dark glass until it's loaded and fades in, never the
                // new film's TV glyph for the moment between (Remote gate 3: a grey glyph flashed for 0.25 s), unless it
                // takes longer than that.
                NoPictureSoon()
            } else if model.mirrorLive && model.filmOnScreen {
                // A film playing with no poster to stand in (YouTube, a stream without art): the stream is stopped for it, and
                // the frame it left was the launcher from before the film, dimmed with a spinner for as long as it played
                // (r32 repisode and ryoutube shots). Nor an empty box (r33: the wall's art is the poster it hasn't got, so
                // that was always blank): the picture of what's on that there is (YouTube's, Stremio's own banner) as a
                // poster is shown, sat on a blurred copy of itself, and nothing claiming to be the TV's screen.
                // Never Stremio's own banner, though: the app doing the work isn't what he's watching (r34: its logo filled the
                // picture for an episode with no poster). YouTube's banner is, near enough.
                if model.status?.session?.pkg != "com.stremio.one", let art = model.nowArt.flatMap(URL.init(string:)) {
                    PosterOnBlur(url: art).id(art).transition(.opacity)
                } else if model.status?.session?.pkg == "com.stremio.one" { EpisodeStill() } else { NoPicture() }
            } else if model.mirrorLive {
                #if os(iOS)
                ScreenPicture(live: model.live, store: store, art: model.nowArt)
                #else
                if let m = store.image { Image(tv: m).resizable().scaledToFit() }
                #endif
            } else {
                // Never an empty box and never a key asking to be shown (2026-11-20): what is on, sharp, else the TV's glyph.
                if let art = model.nowArt.flatMap(URL.init(string:)) { PosterOnBlur(url: art).id(art) } else { NoPicture() }
            }
        }
        .aspectRatio(16.0 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: TVLook.card, style: .continuous))
        .settledAnimation(.easeOut(duration: 0.25), value: film)
        // Every other change of what the picture is (the live screen to a poster's place, hidden and shown again) fades
        // the same way: the live picture cut to the TV glyph the frame a film's status came in, before its poster was
        // known (tv21 posture-remote 9.06 → 9.15 s), and hiding the screen swapped it for the blurred art in one frame.
        .settledAnimation(.easeOut(duration: 0.25), value: look)
        .task(id: self.film) {
            let next = self.film
            guard let current = drawn else { drawn = .some(next); return }
            guard next != current else { return }
            if let next, ImageStore.shared.cached(next) == nil { _ = await ImageStore.shared.load(next) }
            if !Task.isCancelled { drawn = .some(next) }
        }
        // Where it is, for a flick's screen to move onto it. Nothing moves this view, so the measure moves nothing.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.mirrorSlot = $0 }
        .onScreen { model.mirrorShown($0) }
    }
}
#if os(iOS)
// The TV's screen itself: the live stream once it has a picture, and until then (or without one) the latest still,
// shown dimmed with the light running round it once it's more than a few seconds old, so an old picture never passes for now.
private struct ScreenPicture: View {
    @ObservedObject var live: LiveMirror
    @ObservedObject var store: MirrorStore
    let art: String?
    // Coming back to the Remote, the kept frame is what was on a moment ago and the stream is on its way: it isn't dimmed
    // as old for this long, so the picture never dips and comes back. Only a moment ago, though: a frame from minutes
    // back (the Remote left long since) is dimmed from the first frame, never shown bright as if it were the TV now.
    @State private var shownAt = Date()
    func isOld(_ taken: Date, _ now: Date) -> Bool {
        let age = now.timeIntervalSince(taken)
        return age > 4 && (now.timeIntervalSince(shownAt) > 1.5 || age > 20)
    }
    var body: some View {
        // The stream's own last frame, while it's newer than the latest still: what was on screen when last looked at.
        let held = !live.showing && live.heldAt.map { $0 > store.at } == true
        ZStack {
            // The still stays under the live picture until that has faded fully in over it, so the change is one picture
            // over another, never through an empty box (r33 rjoin: the still faded out and the live one cut in after).
            if !held && !liveIn {
                if let m = store.image {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let old = isOld(store.at, ctx.date)
                        Image(tv: m).resizable().scaledToFit().opacity(old ? 0.5 : 1)
                            // The light only once the picture has been up a moment: in the half second before a new still
                            // lands (a film ending), it sat stuck at its corner rather than running (Remote gate 3).
                            .overlay { if old && !live.stalled && ctx.date.timeIntervalSince(shownAt) > 1.5 { LoadingRing(radius: TVLook.card).transition(.opacity) } }
                            .animation(.easeOut(duration: 0.3), value: old)
                    }
                } else {
                    // Nothing yet: what's playing, blurred, with a spinner, rather than an empty box. Once the stream has had 1.5 s
                    // and no picture (a TV asleep, say), the spinner goes: the poster as it is, or a quiet moon with none.
                    // Stalled, the TV glyph alone on the dark, whatever art there is: the art drawn sharp under it read as a
                    // washed-out banner with the glyph stuck on its wordmark, and only when the art beat the stall (r33).
                    ZStack {
                        if live.stalled { NoPicture() }
                        // With no art either, the TV's glyph under the light, never an empty box (gate 3, first arrival).
                        else if art == nil { NoPicture().overlay { LoadingRing(radius: TVLook.card) } }
                        else if let u = art.flatMap(URL.init(string:)) {
                            // What's on, sharp on its blur, while the TV's picture comes: the half-dark blur alone read as an
                            // empty box (audit of 5b7b503). The light runs round the picture's edge, as it does round every
                            // card that's loading and round a flick's start (tv-iphone.md ruling 9), not a spinner.
                            PosterOnBlur(url: u).overlay { LoadingRing(radius: TVLook.card) }
                        } else { NoPicture() }
                    }
                    .animation(.easeOut(duration: 0.3), value: live.stalled)
                }
            }
            // One layer throughout, kept frame and live stream alike: swapping one for another faded the picture from
            // nothing. Old the same way a still is, once it's a few seconds old and the stream still isn't back.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let old = held && live.heldAt.map { isOld($0, ctx.date) } == true
                LiveMirrorLayer(mirror: live).opacity(live.showing || held ? (old ? 0.5 : 1) : 0)
                    .overlay { if old && !live.stalled { LoadingRing(radius: TVLook.card).transition(.opacity) } }
                    .animation(.easeOut(duration: 0.3), value: old)
            }
        }
        .animation(.easeOut(duration: 0.2), value: live.showing)
        // Each return to the Remote counts as a showing, the tab being kept rather than shown afresh: the frame kept from a
        // moment ago is up bright at once, not dimmed as old.
        .onScreen { on in if on { shownAt = Date(); liveIn = live.showing } }
        .task(id: live.showing) {
            guard live.showing else { liveIn = false; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled, live.showing { liveIn = true }
        }
    }
    // The live picture has been up long enough to have faded in over the still.
    @State private var liveIn = false
}
#endif

// A picture on its way: the dark glass for a moment, then the TV's glyph, so a picture that doesn't come is never an empty
// box (audit of 5b7b503: the Remote's picture sat as a dark box).
struct NoPictureSoon: View {
    @State private var late = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            if late { NoPicture().transition(.opacity) }
        }
        .task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { late = true } }
        }
    }
}

// A picture that can't be had: a TV, not a moon (an awake TV whose picture can't be had isn't asleep; asleep, the Remote
// lays its own moon over everything).
struct NoPicture: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            Image(systemName: "tv").font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

// A Stremio episode the Mac found no poster for: the episode's own still from the show's catalogue, as Playing shows it,
// rather than a dark box with a TV glyph (review of dfd490e). The glyph only while there's none to be had.
struct EpisodeStill: View {
    @ObservedObject private var nextUp = NextUp.shared
    @State private var still: String?
    @State private var looked = false
    // The still already known, so a return to the Remote draws it from the first frame.
    var known: String? {
        guard let s = nextUp.series, let e = NextUp.cached(s.imdb)?.episodes.first(where: { $0.id == s.current }), !e.thumb.isEmpty else { return nil }
        return e.thumb
    }
    var body: some View {
        ZStack {
            if let u = (still ?? known).flatMap(URL.init(string:)) {
                Cover(url: u, mode: .fill) { Color.clear }.transition(.opacity)
            } else if looked {
                NoPicture()
            } else {
                // Looked for a moment without an answer yet: the glyph, rather than dark glass for as long as that takes.
                NoPictureSoon()
            }
            // Until it's known there's no still, the dark glass: a cold launch on a show flashed the TV glyph for 0.4 s
            // before the still (Remote gate 4).
        }
        .clipped()
        .task(id: nextUp.series) {
            guard let s = nextUp.series, let m = await NextUp.meta(s.imdb),
                  let e = m.episodes.first(where: { $0.id == s.current }), !e.thumb.isEmpty else { still = nil; looked = true; return }
            if still != e.thumb { withAnimation(.easeOut(duration: 0.25)) { still = e.thumb } }
        }
    }
}

// One arrow or the centre of the D-pad: a press acts at once, holding repeats until you lift.
// Set on pages that scroll. There a key waits to see it's a real press, or starting a scroll on one would press it on the TV.
private struct KeysInScrollKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var keysInScroll: Bool { get { self[KeysInScrollKey.self] } set { self[KeysInScrollKey.self] = newValue } } }
private struct PadKey<Face: View>: View {
    @Environment(TVModel.self) var model
    @Environment(\.keysInScroll) private var inScroll
    @State private var pressed = false
    let key: String
    var longPress = false
    let label: String
    @ViewBuilder let face: (Bool) -> Face
    @GestureState private var touching = false
    @State private var held: Task<Void, Never>?
    @State private var fired = false
    func begin() {
        guard held == nil else { return }
        fired = false
        if !longPress { model.key(key) }
        held = Task {
            try? await Task.sleep(nanoseconds: longPress ? 600_000_000 : 350_000_000)
            if Task.isCancelled { return }
            if longPress { fired = true; model.key(key, long: true); return }
            // Ten seconds is further than any row goes; never run away.
            let started = Date()
            while !Task.isCancelled, Date().timeIntervalSince(started) < 10 {
                model.key(key, repeating: true)
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }
    func end(tapped: Bool) {
        held?.cancel(); held = nil
        if tapped && longPress && !fired { model.key(key) }
    }
    var body: some View {
        Group {
            if inScroll {
                face(pressed)
                    .contentShape(Rectangle())
                    .onTapGesture { model.key(key) }
                    .onLongPressGesture(minimumDuration: 0.6, maximumDistance: 12, perform: { if longPress { model.key(key, long: true) } else { model.key(key) } }, onPressingChanged: { pressed = $0 })
            } else {
                face(touching)
                    .contentShape(Rectangle())
                    // Resets by itself if the system takes the touch away, so a key can't get stuck.
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($touching) { _, state, _ in state = true }
                        .onChanged { _ in begin() }
                        .onEnded { _ in end(tapped: true) })
                    .onChange(of: touching) { _, now in if !now { end(tapped: false) } }
            }
        }
            .onDisappear { end(tapped: false) }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.key(key) }
    }
}
struct DPad: View {
    // Just the ring, its keys faded out, so something laid on it (the wake button) sits on an empty dial.
    var bare = false
    func arrow(_ icon: String, _ key: String, _ label: String, _ side: CGFloat) -> some View {
        PadKey(key: key, label: label) { down in
            Image(systemName: icon).font(.system(size: side * 0.34, weight: .semibold))
                .frame(width: side, height: side)
                .background(Circle().fill(.white.opacity(down ? 0.2 : 0)))
                .scaleEffect(down ? 0.92 : 1).animation(TVLook.press, value: down)
        }
    }
    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height), side = d / 3
            ZStack {
                Circle().fill(.ultraThinMaterial).overlay { Circle().strokeBorder(.white.opacity(0.08)) }
                VStack(spacing: 0) {
                    arrow("chevron.up", "up", "Up", side)
                    HStack(spacing: 0) {
                        arrow("chevron.left", "left", "Left", side)
                        PadKey(key: "ok", longPress: true, label: "Select. Hold for a long press.") { down in
                            Circle().fill(.white.opacity(down ? 0.75 : 0.92)).padding(side * 0.1).frame(width: side, height: side)
                                .scaleEffect(down ? 0.92 : 1).animation(TVLook.press, value: down)
                        }
                        arrow("chevron.right", "right", "Right", side)
                    }
                    arrow("chevron.down", "down", "Down", side)
                }
                .opacity(bare ? 0 : 1)
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct GlassKey: View {
    let icon: String, label: String, key: String
    var size: CGFloat = 54
    var body: some View {
        PadKey(key: key, longPress: true, label: label) { down in
            Image(systemName: icon).font(.system(size: size * 0.36, weight: .medium)).frame(width: size, height: size).contentShape(Circle())
                .scaleEffect(down ? 0.92 : 1).animation(TVLook.press, value: down)
        }
        .keyGlass()
    }
}
struct PlayKey: View {
    @Environment(TVModel.self) var model
    var playing: Bool?
    var tint: Color = TVLook.accent
    var size: CGFloat = 68
    var glow = true
    // For a player on this phone rather than the TV.
    var action: (() -> Void)?
    // The TV's own play key says what it pressed the moment it's pressed, not when the TV next reports.
    var shown: Bool? { action == nil ? model.shownPlaying(playing) : playing }
    var body: some View {
        let playing = shown
        Button {
            if let action { model.tick(); action() }
            else { model.togglePlay(shown: playing) }
        } label: {
            // Not knowing (offline, or nothing reported yet), the one plain play glyph rather than the two-in-one "▶︎II" (r26).
            Image(systemName: playing == true ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                // The swap is the symbol's own, on the press and on the TV's word alike: neither set the glyph inside an
                // animation, so the replace never ran and ▶ cut to ⏸ (tv21 realpause 8.49 → 8.59 s, no frame between).
                .settledAnimation(.snappy(duration: 0.25), value: playing)
                .frame(width: size, height: size).background(tint, in: Circle())
                .shadow(color: tint.opacity(glow ? 0.45 : 0), radius: 14, y: 4)
                .animation(.easeOut(duration: 0.2), value: glow)
        }
        .buttonStyle(PressCard()).accessibilityLabel(playing == true ? "Pause" : playing == false ? "Play" : "Play or pause")
    }
}

struct RemoteTab: View {
    @Environment(TVModel.self) var model
    @Environment(\.horizontalSizeClass) private var size
    // Folded and turned sideways the display is short: the one column stacked the picture, its lines, the pad and the keys
    // in 405 pt and the picture collapsed to a sliver under the pad (836207d's folded-landscape shots). There the Remote
    // lays out as open does, the picture beside the pad.
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.paneLayout) private var panes
    @ObservedObject private var nextUp = NextUp.shared
    // The build's shot of the typing bar opens with it up.
    @State private var typing = UserDefaults.standard.string(forKey: "pose") == "type"
    @State private var wakeAskedAt: Date?
    // The layout's own idea of typing: on with the keyboard key, and off only once the keyboard has gone, so the page
    // never lays itself out in the room a keyboard still on its way down leaves (Remote gate 4: for half a second it
    // split into two columns upright, crushed open flat, and came back under the keyboard folded).
    @State private var lay = UserDefaults.standard.string(forKey: "pose") == "type"
    // Arriving from a flick's controls, the pad and keys come in during the screen's move onto the picture above them.
    // Read only inside KeysArrive, so the keys coming in redraws them alone, not the whole Remote: as a plain @State it
    // re-laid out both open panes mid-move, the 147–177 ms hitch at +0.72 s (r27).
    @State private var keysGate = KeysGate()
    @ObservedObject private var epPanel = EpisodesPanel.shared
    // The episodes, over what they're given: a page's whole width or the left column, with a margin the pad's size.
    @ViewBuilder func episodesPanel() -> some View {
        if epPanel.open && (session || model.status?.session != nil) { EpisodePanel().padding(.horizontal, 12).padding(.top, 0).padding(.bottom, 12).transition(.opacity) }
    }
    var state: String {
        // Not reaching it is said once, by the red note at the top; "Connecting…" under it contradicted it.
        if unreachable || !model.reachable || epPanel.open { return "" }
        // A start under way, or one that failed: its title from the first frame, kept through a failure, so the line never
        // appears late and pushes the title up (r19).
        if let st = model.starting, !st.played { return ([st.title] + (st.line.map { [String($0.prefix { $0 != "·" }).trimmingCharacters(in: .whitespaces)] } ?? [])).joined(separator: " · ") }
        guard !model.staleStatus, let s = model.status else { return "Connecting…" }
        // The wake button says the rest.
        if s.screen == "asleep" { return "Asleep" }
        // The box is up but the television isn't showing it (HDMI-CEC): that is what's true, not what the box has on.
        if let a = s.away { return a.line }
        // The television has been asked on and isn't lit yet: said, where "Asleep" was a moment ago.
        if s.comingOn { return TVStatus.comingOnLine }
        if s.screen == "screensaver" { return "Screensaver" }
        // What's playing, by name, rather than the app it's playing in. Only while it's what's on, never one left behind.
        if model.videoIsCurrent, let p = s.session, !p.showName.isEmpty {
            // The episodes line under the picture already says "S2 E3 · …": the header has just the show (r26), folded
            // and open alike now the line is under the picture folded too.
            let lined = p.pkg == "com.stremio.one" && p.episodeLine != nil && nextUp.series != nil
            return ([p.showName] + (lined ? [] : Self.detail(p))).joined(separator: " · ")
        }
        // Nothing with a name on: nothing said, rather than which app is in front.
        return ""
    }
    // After the title: which episode, if it's one. "S1 E2". How long is left is the bar's to say, right under the picture.
    static func detail(_ s: TVStatus.Session) -> [String] {
        if let se = s.seasonEpisode { return ["S\(se.season) E\(se.episode)"] }
        var out: [String] = []
        if let ep = s.description.dropFirst().lazy.map(Wording.episode).first(where: { $0.hasPrefix("S") && $0.contains(" E") }) {
            out.append(String(ep.prefix { $0 != "·" }).trimmingCharacters(in: .whitespaces))
        }
        return out
    }
    // Something on with a player, or being started: only then are there keys to play, pause and jump. Kept while the TV
    // can't be reached, dimmed with everything else rather than taken away, so the layout never collapses (r17).
    var session: Bool {
        model.status?.session != nil || model.starting != nil || (unreachable && hadSession)
            || Date().timeIntervalSince(model.startEndedAt) < 12
    }
    @State private var hadSession = false
    var asleep: Bool { !model.staleStatus && model.status?.screen == "asleep" }
    // The television off, or on another input, while the box is awake: treated as asleep is, with its own one key.
    var away: TVStatus.Away? { model.staleStatus ? nil : model.status?.away }
    // The Mac answers but the TV doesn't: the keys can't reach it, so they show it.
    var unreachable: Bool { model.status.map { !$0.online } ?? false }
    // While something plays, where it is and a bar to move it, right under the picture, as on the Playing tab.
    // Hidden, not removed, while a flick's screen moves onto the picture: it carries its own bar, and two showed at once.
    // Its place is kept from the landing on (a start, or a film whose length isn't known yet shows the time it's at), so
    // nothing pops in and the picture never shrinks when the length arrives (r17).
    // One slot of one height for whatever sits under the picture while something is on or starting: the bar, its 40 %
    // stand-in, "Still starting", or the failed line. Whatever changes inside it, nothing around it moves (r18: the pad
    // and keys jumped 40 px the moment playing arrived).
    static let barSlot: CGFloat = 46
    @ViewBuilder var progress: some View {
        if session {
            ZStack {
                if let st = model.starting, !st.played, st.failed {
                    StartingNote()
                } else if model.videoIsCurrent, model.starting == nil || model.starting?.played == true, let s = model.status?.session {
                    VideoProgress(session: s, live: !model.staleStatus && !unreachable)
                } else if model.starting != nil {
                    // While a flicked start is under way: the bar's place, at 40 %, with "Still starting" after 8 s under it.
                    ProgressPlaceholder().opacity(0.4)
                        .overlay(alignment: .bottom) { StartingNote().offset(y: 4) }
                }
                // Otherwise (connecting, or a session that isn't what's on) the place stays empty: a grey bar there claimed
                // something it didn't know (r33).
                Color.clear
            }
            .frame(height: Self.barSlot)
            .opacity(model.flickHandoff ? 0 : unreachable ? Self.dim : 1)
            .allowsHitTesting(!unreachable)
            .settledAnimation(.easeOut(duration: 0.2), value: model.starting?.played)
        }
    }
    // The episode line's place is kept from the start of an episode's flick, so it fills in rather than pushes in.
    var seriesOn: Bool {
        (model.starting?.line?.hasPrefix("S") ?? false) || model.status?.session?.seasonEpisode != nil
            || (Date().timeIntervalSince(model.startEndedAt) < 12 && lastStartWasSeries)
    }
    @State private var lastStartWasSeries = false
    @ViewBuilder var episodes: some View {
        if session && seriesOn { ZStack { EpisodesLine() }.frame(height: 46) } else { EpisodesLine() }
    }
    // Asleep or out of reach, the picture is dark with a moon or a cut wire, not the last frame passed off as now.
    var dark: Bool { asleep || unreachable || away != nil }
    static let dim = 0.35
    func picture(closable: Bool) -> some View {
        MirrorView(store: model.mirrorStore, closable: closable && !dark)
            // A start the flick sent: its poster in the picture, with the light lapping its edge, until it plays and the
            // TV's own picture takes over (§2.5a C5). The flick's screen lands on exactly this.
            .overlay { if let s = model.starting { StartingPicture(start: s).transition(.opacity) } }
            .settledAnimation(.easeOut(duration: 0.25), value: model.starting?.played)
            .overlay {
                if dark {
                    ZStack {
                        // Fully black: a faint last frame through it read as the TV still showing something (r26).
                        Color.black
                        VStack(spacing: 8) {
                            Image(systemName: unreachable ? "wifi.slash" : away?.glyph ?? "moon.fill").font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: TVLook.card, style: .continuous))
                    .transition(.opacity)
                }
            }
            .settledAnimation(.easeInOut(duration: 0.3), value: dark)
            // One door each way: the eye at the picture's corner hides it, and the one key on the hidden picture shows it.
            // A held menu on the picture offered both a second time (the 2026-11-10 logic pass).
            .opacity(model.flickHandoff ? 0 : 1)
            // Laid out first, at the full width, so the bar or a player coming in under it never shrinks it, and a flick's
            // screen moving onto it lands where it stays.
            .layoutPriority(1)
    }
    // Asleep, one big way to wake it over the pad, which wakes it too.
    var wakeShown: Bool { asleep || away == .off }
    @ViewBuilder var wake: some View {
        // The television off with the box still up is the same key, in the same place: it turns the television on.
        if wakeShown {
            Button {
                model.tick(); if asleep { model.key("wake") } else { model.post("tv-on") }
                // Said on the key at once, until the TV answers (or 10 s): a press with nothing to show for it read as dead.
                wakeAskedAt = Date()
            } label: {
                // The whole ring is the key: the glyph over the words, never cut. "Waking the TV…" with the light running round
                // it after a press; still asleep 10 s on, it says so (tv-pass-1122).
                TimelineView(.periodic(from: .now, by: 1)) { t in
                    let since = wakeAskedAt.map { t.date.timeIntervalSince($0) }
                    let waking = since.map { $0 < 10 } ?? false
                    let stuck = since.map { $0 >= 10 && $0 < 40 } ?? false
                    GeometryReader { g in
                        let d = min(g.size.width, g.size.height)
                        VStack(spacing: d * 0.04) {
                            Image(systemName: "power").font(.system(size: max(16, d * 0.16), weight: .semibold))
                            Text(waking ? "Waking the TV…" : stuck ? "Still asleep. Try again" : "Wake the TV")
                                .font(.system(size: max(12, min(20, d * 0.12)), weight: .semibold))
                                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                                .contentTransition(.opacity)
                        }
                        .padding(d * 0.12)
                        .frame(width: d, height: d)
                        .overlay { if waking { LoadingRing(radius: d / 2) } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Wake the TV")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if let away, !unreachable {
            TelevisionKey(away: away).transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
    // The two rows of keys, on the Remote's one column: five equal places across exactly the column's width, the keys
    // sized to it (never five fixed keys spread wider than the picture above them, as on his folded phone, 2026-11-11:
    // "look at the controls fucked"), each key over the one below it. The outer keys' edges are the column's edges.
    func keys(_ grid: RemoteGrid, transport: Bool = true) -> some View {
        VStack(spacing: 12) {
            // Power joins the top row like a real remote's, rather than sitting alone under everything.
            HStack(spacing: 0) {
                // While the big wake key is up in the pad's ring, these step back, dimmed in their places: one way to wake the
                // TV on the page, and nothing lit that does nothing (tv-pass-1122).
                GlassKey(icon: "power", label: "Sleep or wake", key: model.status?.screen == "asleep" ? "wake" : "sleep", size: grid.key).sleepDim(wakeShown).slot()
                GlassKey(icon: "chevron.left", label: "Back", key: "back", size: grid.key).sleepDim(wakeShown).slot()
                GlassKey(icon: "house.fill", label: "Home", key: "home", size: grid.key).sleepDim(wakeShown).slot()
                // Lit while the typing bar is up, and closes it again.
                Button { model.tick(); withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { typing.toggle() } } label: {
                    Image(systemName: "keyboard").font(.system(size: grid.key * 0.35, weight: .medium)).foregroundStyle(typing ? AnyShapeStyle(TVLook.accent) : AnyShapeStyle(.primary))
                        .frame(width: grid.key, height: grid.key).contentShape(Circle())
                }
                .buttonStyle(.plain).keyGlass().accessibilityLabel(typing ? "Stop typing" : "Type on TV")
                .sleepDim(wakeShown)
                .slot()
                GlassKey(icon: "line.3.horizontal", label: "Menu", key: "menu", size: grid.key).sleepDim(wakeShown).slot()
            }
            // Typing takes the transport's room, in every posture: folded the keyboard sliced it in half, and upright it sat
            // across the hinge (Remote gate 4).
            // Only with something on to play: idle on the home screen, five transport keys did nothing.
            // The one transport, the same as Playing's, on the top row's five places.
            // Never under Mint's own player, online or dimmed out of reach: one condition in every state (gate, 2026-11-11).
            // Open upright it's under the scrub bar in the picture's pane instead (2026-11-14), so the pad and this one row
            // have the whole lower pane.
            if transport && session && !musicShown && !lay { Transport(glow: !lay, size: grid.key, playSize: grid.play).transition(.opacity) }
            // No volume here: the TV refuses volume over HDMI, so only its own remote can change it.
        }
        // Five places of a key and a gap each: the first and last keys' edges land on the column's.
        .frame(width: grid.width + grid.gap)
        // Laid out at exactly the column's width, so a column as wide as its room never pushes the keys past its edge
        // (folded sideways and typing upright, Menu and ⏭ sat 13 pt from the right edge, gate 2026-11-11).
        .padding(.horizontal, -grid.gap / 2)
        // The TV's status is never set inside an animation, so the row came and went in one frame as something started
        // or ended on the TV. It fades, like the lines under the picture (the 2026-11-10 motion pass).
        .settledAnimation(.easeOut(duration: 0.25), value: session)
    }
    func keysBlock(_ grid: RemoteGrid, transport: Bool = true) -> some View {
        VStack(spacing: 12) {
            // Above the keys, and up for as long as it's wanted, so typing and moving between boxes go together.
            if typing { TypeBar(open: $typing).frame(width: grid.width).transition(.move(edge: .bottom).combined(with: .opacity)) }
            keys(grid, transport: transport)
        }
        .opacity(unreachable ? Self.dim : 1).allowsHitTesting(!unreachable)
        // Whether something was on when the TV was last heard: kept through a drop, so its keys stay (dimmed).
        .onChange(of: model.status?.session != nil, initial: true) { _, has in if !unreachable { hadSession = has } }
        .onChange(of: model.starting?.line) { _, line in if let line { lastStartWasSeries = line.hasPrefix("S") } }
    }
    // The pad with volume, across the column's whole width: − and + at the column's two edges (over the first and last
    // keys of the row below) with the pad between them and a slim level bar under it; or, where the column is tall, the
    // pad as wide as the column with − bar + on a row under it. The pad is the ring that fits the height it's given.
    // The pad on its row, as big as the row allows (volume went, 2026-11-24: "idc abt volume in tv app").
    func padRow(_ grid: RemoteGrid) -> some View {
        let d = min(grid.pad, grid.width)
        return pad.frame(width: d, height: d).frame(width: grid.width)
    }
    // The pad, dimmed while the TV can't be reached. Asleep, its keys step back and the wake button sits in the empty ring.
    var pad: some View {
        DPad(bare: asleep || away != nil).opacity(unreachable ? Self.dim : 1).allowsHitTesting(!unreachable && !asleep && away == nil)
            .overlay { wake }
            .settledAnimation(.easeInOut(duration: 0.25), value: asleep || away != nil)
    }
    // Only when the music is what's on: a song's player beside a film's was two now-playings on one TV.
    // Dimmed and out of reach with every other key while the TV can't be reached (its ▶ stayed bright and live, r32).
    // Not from the status kept from last time: opening, the cached song's player showed under "Connecting…" and went a
    // moment later, the send bar jumping up after it (r34). It comes in with the TV's first answer, if it's on.
    var musicShown: Bool { !model.staleStatus && model.musicIsCurrent }
    @ViewBuilder var music: some View {
        if musicShown, let m = model.nowMusic {
            Transport(playing: .some(model.songPlaying(m))).opacity(unreachable ? Self.dim : 1).allowsHitTesting(!unreachable).transition(.opacity)
        }
    }
    // The bar and the episode line under the picture, with their spacing: the picture is sized as if they're always there,
    // folded and open.
    static let underRoom = barSlot + 46 + 28
    // Open upright, the transport's keys in the picture's pane: 64 pt (the least a key is), ⏯ a little bigger, on the
    // column's five places, so each sits over the key under it across the fold.
    static let upperKey: CGFloat = 64, upperPlay: CGFloat = 72
    func upperGrid(_ width: CGFloat) -> RemoteGrid {
        var g = RemoteGrid.keys(width, maxKey: Self.upperKey)
        g.play = min(g.play, Self.upperPlay)
        return g
    }
    func side(apps: Bool) -> some View {
        // Open upright the lines under the picture are the keys' column (the pane's width, 520 pt at most), whatever
        // width the pane's height leaves the picture; elsewhere they're the picture's own width.
        let upper = stackedUpright && !lay
        return PictureColumn(spacing: 14, under: Self.underRoom + (upper ? Self.upperPlay + 14 : 0), lines: stackedUpright ? RemoteGrid.most : nil, leading: panes && !stackedUpright) {
            picture(closable: true).columnRole(.picture)
            // Mint's player is what's on when it shows: no bar's place above it, online or out of reach (upright offline the
            // kept place shrank the picture and left 83 pt empty, Remote gate 3).
            if !musicShown { progress.columnRole(.under) }
            // Open upright: prev, −10, ⏯, +10, next right under the scrub bar (Richard, 2026-11-14: "the buttons r so
            // small"; this overturns the 11-11 rule that the transport is anchored from the foot with the keys). The pad
            // and the keys' row then have the whole lower pane. Its room is kept while nothing's on, like the bar's.
            if upper && session && !musicShown {
                GeometryReader { g in
                    let grid = upperGrid(g.size.width)
                    Transport(size: grid.key, playSize: grid.play)
                        .frame(width: grid.width + grid.gap).frame(width: g.size.width, height: Self.upperPlay)
                }
                .frame(height: Self.upperPlay)
                .opacity(model.flickHandoff ? 0 : unreachable ? Self.dim : 1).allowsHitTesting(!unreachable)
                .transition(.opacity)
                .columnRole(.under)
            }
            // Typing, the episode line and Mint's player step aside, in every posture: open flat they sat half under the
            // keyboard, and upright the picture's pane gives its height to the bar and the keys (an episode line at the
            // shrunken picture's width read "Episo…", CI 69af3dc). Folded does the same.
            if !lay { episodes.columnRole(.under); music.columnRole(.under) }
            // Typing, the keyboard comes up over this pane's foot: the tiles and the send box step aside rather than show
            // through it.
            if !lay {
                // Out of reach, the tiles can't open anything on the TV: dimmed with every other key, the ring on the app in
                // front with them (r33: bright, Stremio's ring lit, beside a dimmed pad).
                if apps, model.status?.apps?.isEmpty == false {
                    QuickApps().opacity(unreachable ? Self.dim : 1).allowsHitTesting(!unreachable)
                        .settledAnimation(.easeInOut(duration: 0.3), value: unreachable).columnRole(.aligned)
                }
                // No search box here: Search is its own tab (Richard, 2026-11-11).
            }
            // Upright the field is the pane's foot: a second spacer split the room and floated it (Remote gate 4).
            if !stackedUpright { Spacer(minLength: 0) }
        }
        .settledAnimation(.spring(response: 0.45, dampingFraction: 0.9), value: musicShown)
        // The bar and the episode line come and go with the TV's status, which is set with no animation: faded in and
        // out here rather than popped (the 2026-11-10 motion pass). Their room is kept either way (PictureColumn).
        .settledAnimation(.easeOut(duration: 0.25), value: session)
        .settledAnimation(.easeOut(duration: 0.25), value: seriesOn)
        // Open upright, the keys' column's own margins (12 pt), so its edges are theirs across the fold; the fold's own
        // band is under it there, so less at the foot.
        .padding(.horizontal, stackedUpright ? 12 : 20).padding(.bottom, stackedUpright ? 8 : 16)
    }
    // The pad and the keys, the second column wherever the Remote has two.
    // Its width is the Remote's column: a remote's width at most (380 pt), and open upright, where the picture's pane
    // is above it, the picture's own width, so the keys' edges are the picture's, the bar's and the episode line's. The
    // pad is never wider than the keys under it.
    private var keysColumn: some View {
        GeometryReader { geo in
            let stacked = stackedUpright
            // The column's whole width and height, margins aside: keys and pad fill it (Richard, 2026-11-14: "the buttons
            // are so small"), the pad taking what height the keys leave. Open upright that's one row of keys, the
            // transport being in the picture's pane.
            let grid = RemoteGrid.fit(width: geo.size.width, height: geo.size.height, transport: !stacked)
            if stacked {
                // Open upright, the whole pane under the fold: the pad as big as fits over the one row of keys, the spare
                // room shared above and below the pad. Typing, the pad steps aside so the bar and the keys stay above
                // the keyboard.
                VStack(spacing: 0) {
                    Spacer(minLength: 14)
                    if !lay { padRow(grid).transition(.opacity); Spacer(minLength: 14) }
                    keysBlock(grid, transport: false).frame(height: lay ? nil : grid.key, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Typing, the pad steps aside here too, rather than shrink to a 60 pt miniature (Remote gate 4).
                VStack(spacing: 14) {
                    if lay { Spacer(minLength: 0) } else { padRow(grid).frame(maxHeight: .infinity).transition(.opacity) }
                    keysBlock(grid)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Beside the picture (open flat, folded sideways) the pane is narrow: 6 pt margins leave five 64 pt keys their
        // 8 pt gaps (at 12 they were 62 pt, gate 2026-11-14).
        .padding(.horizontal, stackedUpright ? 12 : 6).padding(.bottom, panes ? 16 : 8)
        // The apps, at the foot in every posture (2026-11-20): the same row folded and open; open flat they are the tiles
        // under the picture.
        .stripUnder(!panes && !lay ? appStrip : nil)
        .opacity(stackedUpright && epPanel.open ? 0 : 1).allowsHitTesting(!(stackedUpright && epPanel.open))
        .modifier(KeysArrive(gate: keysGate))
    }
    // Open upright, not typing: the picture beside the pad, then the bar, the transport, the episode line, the keys'
    // row, volume, and the apps at the foot. Every place is kept whatever is on, so nothing moves as a show starts.
    func uprightColumn(width: CGFloat, height: CGFloat, margin: CGFloat = 20) -> some View {
        // The page's own width and edges: the title, the picture, the keys and the apps start on one line (the column
        // was 520 pt in the middle of a 669 pt screen: three left edges, gate on b97a5e7).
        func gridFor(_ k: CGFloat) -> RemoteGrid {
            var g = RemoteGrid.keys(width - 2 * margin, maxKey: k)
            g.width = max(g.width, width - 2 * margin)
            g.play = min(g.key + 8, 104)
            return g
        }
        // Folded there is less height: the same rows, 10 pt apart rather than 14.
        let gap: CGFloat = height < 600 ? 10 : 14
        let strip = AppStrip.tile * TVLook.bannerSize.height / TVLook.bannerSize.width + 8
        // One arrangement whatever is on: the picture beside the pad, and places kept for the bar, the transport and the
        // episode line. It was two (the picture over the pad when nothing was on), and the first reading, about 1.5 s after
        // opening, moved everything from one to the other in a spring (audit of 5b7b503). What's on only fills the places.
        let rows: CGFloat = 4
        func roomFor(_ g: RemoteGrid) -> CGFloat { max(0, height - (g.key + Self.barSlot + g.play + 46 + strip + 8) - gap * rows) }
        // The spare height goes to the controls, not to gaps (ruling b): the keys from 72 down only until the pad has
        // 110 pt, then up (to 96) into whatever the pad, capped by the row's width beside the picture, can't use. With
        // volume gone (11-24) that room was an empty band folded.
        let dMax = ((gridFor(72).width - 16) * 9 / 25).rounded(.down)
        var k: CGFloat = 72
        while k > 52, roomFor(gridFor(k)) < 110 { k -= 2 }
        while k < 96, roomFor(gridFor(k + 2)) >= dMax { k += 2 }
        let grid = gridFor(k)
        let room = roomFor(grid)
        let w = grid.width
        // Where the width holds the keys back (folded: five keys and their 8 pt gaps), the pad takes more of its row, up to
        // 45% (the picture stays the bigger of the two); what's still over is shared between the rows, never one band.
        let d = max(110, min(((w - 16) * 0.45).rounded(.down), room))
        let pw = min(w - 16 - d, d * 16 / 9)
        let spread = min(16, max(0, room - d) / (rows + 1)).rounded(.down)
        return VStack(spacing: 0) {
            VStack(spacing: gap + spread) {
                HStack(spacing: max(16, w - pw - d)) {
                    picture(closable: true).frame(width: pw, height: pw * 9 / 16)
                    pad.frame(width: d, height: d)
                }
                .frame(width: w)
                ZStack {
                    if !musicShown && session { progress }
                    // Nothing on: the bar's bare track, so its place reads as the bar it is, never a hole (tv-pass-1122).
                    else { Capsule().fill(.white.opacity(0.1)).frame(height: RemoteGrid.barH).frame(maxHeight: .infinity, alignment: .top).padding(.top, 8) }
                }.frame(width: grid.width, height: Self.barSlot)
                ZStack {
                    if musicShown, let m = model.nowMusic { Transport(size: grid.key, playSize: grid.play, playing: .some(model.songPlaying(m))).frame(width: grid.width + grid.gap) }
                    else {
                        // Idle: still there, dimmed and still, so no key ever moves when something starts (tv-pass-1122).
                        let idle = !session
                        Transport(size: grid.key, playSize: grid.play).frame(width: grid.width + grid.gap)
                            .opacity(idle ? 0.35 : 1).allowsHitTesting(!idle).accessibilityHidden(idle)
                    }
                }
                .frame(width: grid.width, height: grid.play)
                .opacity(model.flickHandoff ? 0 : unreachable ? Self.dim : 1).allowsHitTesting(!unreachable)
                ZStack { Color.clear; if seriesOn && (session || musicShown) { episodes } }.frame(width: grid.width, height: 46)
                VStack(spacing: gap) {
                    keysBlock(grid, transport: false)
                }
                .opacity(epPanel.open ? 0 : 1).allowsHitTesting(!epPanel.open)
                .modifier(KeysArrive(gate: keysGate))
            }
            Spacer(minLength: 8)
            AppStrip(inset: margin).opacity(unreachable ? Self.dim : 1).allowsHitTesting(!unreachable).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder var appStrip: some View {
        AppStrip().opacity(unreachable ? Self.dim : 1).allowsHitTesting(!unreachable)
    }
    // The folded column as it was before typing began, kept while typing so the keys don't move or shrink.
    @State private var foldedGrid: RemoteGrid?
    // Open upright: one column, picture above the fold and the keys under it, in every state, typing included.
    // Read as typing begins and kept while it lasts: the app's pane reading flipped to two panes as the keyboard took the
    // height, and the page went side by side (CI 1180364 and 5767dcc, type-portrait).
    var stackedUpright: Bool { size == .regular && !(lay ? calmPanes : panes) }
    // The pane reading as last seen with no keyboard up. The keyboard only ever turns one column into two (it takes
    // height), never two into one, so a change to one column is always taken and a change to two only while not typing
    // (CI d0327e7: going by the keyboard's own notice let the flip through, the notice coming after it).
    @State private var calmPanes = false
    @State private var calmSet = false
    @State private var calmWidth: CGFloat = 0
    @State private var windowWidth: CGFloat = 0
    // Where the fold runs across this view open upright, in its own space: the hinge's own region when the system reports
    // it, otherwise the middle of the screen, 40 pt wide (about the crease's width).
    static func crease(in g: GeometryProxy) -> CGRect {
        #if os(iOS)
        if #available(iOS 27.1, *), let r = g.reservedRegions(kind: .division, options: .includeInactive).first?.frame, r.width > r.height {
            return CGRect(x: 0, y: r.minY - 4, width: g.size.width, height: r.height + 8)
        }
        let mid = UIScreen.main.bounds.height / 2 - g.frame(in: .global).minY
        return CGRect(x: 0, y: mid - 20, width: g.size.width, height: 40)
        #else
        return CGRect(x: 0, y: g.size.height / 2 - 20, width: g.size.width, height: 40)
        #endif
    }
    // Where the keyboard's top is on screen (infinity while it's down).
    @State private var keyboardTop: CGFloat = .infinity
    // The build's check of a narrower open phone ("-narrow 375"): the upright page laid out at that width.
    static let narrow: CGFloat? = { let v = UserDefaults.standard.double(forKey: "narrow"); return v > 0 ? CGFloat(v) : nil }()
    var body: some View {
        let _ = SwipeLog.mark("body remote")
        Group {
            if stackedUpright {
                // Open upright: the picture's pane above the fold and the keys' pane under it, laid out here rather than by
                // the system's split, which turned the page into two columns side by side as the keyboard came up (Remote
                // gate 3). The page ignores the keyboard, so it stays one column; the keys' pane lifts its bar and keys.
                GeometryReader { g in
                    let crease = Self.crease(in: g)
                    if lay {
                        // Typing, the keyboard covers nearly all of the pane under the fold, so the bar and the keys' row
                        // come up above it, under the picture's pane (CI 219df47: under the fold they sat beneath the keyboard).
                        // At the column's width from before typing: the picture shrinks to give up the height, the keys don't.
                        let tg = RemoteGrid.keys(g.size.width - 24, maxKey: 64)
                        let rows = 50 + 12 + tg.key
                        VStack(spacing: 14) {
                            side(apps: false).frame(height: max(0, crease.minY - 14 - rows - 8))
                            keysBlock(tg).frame(maxWidth: .infinity)
                            Spacer(minLength: 0)
                        }
                    } else {
                        // One column down the open screen (2026-11-20). Split at the fold, with the lip and the title
                        // above, the picture was a sliver (CI 53b4243) and then the pad a 100 pt miniature whose wake key
                        // read "Wake the…" (CI b88affc). Now the picture and the pad share the top row at one height, the
                        // bar and the transport hang from the picture, and every key is one size: 72 pt, ⏯ 80.
                        uprightColumn(width: g.size.width, height: g.size.height)
                    }
                }
                .ignoresSafeArea(lay ? .keyboard : [], edges: .bottom)
                .overlay { episodesPanel() }
                .frame(maxWidth: Self.narrow)
            } else if size == .regular {
                FoldSplit {
                    // The apps come along when there's room, and step aside when held in portrait.
                    side(apps: panes)
                        // While typing on the TV the keyboard is for the other pane, so this one keeps its size under it
                        // rather than squeezing the screen and cutting its labels. Its own search box still lifts.
                        .ignoresSafeArea(lay ? .keyboard : [], edges: .bottom)
                        .overlay { episodesPanel() }
                } right: { keysColumn }
            } else if vSize == .compact {
                // Folded and turned sideways: the picture beside the pad, as open. Not through FoldSplit, whose split
                // arrangement shows only its first pane on the folded display (54832f8's shot: no pad and no keys at all).
                HStack(spacing: 0) {
                    side(apps: false).ignoresSafeArea(lay ? .keyboard : [], edges: .bottom).overlay { episodesPanel() }.frame(maxWidth: .infinity)
                    keysColumn.frame(maxWidth: .infinity)
                }
            } else {
                // Folded, the picture is one size in every state (r33: 345 pt idle, 206 with an episode, so it shrank as a
                // show started): sized, as open, for the bar and the episode line under it, which sits there as open does
                // rather than as a loose glass circle over the side bar (review of dfd490e: Episodes and the eye floated
                // there). The pad gives up the height, down to 110 pt while something plays. The transport row is in this
                // column too, so its room is kept as well while nothing is on, and only then: it's in the keys' own height
                // once something is (the review of 9c34a08: 343 pt idle, 275 pt with anything on, the picture shrinking the
                // moment a show started; 01fc626 kept the room on top of the row itself, and the picture was 155 pt with a
                // film on).
                // One column, worked out from the room there is (RemoteGrid.folded): the picture, the bar, the episode
                // line, the pad and both rows of keys share its width and its edges, and the keys are sized to it.
                // Every size is fixed per posture (gate, 2026-11-11): the room under the picture is always counted with Mint's
                // player in it, so nothing moves as a song or a show starts; the pad is one diameter, and spare height is
                // space either side of it, never pad. Typing keeps the column it had, so the keys stay where they were.
                // Folded and not typing: the open phone's column at this width (2026-11-20). The old folded column put the
                // transport under the apps row and its keys at 42 pt (gate on cbfc0b5).
                if !lay {
                    GeometryReader { g in uprightColumn(width: g.size.width, height: g.size.height, margin: 14) }
                        .overlay { episodesPanel() }
                } else {
                GeometryReader { geo in
                    let fresh = RemoteGrid.folded(width: geo.size.width, height: geo.size.height, under: Self.barSlot + 46 + 2 * RemoteGrid.foldedGap)
                    let grid = lay ? (foldedGrid ?? fresh) : fresh
                    // Typing, the picture stays, at whatever width fits above the bar and the keys' row (gate 3: 150 pt of
                    // empty art where it had been).
                    let typingPic = min(grid.width, max(0, geo.size.height - 30 - (14 + 50 + 12 + grid.key + 14)) * 16 / 9)
                    VStack(spacing: 0) {
                      VStack(spacing: RemoteGrid.foldedGap) {
                        // The Remote's one rule (2026-11-11, with the designer, so it doesn't flip again): what's on hangs
                        // straight from the picture, with no place kept for what isn't there; the pad and the keys are
                        // anchored from the foot, where the thumbs are, the transport's row always counted; the spare room is
                        // the one gap between them. Nothing moves either way as something starts or stops.
                        if !lay {
                            picture(closable: true).frame(width: grid.width, height: grid.width * 9 / 16).transition(.opacity)
                            if !musicShown { progress.frame(width: grid.width) }
                            episodes.frame(width: grid.width); music.frame(width: grid.width)
                        } else if typingPic >= grid.width * 0.5 {
                            picture(closable: true).frame(width: typingPic, height: typingPic * 9 / 16).transition(.opacity)
                        }
                      }
                        Spacer(minLength: RemoteGrid.foldedGap)
                        // The level bar under the pad sits midway to the keys: 8 pt either side of it.
                        VStack(spacing: RemoteGrid.volGap) {
                            // Typing, the pad steps aside: the bar and the keys' row sit at the foot, above the keyboard.
                            if !lay { padRow(grid).transition(.opacity) }
                            keysBlock(grid).frame(height: lay ? nil : grid.key + 12 + grid.play, alignment: .top)
                        }
                        .modifier(KeysArrive(gate: keysGate))
                        .opacity(epPanel.open ? 0 : 1).allowsHitTesting(!epPanel.open)
                    }
                    // Centred in the room left of the rail: on the title's inset it left a wide empty band before the
                    // rail (CI ee66d34).
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Typing, clear of the keyboard's own soft edge, which faded the keys' row away above it (CI d2fba13).
                    .padding(.bottom, lay ? 30 : 0)
                    .onChange(of: fresh, initial: true) { _, g in if !lay { foldedGrid = g } }
                }
                .settledAnimation(.spring(response: 0.45, dampingFraction: 0.9), value: musicShown)
                // As open: the lines under the picture fade with the TV's status rather than pop.
                .settledAnimation(.easeOut(duration: 0.25), value: session)
                .settledAnimation(.easeOut(duration: 0.25), value: seriesOn)
                .padding(.horizontal, 14).padding(.bottom, 8)
                // The apps under the column, inside the page's own width: as a bottom inset the row ran on under the
                // tab rail, which cut a tile in half (CI b88affc, folded).
                .overlay { episodesPanel() }
                }
            }
        }
        // Always a line under the title, blank when there's nothing to say, so "Remote" never moves as a show starts or
        // ends (r33: 7 pt up and down with the subtitle).
        .navigationSubtitle(state.isEmpty ? "\u{00A0}" : state)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            // Its top as it ends up, whatever screen it's on (the Duo's main screen isn't UIScreen.main's; checked against that, a
            // keyboard up read as down, CI f735bda). Put away, it's said by its own notice below.
            if let r = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, r.height > 0 { keyboardTop = r.minY }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { n in
            keyboardTop = .infinity
            // The page comes back as one move, timed to the keyboard's own going.
            let d = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            if !typing && lay { withAnimation(.easeOut(duration: max(d, 0.2))) { lay = false } }
        }
        #endif
        .onChange(of: panes, initial: true) { _, p in
            // A real change of posture (the window's width changes; a keyboard only takes height) is always taken
            // (Remote gate 4: unfolded with the keyboard up, the page stayed one narrow column across the hinge).
            if !calmSet || !lay || !p || abs(windowWidth - calmWidth) > 1 { calmPanes = p; calmSet = true; calmWidth = windowWidth }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            windowWidth = w
            if abs(w - calmWidth) > 1 { calmPanes = panes; calmWidth = w }
        }
        .onChange(of: typing) { _, t in
            if t { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { lay = true }; return }
            // Back once the keyboard has gone (its notice below), or straight away if it never came; never later than 0.8 s.
            if keyboardTop == .infinity { withAnimation(.easeOut(duration: 0.25)) { lay = false } }
            else { Task { try? await Task.sleep(nanoseconds: 800_000_000); if !typing && lay { withAnimation(.easeOut(duration: 0.25)) { lay = false } } } }
        }
        // The build's typing film ("-typeCycle YES"): the keyboard comes and goes every 5 s, as the keyboard key would
        // have it, so typing in and out is filmed in every posture without a tap (Remote gate 3).
        .task {
            guard UserDefaults.standard.bool(forKey: "typeCycle") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { typing.toggle() }
            }
        }
        // Started as the tab comes up, so the first live picture is there by the time it's looked at. It stays on, as
        // he left it, for the next visit.
        .onAppear { model.remoteBuilt = true }
        .onScreen { on in
            if on { model.warmMirror() }
            // Leaving the tab leaves the typing too, so coming back never finds the keyboard already up.
            else { typing = false; epPanel.open = false }
        }
        // The app tiles' banners fetched once, ahead, so the open Remote's tiles never show their stand-ins first.
        .task(id: model.status?.apps?.map(\.pkg) ?? []) {
            for a in AppsTab.watching(model.status?.apps ?? []).prefix(8) where a.hasIcon {
                if let u = model.url("/api/tv/icon?pkg=\(a.pkg)&v=2") { _ = await ImageStore.shared.load(u) }
            }
        }
        .task(id: model.remoteArrival) {
            guard Date().timeIntervalSince(model.remoteArrival) < 1 else { return }
            // The pick's picture flying in the render server: the flick's page went under the still at the pick, so there
            // is nothing of it to sit on the keys, and the keys come up with the rest of the Remote as the still fades off
            // it (gated, they came 0.3 s after the picture had landed: the review of d5d94f4).
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { keysGate.shown = false }
            // Once the flick's title, poster and controls are nearly gone (they fade in 0.12 s from the move's start), so the
            // two never sit on each other, and still early enough that the picture is never alone on the backdrop. Not later
            // than a second if no move comes.
            let arrival = model.remoteArrival
            for _ in 0..<60 where model.remoteMoveAt < arrival { try? await Task.sleep(nanoseconds: 16_000_000) }
            try? await Task.sleep(nanoseconds: 70_000_000)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { keysGate.shown = true }
        }
    }
}

private extension View {
    // A row at the foot of this view, within its width (never under the tab rail beside it).
    func stripUnder<S: View>(_ strip: S?) -> some View {
        VStack(spacing: 0) {
            self
            if let strip { strip.clipped().padding(.bottom, 8) }
        }
    }
    // One of a key row's five equal places, the key centred in it.
    func slot() -> some View { frame(maxWidth: .infinity) }
    func columnRole(_ role: PictureColumn.Role) -> some View { layoutValue(key: PictureColumn.RoleKey.self, value: role) }
}

// The Remote's column with the TV's picture at its head. The picture is the size it has with the most under it (the bar and
// the episode line), in every state, so it never shrinks when a show starts or grows when one ends (r32 shots, folded:
// about 266 pt wide with nothing on, 209 with an episode); it's the column's full width whenever that fits. What sits
// under it, and the tiles beside it open, take the picture's width, so their edges line up with it. Whatever height is
// left goes to what can grow (the pad, a spacer), never to the picture.
// The Remote's one column: how wide it is, and the keys sized to it. Five keys and four gaps make exactly the width,
// 54 pt keys at most (a remote's own size) and 40 at least; ⏯ is a quarter bigger, as it always was.
struct RemoteGrid: Equatable {
    var width: CGFloat, key: CGFloat, play: CGFloat
    // The pad's one diameter, when the posture works it out from its height; otherwise a little over half the column.
    var padSet: CGFloat?
    // Volume: − and + either side of the pad (a short column), or on a row of their own under it (a tall one).
    var volBelow = false
    var gap: CGFloat { (width - 5 * key) / 4 }
    var pad: CGFloat { padSet ?? max(110, (width * 0.54).rounded()) }
    // The keys' own room with the transport under them: the two rows (the keys, a gap, the transport with ⏯ bigger).
    var rows: CGFloat { key + 12 + play }
    static let sideGap: CGFloat = 14, volGap: CGFloat = 8, barH: CGFloat = 6
    static var volRoom: CGFloat { 0 }  // volume went (11-24); its room goes to the pad
    // The widest the column ever is, so a wide screen never spreads the keys; the least a key is where five fit.
    static let most: CGFloat = 520, least: CGFloat = 64
    var padWidth: CGFloat { volBelow ? min(pad, width) : max(60, min(pad, width - 2 * key - 2 * Self.sideGap)) }
    // Five keys and four gaps make exactly the width: as big as the width allows (a gap of 8 pt at least), 96 pt at most;
    // the column is 520 pt at most. Thumb-sized, not a remote's 54 pt (Richard, 2026-11-14). 64 pt needs 352 pt; in a
    // narrower column they come down with it, the 8 pt gaps kept, never under 44.
    static func keys(_ width: CGFloat, maxKey: CGFloat = 96) -> RemoteGrid {
        let w = min(max(width, 212), most)
        let k = min(maxKey, max(44, ((w - 32) / 5).rounded(.down)))
        let gap = (w - 5 * k) / 4
        // ⏯ a quarter bigger, but never so big that a gap beside it drops under 8 pt.
        return RemoteGrid(width: w, key: k, play: min((k * 68 / 54).rounded(), k + 2 * max(0, gap - 8)).rounded(.down))
    }
    // Given the height left for the pad and the volume, choose where the volume goes and how big the pad is: the ring
    // as large as fits (100 pt at least, the column's width at most).
    // No volume any more (11-24): the pad takes the whole room, up to the column's width.
    mutating func place(room: CGFloat) {
        volBelow = true
        padSet = max(100, min(width, room).rounded(.down))
    }
    // A column with a height to fill: the keys take what the width gives but leave the pad room (about two and a half
    // keys of it; never under 64 pt for that where the width gives 64), and the pad takes all the rest. The gaps are
    // 14 pt: above the pad, and between the pad and the keys. With the transport, two rows of keys; without, one.
    static func fit(width: CGFloat, height: CGFloat, transport: Bool) -> RemoteGrid {
        var g = keys(width)
        let kH = ((height - 28 - volRoom - (transport ? 12 : 0)) / (transport ? 4.26 : 3.4)).rounded(.down)
        if kH < g.key { g = keys(width, maxKey: max(min(g.key, least), kH)) }
        g.place(room: height - 28 - (transport ? g.rows : g.key))
        return g
    }
    // Folded, one width for everything in the column: the picture, the bar and the episode line under it, the pad's row
    // and both rows of keys share it and its edges (gate 2026-11-14: a 203 pt picture over a 255 pt pad row over 354 pt
    // of keys were three columns). The height is all spoken for (the picture, the two lines under it, the pad, two rows
    // of keys), so it's the widest that still leaves the pad a little over a third of it; never under 280 pt, the
    // picture's width before. Fixed per posture, never by what's on. `under` is the bar and the episode line with the
    // gaps over them; after them a gap, the pad with its level bar, the bar's gap to the keys, and the keys' two rows.
    static let foldedGap: CGFloat = 12
    static func folded(width: CGFloat, height: CGFloat, under: CGFloat) -> RemoteGrid {
        func room(_ w: CGFloat) -> (grid: RemoteGrid, pad: CGFloat) {
            let g = keys(w)
            return (g, height - (g.width * 9 / 16 + under + foldedGap + volRoom + volGap + g.rows))
        }
        var w = min(max(width, 212), most)
        while w > 280, room(w).pad < max(112, w * 0.36) { w -= 2 }
        var (g, r) = room(w)
        g.place(room: r + volRoom)
        return g
    }
}
struct PictureColumn: Layout {
    enum Role { case picture, under, aligned, other }
    struct RoleKey: LayoutValueKey { static let defaultValue = Role.other }
    var spacing: CGFloat = 14
    // The most the lines under the picture take in normal use, spacing included: kept for them while they're away.
    var under: CGFloat = 0
    // Where given, the lines under the picture are this wide (the column's width at most) rather than the picture's
    // width: open upright the picture is as wide as its pane's height lets it be, and the keys under it need the column.
    var lines: CGFloat? = nil
    // Open flat the column starts at the pane's edge, under the page's name, rather than centred 20 pt in from it.
    var leading = false
    private func plan(_ width: CGFloat, _ height: CGFloat?, _ subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let roles = subviews.map { $0[RoleKey.self] }
        let lined: (Int) -> Bool = { roles[$0] == .under || roles[$0] == .aligned }
        func measure(_ i: Int, _ w: CGFloat) -> (lo: CGFloat, hi: CGFloat) {
            let lo = subviews[i].sizeThatFits(ProposedViewSize(width: w, height: 0)).height
            let hi = subviews[i].sizeThatFits(ProposedViewSize(width: w, height: .infinity)).height
            return (lo, max(lo, hi))
        }
        var sizes = subviews.indices.map { roles[$0] == .picture ? (lo: CGFloat(0), hi: CGFloat(0)) : measure($0, width) }
        let shown = subviews.indices.filter { roles[$0] == .picture || sizes[$0].hi > 0 }
        let gaps = spacing * CGFloat(max(0, shown.count - 1))
        func fixed() -> CGFloat { shown.filter { roles[$0] != .picture }.reduce(0) { $0 + sizes[$1].lo } + gaps }
        var pictureH: CGFloat = 0, lineW = width
        if roles.contains(.picture) {
            let underNow = shown.filter { roles[$0] == .under }.reduce(0) { $0 + sizes[$1].lo + spacing }
            let full = width * 9 / 16
            pictureH = height.map { min(full, max(0, $0 - fixed() - max(0, under - underNow))) } ?? full
            lineW = lines.map { min(width, $0) } ?? pictureH * 16 / 9
            for i in subviews.indices where lined(i) { sizes[i] = measure(i, lineW) }
        }
        let room = max(0, (height ?? 0) - fixed() - pictureH)
        let growing = shown.filter { roles[$0] != .picture && sizes[$0].hi > sizes[$0].lo + 0.5 }
        let share = growing.isEmpty ? 0 : room / CGFloat(growing.count)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        for i in shown {
            let h = roles[i] == .picture ? pictureH : sizes[i].lo + (growing.contains(i) ? min(share, sizes[i].hi - sizes[i].lo) : 0)
            let w = roles[i] == .picture ? pictureH * 16 / 9 : lined(i) ? lineW : width
            frames[i] = CGRect(x: leading ? 0 : (width - w) / 2, y: y, width: w, height: h)
            y += h + spacing
        }
        for i in subviews.indices where !shown.contains(i) { frames[i] = CGRect(x: width / 2, y: y, width: 0, height: 0) }
        return (frames, max(0, y - spacing))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        return CGSize(width: width, height: proposal.height ?? plan(width, nil, subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = plan(bounds.width, bounds.height, subviews).frames
        for (i, f) in frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading, proposal: ProposedViewSize(f.size))
        }
    }
}

// The Remote's keys coming in: a slight grow out of a blur on the move's own spring, and a fade so short the pad's white
// centre never sits grey on the way. Nothing in the keys is measured, so the scale moves nothing that's read.
@Observable final class KeysGate { var shown = true }
private struct KeysArrive: ViewModifier {
    let gate: KeysGate
    func body(content: Content) -> some View {
        let shown = gate.shown
        return content
            .opacity(shown ? 1 : 0)
            .animation(.linear(duration: 0.08), value: shown)
            // No blur: a blur over the whole pad and its keys, animated, was most of the hitch as the flick's screen moved
            // onto the Remote (r26). A fade and a slight grow, nothing else.
            .scaleEffect(shown ? 1 : 0.96)
    }
}

// Typing into whatever box is focused on the TV. Each change sends only what's different: new letters as text, and as
// many deletes as letters went. Return is the TV's Enter, and starts afresh for the next box.
struct TypeBar: View {
    @Environment(TVModel.self) var model
    @Binding var open: Bool
    @State private var text = ""
    // What the TV's box has been sent so far.
    @State private var sent = ""
    @State private var soon: Task<Void, Never>?
    @FocusState private var focused: Bool
    // Only what the TV can type: the bridge drops anything else, so it mustn't count here either.
    static func clean(_ s: String) -> String {
        String(s.replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7e }.map(Character.init))
    }
    func sync() {
        soon?.cancel(); soon = nil
        let now = Self.clean(text)
        guard now != sent else { return }
        let same = zip(sent, now).prefix { $0 == $1 }.count
        model.type(deleting: sent.count - same, adding: String(now.dropFirst(same)))
        sent = now
    }
    var body: some View {
        HStack(spacing: 4) {
            TextField("Type on the TV", text: $text)
                .focused($focused).autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.return)
                .padding(.leading, 18)
                // A short wait gathers fast typing into one send.
                .onChange(of: text) { _, _ in
                    soon?.cancel()
                    soon = Task { try? await Task.sleep(nanoseconds: 150_000_000); if !Task.isCancelled { sync() } }
                }
                .onSubmit {
                    sync(); model.key("enter")
                    text = ""; sent = ""
                    // Return would put the keyboard away; the bar is for one box after another.
                    Task { focused = true }
                }
            // Deletes on the TV even what was typed there before this bar.
            Button {
                if text.isEmpty { model.key("del") } else { text.removeLast() }
            } label: { Image(systemName: "delete.left").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 4).accessibilityLabel("Delete on TV")
            // No second way to put the keyboard away here: the lit keyboard key just under the bar does it, and without
            // this one the placeholder fits on the folded phone ("Type on th…", Remote gate 3).
        }
        // Whatever was typed last goes before the bar does.
        .onDisappear { sync() }
        .frame(height: 50)
        .glassEffect(.regular, in: Capsule())
        .onAppear { focused = true }
        .onDisappear { sync() }
    }
}
// Whole tiles only, as many across as fit, in up to two rows: a row running off the pane cut the last one to "YouTu".
// The flicked film on the Remote's picture while the TV starts it: its poster, the light running round its edge.
// Dimmed if nothing would start.
// A film's poster as the Remote's picture shows it: sat on a blurred copy of itself. The same from the moment a flick
// lands, through its start, to playing, so the picture never changes look on the way (r17: full-bleed, then
// portrait-on-blur, a jump at the start).
struct PosterOnBlur: View {
    let url: URL?
    // The poster at 16 px, stretched: the same softness with no live blur, which redrew the whole picture every frame it
    // moved or the light ran round it.
    @State private var soft: TVImage?
    // A picture as wide as the screen it's in (a video's still, 16:9) fills it; only a poster sits framed on its blur.
    // Framed, a 16:9 still sat inset in a 16:9 box with a blur of itself round it, a letterbox of itself (the review of
    // 9c34a08, the Remote with YouTube on).
    static func isWide(_ image: TVImage) -> Bool { image.size.width > image.size.height * 1.3 }
    var wide: Bool { ImageStore.shared.cached(url).map(Self.isWide) ?? false }
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            if wide {
                Color.clear.overlay { Art(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }.clipped()
            } else {
                if let soft = soft ?? url.flatMap({ ImageStore.shared.small($0, 16) }) {
                    Color.clear.overlay { Image(tv: soft).resizable().interpolation(.high).scaledToFill() }.clipped().opacity(0.7)
                } else {
                    Color.clear.overlay { Art(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
                        .clipped().blur(radius: 24).opacity(0.7)
                }
                Art(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .padding(14)
            }
        }
        .task(id: url) {
            guard let url, soft == nil, ImageStore.shared.small(url, 16) == nil else { return }
            if await ImageStore.shared.load(url) != nil { soft = ImageStore.shared.small(url, 16) }
        }
    }
}
private struct StartingPicture: View {
    @Environment(TVModel.self) var model
    let start: TVModel.Starting
    var body: some View {
        ZStack {
            // Opaque from its first frame, whatever is or isn't loaded yet: nothing under it ever reads through (r26). Before
            // its picture comes, the app's purple with the title on it, never an empty box (the review of 94d0f11).
            LinearGradient(colors: [Color(hex: 0x352B4E), Color(hex: 0x16121F)], startPoint: .top, endPoint: .bottom)
            if start.art.isEmpty {
                Text(start.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 24)
            }
            // Failed: dimmed to half by black over it, not by fading it, which let the picture under it show through (r19).
            PosterOnBlur(url: URL(string: start.art))
                .overlay { Color.black.opacity(start.failed ? 0.5 : 0) }
            // Not while the flick's screen is moving onto it: that picture carries its own light, and two drew a second
            // frame lagging beside the moving one (r19).
            if !start.failed && !start.played && !model.flickHandoff { LoadingRing(radius: TVLook.card) }
        }
        .clipShape(RoundedRectangle(cornerRadius: TVLook.card, style: .continuous))
        // Playing: the light finishes, and the picture under it is the TV's own.
        .opacity(start.played ? 0 : 1)
        .settledAnimation(.easeOut(duration: 0.3), value: start.played)
        .allowsHitTesting(false)
        .accessibilityLabel(start.failed ? "\(start.title) didn’t start" : "\(start.title) is starting")
    }
}
// Under the picture while a start takes long: one quiet line after eight seconds. If it failed, one way on.
struct StartingNote: View {
    @Environment(TVModel.self) var model
    var body: some View {
        if let s = model.starting, !s.played {
            if s.failed {
                Button { model.tick(); model.chooseAnother() } label: {
                    Text(s.tries > 1 ? "None of those started · Choose another" : "That stream didn’t start · Choose another").font(.subheadline.weight(.semibold)).padding(.horizontal, 18).frame(height: 44)
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
                .transition(.opacity)
            } else {
                // What the TV is doing, from the first moment, in the Mac's own steps: a start takes 4 to 20 s, and a poster
                // with a light round it and no word read as nothing happening (Richard, 2026-11-10: "tv app is still slow").
                TimelineView(.periodic(from: s.since, by: 1)) { ctx in
                    let words = StartingWords.line(s, now: ctx.date)
                    Text(words).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.25), value: words)
                }
                .frame(height: 18)
            }
        }
    }
}
// The apps as one row at the Remote's foot: the launcher's banners, small, sliding sideways, the row ending in the way to
// all of them. The same row in every posture that hasn't room for the tiles.
enum AppsRoute: Hashable { case all }
struct AppStrip: View {
    @Environment(TVModel.self) var model
    @Environment(\.pagePush) private var pagePush
    static let tile: CGFloat = 96
    var inset: CGFloat = 14
    var body: some View {
        let apps = AppsTab.watching(model.status?.apps ?? [])
        let all = apps.isEmpty ? (model.status?.apps ?? []) : apps
        let h = Self.tile * TVLook.bannerSize.height / TVLook.bannerSize.width
        // The banners slide; the key to all of them stays whole at the row's end (it was the last thing in the slide, cut
        // by the screen's edge: gate on cbfc0b5).
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(all.prefix(8)) { Banner(app: $0, browses: false, width: Self.tile) } }
            }
            .clipShape(RoundedRectangle(cornerRadius: TVLook.banner, style: .continuous))
            Button { model.tick(); pagePush.push(AppsRoute.all) } label: {
                Image(systemName: "square.grid.2x2").font(.system(size: 18, weight: .semibold))
                    .frame(width: max(h, 44), height: max(h, 44))
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: TVLook.banner, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("All apps")
        }
        .padding(.horizontal, inset)
        .frame(height: max(h, 44))
    }
}
// Every app on the TV, opened from the Remote's row.
struct AppsPage: View {
    var body: some View {
        AppsTab()
            .summonsBar().topShade()
            .background { Ambience() }
            .navigationTitle("Apps").toolbar(removing: .title).navigationBarTitleDisplayMode(.inline)
            .barPage()
    }
}
struct QuickApps: View {
    @Environment(TVModel.self) var model
    // Never two tiles at the pane's edges with a hole between (r18): at least three across, sized to share the width
    // equally, as many as fit at the launcher's own size where there's more room. Up to two rows of whole tiles.
    var body: some View {
        TileRows(tile: TVLook.bannerSize, gap: TVLook.gap, rows: 2, least: 3) { w in
            ForEach(Array(AppsTab.watching(model.status?.apps ?? []).prefix(12))) { Banner(app: $0, width: w) }
        }
    }
}
// Whole tiles in rows: as many across as fit, at most `rows` rows, spread to fill the width. Any that don't fit go out of
// sight rather than being cut at the edge.
struct TileRows<Content: View>: View {
    var tile: CGSize
    var gap: CGFloat
    var rows: Int
    var least = 1
    @ViewBuilder var content: (CGFloat) -> Content
    // The tile width for a row this wide: the launcher's own size where enough of them fit, else at least `least` across,
    // each the same share of the width.
    static func layout(_ w: CGFloat, tile: CGFloat, gap: CGFloat, least: Int) -> (across: Int, width: CGFloat) {
        let fit = max(1, Int((w + gap) / (tile + gap)))
        if fit >= least { return (fit, tile + (w - CGFloat(fit) * tile - CGFloat(fit - 1) * gap) / CGFloat(fit)) }
        return (least, (w - CGFloat(least - 1) * gap) / CGFloat(least))
    }
    var body: some View {
        // The width it's given in this pass, read by the layout, so there's no first frame at the wrong size.
        TileGrid(gap: gap, rows: rows, aspect: tile.height / tile.width) { w in
            Self.layout(w, tile: tile.width, gap: gap, least: least)
        } content: { w in content(w) }
    }
}
// Lays the tiles out from the width it's offered: whole tiles in rows, equal widths, any beyond `rows` rows out of sight.
private struct TileGrid<Content: View>: View {
    var gap: CGFloat, rows: Int, aspect: CGFloat
    var plan: (CGFloat) -> (across: Int, width: CGFloat)
    @ViewBuilder var content: (CGFloat) -> Content
    @State private var width: CGFloat = 0
    var body: some View {
        let p = plan(max(width, 1))
        Grid(width: p.width, across: p.across, gap: gap, rows: rows, aspect: aspect) { content(p.width) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if abs($0 - width) > 0.5 { width = $0 } }
            .opacity(width > 0 ? 1 : 0)
    }
    private struct Grid: Layout {
        var width: CGFloat, across: Int, gap: CGFloat, rows: Int, aspect: CGFloat
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let n = min(subviews.count, across * rows), r = n == 0 ? 0 : (n + across - 1) / across
            let h = width * aspect
            return CGSize(width: proposal.width ?? CGFloat(across) * width, height: CGFloat(r) * h + CGFloat(max(r - 1, 0)) * gap)
        }
        func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let n = min(subviews.count, across * rows), h = width * aspect
            for (i, v) in subviews.enumerated() {
                let size = ProposedViewSize(width: width, height: h)
                guard i < n else { v.place(at: CGPoint(x: b.minX - 10_000, y: b.minY), anchor: .topLeading, proposal: size); continue }
                v.place(at: CGPoint(x: b.minX + CGFloat(i % across) * (width + gap), y: b.minY + CGFloat(i / across) * (h + gap)), anchor: .topLeading, proposal: size)
            }
        }
    }
}
// The five keys under whatever's playing, the same on the Remote and on Playing: back, ten back, play, ten on, next.
// Stremio's player ignores the media keys, so with it open the jumps go through its seek bar, back is the start of the
// episode and then the one before, and next is the next episode. Five keys always, in the top row's five places: an
// empty place read as a missing button (Richard, 2026-11-05: "no back button here is ridiculous").
struct Transport: View {
    // For the build's recording: ⏭ pressed while the next episode isn't known yet.
    // Whichever ⏭ is up: the next episode's own key when it's known, otherwise the one still working it out.
    @MainActor static func pressNext(_ model: TVModel) {
        if let n = NextUp.shared.next { model.flick(FlickTarget(item: n, source: .stremio, ready: true, autoplay: true)) }
        else { NotificationCenter.default.post(name: ResolvingNextKey.press, object: nil) }
    }
    @Environment(TVModel.self) var model
    @ObservedObject private var nextUp = NextUp.shared
    // No glow while typing on the Remote: it would smear through the keyboard just above.
    var glow = true
    var size: CGFloat = 54
    var playSize: CGFloat = 68
    // Said to be playing but already at the end: an old report, shown as stopped there.
    var ended = false
    // Whether what it plays is playing, when that's not the video session's to say (Mint's music).
    var playing: Bool?? = nil
    // A flicked start under way: ⏯ says pause (it's going), ⏭ is dimmed for a film. Failed: everything but holding ⏯ to
    // stop is dimmed, since nothing is on to control (r18).
    var starting: TVModel.Starting? { model.starting.flatMap { $0.played ? nil : $0 } }
    var failed: Bool { starting?.failed == true }
    // An episode on whose next can't be worked out yet: ⏭ stays lit and works it out on the press (r18: dimmed on S2 E3 of 4).
    var episodeOn: Bool { model.status?.session?.seasonEpisode != nil || (starting?.line?.hasPrefix("S") ?? false) }
    // Nothing after this (a film, or the last episode): four keys, never a dead ⏭ (TV polish designer, 2026-11-11). The
    // four keep the five places' outer edges, so they still line up with the keys above them.
    @State private var rowWidth: CGFloat = 0
    var body: some View {
        let stremio = playing == nil && (model.status?.session?.pkg == "com.stremio.one" || starting != nil)
        let four = stremio && nextUp.next == nil && !(episodeOn && nextUp.series == nil)
        let slot: CGFloat? = four ? nil : .infinity
        let inset = four ? max(0, (rowWidth / 5 - size) / 2) : 0
        HStack(spacing: 0) {
            Group {
                if stremio { GlassButton(icon: "backward.end.fill", label: nextUp.previous.map { "Start over, or \($0.subtitle)" } ?? "Start over", size: size) { StremioBack.press(model) } }
                else { GlassKey(icon: "backward.end.fill", label: "Previous", key: "previous", size: size) }
            }.frame(maxWidth: slot)
            if four { Spacer(minLength: 0) }
            Group {
                if stremio { SeekButton(icon: "gobackward.10", label: "Back 10 seconds", step: -1, size: size) } else { GlassKey(icon: "gobackward.10", label: "Rewind", key: "rewind", size: size) }
            }.frame(maxWidth: slot)
            if four { Spacer(minLength: 0) }
            // Says which it'll do, as on the Playing tab, once the TV's word is fresh.
            // Held, it stops: the flick's own control screen is gone, and Stop went with it to here.
            // A start shows pause from the throw on (r19: the key changed glyph mid-start for no reason). Failed, nothing is
            // playing, so it says play, with the row dimmed, never a dimmed pause over nothing (review of dfd490e); what the
            // TV says is on, if anything, decides it.
            PlayKey(playing: ended ? false : playing ?? (failed ? (model.status?.session?.playing ?? false) : starting != nil ? true : model.staleStatus ? nil : model.status?.session?.playing), size: playSize, glow: glow)
                .contextMenu {
                    Button("Stop", systemImage: "stop.fill") {
                        // Held while a flicked film is still starting, it calls the start off too.
                        if model.starting != nil { model.post("stop-playing", ["pkg": "com.stremio.one"]); model.clearStart() }
                        model.key(stremio ? "back" : "stop")
                        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); await model.load() }
                    }
                }
                .frame(maxWidth: slot)
            if four { Spacer(minLength: 0) }
            Group {
                if stremio { SeekButton(icon: "goforward.10", label: "Forward 10 seconds", step: 1, size: size) } else { GlassKey(icon: "goforward.10", label: "Fast forward", key: "forward", size: size) }
            }.frame(maxWidth: slot)
            if !four {
            Group {
                if !stremio { GlassKey(icon: "forward.end.fill", label: "Next", key: "next", size: size) }
                else if let next = nextUp.next {
                    GlassButton(icon: "forward.end.fill", label: "Next episode, \(next.subtitle)", size: size) {
                        model.flick(FlickTarget(item: next, source: .stremio, ready: true, autoplay: true))
                    }
                } else if episodeOn && nextUp.series == nil {
                    // Not worked out yet: asked for on the press, and the TV's own next if it still can't be. A series never
                    // dims ⏭ for not knowing (r19), and the key shows it's working on it until it throws.
                    ResolvingNextKey(size: size)
                }
            }.frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, inset)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in if abs(w - rowWidth) > 0.5 { rowWidth = w } }
        // Failed: nothing to control but stopping, which is the held ⏯.
        // Connecting (nothing heard from the TV yet this launch, and no start under way): the row waits at 40 %, like the
        // bar's place in a start, rather than a bright ▶ saying it's paused when it may be playing (r33: ▶, then ⏸ a
        // second later).
        .opacity(failed || connecting ? 0.4 : 1)
        .allowsHitTesting(!connecting)
        // Coming up only once ⏯ has swapped to what the TV said: as one, the bright ▶ showed for a frame before ⏸ (r34).
        .settledAnimation(.easeOut(duration: 0.2).delay(connecting ? 0 : 0.3), value: connecting)
        // The outer keys change kind with the app on the TV (Stremio's own seek and episode keys, else the TV's media
        // keys): a crossfade, not a swap, as the status comes in.
        .settledAnimation(.easeOut(duration: 0.2), value: stremio)
    }
    var connecting: Bool { playing == nil && starting == nil && model.staleStatus }
}

// ⏭ for an episode whose next isn't worked out yet: the light runs round the key from the press until the next one is
// thrown (or the TV's own next is sent), so the press answers at once (r19: up to 2 s with no response).
struct ResolvingNextKey: View {
    @Environment(TVModel.self) var model
    var size: CGFloat
    @State private var busy = false
    // The build's recording presses it the way a finger does (the realnext pose).
    static let press = Notification.Name("ResolvingNextKey.press")
    var body: some View {
        GlassButton(icon: "forward.end.fill", label: "Next episode", size: size) { go() }
        // Its own press, or the Now Playing card's next-episode link working the same thing out.
        .overlay { if busy || model.resolvingNext { LoadingRing(radius: size / 2).frame(width: size, height: size).transition(.opacity) } }
        .animation(.easeOut(duration: 0.15), value: busy || model.resolvingNext)
        .onReceive(NotificationCenter.default.publisher(for: Self.press)) { _ in go() }
    }
    func go() {
            guard !busy, !model.resolvingNext else { return }
            busy = true
            Task {
                NextUp.shared.forget(); NextUp.shared.follow(model.status)
                for _ in 0..<20 where NextUp.shared.next == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                // Stremio ignores the TV's own skip keys, so with no next episode found there's nothing to send: said so,
                // never a key that does nothing (real-TV test, 2026-11-05).
                if let n = NextUp.shared.next { model.flick(FlickTarget(item: n, source: .stremio, ready: true, autoplay: true)) } else { model.say("Couldn’t find the next episode") }
                busy = false
            }
    }
}

// MARK: - Apps
struct Banner: View {
    @Environment(TVModel.self) var model
    let app: TVStatus.App
    var browses = false
    // Its width where a row fits its tiles to the room (the Remote's tiles, three across); the launcher's own otherwise.
    var width: CGFloat = TVLook.bannerSize.width
    // The press shows at once: the ring goes to the tile pressed and stays until the TV says which app is in front
    // (it took the open's round trip, 0.8 s and the next reading, about two seconds, with nothing on the tile to say
    // the press had landed).
    func open() { model.tick(); model.opening(app.pkg); model.post("open", ["pkg": app.pkg]) }
    var body: some View {
        Button {
            // An app with something to choose from opens that here; the rest go straight to the TV.
            // Stremio's tile is Watch, where its shelves already are (Richard, 2026-11-11).
            if browses, app.pkg == "com.stremio.one" { model.tick(); model.tab = 3 }
            else if browses, let s = MediaSource.of(pkg: app.pkg) { model.tick(); model.browsing = s }
            else if browses, app.pkg == "com.mint.letterboxd" { model.tick(); model.tab = 3 }
            else { open() }
        } label: {
            ZStack {
                // Some banners are a white logo on nothing, meant for a dark tile, like YouTube Music's.
                app.wide == true ? Color.black : TVLook.bannerTile
                if app.pkg == MintBanner.pkg { MintBanner() }
                else if app.hasIcon, let u = model.url("/api/tv/icon?pkg=\(app.pkg)&v=2") {
                    Art(url: u) { i in
                        // A banner that came out blank, a white logo flattened onto white, is never shown as it is.
                        if ImageStore.shared.isFlat(u) { BannerFallback(app: app) }
                        else if app.wide == true { i.resizable().scaledToFill() }
                        else {
                            VStack(spacing: 4) { i.resizable().scaledToFit().frame(width: 30, height: 30); Text(app.name).font(.caption.weight(.medium)).lineLimit(1).padding(.horizontal, 8) }
                        }
                    } placeholder: {
                        // Waiting for a wide banner: its brand's colour, never a grey tile over black.
                        if app.wide == true, let c = BannerFallback.brands[app.pkg] { Color(hex: c) } else { TVLook.bannerTile }
                    }
                } else { BannerFallback(app: app) }
            }
            .frame(width: width, height: width * TVLook.bannerSize.height / TVLook.bannerSize.width)
            .clipShape(RoundedRectangle(cornerRadius: TVLook.banner, style: .continuous))
            .overlay { FrontRing(pkg: app.pkg) }
            .overlay(alignment: .topTrailing) { OnTVMark(pkg: app.pkg) }
            .shotSpot(browses && app.pkg == "com.stremio.one" ? "stremio" : "", pose: "stremiotile")
        }
        .buttonStyle(PressCard()).accessibilityLabel(app.name).accessibilityAddTraits(model.frontApp == app.pkg ? .isSelected : [])
        .contextMenu { if browses { Button("Open on TV", systemImage: "tv") { open() } } }
    }
}
// The ring round the app in front on the TV. A view of its own, so the TV's status changing redraws the rings, not
// every banner and its picture.
private struct FrontRing: View {
    @Environment(TVModel.self) var model
    let pkg: String
    var body: some View {
        let on = model.frontApp == pkg
        RoundedRectangle(cornerRadius: TVLook.banner, style: .continuous).strokeBorder(TVLook.accent, lineWidth: 2.5)
            // Pressed and not yet confirmed: the ring breathes, quietly, until the TV says the app is in front.
            .modifier(RingWaits(on: model.openingApp?.pkg == pkg))
            .opacity(on ? 1 : 0)
            // Settled: coming back to the page, the ring is simply where it is; it only moves in front of him.
            .settledAnimation(.easeOut(duration: 0.15), value: on)
            .accessibilityHidden(true)
    }
}
// The ring's meaning, said on the tile: a small TV in the ring's cyan at its corner, once the TV says this app is in front
// (gate 276: the cyan ring alone had no stated meaning). Not while a press is still waiting for the TV's word.
private struct OnTVMark: View {
    @Environment(TVModel.self) var model
    let pkg: String
    var body: some View {
        let on = model.frontApp == pkg && model.openingApp?.pkg != pkg
        Image(systemName: "tv.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.85))
            .frame(width: 20, height: 20).background(TVLook.accent, in: Circle())
            .padding(5)
            .opacity(on ? 1 : 0)
            .settledAnimation(.easeOut(duration: 0.15), value: on)
            .accessibilityHidden(true)
    }
}
// Mint's banner, made from Mint's own icon and its name, as YouTube Music's is its mark and its name: the banner Mint
// ships is a play triangle on a dark block beside thin words on mint, which read as home-made beside the real ones
// (gate 276, law 3).
struct MintBanner: View {
    static let pkg = "com.codex.musicwebtv"
    // A thumbnail beside the app's own name: the icon alone, no words too small to read.
    var iconOnly = false
    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            HStack(spacing: h * 0.13) {
                Image("MintIcon").resizable().interpolation(.high).scaledToFit().frame(width: h * (iconOnly ? 0.66 : 0.46), height: h * (iconOnly ? 0.66 : 0.46))
                if !iconOnly { Text("Mint Music").font(.system(size: h * 0.2, weight: .bold)).tracking(-0.2).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6) }
            }
            .padding(.horizontal, iconOnly ? 0 : h * 0.16)
            .frame(width: g.size.width, height: h)
        }
        .background(Color(hex: 0x263238))
        .accessibilityHidden(true)
    }
}
private struct RingWaits: ViewModifier {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var still
    // One view throughout, its strength eased both ways: swapped for another when the TV confirmed, the ring jumped from
    // wherever its breath was (as low as 45 %) to full in one frame.
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1)
            .animation(on && !still ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .easeOut(duration: 0.2), value: dim)
            .onChange(of: on, initial: true) { _, now in dim = now && !still }
    }
}
// A banner drawn here, for an app whose own is missing or came out blank: its brand's colour, its mark where it has a
// simple one, and its name in the launcher's weight. Never a white card, never an icon in a grey box.
struct BannerFallback: View {
    let app: TVStatus.App
    var monogram: some View {
        Text(String(app.name.prefix(1)).uppercased()).font(.system(size: 17, weight: .heavy, design: .rounded))
            .frame(width: 34, height: 34).background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    static let brands: [String: UInt32] = ["com.google.android.youtube.tvmusic": 0x0F0F0F, "flar2.homebutton": 0x1E3A5F, "com.netflix.ninja": 0x141414,
                                           "com.stremio.one": 0x19152C, "com.codex.musicwebtv": 0x1F9E78, "com.mint.letterboxd": 0x202830]
    var body: some View {
        ZStack {
            Self.brands[app.pkg].map { Color(hex: $0) } ?? TVLook.bannerTile
            HStack(spacing: 9) {
                if app.pkg == "com.google.android.youtube.tvmusic" {
                    // YouTube Music's mark: a red disc, a white ring, a play triangle.
                    ZStack {
                        Circle().fill(Color(hex: 0xFF0033))
                        Circle().strokeBorder(.white, lineWidth: 1.8).padding(6)
                        Image(systemName: "play.fill").font(.system(size: 8, weight: .bold)).offset(x: 0.6)
                    }
                    .frame(width: 30, height: 30)
                } else if app.hasIcon, let u = TVBridge.url("/api/tv/icon?pkg=\(app.pkg)&v=2"), !ImageStore.shared.isFlat(u) {
                    // Its own icon beside its name, when it has one with something in it.
                    Art(url: u) { i in
                        i.resizable().scaledToFit().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } placeholder: { monogram }
                } else {
                    // No mark of its own: a drawn one, its initial on a lighter disc, so the tile is never words alone.
                    monogram
                }
                Text(app.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
        }
        .accessibilityHidden(true)
    }
}
// A section of the Apps tab: every app in it on the page, in rows that wrap at the width the tab gives it, never a
// sideways row with its fifth tile cut at the edge (gate 276).
struct BannerRow: View {
    let title: String, apps: [TVStatus.App]
    var across: Int
    var width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowTitle(title)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: TVLook.gap, alignment: .leading), count: max(across, 1)), alignment: .leading, spacing: TVLook.gap) {
                ForEach(apps) { Banner(app: $0, browses: true, width: width) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    // How many across for this many tiles in this width: as many as fit at the launcher's size (at least two), then
    // fewer if that leaves fewer holes in the last row (six in a row of four would be four and two; it's three and three).
    static func across(_ n: Int, in w: CGFloat) -> Int {
        let fit = max(2, Int((w + TVLook.gap) / (TVLook.bannerSize.width + TVLook.gap)))
        guard n > 0 else { return fit }
        return (2...fit).reversed().min { a, b in
            let ha = (a - n % a) % a + (a > n ? a - n : 0), hb = (b - n % b) % b + (b > n ? b - n : 0)
            return ha != hb ? ha < hb : a > b
        } ?? fit
    }
    static func width(_ across: Int, in w: CGFloat) -> CGFloat { max(40, (w - CGFloat(across - 1) * TVLook.gap) / CGFloat(across)) }
}
struct AppsTab: View {
    @Environment(TVModel.self) var model
    @Environment(\.paneLayout) private var panes
    static let listen = ["com.codex.musicwebtv", "com.google.android.youtube.tvmusic"]
    static let tools: Set<String> = ["com.android.tv.settings", "com.android.vending", "com.cxinventor.file.explorer", "com.esaba.downloader", "flar2.homebutton", "com.macropinch.axe"]
    // Never offered on the phone at all: no games.
    static let hidden: Set<String> = ["com.google.android.play.games"]
    static let watchOrder = ["com.mint.letterboxd", "com.stremio.one", "com.google.android.youtube.tv", "com.google.android.youtube.tvunplugged", "com.netflix.ninja", "com.plexapp.android", "com.apple.atve.androidtv.appletv", "com.amazon.amazonvideo.livingroom", "com.cbs.ott"]
    var all: [TVStatus.App] { (model.status?.apps ?? []).filter { !Self.hidden.contains($0.pkg) } }
    static func watching(_ all: [TVStatus.App]) -> [TVStatus.App] {
        let rest = all.filter { !tools.contains($0.pkg) && !listen.contains($0.pkg) && !hidden.contains($0.pkg) }
        return rest.sorted { (watchOrder.firstIndex(of: $0.pkg) ?? 99) < (watchOrder.firstIndex(of: $1.pkg) ?? 99) }
    }
    var watch: [TVStatus.App] { Self.watching(all) }
    var listen: [TVStatus.App] { Self.listen.compactMap { p in all.first { $0.pkg == p } } }
    var tools: [TVStatus.App] { all.filter { Self.tools.contains($0.pkg) } }
    @ViewBuilder func row(_ title: String, _ apps: [TVStatus.App], across: Int, width: CGFloat) -> some View {
        if !apps.isEmpty { BannerRow(title: title, apps: apps, across: across, width: width) }
    }
    // The room the rows have, inside the page's 20 pt sides: the whole column folded and open upright, each pane open flat
    // (both panes' tiles take the narrower pane's size, so the same kind of tile is one size on both sides; gate 276).
    @State private var pageWidth: CGFloat = 0
    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0
    // Open flat, the right pane starts its first heading level with "Watch", under the search on the left.
    @State private var barRoom: CGFloat = 0
    func measured(_ w: Binding<CGFloat>) -> some View {
        Color.clear.frame(height: 0).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if abs($0 - w.wrappedValue) > 0.5 { w.wrappedValue = $0 } }
    }

    // Folded and open upright: Watch as many across as leave no holes; open upright Listen and Tools share one band, two
    // each, rather than two rows of two with half the screen empty beside them.
    @ViewBuilder var rows: some View {
        let w = max(pageWidth - 40, 1)
        let a = BannerRow.across(watch.count, in: w)
        row("Watch", watch, across: a, width: BannerRow.width(a, in: w))
        if w >= 520, !listen.isEmpty, !tools.isEmpty {
            let half = (w - TVLook.gap * 2) / 2
            HStack(alignment: .top, spacing: TVLook.gap * 2) {
                row("Listen", listen, across: 2, width: BannerRow.width(2, in: half)).frame(width: half, alignment: .leading)
                row("Tools", tools, across: 2, width: BannerRow.width(2, in: half)).frame(width: half, alignment: .leading)
            }
        } else {
            let b = BannerRow.across(max(listen.count, tools.count), in: w)
            row("Listen", listen, across: b, width: BannerRow.width(b, in: w))
            row("Tools", tools, across: b, width: BannerRow.width(b, in: w))
        }
    }
    // Open flat: two across each side, at one width.
    // Two across in each pane at one width: the narrower pane's room inside its 20 pt sides, so the right pane's two
    // end where Settings' cards do, and the left's are the same size (fifth pass).
    static let railClear: CGFloat = 66
    var paneTile: CGFloat { BannerRow.width(2, in: max(min(leftWidth - 40, rightWidth - 20 - Self.railClear), 1)) }
    // Before the first answer, the shape of the page instead of a blank one.
    var waiting: some View {
        HStack(spacing: TVLook.gap) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: TVLook.banner, style: .continuous).fill(.white.opacity(0.08)).frame(width: TVLook.bannerSize.width, height: TVLook.bannerSize.height)
            }
        }
        // minWidth 0, so six banners never widen the page they wait on (the cold-entry jump).
        .padding(.horizontal, 20).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
    }
    var body: some View {
        let _ = SwipeLog.mark("body apps")
        content.navigationDestination(item: Binding(get: { model.browsing }, set: { model.browsing = $0 })) { AppBrowse(source: $0).underFlick(barHidden: true) }
            #if os(iOS)
            .onChange(of: model.browsing) { _, b in HitchLog.shared.note(b == nil ? "Apps pop app page" : "Apps push app page") }
            #endif
    }
    @ViewBuilder var content: some View {
        if all.isEmpty {
            ScrollView { VStack(alignment: .leading, spacing: 24) { PageHeading("Apps").padding(.horizontal, 20); waiting }.padding(.vertical, 12) }.backToTop()
        } else if panes {
            FoldSplit {
                ScrollView {
                    // The field opens the one search (the Search tab); a copied link pasted here still goes to the TV.
                    VStack(alignment: .leading, spacing: 26) {
                        // The field as wide as the grid under it, so the column has one right edge (fifth pass).
                        PageHeading("Apps").padding(.horizontal, 20)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if abs($0 - barRoom) > 0.5 { barRoom = $0 } }
                        row("Watch", watch, across: 2, width: paneTile).padding(.horizontal, 20)
                    }
                    .padding(.vertical, 12)
                    .background(alignment: .top) { measured($leftWidth) }
                }
                .backToTop(posed: false)
            } right: {
                // Unfolded, the apps go on across the fold: what he watches with the search on the left, what he listens
                // with and the TV's tools on the right. Only apps on this tab (Richard's choice, 2026-11-10): Continue
                // watching is Watch's and Recently played is Playing's.
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: barRoom)
                        row("Listen", listen, across: 2, width: paneTile)
                        row("Tools", tools, across: 2, width: paneTile)
                    }
                    // Inside a tab's page the right pane's room runs about 16 pt under the side bar, where Settings'
                    // does: kept 66 pt clear, so the tiles end 50 pt short of the bar where Settings' cards do (fifth pass, measured).
                    .padding(.leading, 20).padding(.trailing, Self.railClear)
                    .padding(.vertical, 12)
                    .background(alignment: .top) { measured($rightWidth) }
                }
                .backToTop()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    PageHeading("Apps").padding(.horizontal, 20)
                    rows.padding(.horizontal, 20)
                }
                .padding(.vertical, 12)
                .background(alignment: .top) { measured($pageWidth) }
            }
            .backToTop()
        }
    }
}

// Ten seconds back or on in Stremio. Taps add up while the TV catches up: the button in the direction it's going shows
// how far, in seconds, until the TV's own report has it.
struct SeekButton: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var seeker = SeekQueue.shared
    let icon: String, label: String, step: Int
    var size: CGFloat = 56
    var body: some View {
        let net = Int(seeker.offset(for: model.status?.session) / 1000)
        let mine = step > 0 ? net > 0 : net < 0
        Button { seeker.add(step, for: model.status?.session, model: model) } label: {
            ZStack {
                if mine {
                    Text((net > 0 ? "+" : "−") + "\(abs(net))").font(.system(size: size * 0.3, weight: .semibold).monospacedDigit())
                        .foregroundStyle(TVLook.accent).contentTransition(.numericText(value: Double(net)))
                        .transition(.opacity)
                } else {
                    Image(systemName: icon).font(.system(size: size * 0.39, weight: .medium)).transition(.opacity)
                }
            }
            .frame(width: size, height: size).contentShape(Circle())
        }
        // Still on its way after a moment: a ring turning round the key that shows how far, easier to see than anything
        // on a long film's bar.
        .overlay { if mine && seeker.spinning { SpinRing().transition(.opacity) } }
        .buttonStyle(.plain).keyGlass().accessibilityLabel(label)
        .accessibilityValue(mine ? "\(abs(net)) seconds" : "")
        .animation(.easeOut(duration: 0.2), value: mine && seeker.spinning)
        .animation(.snappy(duration: 0.2), value: net)
    }
}

private struct SpinRing: View {
    @State private var turn = false
    var body: some View {
        Circle().trim(from: 0, to: 0.28).stroke(TVLook.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .padding(1.5)
            .rotationEffect(.degrees(turn ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = true } }
            .allowsHitTesting(false)
    }
}

// The bar itself, for songs and films alike. With nothing to show yet, just the empty track. When jumps are on their
// way, the part the TV hasn't confirmed is drawn at half strength, from where it is to where it's going, and once
// that's taken a while a small spinner sits at the head.
struct ProgressTrack: View {
    let fraction: Double?
    var thick: CGFloat = 6
    var fill: AnyShapeStyle = AnyShapeStyle(TVLook.accent)
    var confirmed: Double? = nil
    var spinning = false
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, at = { (f: Double) in w * min(1, max(0, f)) }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height: thick)
                if let fraction {
                    if let confirmed, abs(confirmed - fraction) > 0.0005 {
                        Capsule().fill(TVLook.accent.opacity(0.5)).frame(width: max(thick, at(max(confirmed, fraction))), height: thick)
                        Capsule().fill(fill).frame(width: max(thick, at(min(confirmed, fraction))), height: thick)
                    } else {
                        Capsule().fill(fill).frame(width: max(thick, at(fraction)), height: thick)
                    }
                    if spinning {
                        ProgressView().controlSize(.small).tint(.white).scaleEffect(0.7).frame(width: 14, height: 14)
                            .offset(x: min(max(at(fraction) - 7, 0), max(w - 14, 0)))
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.2), value: spinning)
        }
    }
}
// MARK: - Films
struct FilmCard: View {
    @Environment(TVModel.self) var model
    let film: Film
    @State private var place = FrameBox()
    var body: some View {
        Button { guard Date().timeIntervalSince(ShelfHand.shared.handledAt) >= 0.35 else { return }; model.tick(); FlickCardButton.tap(model, film.media, .stremio, origin: place.rect) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Art(url: URL(string: film.poster)) { i in i.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                    .frame(width: 118, height: 177).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .measured(place)
                VStack(alignment: .leading, spacing: 1) {
                    Text(film.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    if !film.note.isEmpty { Text(film.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(width: 118, alignment: .leading)
            }
        }.buttonStyle(PressCard()).modifier(RowFlick(item: film.media, source: .stremio, width: 118, place: place)).accessibilityLabel(film.title)
    }
}
struct FilmRow: View {
    let title: String, films: [Film]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowHeader(title: title, route: .films(title, films)).padding(.leading, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { ForEach(films) { FilmCard(film: $0) } }.padding(.horizontal, 20).scrollTargetLayout()
            }
            .rowEdge()
        }
    }
}
struct FilmList: View {
    @Environment(TVModel.self) var model
    let title: String, films: [Film]
    var body: some View {
        RowList(title: title) {
            ForEach(films) { film in
                FlickRowBox(item: film.media, source: .stremio, width: 50, label: { place in AnyView(
                    HStack(spacing: 12) {
                        Art(url: URL(string: film.poster)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                            .frame(width: 50, height: 75).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .measured(place)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(film.title).font(.body.weight(.semibold)).lineLimit(2)
                            HStack(spacing: 6) {
                                if !film.year.isEmpty { Text(film.year) }
                                if !film.note.isEmpty, film.note != film.year { Text(film.note).lineLimit(1) }
                            }.font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "tv").foregroundStyle(TVLook.accent).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                ) })
            }
        }
    }
}
// Films and shows to pick from: what's on the TV's own Stremio home, Letterboxd's picks and friends, and Stremio's
// catalogue, popular, top rated, new, by genre and by search. Every card flicks like anywhere else.
struct FilmsTab: View {
    @Environment(TVModel.self) var model
    // Films or shows, kept through unfolding, which rebuilds the layout. The lists themselves live for the app's life.
    @SceneStorage("watchKind") private var kind = "movie"
    var films: BrowseStore { .discover("movie") }
    var shows: BrowseStore { .discover("series") }
    static let genres = ["Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama", "Family", "Fantasy", "History", "Horror", "Mystery", "Romance", "Sci-Fi", "Thriller", "War", "Western"]
    @Environment(\.paneLayout) private var panes
    var body: some View {
        let _ = SwipeLog.mark("body films")
        // Films or shows only swaps the rows: the switch itself, the search and the place on the page stay put.
        Group {
            // Unfolded, the rows take turns on each side of the fold, as on an app's own page, rather than running across it.
            if panes {
                FoldSplit { DiscoverColumn(store: kind == "movie" ? films : shows, kind: $kind, part: .left) }
                    right: { DiscoverColumn(store: kind == "movie" ? films : shows, kind: $kind, part: .right) }
            } else {
                DiscoverColumn(store: kind == "movie" ? films : shows, kind: $kind)
            }
        }
    }
}
// Watch's one filter: films or shows, and the genre, in a menu beside the page's name.
struct WatchFilterKey: View {
    @Environment(TVModel.self) var model
    @SceneStorage("watchKind") private var kind = "movie"
    @ObservedObject private var films = BrowseStore.discover("movie")
    @ObservedObject private var shows = BrowseStore.discover("series")
    var store: BrowseStore { kind == "movie" ? films : shows }
    var body: some View {
        Menu {
            Picker("Kind", selection: $kind) { Text("Films").tag("movie"); Text("Shows").tag("series") }
            Picker("Genre", selection: Binding(get: { store.genre }, set: { g in
                let st = store
                st.genre = g
                Task { await st.load(force: true) }
            })) {
                Text("All genres").tag("")
                ForEach(FilmsTab.genres, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 15, weight: .semibold))
                Text((kind == "movie" ? "Films" : "Shows") + (store.genre.isEmpty ? "" : " · " + store.genre)).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 44)
            .background(.white.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .haptic(.tick, trigger: kind)
        .accessibilityLabel("Filter: " + (kind == "movie" ? "films" : "shows") + (store.genre.isEmpty ? "" : ", " + store.genre))
    }
}
struct DiscoverColumn: View {
    @Environment(TVModel.self) var model
    @ObservedObject var store: BrowseStore
    @Binding var kind: String
    var part = BrowseColumn.Part.all
    // Both lists, so where he is stays put above the switch while the other kind's rows are still coming.
    @ObservedObject private var films = BrowseStore.discover("movie")
    @ObservedObject private var shows = BrowseStore.discover("series")
    @ObservedObject private var home = BrowseStore.shared(.stremio)
    @FocusState private var searchFocused: Bool
    // How wide the column is, for whether a found list is all on screen (then its heading is no door).
    @State private var paneWidth: CGFloat = 0
    static let continueTitle = "Continue watching"
    // Films and shows together, so it sits above the switch and belongs to neither: the page's first row, and its home
    // since it left the Apps tab (Richard's choice, 2026-11-10). Only ever Stremio's own row, the one under a film on
    // Playing and on Stremio's page, so there's one list of where he is everywhere: nothing until that one is in, never a
    // different list that then swaps.
    var continuing: MediaRow? {
        guard store.query.isEmpty else { return nil }
        return home.rows.first { $0.title == Self.continueTitle && !$0.items.isEmpty }
    }
    // What's in Continue watching isn't shown again further down. A row left with fewer than four isn't shown alone, and
    // never under another row's name, which would then say something false ("Top rated" over a friend's pick): what's
    // left of the short ones goes together at the end, as "More to watch", once each, if there are enough of them.
    // Worked out when the lists change, not on every redraw of the column.
    @State private var built: [MediaRow]?
    var rows: [MediaRow] { built ?? computeRows() }
    func computeRows() -> [MediaRow] {
        // What a search found is shown as found, under its own name, however few: regrouped like the shelves, one show
        // found came out as "More to watch".
        // Only once the search has its answer: until then the page stays as it was, not the shelves as they came.
        if !store.query.trimmingCharacters(in: .whitespaces).isEmpty { return store.answered(store.query) ? store.rows : (built ?? []) }
        func key(_ i: MediaItem) -> String { i.stremioRef?.imdb ?? i.id }
        let mine = Set((continuing?.items ?? []).map(key))
        let kept = store.rows.filter { $0.title != Self.continueTitle }.compactMap { r -> MediaRow? in
            let items = r.items.filter { !mine.contains(key($0)) }
            return items.isEmpty ? nil : MediaRow(title: r.title, items: items)
        }
        var out: [MediaRow] = [], spare: [MediaItem] = []
        for r in kept { if r.items.count >= 4 { out.append(r) } else { spare += r.items } }
        var seen = Set(out.flatMap { $0.items.map(key) })
        spare = spare.filter { seen.insert(key($0)).inserted }
        // Always under their own name, never another row's: four or more make "More to watch". Fewer, with full rows on
        // the page, are dropped (a sparse shelf or a false heading are both worse than three fewer cards). With no full
        // row at all, whatever there is shows as "More to watch" rather than an empty page.
        if spare.count >= 4 || (out.isEmpty && !spare.isEmpty) { out.append(MediaRow(title: "More to watch", items: spare)) }
        return out
    }
    var shown: [MediaRow] {
        part == .all ? rows : rows.enumerated().filter { ($0.offset % 2 == 0) == (part == .left) }.map(\.element)
    }
    // Continue watching leads, as large cards, about two and a half across: what he throws most nights (brief 3.3).
    var leadWidth: CGFloat { paneWidth < 1 ? 150 : max(132, min(190, (paneWidth - 40 - 20) / 2.5)) }
    func shelf(_ row: MediaRow) -> some View {
        // What a search found is named for what it is ("Films", "Shows", as on the Apps page), not "Results"; and a list
        // short enough to be all on screen has no door to a page of the same few cards.
        let searched = !store.query.trimmingCharacters(in: .whitespaces).isEmpty && row.title == "Results"
        let title = searched ? (kind == "movie" ? "Films" : "Shows") : row.title
        return VStack(alignment: .leading, spacing: 0) {
            if searched && 20 + CGFloat(row.items.count) * 124 + CGFloat(max(row.items.count - 1, 0)) * 10 <= max(paneWidth, 1) { RowTitle(title).padding(.leading, 20) }
            else { RowHeader(title: title, route: .media(MediaRow(title: title, items: row.items), .stremio)).padding(.leading, 20) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(row.items) { item in FlickCardButton(item: item, source: .stremio, width: row.title == Self.continueTitle ? leadWidth : 124) }
                }
                .padding(.horizontal, 20)
            }
            .rowEdge()
        }
    }
    // Stremio's home not in yet, and there was a Continue watching last time: its room is kept, so it fills in rather than
    // arriving above the films and pushing them down (r18).
    var waitingForContinue: Bool { home.rows.isEmpty && !home.failed && UserDefaults.standard.bool(forKey: "hadContinueWatching") }
    @ViewBuilder var controls: some View {
        // One slot whose insides change, never two views swapped under the same id: as an if/else of a placeholder and a
        // shelf both given this id, the lazy stack kept the placeholder it had built, and Continue watching stayed four
        // grey boxes on every launch after the first (r26–r28: open and open portrait, where "hadContinueWatching" was
        // already set by the folded run; folded's own first launch never showed a placeholder, so it passed).
        if continuing != nil || waitingForContinue {
            VStack(alignment: .leading, spacing: 0) {
                if let continuing {
                    shelf(continuing)
                        .opacity(home.keptSince != nil ? 0.55 : 1)
                        // Said only from the real row on screen, so CI fails a pane still showing grey boxes, whatever the
                        // store holds (r28: the store had the rows, the screen didn't, and the check passed).
                        .task { _ = await TVBridge.data(TVBridge.url("/api/tv/applied?what=home&pane=\(part)"), timeout: 3) }
                } else {
                    PlaceholderShelf(cardWidth: leadWidth, cardHeight: MediaCard.height(leadWidth, .stremio), headed: true, title: Self.continueTitle)
                }
            }
            .id(Self.continueTitle)
        }
        // Films or shows and the genre are one key beside the page's name (WatchFilterKey), not three rows in the middle
        // of the shelves; searching is the Search tab's (2026-11-20).
        if store.query.isEmpty { RecentRow(kind: kind) }
        if store.rows.isEmpty {
            Group {
                if store.loading { VStack(alignment: .leading, spacing: 22) { ForEach(0..<3, id: \.self) { _ in PlaceholderShelf(headed: true) } } }
                else if store.failed { ContentUnavailableView("Can’t reach the TV", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again.")) }
                else { ContentUnavailableView.search }
            }
            .frame(maxWidth: .infinity)
        }
    }
    var body: some View {
        ScrollView {
            // Not lazy: every row is laid out before it can be reached, so the page's height never changes under a fling
            // to its end (2026-11-20: the last row arrived blank and the page crept after the bounce).
            VStack(alignment: .leading, spacing: 24) {
                if part != .right { controls }
                // The Mac can't be asked: the rows are the ones kept from last time, said so and dimmed.
                if part != .right, store.query.isEmpty, let since = store.keptSince ?? home.keptSince { KeptNote(since: since) }
                // Each kind's rows are their own, so switching crossfades the rows alone.
                ForEach(shown, id: \.title) { row in
                    shelf(row)
                    .opacity(store.keptSince != nil ? 0.55 : 1)
                    .id(kind + "/" + row.title)
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 12)
            .animation(.easeInOut(duration: 0.25), value: kind)
            // Typing in the search takes the chips and Recently flicked away and brings the found rows; Continue watching
            // fills in over its waiting shapes; the catalogue's rows arrive. Each a fade, where each was a cut: the lists
            // are set outside any animation (the 2026-11-10 motion pass).
            .animation(.easeOut(duration: 0.25), value: store.query.isEmpty)
            .settledAnimation(.easeOut(duration: 0.25), value: continuing == nil)
            .settledAnimation(.easeOut(duration: 0.25), value: shown.map(\.title))
        }
        // No row snapping here: aligning a row to the scroll view's top as the page first filled in pulled the content up
        // under the large title, which then opened folded on some launches and large on others (r26). Nor a scroll target
        // layout: with one, the page rested with its first row at the top, past the stack's 12 pt top padding, so "Watch"
        // sat 12 pt above every other tab's title, faded, and folded cut off at the screen's top (d7c64e6 tv-3, TV-3).
        .scrollDismissesKeyboard(.immediately)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if abs($0 - paneWidth) > 0.5 { paneWidth = $0 } }
        .settledAnimation(.easeOut(duration: 0.25), value: (store.keptSince ?? home.keptSince) != nil)
        .backToTop(posed: part != .left)
        // Stremio's home, asked for here as well as at launch, and asked again until it's in: open, the launch's own ask
        // could be lost in the relayout of unfolding, and Continue watching sat as grey boxes for good (r26). A failure
        // takes the waiting row away rather than leaving its boxes up.
        .task(id: home.rows.isEmpty) {
            // One pane asks; both share the answer.
            guard part != .right else { return }
            var tries = 0
            while home.rows.isEmpty && !Task.isCancelled && tries < 8 {
                await home.loadHome()
                if !home.rows.isEmpty { break }
                tries += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // Whether Stremio's home had a Continue watching, for keeping its room next time before it's in.
        .onChange(of: home.rows.isEmpty || !store.query.isEmpty ? nil : continuing != nil, initial: true) { _, v in
            if let v, part != .right { UserDefaults.standard.set(v, forKey: "hadContinueWatching") }
        }
        .refreshable { await store.load(force: true) }
        .task(id: kind) { await store.load() }
        .onChange(of: store.rows, initial: true) { _, _ in built = computeRows() }
        .onChange(of: home.rows) { _, _ in built = computeRows() }
        .onChange(of: store.query) { _, _ in built = computeRows() }
    }
}
// What was last flicked from this phone, newest first. One tap has it in the hand again, episode and best stream
// already chosen, ready to flick.
struct RecentRow: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var recent = RecentFlicks.shared
    // On Watch, only the kind the switch is on (Richard, 2026-11-07: "recently flicked should change based on if i choose
    // show or movie"). Nil elsewhere: everything.
    var kind: String? = nil
    var list: [RecentFlick] {
        guard let kind else { return recent.list }
        return recent.list.filter { ($0.item.stremioRef?.type ?? ($0.item.kind == "series" ? "series" : "movie")) == kind }
    }
    var body: some View {
        // Its own row only with four or more (2026-11-20: two posters in a row made for five).
        if list.count >= 4 {
            VStack(alignment: .leading, spacing: 0) {
                RowTitle("Recently flicked").padding(.leading, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(list) { f in FlickCardButton(item: f.item, source: .stremio, width: 124, ready: true) }
                    }
                    .padding(.horizontal, 20)
                }
                .rowEdge()
            }
            .id(kind ?? "all")
            .transition(.opacity)
        }
    }
}
// A row still on its way: a title bar and a few card shapes, breathing.
// The cards are as big as the row's real ones, so nothing moves when it comes.
struct PlaceholderShelf: View {
    var cardWidth: CGFloat = 124
    var cardHeight: CGFloat = MediaCard.height(124, .stremio)
    // Where the row's own heading will be: the height of its line, so the cards start where they will.
    var headed = false
    // The row's own name when it's known (Continue watching), drawn as the real heading draws it, so it doesn't change
    // as the row comes (gate 3: the skeleton, then a different page).
    var title: String? = nil
    @State private var breathe = false
    var body: some View {
        VStack(alignment: .leading, spacing: headed ? 8 : 10) {
            Group {
                if let title {
                    HStack(spacing: 5) {
                        Text(title).font(.title3.weight(.bold))
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    }
                } else {
                    Capsule().fill(.white.opacity(0.12)).frame(width: 150, height: 16)
                }
            }
                .frame(height: headed ? 25 : 16, alignment: .leading).padding(.leading, 20)
            // Each waiting card in the cover's own waiting look, the light running round it (ruling 9), never a flat grey slab (r20).
            HStack(spacing: 10) { ForEach(0..<4, id: \.self) { _ in CoverWait().frame(width: cardWidth, height: cardHeight).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay { LoadingRing(radius: 6) } } }
                .padding(.leading, 20)
        }
        // minWidth 0: four cards are wider than a folded column, and without it their width widened the whole page,
        // which then drew about 90 pt to the left and snapped back once the real row came (the Apps cold-entry jump).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
        // A plain repeating fade rather than a phase animator, which would lay this out at its natural size.
        .opacity(breathe ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathe)
        .onAppear { breathe = true }
        .accessibilityHidden(true)
    }
}

// Where a film or video is, ticking along while it plays. Stremio's can be slid along or tapped to jump there on the TV;
// anything else only shows, as a thin line with nothing to catch a finger.
struct VideoProgress: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var seeker = SeekQueue.shared
    let session: TVStatus.Session
    // False while the picture of the TV is the one kept from last time: then nothing ticks and nothing moves.
    var live = true
    // What the TV is doing, in the middle of the times, while it's still getting the film going.
    var note: String? = nil
    // Dimmed and out of reach until the film is really going; the note stays clear.
    var locked = false
    // Where the time sits with no length to draw a bar for: at the bar's start, on the Remote and on Playing alike, where
    // it stays when the length comes and the bar fades in under it (r35: a lone "1:23" floating mid-page under left-set
    // titles; review of dfd490e: centred on the Remote, left on Playing).
    var alone: HorizontalAlignment = .leading
    @State private var scrub: Double?
    // The spot asked for, shown until the TV is there. A newer one asked for meanwhile goes as soon as this lands.
    @State private var target: Double?
    @State private var seeking = false
    var duration: Double { session.duration ?? 0 }
    var scrubbable: Bool { session.pkg == "com.stremio.one" }
    var canSeek: Bool { scrubbable && session.canSeek == true && duration > 0 && live }
    // Where the TV is known to be: the player's own answer to a jump for a moment after it, else the status.
    func confirmed(at date: Date) -> Double {
        var now = seeker.held(for: session, at: date) ?? (session.position ?? 0)
        // While a ⏯ press is held, the clock goes by the press, not the TV's last word: paused, it stops where it was
        // pressed (r18: it kept counting 0:05 to 0:08 under a paused key); played, it runs from the press.
        let held = model.playHeld
        let running = held?.playing ?? session.playing
        if seeker.held(for: session, at: date) == nil, live, let at = session.sampledAt {
            // Frozen at the press: a reading taken after the press, the TV still playing on, is wound back to the press, or
            // the fresh readings the hold asks for carried the clock on under a paused key (r21: 0:04 to 0:07).
            if session.playing && held?.playing == false { now += held!.at.timeIntervalSince1970 * 1000 - at }
            else if running && session.playing { now += max(0, date.timeIntervalSince1970 * 1000 - at) }
            else if running, let h = held { now += max(0, date.timeIntervalSince(h.at) * 1000) }
        }
        // Playing, the clock never steps back for a reading a few seconds behind (a stalled report repeating its last spot
        // with a fresh time): it holds where it was. It never runs on past the TV, or a real stall (buffering) would run it
        // ahead and then jump it back (r20). A real jump back (a seek, a restart) is more than 6 s, or asked.
        let key = session.description.joined(separator: "\n")
        if running && live && seeker.held(for: session, at: date) == nil && target == nil && floor.key == key {
            if now < floor.pos && floor.pos - now < 6000 { now = floor.pos }
        }
        floor.key = key; floor.pos = now; floor.at = date
        return max(0, duration > 0 ? min(now, duration) : now)
    }
    // The last spot shown and when, for the no-stepping-back rule. A reference, so writing it from a frame redraws nothing.
    final class ClockFloor { var key = ""; var pos: Double = 0; var at = Date.distantPast }
    @State private var floor = ClockFloor()
    // Ahead of that by any jumps tapped that the TV hasn't confirmed yet.
    func position(at date: Date) -> Double {
        let now = confirmed(at: date) + seeker.offset(for: session)
        return max(0, duration > 0 ? min(now, duration) : now)
    }
    func clock(_ ms: Double) -> String {
        let t = Int(max(0, ms) / 1000)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    func seek(to ms: Double) {
        model.tick()
        target = ms
        guard !seeking else { return }
        seeking = true
        Task {
            var sent = ms
            var landed: Double?
            while true {
                do {
                    let d = try await TVBridge.post("player-seek-to", ["ms": Int(sent)], timeout: 60)
                    landed = ((try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["position"] as? NSNumber)?.doubleValue
                } catch {
                    Haptic.fire(.fail)
                    model.say("Couldn’t move there"); landed = nil; break
                }
                guard let t = target, t != sent else { break }
                sent = t
            }
            // Where the player says it landed, taken on as the asked-for spot is let go, so the bar doesn't step back.
            if let landed { seeker.adopt(landed, for: session) } else { await model.load() }
            withAnimation(.snappy) { target = nil; seeking = false }
            if landed != nil { Task { await model.load() } }
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = position(at: ctx.date), shown = scrub ?? target ?? now
            let known = live && session.position != nil
            let ahead = scrub == nil && target == nil && seeker.offset(for: session) != 0
            // No length yet (the real bridge has none for some episodes, or for the first 20 s): only where it's got to, in
            // the middle of the bar's place, never an empty track that looks like a bar and does nothing (r32). Nor before the
            // TV has said where it is (connecting): then the place is empty, not a grey bar claiming one (r33).
            let bar = (duration > 0 || seeking) && !model.staleStatus
            // One time label throughout: alone it sits in the middle, and when the length comes it moves to its place under
            // the bar's start as the bar fades in, rather than one fading out as another fades in, two "0:23"s at once (r33).
            VStack(spacing: 0) {
                Group {
                    if scrubbable {
                        ScrubBar(value: known && duration > 0 ? shown : nil, total: duration, enabled: canSeek, busy: seeking,
                                 confirmed: ahead && duration > 0 ? confirmed(at: ctx.date) : nil,
                                 scrub: $scrub, tickEvery: 10000, label: clock) { seek(to: $0) }
                            .opacity(locked ? 0.4 : 1).allowsHitTesting(!locked && bar)
                    } else {
                        // The same 28 pt band and the same 6 pt track either way, the track centred in it, and the times
                        // tucked up to 6 pt under the track itself rather than under the finger's room.
                        ProgressTrack(fraction: known && duration > 0 ? shown / duration : nil).frame(height: 28)
                    }
                }
                .opacity(bar ? 1 : 0)
                ZStack {
                    HStack {
                        Spacer()
                        if seeking { Text("Moving there on the TV…").foregroundStyle(TVLook.accent) }
                        else if let note { Text(note).foregroundStyle(TVLook.accent).contentTransition(.opacity) }
                        Spacer()
                        Text("-" + clock(duration - shown)).opacity(known && duration > 0 ? (locked ? 0.4 : 1) : 0)
                    }
                    Text(clock(shown))
                        .scaleEffect(bar ? 1 : 1.25, anchor: bar || alone == .leading ? .leading : .center)
                        .frame(maxWidth: .infinity, alignment: bar || alone == .leading ? .leading : .center)
                        // Alone, level with the middle of the bar's place.
                        .offset(y: bar ? 0 : -14)
                        .opacity(known ? (locked ? 0.4 : 1) : 0)
                }
                .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
                .padding(.top, -5)
            }
            .animation(.snappy(duration: 0.25), value: seeker.pending)
            .animation(.spring(response: 0.5, dampingFraction: 0.88), value: locked)
        }
        .settledAnimation(.spring(response: 0.45, dampingFraction: 0.9), value: duration > 0 && !model.staleStatus)
        // The build's shot of a drag along the bar, its bubble up ("-pose scrub"): held at 40 %, never let go.
        // Waits for the film's length (the real bridge's comes about 20 s in) rather than for the TV to allow seeking, which
        // the mock never said, so it was never shown (r18).
        .task(id: scrubbable && duration > 0) { if UserDefaults.standard.string(forKey: "pose") == "scrub", scrubbable, duration > 0, scrub == nil { try? await Task.sleep(nanoseconds: 1_500_000_000); scrub = duration * 0.4 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue(!live ? "" : duration > 0 ? "\(clock(position(at: Date()))) of \(clock(duration))" : clock(position(at: Date())))
        .accessibilityAdjustableAction { dir in
            guard canSeek else { return }
            seek(to: position(at: Date()) + (dir == .increment ? 30000 : -30000))
        }
    }
}

// Behind every page: what's on the TV, heavily blurred, washed with the colour of wherever you are. An app brings its own
// colour, a picked film or album brings its cover's, and with nothing picked the colour comes from what's playing.
struct Ambience: View {
    @Environment(TVModel.self) var model
    // One picture and colour for every page at once, so a page shows the current one the moment it appears, never
    // whatever it showed last time.
    @ObservedObject private var store = AmbienceStore.shared
    @State private var appeared = false
    @Environment(\.tabInFront) private var front
    var tint: Color { model.mood ?? store.band ?? Color(hex: 0x4A1A5C) }
    var body: some View {
        ZStack {
            Color.black
            if let small = store.image {
                Color.clear
                    .overlay { Image(tv: small).resizable().interpolation(.high).scaledToFill().opacity(0.55) }
                    .clipped()
                    // A new picture crossfades over the last, in place.
                    .id(store.key)
                    .transition(.opacity)
            }
            // Only the colour eases, and only the colour: an animation on the whole backdrop would grow it from a corner
            // as a page lays out.
            LinearGradient(colors: [tint.opacity(0.8), tint.opacity(0.45), .black.opacity(0.75)], startPoint: .topLeading, endPoint: .bottom)
                .animation(appeared ? .easeInOut(duration: 0.7) : nil, value: tint)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // Arriving on a page it's simply there, as it was: nothing eases in as the page appears.
        .transaction { if !appeared { $0.animation = nil } }
        .onAppear { Task { appeared = true } }
        .onDisappear { appeared = false }
        // A tab left is kept under the rail, not taken down: arriving back, it's simply there, as on a first appearance.
        .onChange(of: front) { _, f in if !f { appeared = false } else { Task { appeared = true } } }
    }
}
// The picture behind every page, held once for the whole app. It changes only when a new one is ready, never to
// nothing, so coming back to a tab shows exactly what's behind every other tab right now.
@MainActor
final class AmbienceStore: ObservableObject {
    static let shared = AmbienceStore()
    @Published private(set) var image: TVImage?
    @Published private(set) var band: Color?
    @Published private(set) var key: String?
    // The last few, so going back to something played lately needs no fetching.
    private var recent: [(art: String, image: TVImage, band: Color?)] = []
    private var wanted: String?
    // The last background, kept for the next launch, so the first frame is already the right colour rather than a
    // stand-in that changes a second later (r17: blue-grey, then brown).
    private static let keptFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ambience.png")
    init() {
        #if canImport(UIKit)
        if let d = try? Data(contentsOf: Self.keptFile), let i = UIImage(data: d) {
            image = i
            key = UserDefaults.standard.string(forKey: "ambienceArt")
            if let c = UserDefaults.standard.array(forKey: "ambienceBand") as? [Double], c.count == 3 { band = Color(red: c[0], green: c[1], blue: c[2]) }
        }
        #endif
    }
    private func keep(_ art: String, _ image: TVImage, _ band: Color?) {
        #if canImport(UIKit)
        UserDefaults.standard.set(art, forKey: "ambienceArt")
        if let band { let c = UIColor(band).cgColor.components ?? []; if c.count >= 3 { UserDefaults.standard.set(Array(c.prefix(3)).map(Double.init), forKey: "ambienceBand") } }
        let file = Self.keptFile
        Task.detached(priority: .utility) { if let d = image.pngData() { try? d.write(to: file, options: .atomic) } }
        #endif
    }
    func show(_ art: String?) async {
        guard let art, art != key else { return }
        wanted = art
        let hit = recent.firstIndex { $0.art == art }.map { recent.remove(at: $0) }
        var entry = hit
        if entry == nil {
            guard let u = URL(string: art), let i = await ImageStore.shared.load(u) else { return }
            let band = await ImageStore.shared.band(u)
            // Shrunk to a few pixels and stretched back: a heavy blur that costs nothing while scrolling. Made off the main
            // thread with the picture itself.
            let small = ImageStore.shared.small(u, 6) ?? i
            entry = (art, small, band)
        }
        guard let entry else { return }
        recent.insert(entry, at: 0)
        if recent.count > 8 { recent.removeLast() }
        // A newer one asked for meanwhile wins.
        guard wanted == art else { return }
        withAnimation(.easeInOut(duration: 0.7)) { image = entry.image; band = entry.band; key = art }
        keep(art, entry.image, entry.band)
    }
}

// Under a show's or stream's page laid over everything, each page steps out of sight and its bar goes, so nothing of it (a
// search pill, chips, a second back) shows beside it. Per page, pushed ones included, never the whole stack: dimming the
// stack took the tab rail with it (r20).
struct UnderFlick: ViewModifier {
    @Environment(TVModel.self) private var model
    // A page pushed over a tab that draws its own large heading: the system's bar stays, for its Back (the Duo's own,
    // 2026-11-08), but carries no title, so the heading isn't printed twice.
    var barHidden = false
    // The Remote's page: drawn, not hidden, while it's built unseen ahead of the first pick (remoteWarming), so its text and
    // pictures are drawn then rather than at the pick.
    var warms = false
    func body(content: Content) -> some View {
        // Not once a pick is on its way to the Remote (flickHandoff): the Remote's tab is up under the flick's page then,
        // and must be drawn there for the picture to land on, while the page's own rail stays beside it.
        let covered = ((model.flickChoosing && model.flickArrived && !model.flickHandoff) || model.flickCovering) && !(warms && model.remoteWarming)
        content
            // Held at its size and safe area while the edge swipe moves it (Shared/Duo.swift HoldsWhileMoving), so a page
            // swiped off, and the one coming back under it, slide whole instead of re-flowing their text as they go
            // (Richard, 2026-11-24: "the elements with text compress in a stupid manner").
            .holdsWhileMoving(warms ? "remote" : barHidden ? "pushed" : "tab")
            .opacity(covered ? 0 : 1)
            // Faded out under a flick's page, it takes no touches either: invisible, it still caught them (opacity alone
            // leaves a view hit-testable).
            .allowsHitTesting(!covered)
            // Black under the side bar too while covered: the strip beside a show's or stream's page showed whatever lay
            // under the faded page, a brown (28,16,10) against the page's near-black (8,5,4) edge, a band (r30).
            .overlay { Color.black.ignoresSafeArea().opacity(covered ? 1 : 0).allowsHitTesting(false) }
            // Covered as the flick's page fades up over it (flickArrived, set with the fade once the page is drawn), slowly
            // at first so the flick is mostly up before the page darkens; uncovered at once.
            .animation(covered ? .easeIn(duration: 0.22) : .easeOut(duration: 0.15), value: covered)
            .modifier(Untitled(on: barHidden))
            #if os(iOS)
            .toolbarVisibility(barHidden ? .visible : .automatic, for: .navigationBar)
            #endif
    }
}
// The black over a whole tab's stack, art included, while a flick's page covers it (the same rule as UnderFlick).
struct UnderFlickGround: ViewModifier {
    @Environment(TVModel.self) private var model
    var warms = false
    func body(content: Content) -> some View {
        let covered = ((model.flickChoosing && model.flickArrived && !model.flickHandoff) || model.flickCovering) && !(warms && model.remoteWarming)
        content
            .overlay { Color.black.ignoresSafeArea().opacity(covered ? 1 : 0).allowsHitTesting(false) }
            .animation(covered ? .easeIn(duration: 0.22) : .easeOut(duration: 0.15), value: covered)
    }
}
// No title drawn in the bar for a page that draws its own heading. The page's own name still reaches the system, for
// Back and the long press on Back (the history menu).
private struct Untitled: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.toolbar(removing: .title).navigationBarTitleDisplayMode(.inline) } else { content }
    }
}
extension View { func underFlick(barHidden: Bool = false, warms: Bool = false) -> some View { modifier(UnderFlick(barHidden: barHidden, warms: warms)) } }

// On each search or send box: while it has the keyboard, it's the one `typingIn` names, and the tab bar is away.
private struct HidesTabBarWhileTyping: ViewModifier {
    @Environment(TVModel.self) private var model
    let focused: Bool
    let id: String
    func body(content: Content) -> some View {
        content
            .onChange(of: focused, initial: true) { _, on in
                if on { if model.typingIn != id { withAnimation(.easeOut(duration: 0.25)) { model.typingIn = id } } }
                else if model.typingIn == id { withAnimation(.easeOut(duration: 0.25)) { model.typingIn = nil } }
            }
            .onDisappear { if model.typingIn == id { model.typingIn = nil } }
    }
}
extension View {
    func hidesTabBar(while focused: Bool, _ id: String) -> some View { modifier(HidesTabBarWhileTyping(focused: focused, id: id)) }
}

// Open in portrait the tabs are a bar along the foot, and the page ran on through its glass (r24: "Recently played"
// read through it). The page fades out over 18 pt above the bar and is clear behind it. The inset is measured on the
// page itself; read inside a view that ignores the safe area it was always 0, and the fade did nothing (the Chumby's).
// Only where the foot inset is a tab bar's, not just the home indicator's.
// Never the keyboard's inset: counted, it faded out everything above the keyboard, and the Remote's keys were cut to half
// circles while typing folded (d7c64e6 tv-type; Richard, 2026-11-07: "the keys cut to half circles"). Measured on a layer
// that ignores the keyboard, so only a tab bar's foot counts.
struct TabBarFade: ViewModifier {
    @State private var foot: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .background {
                Color.clear.ignoresSafeArea(.keyboard)
                    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { foot = $0 }
            }
            .mask {
                if foot > 40 {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                        Color.clear.frame(height: foot)
                    }
                    .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
    }
}
