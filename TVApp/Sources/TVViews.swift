import SwiftUI
#if os(iOS)
import AVKit
import MediaPlayer
#endif

@main
struct TVApp: App {
    @StateObject private var model = TVModel()
    @Environment(\.scenePhase) private var phase
    init() {
        #if os(iOS)
        // Long-form audio is what lets the AirPlay list move the whole phone's audio, not only this app's.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        #endif
        TVShortcuts.updateAppShortcutParameters()
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).preferredColorScheme(.dark).tint(TVLook.accent)
                .onChange(of: phase) { _, p in if p == .active { model.start() } else { model.stop() } }
                .onAppear { model.start() }
                .onOpenURL { if $0.host == "tab", let t = Int($0.lastPathComponent) { model.tab = t == 4 ? 1 : t } }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: TVModel
    var problem: String? {
        if !model.reachable { return "Can’t reach the Mac. Is Tailscale on?" }
        if model.status?.online == false { return "The Mac can’t reach the TV" }
        return nil
    }
    // The build's simulator shots ask for screens a launch alone can't reach.
    func poseForShots() {
        guard let pose = UserDefaults.standard.string(forKey: "pose") else { return }
        if pose == "search" { SendDraft.shared.text = "Heat"; return }
        if pose == "tour" || pose == "type" { return }
        // Three quick skips on a film near its end, caught before the TV has confirmed them.
        if pose == "skip" {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for _ in 0..<3 { SeekQueue.shared.add(1, for: model.status?.session, model: model) }
            }
            return
        }
        model.browsing = .stremio
        guard pose != "browse" else { return }
        Task {
            // The page is loading the same list, so wait for it rather than asking again.
            for _ in 0..<40 {
                if let item = BrowseStore.shared(.stremio).rows.flatMap(\.items).first(where: { $0.kind == (["streams", "flickdemo", "flickdemo-stream", "startover", "toremote"].contains(pose) ? "movie" : "series") }) {
                    // The stream flick goes as he does it most: the best stream found for him, in the hand, thrown.
                    model.flick(FlickTarget(item: item, source: .stremio, ready: pose == "flickdemo-stream")); return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    @State private var resets: [Int: Int] = [:]
    @State private var playingIcon: TVImage?
    var body: some View {
        PaneReader {
            TabView(selection: TabReset.binding($model.tab) { t in
                // Back to the tab's own start: anything opened on it closes, and its page goes back to the top. Nothing is
                // rebuilt, so what was loaded, and the choices made on it, stay.
                if t == 1 { model.browsing = nil; SendDraft.shared.text = "" }
                resets[t, default: 0] += 1
            }) {
                Tab(value: 0) { Page(title: "Remote", alwaysInline: true, retaps: resets[0, default: 0]) { RemoteTab() } } label: { tabLabel("Remote", "av.remote") }
                Tab(value: 1) { Page(title: "Apps", retaps: resets[1, default: 0]) { AppsTab() } } label: { tabLabel("Apps", "square.grid.2x2") }
                Tab(value: 2) { Page(title: "Playing", alwaysInline: true, retaps: resets[2, default: 0]) { PlayingTab() } } label: {
                    // The cover of what's on, so the button says what's playing before it's pressed.
                    if let i = playingIcon { Label { Text("Playing") } icon: { Image(tv: i) } }
                    else { tabLabel("Playing", model.otherAirPlay ? "airplayaudio" : "play.circle") }
                }
                Tab(value: 3) { Page(title: "Watch", retaps: resets[3, default: 0]) { FilmsTab() } } label: { tabLabel("Watch", "film") }
                Tab(value: 5) { Page(title: "Status", retaps: resets[5, default: 0]) { DeviceTab() } } label: { tabLabel("Status", "gauge.with.dots.needle.33percent") }
                // Last, so it sits at the foot of the side bar, as in the other apps.
                Tab(value: 9) { TVSettingsTab(retaps: resets[9, default: 0]) } label: { tabLabel("Settings", "gearshape") }
            }
            .onChange(of: model.tab) { _, t in
                UserDefaults.standard.set(t, forKey: "tab")
                // Opening Playing shows what's on now, not what was on at the last look.
                if t == 2 { Task { await model.load() } }
            }
            // Over everything, side bar included, and edge to edge. Not a presented screen: the system slides those up
            // from the bottom, a blurred panel with a hard top edge. The flick fades its own way in and out.
            .overlay {
                if let target = model.flicking {
                    FlickScreen(target: target).environmentObject(model).id(target.id)
                }
            }
        }
        // Waits for the cover before changing the icon, and changes it again when the cover arrives, so the button
        // shows the cover for as long as it's playing, not only when it happened to be ready at the last redraw.
        // The old cover stays until the new one is ready, never the plain symbol in between, and through a flick it
        // only goes if something else is really playing.
        .task(id: model.nowArt) {
            guard let art = model.nowArt, let u = URL(string: art) else { if model.flicking == nil { playingIcon = nil }; return }
            if let i = ImageStore.shared.cached(u) { playingIcon = PlayingIcon.make(i); return }
            if let i = await ImageStore.shared.load(u), !Task.isCancelled { playingIcon = PlayingIcon.make(i) }
        }
        .onChange(of: model.flicking == nil) { _, closed in if closed && model.nowArt == nil { playingIcon = nil } }
        // The one picture behind every page follows what's on.
        .task(id: model.nowArt) {
            await AmbienceStore.shared.show(model.nowArt)
            // A film's colour kept after its flick gives way once something else is what's on.
            if model.moodArt != nil, !(model.videoIsCurrent && model.status?.session?.pkg == "com.stremio.one") {
                model.moodArt = nil; model.mood = nil
            }
        }
        .overlay(alignment: .top) {
            if let problem {
                Label(problem, systemImage: "wifi.exclamationmark").font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.red.opacity(0.85), in: Capsule()).padding(.top, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 11)
                    .glassEffect(.regular, in: Capsule()).padding(.bottom, 24).transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(TVLook.press, value: model.toast)
        .onAppear { followRequest(); poseForShots(); TabTour.run([0, 1, 2, 3, 5, 9]) { model.tab = $0 } }
        .onReceive(NotificationCenter.default.publisher(for: FlickRequest.airPlay)) { _ in followRequest() }
    }
    // Control Center and Siri can ask before this view exists, so the request waits in a flag.
    func followRequest() {
        if FlickRequest.wantsRemote { FlickRequest.wantsRemote = false; model.tab = 0 }
        if FlickRequest.wantsAirPlay { model.tab = 2 }
    }
}

// The top of every page. The system's soft edge drew a frosted block behind the clock over scrolled rows, so it's off,
// and each scroll view fades its own top instead: the same fade edge to edge, side bar and panes alike.
private struct TopShade: ViewModifier {
    func body(content: Content) -> some View { content.scrollEdgeEffectHidden(true, for: .top) }
}
// The fade itself, from the very top of the display, so it reaches under the side bar and the clock too.
private struct TopFade: ViewModifier {
    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
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
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    let title: String
    var alwaysInline = false
    // Taps on this tab's button while it's already showing.
    var retaps = 0
    @ViewBuilder let content: () -> C
    @State private var path = NavigationPath()
    @State private var top = 0
    var body: some View {
        // The art and the edge setting sit on the stack, not the page, so the page's scroll view stays the stack's root
        // and the large title can track it and fold away. The fade itself is on each scroll view (backToTop).
        NavigationStack(path: $path) {
            content()
                .environment(\.backToTop, top)
                .navigationDestination(for: RowRoute.self) { $0.page }
                .containerBackground(.clear, for: .navigation)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(alwaysInline || panes ? .inline : .large)
        }
        .topShade()
        .background { Ambience() }
        // A list opened from the tab closes first; once on the tab's own page, it goes to the top.
        .onChange(of: retaps) { _, _ in if path.isEmpty { top += 1 } else { path = NavigationPath() } }
    }
}

// The TV's own settings and this app's connection, as a tab at the foot of the side bar.
struct TVSettingsTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    var retaps = 0
    @State private var path: [ManagePage] = []
    @StateObject private var store = ManageStore()
    var manage: some View { TVManageSections() }
    // The launcher's own two jobs, then how the app reaches the TV, which is set once and lives on its own page.
    @ViewBuilder var connection: some View {
        Section {
            SettingsAction(title: "Refresh the TV’s recommendations", icon: "arrow.clockwise") { model.post("refresh") }
            SettingsAction(title: "Launcher settings on the TV", icon: "rectangle.grid.1x2") { model.post("launcher-settings") }
        }
        Section {
            NavigationLink(value: ManagePage.connection) { Label("Connection", systemImage: "network") }
        }
    }
    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                Group {
                    // Unfolded, one list each side of the fold rather than one list across it.
                    if panes {
                        FoldSplit { Form { manage }.scrollContentBackground(.hidden) } right: { Form { connection }.scrollContentBackground(.hidden).poseScroll() }
                    } else {
                        Form { manage; connection }.scrollContentBackground(.hidden).poseScroll()
                    }
                }
                .topShade().topFade()
                // Tapping the tab again: out of a page opened from here, else back to the top.
                .onChange(of: retaps) { _, _ in
                    if path.isEmpty { withAnimation(.snappy) { proxy.scrollTo(ManagePage.apps, anchor: .top) } } else { path = [] }
                }
            }
            .navigationDestination(for: ManagePage.self) { page in
                switch page {
                case .apps: ManageAppsView(store: store)
                case .settings: ManageSettingsView(store: store)
                case .connection: ConnectionView()
                }
            }
            .background { Ambience() }
            .navigationTitle("Settings")
            // The same title as every other tab: large on the outer screen, in the bar when unfolded.
            .navigationBarTitleDisplayMode(panes ? .inline : .large)
        }
    }
}

// Where the Mac is, and what it takes to reach it from away.
struct ConnectionView: View {
    @EnvironmentObject var model: TVModel
    @State private var address = ""
    var body: some View {
        Form {
            Section {
                TextField("Address", text: $address).autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit { model.address = address.trimmingCharacters(in: .whitespacesAndNewlines); model.start() }
            } header: { Text("Mac Pro address") } footer: { Text("Everything here works anywhere with Tailscale on, as long as the Mac is awake and can reach the TV.") }
        }
        .scrollContentBackground(.hidden)
        .topShade().topFade()
        .background { Ambience() }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { address = model.address }
    }
}

// Type or paste anything: a link opens in the right app, words become a search right here.
struct SendBar: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject private var draft = SendDraft.shared
    @FocusState private var focused: Bool
    static func isLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.contains("://") || t.lowercased().hasPrefix("www.") || (!t.contains(" ") && t.contains(".") && t.contains("/"))
    }
    var link: Bool { Self.isLink(draft.text) }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: link ? "paperplane" : "magnifyingglass").foregroundStyle(.secondary).padding(.leading, 14)
                .contentTransition(.symbolEffect(.replace))
            TextField("Search, or send a link", text: $draft.text)
                .focused($focused).autocorrectionDisabled().submitLabel(link ? .send : .search)
                // Words are already being searched as they're typed, so Return only puts the keyboard away.
                .onSubmit { if link { submit() } else { focused = false } }
            if draft.text.isEmpty {
                Button {
                    #if canImport(UIKit)
                    // A copied link goes to the TV; copied words are searched here, like typed ones.
                    if let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                        if Self.isLink(s) { model.send(s) } else { draft.text = s }
                    } else { focused = true }
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
    }
    func submit() { if link { model.send(draft.text); draft.text = "" } }
}

struct RowTitle: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View { Text(title).font(.title3.weight(.bold)).padding(.bottom, 8) }
}

// A row's heading: tap it to see everything in that row as one scrolling list.
struct RowHeader: View {
    let title: String
    let route: RowRoute
    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 5) {
                Text(title).font(.title3.weight(.bold))
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See all of \(title)")
    }
}
// The same frame for every full list: the art behind it and the rows on top.
struct RowList<Content: View>: View {
    @EnvironmentObject var model: TVModel
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        List { content().listRowBackground(Color.clear) }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .topShade().topFade()
            .background { Ambience() }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Remote
struct MirrorView: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject var store: MirrorStore
    // Where it always has its place, it carries its own way to hide it, and the bar has no second one.
    var closable = false
    // A playing film is black on any capture of the screen, so its poster stands in, sat on a blurred copy of itself.
    // So does one just flicked, until the TV says it's playing.
    var film: URL? {
        guard model.mirrorLive else { return nil }
        if model.filmOnScreen, let s = model.status?.session { return model.picture(for: s).flatMap(URL.init(string:)) }
        return model.standInNow.flatMap(URL.init(string:))
    }
    // The picture drawn, which only moves on to a new one once it's loaded, then fades in over what was there: the
    // flicked poster gives way to the TV's own without a frame of empty glass between. Unset until first drawn.
    @State private var drawn: URL??
    var body: some View {
        let film = drawn ?? self.film
        ZStack {
            Color.black.opacity(0.35)
            if let film {
                ZStack {
                    Color.clear.overlay { Art(url: film) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
                        .clipped().blur(radius: 24).opacity(0.7)
                    Art(url: film) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                        .padding(14)
                }
                .id(film)
                .transition(.opacity)
            } else if model.mirrorLive {
                #if os(iOS)
                ScreenPicture(live: model.live, store: store, art: model.nowArt)
                #else
                if let m = store.image { Image(tv: m).resizable().scaledToFit() }
                #endif
            } else {
                // Turned off: what's playing, blurred, behind the one button, rather than an empty box.
                ZStack {
                    Color.clear.overlay { Art(url: model.nowArt.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
                        .clipped().blur(radius: 26).opacity(0.55)
                    Button { model.setMirror(true) } label: {
                        Label("Show the TV’s screen", systemImage: "eye").font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 11)
                    }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
                }
            }
        }
        .aspectRatio(16.0 / 9, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if closable, model.mirrorLive {
                Button { model.setMirror(false) } label: { Image(systemName: "eye.slash").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40).contentShape(Circle()) }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).padding(10).accessibilityLabel("Hide the TV’s screen")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TVLook.card, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: film)
        .task(id: self.film) {
            let next = self.film
            guard let current = drawn else { drawn = .some(next); return }
            guard next != current else { return }
            if let next, ImageStore.shared.cached(next) == nil { _ = await ImageStore.shared.load(next) }
            if !Task.isCancelled { drawn = .some(next) }
        }
        // Where it is, for a flick's screen to move onto it. Nothing moves this view, so the measure moves nothing.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.mirrorSlot = $0 }
        .onAppear { model.mirrorShown(true) }
        .onDisappear { model.mirrorShown(false) }
    }
}
#if os(iOS)
// The TV's screen itself: the live stream once it has a picture, and until then (or without one) the latest still,
// shown dimmed with a small spinner once it's more than a few seconds old, so an old picture never passes for now.
private struct ScreenPicture: View {
    @ObservedObject var live: LiveMirror
    @ObservedObject var store: MirrorStore
    let art: String?
    var body: some View {
        ZStack {
            if !live.showing {
                if let m = store.image {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let old = ctx.date.timeIntervalSince(store.at) > 4
                        Image(tv: m).resizable().scaledToFit().opacity(old ? 0.5 : 1)
                            .overlay { if old { ProgressView().tint(.white).transition(.opacity) } }
                            .animation(.easeOut(duration: 0.3), value: old)
                    }
                } else {
                    // Nothing yet: what's playing, blurred, with a spinner, rather than an empty box.
                    Color.clear.overlay { Art(url: art.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
                        .clipped().blur(radius: 26).opacity(0.5)
                        .overlay { ProgressView().tint(.white) }
                }
            }
            LiveMirrorLayer(mirror: live).opacity(live.showing ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: live.showing)
    }
}
#endif

// One arrow or the centre of the D-pad: a press acts at once, holding repeats until you lift.
// Set on pages that scroll. There a key waits to see it's a real press, or starting a scroll on one would press it on the TV.
private struct KeysInScrollKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var keysInScroll: Bool { get { self[KeysInScrollKey.self] } set { self[KeysInScrollKey.self] = newValue } } }
private struct PadKey<Face: View>: View {
    @EnvironmentObject var model: TVModel
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
        .glassEffect(.regular.interactive(), in: Circle())
    }
}
struct PlayKey: View {
    @EnvironmentObject var model: TVModel
    var playing: Bool?
    var tint: Color = TVLook.accent
    var size: CGFloat = 68
    var glow = true
    // For a player on this phone rather than the TV.
    var action: (() -> Void)?
    var body: some View {
        Button { if let action { model.tick(); action() } else { model.key("play") } } label: {
            Image(systemName: playing == nil ? "playpause.fill" : playing == true ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size).background(tint, in: Circle())
                .shadow(color: tint.opacity(glow ? 0.45 : 0), radius: 14, y: 4)
                .animation(.easeOut(duration: 0.2), value: glow)
        }
        .buttonStyle(PressCard()).accessibilityLabel(playing == true ? "Pause" : playing == false ? "Play" : "Play or pause")
    }
}

struct RemoteTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.horizontalSizeClass) private var size
    @Environment(\.paneLayout) private var panes
    @ObservedObject private var nextUp = NextUp.shared
    // The build's shot of the typing bar opens with it up.
    @State private var typing = UserDefaults.standard.string(forKey: "pose") == "type"
    // Arriving from a flick's controls, the pad and keys come in during the screen's move onto the picture above them.
    @State private var keysIn = true
    var state: String {
        guard !model.staleStatus, let s = model.status, s.online else { return "Connecting…" }
        if s.screen == "asleep" { return "Asleep. Press anything to wake it." }
        if s.screen == "screensaver" { return "Screensaver" }
        // What's playing, by name, rather than the app it's playing in. Only while it's what's on, never one left behind.
        if model.videoIsCurrent, let title = s.session?.description.first, !title.isEmpty { return title }
        // Nothing with a name on: nothing said, rather than which app is in front.
        return ""
    }
    var keys: some View {
        VStack(spacing: 12) {
            // Power joins the top row like a real remote's, rather than sitting alone under everything.
            HStack {
                GlassKey(icon: "power", label: "Sleep or wake", key: model.status?.screen == "asleep" ? "wake" : "sleep"); Spacer()
                GlassKey(icon: "chevron.left", label: "Back", key: "back"); Spacer()
                GlassKey(icon: "house.fill", label: "Home", key: "home"); Spacer()
                // Lit while the typing bar is up, and closes it again.
                Button { model.tick(); withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { typing.toggle() } } label: {
                    Image(systemName: "keyboard").font(.system(size: 19, weight: .medium)).foregroundStyle(typing ? AnyShapeStyle(TVLook.accent) : AnyShapeStyle(.primary))
                        .frame(width: 54, height: 54).contentShape(Circle())
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel(typing ? "Stop typing" : "Type on TV")
                Spacer()
                GlassKey(icon: "line.3.horizontal", label: "Menu", key: "menu")
            }
            transport
            // No volume here: the TV refuses volume over HDMI, so only its own remote can change it.
        }
    }
    // Stremio's player ignores the media keys, so with it open the jumps go through its seek bar, there's no going back a
    // track, and next is the next episode when there is one. Every key keeps its place, so nothing shifts as it changes.
    @ViewBuilder var transport: some View {
        let stremio = model.status?.session?.pkg == "com.stremio.one"
        HStack {
            if stremio { Color.clear.frame(width: 50, height: 50) } else { GlassKey(icon: "backward.end.fill", label: "Previous", key: "previous", size: 50) }
            Spacer()
            if stremio { SeekButton(icon: "gobackward.10", label: "Back 10 seconds", step: -1, size: 50) } else { GlassKey(icon: "gobackward.10", label: "Rewind", key: "rewind", size: 50) }
            Spacer()
            // Says which it'll do, as on the Playing tab, once the TV's word is fresh.
            // No glow while typing: it would smear through the keyboard just above.
            PlayKey(playing: model.staleStatus ? nil : model.status?.session?.playing, glow: !typing)
            Spacer()
            if stremio { SeekButton(icon: "goforward.10", label: "Forward 10 seconds", step: 1, size: 50) } else { GlassKey(icon: "goforward.10", label: "Fast forward", key: "forward", size: 50) }
            Spacer()
            if !stremio { GlassKey(icon: "forward.end.fill", label: "Next", key: "next", size: 50) }
            else if let next = nextUp.next {
                GlassButton(icon: "forward.end.fill", label: "Next episode, \(next.subtitle)", size: 50) {
                    model.flick(FlickTarget(item: next, source: .stremio, ready: true, autoplay: true))
                }
            } else { Color.clear.frame(width: 50, height: 50) }
        }
    }
    var keysBlock: some View {
        VStack(spacing: 12) {
            // Above the keys, and up for as long as it's wanted, so typing and moving between boxes go together.
            if typing { TypeBar(open: $typing).transition(.move(edge: .bottom).combined(with: .opacity)) }
            keys
        }
    }
    func side(apps: Bool) -> some View {
        VStack(spacing: 14) {
            MirrorView(store: model.mirrorStore, closable: true)
            if let m = model.nowMusic { MiniPlayer(music: m) }
            if apps, model.status?.apps?.isEmpty == false { QuickApps() }
            Spacer(minLength: 0)
            SendBar()
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
    }
    var body: some View {
        Group {
            if size == .regular {
                FoldSplit {
                    // The apps come along when there's room, and step aside when held in portrait.
                    side(apps: panes)
                        // While typing on the TV the keyboard is for the other pane, so this one keeps its size under it
                        // rather than squeezing the screen and cutting its labels. Its own search box still lifts.
                        .ignoresSafeArea(typing ? .keyboard : [], edges: .bottom)
                } right: {
                    VStack(spacing: 14) { DPad().frame(maxHeight: .infinity); keysBlock }.padding(.horizontal, 20).padding(.bottom, 16)
                        .modifier(KeysArrive(shown: keysIn))
                }
            } else {
                // Folded, the pad gets the room until the screen is asked for.
                VStack(spacing: 14) {
                    // Steps aside while typing, so the keyboard, the pad and the title each have their own room.
                    if model.mirrorLive && !typing { MirrorView(store: model.mirrorStore).transition(.opacity) }
                    Group {
                        DPad().frame(minHeight: 150, maxHeight: .infinity)
                        keysBlock
                    }
                    .modifier(KeysArrive(shown: keysIn))
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .navigationSubtitle(state)
        .toolbar {
            // Folded, the screen goes above the pad unless he's hidden it, so the bar has the switch. Wider, it has its
            // own place and button.
            if size != .regular {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.setMirror(!model.mirrorLive) } label: { Label(model.mirrorLive ? "Hide the TV’s screen" : "Show the TV’s screen", systemImage: model.mirrorLive ? "eye.slash" : "eye") }
                }
            }
        }
        // Started as the tab comes up, so the first live picture is there by the time it's looked at. It stays on, as
        // he left it, for the next visit.
        .onAppear { model.warmMirror() }
        .task(id: model.remoteArrival) {
            guard Date().timeIntervalSince(model.remoteArrival) < 1 else { return }
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { keysIn = false }
            // Partway through the screen's move, as the flick's backdrop thins, rather than after it.
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { keysIn = true }
        }
    }
}

// The Remote's keys coming in: a slight grow out of a blur on the move's own spring, and a fade so short the pad's white
// centre never sits grey on the way. Nothing in the keys is measured, so the scale moves nothing that's read.
private struct KeysArrive: ViewModifier {
    let shown: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .animation(.linear(duration: 0.08), value: shown)
            .blur(radius: shown ? 0 : 6)
            .scaleEffect(shown ? 1 : 0.96)
    }
}

// Typing into whatever box is focused on the TV. Each change sends only what's different: new letters as text, and as
// many deletes as letters went. Return is the TV's Enter, and starts afresh for the next box.
struct TypeBar: View {
    @EnvironmentObject var model: TVModel
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
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Delete on TV")
            Button { sync(); withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { open = false } } label: {
                Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 4).accessibilityLabel("Stop typing")
        }
        .frame(height: 50)
        .glassEffect(.regular, in: Capsule())
        .onAppear { focused = true }
        .onDisappear { sync() }
    }
}
struct QuickApps: View {
    @EnvironmentObject var model: TVModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: TVLook.gap) {
                ForEach(AppsTab.watching(model.status?.apps ?? []).prefix(8)) { Banner(app: $0) }
            }.scrollTargetLayout()
        }
        .frame(height: TVLook.bannerSize.height)
    }
}
struct MiniPlayer: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject private var phone = PhonePlayer.shared
    let music: TVStatus.Music
    // AirPlayed from this phone, the phone's own player says what it is and takes the press, ahead of the TV.
    var song: PhonePlayer.Song? { phone.drives ? phone.song : nil }
    var body: some View {
        HStack(spacing: 12) {
            Button { model.tab = 2 } label: {
                HStack(spacing: 12) {
                    Cover(url: URL(string: music.art), image: song == nil ? nil : phone.art, key: song.map { "phone \($0.id)" }, mode: .fill) { Color.white.opacity(0.1) }
                        .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song?.title ?? music.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(song?.artist ?? music.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Now playing: \(song?.title ?? music.title)")
            if song != nil { PlayKey(playing: phone.playing, size: 44) { phone.toggle() } }
            else { PlayKey(playing: model.staleStatus ? nil : music.playing, size: 44) }
        }
        .padding(10).tvCard()
    }
}

// MARK: - Apps
struct Banner: View {
    @EnvironmentObject var model: TVModel
    let app: TVStatus.App
    var browses = false
    var current: Bool { model.status?.app == app.pkg }
    func open() { model.tick(); model.post("open", ["pkg": app.pkg]) }
    var body: some View {
        Button {
            // An app with something to choose from opens that here; the rest go straight to the TV.
            if browses, let s = MediaSource.of(pkg: app.pkg) { model.tick(); model.browsing = s }
            else if browses, app.pkg == "com.mint.letterboxd" { model.tick(); model.tab = 3 }
            else { open() }
        } label: {
            ZStack {
                // Some banners are a white logo on nothing, meant for a dark tile, like YouTube Music's.
                app.wide == true ? Color.black : TVLook.bannerTile
                if app.hasIcon, let u = model.url("/api/tv/icon?pkg=\(app.pkg)&v=2") {
                    Art(url: u) { i in
                        // A banner that came out blank, a white logo flattened onto white, is never shown as it is.
                        if ImageStore.shared.isFlat(u) { BannerFallback(app: app) }
                        else if app.wide == true { i.resizable().scaledToFill() }
                        else {
                            VStack(spacing: 4) { i.resizable().scaledToFit().frame(width: 30, height: 30); Text(app.name).font(.caption.weight(.medium)).lineLimit(1).padding(.horizontal, 8) }
                        }
                    } placeholder: { TVLook.bannerTile }
                } else { BannerFallback(app: app) }
            }
            .frame(width: TVLook.bannerSize.width, height: TVLook.bannerSize.height)
            .clipShape(RoundedRectangle(cornerRadius: TVLook.banner, style: .continuous))
            .overlay {
                if current { RoundedRectangle(cornerRadius: TVLook.banner, style: .continuous).strokeBorder(TVLook.accent, lineWidth: 2.5) }
            }
        }
        .buttonStyle(PressCard()).accessibilityLabel(app.name).accessibilityAddTraits(current ? .isSelected : [])
        .contextMenu { if browses { Button("Open on TV", systemImage: "tv") { open() } } }
    }
}
// A banner drawn here, for an app whose own is missing or came out blank: its brand's colour, its mark where it has a
// simple one, and its name in the launcher's weight. Never a white card, never an icon in a grey box.
struct BannerFallback: View {
    let app: TVStatus.App
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
                } else if app.hasIcon, let u = TVBridge.url("/api/tv/icon?pkg=\(app.pkg)&v=2") {
                    // Its own icon beside its name, when it has one with something in it.
                    Art(url: u) { i in
                        if !ImageStore.shared.isFlat(u) { i.resizable().scaledToFit().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous)) }
                    } placeholder: { EmptyView() }
                }
                Text(app.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
        }
        .accessibilityHidden(true)
    }
}
struct BannerRow: View {
    let title: String, apps: [TVStatus.App]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowTitle(title).padding(.leading, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: TVLook.gap) { ForEach(apps) { Banner(app: $0, browses: true) } }.padding(.horizontal, 20).scrollTargetLayout()
            }
            .rowEdge()
        }
    }
}
struct AppsTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    @ObservedObject private var draft = SendDraft.shared
    // Words typed into the bar search Stremio and Mint as you type. A link is only ever sent.
    var query: String? {
        let t = draft.text.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && !SendBar.isLink(t) ? t : nil
    }
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
    @ViewBuilder func row(_ title: String, _ apps: [TVStatus.App]) -> some View {
        if !apps.isEmpty { BannerRow(title: title, apps: apps) }
    }
    // Before the first answer, the shape of the page instead of a blank one.
    var waiting: some View {
        HStack(spacing: TVLook.gap) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: TVLook.banner, style: .continuous).fill(.white.opacity(0.08)).frame(width: TVLook.bannerSize.width, height: TVLook.bannerSize.height)
            }
        }
        .padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading).clipped()
    }
    var body: some View {
        content.navigationDestination(item: $model.browsing) { AppBrowse(source: $0) }
    }
    @ViewBuilder var content: some View {
        if all.isEmpty {
            ScrollView { VStack(alignment: .leading, spacing: 24) { SendBar().padding(.horizontal, 20); waiting }.padding(.vertical, 12) }.backToTop()
        } else if panes {
            FoldSplit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        SendBar().padding(.horizontal, 20)
                        if let query { EverywhereSearch(text: query) } else {
                            row("Watch", watch)
                            row("Listen", listen)
                            row("Tools and settings", tools)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .backToTop(posed: false)
            } right: {
                // Unfolded, the other side picks up where you left off, ready to flick.
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Shelf(source: .stremio, title: "Continue watching")
                        Shelf(source: .mint, title: "Recently played")
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 12)
                }
                .restsOnRows()
                .backToTop()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    SendBar().padding(.horizontal, 20)
                    if let query { EverywhereSearch(text: query) } else {
                        row("Watch", watch)
                        Shelf(source: .stremio, title: "Continue watching")
                        row("Listen", listen)
                        Shelf(source: .mint, title: "Recently played")
                        row("Tools and settings", tools)
                    }
                }
                .padding(.vertical, 12)
                .animation(.snappy, value: query == nil)
            }
            .backToTop()
        }
    }
}

// Ten seconds back or on in Stremio. Taps add up while the TV catches up: the button in the direction it's going shows
// how far, in seconds, until the TV's own report has it.
struct SeekButton: View {
    @EnvironmentObject var model: TVModel
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
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel(label)
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

// One row from an app's own page, on the Apps tab: where you left off in Stremio, what you last played in Mint.
struct Shelf: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject var store: BrowseStore
    let title: String
    init(source: MediaSource, title: String) { store = .shared(source); self.title = title }
    var row: MediaRow? { store.query.isEmpty ? store.rows.first { $0.title == title } : nil }
    var body: some View {
        // Always something on screen, even before the row has come, or nothing would ever ask for it.
        VStack(alignment: .leading, spacing: 0) {
            if let row, !row.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    RowHeader(title: title, route: .media(row, store.source)).padding(.leading, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 10) {
                            ForEach(row.items) { item in FlickCardButton(item: item, source: store.source, width: store.source == .mint ? 128 : 112) }
                        }
                        .padding(.horizontal, 20)
                    }
                    .rowEdge()
                }
            } else if store.rows.isEmpty && !store.failed && store.query.isEmpty {
                // Its place is kept while it comes, so the rows under it don't get pushed down when it does.
                let w: CGFloat = store.source == .mint ? 128 : 112
                PlaceholderShelf(cardWidth: w, cardHeight: MediaCard.height(w, store.source), headed: true)
            } else { Color.clear.frame(height: 0) }
        }
        .task { await store.load() }
    }
}

// MARK: - Playing
#if os(iOS)
struct RoutePicker: UIViewRepresentable {
    private static weak var current: AVRoutePickerView?
    // iOS has no call for this, so press the picker's own button. If that ever stops working, the button is still there.
    static func open() -> Bool {
        func button(in v: UIView) -> UIButton? {
            if let b = v as? UIButton { return b }
            for s in v.subviews { if let b = button(in: s) { return b } }
            return nil
        }
        guard let current, let b = button(in: current) else { return false }
        b.sendActions(for: .touchUpInside)
        return true
    }
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView(); Self.current = v; v.clipsToBounds = true; v.tintColor = .white; v.activeTintColor = UIColor(TVLook.accent); v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
#endif

// Flick up to send the phone to the TV. Apple Music goes straight to Mint, from anywhere.
// Anything else opens the AirPlay list, since iOS lets only the owner of the phone choose a route.
struct FlickCard: View {
    @EnvironmentObject var model: TVModel
    // Away from home there's nothing to AirPlay to, so AirPlay isn't offered. Sending a song by name still is.
    @ObservedObject private var reach = AirPlayReach.shared
    @State private var title = ""
    @State private var artist = ""
    @State private var art: Image?
    @State private var showPicker = false
    func refresh() {
        #if os(iOS)
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            if MPMediaLibrary.authorizationStatus() == .notDetermined { MPMediaLibrary.requestAuthorization { _ in Task { @MainActor in refresh() } } }
            return
        }
        // A paused song is left over from earlier; whatever is really playing belongs to another app, so AirPlay it.
        let player = MPMusicPlayerController.systemMusicPlayer
        let item = player.playbackState == .playing ? player.nowPlayingItem : nil
        title = item?.title ?? ""; artist = item?.artist ?? ""
        if let i = item?.artwork?.image(at: CGSize(width: 500, height: 500)) { art = Image(uiImage: i) } else { art = nil }
        #endif
    }
    #if os(iOS)
    // Sent here by the Action Button or Siri, with nothing in Apple Music to send.
    func openAirPlayIfAsked() {
        // Only once this card is really on screen, so the request isn't used up by a hidden tab.
        guard FlickRequest.wantsAirPlay, model.tab == 2 else { return }
        FlickRequest.wantsAirPlay = false
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard await AirPlayReach.shared.check() else { model.say("AirPlay can’t see the TV from here. It needs home Wi-Fi."); return }
            // Mint comes to the front, ready to receive, while the list opens.
            model.post("music-now")
            if !RoutePicker.open() { showPicker = true }
        }
    }
    #endif
    func flick() {
        model.tick()
        #if os(iOS)
        refresh()
        if !title.isEmpty {
            // The phone only stops once the TV has it, so a failed send never silences the music.
            model.flick(FlickTarget(
                item: MediaItem(title: title, subtitle: artist, art: "", id: "", kind: "song"), source: .mint, image: art,
                send: ("flick", ["title": title, "artist": artist]),
                sent: { MPMusicPlayerController.systemMusicPlayer.pause() }))
        } else if reach.inReach {
            // Mint comes to the front first, ready to receive.
            model.post("music-now")
            if RoutePicker.open() { model.say("Choose Mint Music") } else { showPicker = true }
        }
        #endif
    }
    // Nothing to offer when this phone is already AirPlaying to the TV, the TV is already playing the same song, or the
    // phone isn't playing anything at all.
    var alreadyThere: Bool {
        if model.status?.airplay?.active == true { return true }
        guard !title.isEmpty, let m = model.status?.music else { return false }
        return m.title.caseInsensitiveCompare(title) == .orderedSame
    }
    var body: some View {
        Group {
            if alreadyThere || title.isEmpty {
                // Nothing to offer, but the AirPlay picker stays in reach for the Action Button and Siri.
                #if os(iOS)
                // Clipped to its point: unclipped, the picker draws its whole glyph, a faint AirPlay ring on the page.
                RoutePicker().frame(width: 1, height: 1).clipped().opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
                #else
                Color.clear.frame(height: 0)
                #endif
            } else { card }
        }
        .onAppear {
            refresh()
            reach.begin()
            #if os(iOS)
            MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications()
            openAirPlayIfAsked()
            #endif
        }
        .onDisappear { reach.end() }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: FlickRequest.airPlay)) { _ in openAirPlayIfAsked() }
        .onChange(of: model.tab) { _, _ in openAirPlayIfAsked() }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
        .alert("AirPlay to the TV", isPresented: $showPicker) { Button("OK", role: .cancel) {} } message: { Text("Tap the AirPlay button on this card and choose Mint Music. AirPlay only reaches the TV on home Wi-Fi.") }
        #endif
        .animation(.snappy, value: alreadyThere)
        .animation(.snappy, value: reach.inReach)
    }
    var card: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.white.opacity(0.08)
                if let art { art.resizable().scaledToFill() } else { Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary) }
            }
            .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? "On this iPhone" : title).font(.body.weight(.semibold)).lineLimit(1)
                Text(title.isEmpty ? "Tap to AirPlay" : "Tap to send to the TV").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            // The same thing as a flick, for when a flick isn't handy.
            Button(action: flick) { Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(TVLook.accent).accessibilityLabel("Send to the TV")
            #if os(iOS)
            if reach.inReach { RoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay").transition(.opacity) }
            #endif
        }
        .padding(12)
        .tvCard()
        .contentShape(Rectangle())
        .onTapGesture(perform: flick)
    }
}
struct NowControls: View {
    @EnvironmentObject var model: TVModel
    let music: TVStatus.Music
    static func clock(_ ms: Double) -> String { let t = Int(max(ms, 0) / 1000); return String(format: "%d:%02d", t / 60, t % 60) }
    var body: some View {
        VStack(spacing: 14) {
            // The bar keeps its place before there's anything true to show on it.
            if music.duration > 0 && !model.staleStatus { MusicProgress(music: music) } else { ProgressPlaceholder() }
            HStack(spacing: 26) {
                GlassKey(icon: "backward.fill", label: "Previous", key: "previous", size: 54)
                PlayKey(playing: model.staleStatus ? nil : music.playing, size: 74)
                GlassKey(icon: "forward.fill", label: "Next", key: "next", size: 54)
            }
        }
    }
}
// The song this phone is AirPlaying to the TV, driven through the phone's own player: it answers at once, and can be
// moved, which Mint's report of it can't.
struct PhoneControls: View {
    @ObservedObject private var phone = PhonePlayer.shared
    @State private var scrub: Double?
    let song: PhonePlayer.Song
    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let now = min(max(scrub ?? phone.position, 0), song.duration)
                VStack(spacing: 6) {
                    ScrubBar(value: now, total: song.duration, scrub: $scrub, tickEvery: 10) { phone.seek(to: $0) }
                    HStack {
                        Text(NowControls.clock(now * 1000))
                        Spacer()
                        Text("-" + NowControls.clock((song.duration - now) * 1000))
                    }
                    .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Position")
                .accessibilityValue("\(NowControls.clock(now * 1000)) of \(NowControls.clock(song.duration * 1000))")
                .accessibilityAdjustableAction { dir in phone.seek(to: max(0, min(song.duration, now + (dir == .increment ? 15 : -15)))) }
            }
            HStack(spacing: 26) {
                GlassButton(icon: "backward.fill", label: "Previous", size: 54) { phone.previous() }
                PlayKey(playing: phone.playing, size: 74) { phone.toggle() }
                GlassButton(icon: "forward.fill", label: "Next", size: 54) { phone.next() }
            }
        }
    }
}
// Where a song is, drawn as a film's is, so the two read as one thing. Mint can't be moved from here, so it only shows.
struct MusicProgress: View {
    let music: TVStatus.Music
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let raw = music.playing ? music.position + ctx.date.timeIntervalSince1970 * 1000 - music.sampledAt : music.position
            let now = min(max(raw, 0), max(music.duration, 0))
            VStack(spacing: 6) {
                ProgressTrack(fraction: music.duration > 0 ? now / music.duration : 0).frame(height: 28)
                HStack {
                    Text(NowControls.clock(now))
                    Spacer()
                    Text("-" + NowControls.clock(music.duration - now))
                }
                .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue("\(NowControls.clock(music.position)) of \(NowControls.clock(music.duration))")
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
struct PlayingTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    @ObservedObject private var phone = PhonePlayer.shared
    @ObservedObject private var nextUp = NextUp.shared
    @State private var query = ""
    @State private var kind = "song"
    // What Mint finds as he types, the same search as the Apps page's.
    @StateObject private var found = BrowseStore(.mint)
    // A play asked for and not yet showing on the TV.
    @State private var pending = false
    @State private var pendingWait: Task<Void, Never>?
    // Never Mint's last song while the phone plays something else of its own.
    var music: TVStatus.Music? { model.nowMusic }
    var otherAppIsActive: Bool { model.videoIsCurrent }
    // Kept from the last time the app was open, until the TV says what's on now: shown, but not as live.
    var stale: Bool { model.staleStatus }
    var now: some View {
        VStack(spacing: 14) {
            // Sound from the phone that isn't music: not Mint's, whatever Mint last played.
            if model.otherAirPlay, let a = model.status?.airplay {
                Image(systemName: a.handoff == "youtube" ? "play.rectangle.fill" : "iphone").font(.system(size: 54, weight: .light)).foregroundStyle(TVLook.accent).padding(.top, 24)
                Text(a.title?.isEmpty == false ? a.title! : "From this iPhone").font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                Text(a.handoff == "youtube" ? "Opened in YouTube on the TV" : a.title?.isEmpty == false ? "Playing from this iPhone" : "AirPlay").font(.subheadline).foregroundStyle(.secondary)
            } else if phone.drives, let song = phone.song, !otherAppIsActive {
                cover(Cover(url: nil, image: phone.art, key: "phone \(song.id)") { Color.white.opacity(0.08) })
                titles(song.title, [song.artist, song.album])
                PhoneControls(song: song)
                showOnTV
            } else if let m = music, !otherAppIsActive {
                cover(Cover(url: URL(string: m.art)) { Color.white.opacity(0.08) }.opacity(stale ? 0.45 : 1))
                titles(m.title, [m.artist, m.album])
                NowControls(music: m)
                showOnTV
            } else if let s = model.status?.session {
                let appName = model.status?.apps?.first { $0.pkg == s.pkg }?.name ?? s.pkg
                let stremio = s.pkg == "com.stremio.one"
                // Said to be playing but already at the end: an old report, so shown as stopped there, not ticking on.
                let ended = Self.atEnd(s)
                let playing = stale ? nil : ended ? false : Optional(s.playing)
                // What was flicked, or the app's own banner when the app says nothing about what it's playing. Rounded
                // at the picture's own corners, whatever its shape.
                Cover(url: model.picture(for: s).flatMap(URL.init(string:)), radius: 14) {
                    Image(systemName: "play.tv.fill").font(.system(size: 54, weight: .light)).foregroundStyle(TVLook.accent)
                }
                .frame(maxWidth: 300, maxHeight: 190)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                .opacity(stale ? 0.45 : 1)
                .padding(.top, 20)
                // The series, then the episode under it. Paused only when it is: the play key already says playing, and
                // which app is doing it is plumbing.
                VStack(spacing: 3) {
                    Text(s.description.first ?? appName).font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                    if s.description.count > 1 { Text(Wording.episode(s.description[1])).font(.headline).foregroundStyle(.white.opacity(0.85)).lineLimit(2).multilineTextAlignment(.center) }
                    Text("Paused").font(.subheadline).foregroundStyle(.secondary).opacity(playing == false ? 1 : 0).animation(.easeOut(duration: 0.2), value: playing)
                }
                // Stremio's runs and can be moved, so its place is kept even before the running time is in.
                if s.position != nil || stremio { VideoProgress(session: s, live: !stale).padding(.horizontal, 4) }
                HStack(spacing: 18) {
                    if stremio {
                        // Its player ignores the skip keys, so the bridge moves its seek bar instead.
                        SeekButton(icon: "gobackward.10", label: "Back 10 seconds", step: -1)
                        PlayKey(playing: playing, size: 74)
                        SeekButton(icon: "goforward.10", label: "Forward 10 seconds", step: 1)
                    } else {
                        GlassKey(icon: "gobackward.10", label: "Back 10 seconds", key: "rewind", size: 56)
                        PlayKey(playing: playing, size: 74)
                        GlassKey(icon: "goforward.10", label: "Forward 10 seconds", key: "forward", size: 56)
                    }
                }
                .padding(.top, 6)
                HStack(spacing: 18) {
                    // Back closes Stremio's player and it keeps his place; anything else gets the stop key.
                    GlassButton(icon: "stop.fill", label: "Stop", size: 50) {
                        model.key(stremio ? "back" : "stop")
                        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); await model.load() }
                    }
                    if stremio, let next = nextUp.next {
                        GlassButton(icon: "forward.end.fill", label: "Next episode, \(next.subtitle)", size: 50) {
                            model.flick(FlickTarget(item: next, source: .stremio, ready: true, autoplay: true))
                        }
                    }
                    // Stremio's own menus can't be driven from here without risking a restart, so only other apps get these keys.
                    if !stremio {
                        GlassKey(icon: "captions.bubble", label: "Subtitles", key: "captions", size: 50)
                        GlassKey(icon: "waveform", label: "Audio track", key: "audiotrack", size: 50)
                    }
                }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note", description: Text("Search below, or flick something from this iPhone."))
            }
        }
        .frame(maxWidth: .infinity)
    }
    static func atEnd(_ s: TVStatus.Session) -> Bool {
        guard s.playing, let p = s.position, let d = s.duration, d > 0 else { return false }
        let ran = s.sampledAt.map { max(0, Date().timeIntervalSince1970 * 1000 - $0) } ?? 0
        return p + ran >= d
    }
    func cover(_ c: some View) -> some View {
        c.aspectRatio(1, contentMode: .fit).frame(maxWidth: panes ? 300 : 180)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).shadow(color: .black.opacity(0.45), radius: 22, y: 12)
    }
    func titles(_ title: String, _ more: [String]) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
            Text(more.filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: title)
    }
    // Only when Mint isn't already the app on the TV's screen.
    @ViewBuilder var showOnTV: some View {
        if model.status?.app != "com.codex.musicwebtv" {
            Button { model.tick(); model.post("music-now") } label: { Label("Show on TV", systemImage: "tv") }.font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
    }
    var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    // Shuffle only means something for these; a song or an album plays as it is.
    var shuffles: Bool { ["artist", "playlist", "station"].contains(kind) }
    // Songs and albums come back from the search; the kind picked leads.
    var results: [MediaRow] {
        guard ["song", "album"].contains(kind), trimmed.count >= 2 else { return [] }
        return (kind == "song" ? ["Songs", "Albums"] : ["Albums", "Songs"]).compactMap { t in found.rows.first { $0.title == t } }
    }
    func play(shuffle: Bool = false) {
        guard !trimmed.isEmpty else { return }
        let before = model.nowMusic?.title
        model.post("music", ["query": trimmed, "kind": kind, "shuffle": shuffle])
        // The field shows it's on its way until the TV's song changes, or long enough that it isn't coming.
        pending = true
        pendingWait?.cancel()
        pendingWait = Task {
            for _ in 0..<7 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                await model.load()
                if model.nowMusic?.title != before { query = ""; break }
            }
            withAnimation(.easeOut(duration: 0.2)) { pending = false }
        }
    }
    var send: some View {
        VStack(alignment: .leading, spacing: 18) {
            FlickCard()
            VStack(alignment: .leading, spacing: 10) {
                RowTitle("Play on TV").padding(.bottom, -4)
                Picker("Kind", selection: $kind) {
                    ForEach([("Song", "song"), ("Album", "album"), ("Playlist", "playlist"), ("Artist", "artist"), ("Station", "station")], id: \.1) { Text($0.0).tag($0.1) }
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("What should play?", text: $query).autocorrectionDisabled().submitLabel(.go).onSubmit { play() }
                        if pending { ProgressView().controlSize(.small).transition(.opacity) }
                    }
                    .padding(.horizontal, 16).frame(height: 50).glassEffect(.regular, in: Capsule())
                    if shuffles {
                        Button { play(shuffle: true) } label: { Image(systemName: "shuffle").font(.system(size: 18, weight: .medium)).frame(width: 50, height: 50).contentShape(Circle()) }
                            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).disabled(trimmed.isEmpty).opacity(trimmed.isEmpty ? 0.45 : 1).accessibilityLabel("Shuffle")
                            .transition(.opacity)
                    }
                }
                .animation(.snappy, value: shuffles)
                .animation(.easeOut(duration: 0.2), value: pending)
            }
            ForEach(results) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.title).font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 10) {
                            ForEach(row.items) { item in FlickCardButton(item: item, source: .mint, width: 112) }
                        }
                        .scrollTargetLayout()
                    }
                    .rowEdge()
                }
                .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: results.map(\.id))
        .onChange(of: query) { _, _ in
            if pending { pendingWait?.cancel(); pending = false }
            guard trimmed.count >= 2 else { return }
            found.query = trimmed; found.searchSoon()
        }
        // The TV's song changing is the answer to a play.
        .onChange(of: model.nowMusic?.title) { _, _ in
            if pending { pendingWait?.cancel(); withAnimation(.easeOut(duration: 0.2)) { pending = false }; query = "" }
        }
    }
    // With a film, show or video on, what's under it is what comes after it: the next episode, ready to flick, or failing
    // that where he is in other things, and what was flicked lately. Never a row of one, and never the music search,
    // which is only for when Mint is what's on or nothing is.
    @ObservedObject private var stremio = BrowseStore.shared(.stremio)
    var continuing: [MediaItem] { Array((stremio.rows.first { $0.title == "Continue watching" }?.items ?? []).prefix(5)) }
    var watching: Bool { otherAppIsActive && model.status?.session != nil }
    var upNext: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Only ever shows when the phone itself is playing a song, and keeps AirPlay in reach for Siri.
            FlickCard().padding(.horizontal, 20)
            if model.status?.session?.pkg == "com.stremio.one", let n = nextUp.next {
                VStack(alignment: .leading, spacing: 0) {
                    RowTitle("Up next")
                    FlickCardButton(item: n, source: .stremio, width: 168, ready: true)
                }
                .padding(.horizontal, 20)
            } else if continuing.count > 1 {
                VStack(alignment: .leading, spacing: 0) {
                    RowTitle("Continue watching").padding(.leading, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 10) { ForEach(continuing) { FlickCardButton(item: $0, source: .stremio, width: 124) } }
                            .padding(.horizontal, 20)
                    }
                    .rowEdge()
                }
            }
            RecentRow()
        }
        .padding(.vertical, panes ? 20 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        Group {
            if panes {
                FoldSplit { ScrollView { now.padding(20) }.backToTop() } right: {
                    ScrollView { if watching { upNext } else { send.padding(20) } }.backToTop()
                }
            } else {
                // The rows under a film run to the screen's edges, as rows do everywhere else.
                ScrollView {
                    VStack(spacing: 24) {
                        now.padding(.horizontal, 16)
                        if watching { upNext } else { send.padding(.horizontal, 16) }
                    }
                    .padding(.bottom, 16)
                }
                .backToTop()
            }
        }
        .environment(\.keysInScroll, true)
        // Where he is in Stremio, for what's under a show while it's on.
        .task { await stremio.load() }
    }
}

// MARK: - Films
struct FilmCard: View {
    @EnvironmentObject var model: TVModel
    let film: Film
    var body: some View {
        Button { model.tick(); model.flick(FlickTarget(item: film.media, source: .stremio)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Art(url: URL(string: film.poster)) { i in i.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                    .frame(width: 118, height: 177).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(film.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    if !film.note.isEmpty { Text(film.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(width: 118, alignment: .leading)
            }
        }.buttonStyle(PressCard()).accessibilityLabel(film.title)
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
    @EnvironmentObject var model: TVModel
    let title: String, films: [Film]
    var body: some View {
        RowList(title: title) {
            ForEach(films) { film in
                Button { model.tick(); model.flick(FlickTarget(item: film.media, source: .stremio)) } label: {
                    HStack(spacing: 12) {
                        Art(url: URL(string: film.poster)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                            .frame(width: 50, height: 75).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                }
                .buttonStyle(.plain)
                .accessibilityLabel(film.title)
            }
        }
    }
}
// Films and shows to pick from: what's on the TV's own Stremio home, Letterboxd's picks and friends, and Stremio's
// catalogue, popular, top rated, new, by genre and by search. Every card flicks like anywhere else.
struct FilmsTab: View {
    @EnvironmentObject var model: TVModel
    // Films or shows, kept through unfolding, which rebuilds the layout. The lists themselves live for the app's life.
    @SceneStorage("watchKind") private var kind = "movie"
    var films: BrowseStore { .discover("movie") }
    var shows: BrowseStore { .discover("series") }
    static let genres = ["Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama", "Family", "Fantasy", "History", "Horror", "Mystery", "Romance", "Sci-Fi", "Thriller", "War", "Western"]
    @Environment(\.paneLayout) private var panes
    var body: some View {
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
struct DiscoverColumn: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject var store: BrowseStore
    @Binding var kind: String
    var part = BrowseColumn.Part.all
    // Both lists, so where he is stays put above the switch while the other kind's rows are still coming.
    @ObservedObject private var films = BrowseStore.discover("movie")
    @ObservedObject private var shows = BrowseStore.discover("series")
    static let continueTitle = "Continue watching"
    // Films and shows together, so it sits above the switch and belongs to neither.
    var continuing: MediaRow? {
        guard store.query.isEmpty else { return nil }
        let other = store === films ? shows : films
        return [store, other].lazy.compactMap { $0.rows.first { $0.title == Self.continueTitle && !$0.items.isEmpty } }.first
    }
    var rows: [MediaRow] { store.rows.filter { $0.title != Self.continueTitle } }
    var shown: [MediaRow] {
        part == .all ? rows : rows.enumerated().filter { ($0.offset % 2 == 0) == (part == .left) }.map(\.element)
    }
    func shelf(_ row: MediaRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RowHeader(title: row.title, route: .media(row, .stremio)).padding(.leading, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(row.items) { item in FlickCardButton(item: item, source: .stremio, width: 124) }
                }
                .padding(.horizontal, 20)
            }
            .rowEdge()
        }
    }
    @ViewBuilder var controls: some View {
        if let continuing { shelf(continuing).id(Self.continueTitle) }
        Picker("Kind", selection: $kind) { Text("Films").tag("movie"); Text("Shows").tag("series") }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(kind == "movie" ? "Search films" : "Search shows", text: $store.query).autocorrectionDisabled().submitLabel(.search)
                .onChange(of: store.query) { _, _ in store.searchSoon() }
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16).frame(height: 46)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 20)
        if store.query.isEmpty {
            // Inset inside the row, so the chips scroll on to the screen's edge rather than stopping short of it.
            Chips(options: [("", "All")] + FilmsTab.genres.map { ($0, $0) }, selected: Binding(get: { store.genre }, set: { g in
                store.genre = g
                Task { await store.load(force: true) }
            }), inset: 20)
            .rowEdge()
        }
        if store.query.isEmpty { RecentRow() }
        if store.rows.isEmpty {
            Group {
                if store.loading { ForEach(0..<3, id: \.self) { _ in PlaceholderShelf() } }
                else if store.failed { ContentUnavailableView("Can’t reach the TV", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again.")) }
                else { ContentUnavailableView.search }
            }
            .frame(maxWidth: .infinity)
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if part != .right { controls }
                // Each kind's rows are their own, so switching crossfades the rows alone.
                ForEach(shown, id: \.title) { row in
                    shelf(row)
                    .id(kind + "/" + row.title)
                    .transition(.opacity)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 12)
            .animation(.easeInOut(duration: 0.25), value: kind)
        }
        .restsOnRows()
        .backToTop(posed: part != .left)
        .refreshable { await store.load(force: true) }
        .task(id: kind) { await store.load() }
    }
}
// What was last flicked from this phone, newest first. One tap has it in the hand again, episode and best stream
// already chosen, ready to flick.
struct RecentRow: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject private var recent = RecentFlicks.shared
    var body: some View {
        // Never a row of one.
        if recent.list.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                RowTitle("Recently flicked").padding(.leading, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(recent.list) { f in FlickCardButton(item: f.item, source: .stremio, width: 124, ready: true) }
                    }
                    .padding(.horizontal, 20)
                }
                .rowEdge()
            }
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
    @State private var breathe = false
    var body: some View {
        VStack(alignment: .leading, spacing: headed ? 8 : 10) {
            Capsule().fill(.white.opacity(0.12)).frame(width: 150, height: 16)
                .frame(height: headed ? 25 : 16, alignment: .leading).padding(.leading, 20)
            HStack(spacing: 10) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08)).frame(width: cardWidth, height: cardHeight) } }
                .padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading).clipped()
        // A plain repeating fade rather than a phase animator, which would lay this out at its natural size.
        .opacity(breathe ? 1 : 0.5)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true } }
        .accessibilityHidden(true)
    }
}

// Where a film or video is, ticking along while it plays. Stremio's can be slid along or tapped to jump there on the TV;
// anything else only shows, as a thin line with nothing to catch a finger.
struct VideoProgress: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject private var seeker = SeekQueue.shared
    let session: TVStatus.Session
    // False while the picture of the TV is the one kept from last time: then nothing ticks and nothing moves.
    var live = true
    // What the TV is doing, in the middle of the times, while it's still getting the film going.
    var note: String? = nil
    // Dimmed and out of reach until the film is really going; the note stays clear.
    var locked = false
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
        if seeker.held(for: session, at: date) == nil, live, session.playing, let at = session.sampledAt { now += max(0, date.timeIntervalSince1970 * 1000 - at) }
        return max(0, duration > 0 ? min(now, duration) : now)
    }
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
                    #if canImport(UIKit)
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    #endif
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
            VStack(spacing: 6) {
                if scrubbable {
                    ScrubBar(value: known && duration > 0 ? shown : nil, total: duration, enabled: canSeek, busy: seeking,
                             confirmed: ahead && duration > 0 ? confirmed(at: ctx.date) : nil,
                             scrub: $scrub, tickEvery: 10000) { seek(to: $0) }
                        .opacity(locked ? 0.4 : 1).allowsHitTesting(!locked)
                } else {
                    ProgressTrack(fraction: known && duration > 0 ? shown / duration : nil, thick: 3).frame(height: 3)
                }
                HStack {
                    Text(clock(shown)).opacity(known ? (locked ? 0.4 : 1) : 0)
                    Spacer()
                    if seeking { Text("Moving there on the TV…").foregroundStyle(TVLook.accent) }
                    else if let note { Text(note).foregroundStyle(TVLook.accent).contentTransition(.opacity) }
                    Spacer()
                    Text("-" + clock(duration - shown)).opacity(known && duration > 0 ? (locked ? 0.4 : 1) : 0)
                }
                .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            }
            .animation(.snappy(duration: 0.25), value: seeker.pending)
            .animation(.spring(response: 0.5, dampingFraction: 0.88), value: locked)
        }
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
    @EnvironmentObject var model: TVModel
    // One picture and colour for every page at once, so a page shows the current one the moment it appears, never
    // whatever it showed last time.
    @ObservedObject private var store = AmbienceStore.shared
    @State private var appeared = false
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
    func show(_ art: String?) async {
        guard let art, art != key else { return }
        wanted = art
        let hit = recent.firstIndex { $0.art == art }.map { recent.remove(at: $0) }
        var entry = hit
        if entry == nil {
            guard let u = URL(string: art), let i = await ImageStore.shared.load(u) else { return }
            let band = await ImageStore.shared.band(u)
            // Shrunk to a few pixels and stretched back: a heavy blur that costs nothing while scrolling.
            #if canImport(UIKit)
            let small = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 6)).image { _ in i.draw(in: CGRect(x: 0, y: 0, width: 6, height: 6)) }
            #else
            let small = i
            #endif
            entry = (art, small, band)
        }
        guard let entry else { return }
        recent.insert(entry, at: 0)
        if recent.count > 8 { recent.removeLast() }
        // A newer one asked for meanwhile wins.
        guard wanted == art else { return }
        withAnimation(.easeInOut(duration: 0.7)) { image = entry.image; band = entry.band; key = art }
    }
}

// The Playing tab's icon: the cover of what's on, as a small rounded picture. The root asks for it once the cover
// has loaded, and keeps it while that cover is what's on.
enum PlayingIcon {
    @MainActor static func make(_ i: TVImage) -> TVImage? {
        #if canImport(UIKit)
        let side: CGFloat = 26
        let f = UIGraphicsImageRendererFormat(); f.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { _ in
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 6).addClip()
            let k = max(side / i.size.width, side / i.size.height)
            i.draw(in: CGRect(x: (side - i.size.width * k) / 2, y: (side - i.size.height * k) / 2, width: i.size.width * k, height: i.size.height * k))
        }.withRenderingMode(.alwaysOriginal)
        #else
        return nil
        #endif
    }
}
