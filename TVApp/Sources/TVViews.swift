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
        model.browsing = .stremio
        guard pose != "browse" else { return }
        Task {
            // The page is loading the same list, so wait for it rather than asking again.
            for _ in 0..<40 {
                if let item = BrowseStore.shared(.stremio).rows.flatMap(\.items).first(where: { $0.kind == "series" }) { model.flick(FlickTarget(item: item, source: .stremio)); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    var body: some View {
        PaneReader {
            TabView(selection: $model.tab) {
                Tab(value: 0) { Page(title: "Remote", alwaysInline: true) { RemoteTab() } } label: { tabLabel("Remote", "av.remote") }
                Tab(value: 1) { Page(title: "Apps") { AppsTab() } } label: { tabLabel("Apps", "square.grid.2x2") }
                Tab(value: 2) { Page(title: "Playing", alwaysInline: true) { PlayingTab() } } label: { tabLabel("Playing", "play.circle") }
                Tab(value: 3) { Page(title: "Films") { FilmsTab() } } label: { tabLabel("Films", "film") }
                Tab(value: 5) { Page(title: "Status") { DeviceTab() } } label: { tabLabel("Status", "gauge.with.dots.needle.33percent") }
            }
            .onChange(of: model.tab) { _, t in UserDefaults.standard.set(t, forKey: "tab") }
        }
        .fullScreenCover(item: $model.flicking) { FlickScreen(target: $0).environmentObject(model) }
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
        .onAppear { followRequest(); poseForShots() }
        .onReceive(NotificationCenter.default.publisher(for: FlickRequest.airPlay)) { _ in followRequest() }
    }
    // Control Center and Siri can ask before this view exists, so the request waits in a flag.
    func followRequest() {
        if FlickRequest.wantsRemote { FlickRequest.wantsRemote = false; model.tab = 0 }
        if FlickRequest.wantsAirPlay { model.tab = 2 }
    }
}

// Each tab's frame: the art behind it, its title, and the gear.
struct Page<C: View>: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    @State private var settings = false
    let title: String
    var alwaysInline = false
    @ViewBuilder let content: () -> C
    var body: some View {
        NavigationStack {
            content()
                .background { Wall(art: model.status?.music?.art) }
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(alwaysInline || panes ? .inline : .large)
                .toolbar { ToolbarItem(placement: .primaryAction) { Button { settings = true } label: { Label("Connection", systemImage: "gearshape") } } }
                .sheet(isPresented: $settings) { ConnectionView().environmentObject(model) }
        }
    }
}

struct ConnectionView: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    var body: some View {
        NavigationStack {
            Form {
                TVManageSections()
                Section {
                    TextField("Address", text: $address).autocorrectionDisabled()
                } header: { Text("Mac Pro address") } footer: { Text("The TV is reached through your Mac, so this works anywhere with Tailscale on.") }
                Section {
                    Button("Refresh the TV’s recommendations") { model.post("refresh", say: "Refreshing") }
                    Button("Open launcher settings on the TV") { model.post("launcher-settings", say: "Opening") }
                }
            }
            .navigationTitle("TV")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.address = address; model.start(); dismiss() } } }
            .onAppear { address = model.address }
        }
    }
}

// Type or paste anything: a link opens in the right app, words become a search.
struct SendBar: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject private var draft = SendDraft.shared
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane").foregroundStyle(.secondary).padding(.leading, 14)
            TextField("Send a link or search", text: $draft.text)
                .focused($focused).autocorrectionDisabled().submitLabel(.send)
                .onSubmit { submit() }
            if draft.text.isEmpty {
                Button {
                    #if canImport(UIKit)
                    if let s = UIPasteboard.general.string, !s.isEmpty { model.send(s) } else { focused = true }
                    #endif
                } label: { Image(systemName: "doc.on.clipboard").frame(width: 44, height: 44) }
                .buttonStyle(.plain).foregroundStyle(TVLook.accent).accessibilityLabel("Send what you copied to the TV")
            } else {
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(TVLook.accent).accessibilityLabel("Send to the TV")
            }
        }
        .frame(height: 50)
        .glassEffect(.regular, in: Capsule())
    }
    func submit() { if !draft.text.isEmpty { model.send(draft.text); draft.text = "" } }
}

struct RowTitle: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View { Text(title).font(.title3.weight(.bold)).padding(.bottom, 8) }
}

// A row's heading: tap it to see everything in that row as one scrolling list.
struct RowHeader<Destination: View>: View {
    let title: String
    @ViewBuilder let destination: () -> Destination
    var body: some View {
        NavigationLink { destination() } label: {
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
            .background { Wall(art: model.status?.music?.art) }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Remote
struct MirrorView: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject var store: MirrorStore
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            if let m = store.image, model.mirrorLive {
                Image(tv: m).resizable().scaledToFit()
            } else if !model.mirrorLive {
                Button { model.setMirror(true) } label: {
                    Label("Show the TV’s screen", systemImage: "eye").font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 11)
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
            } else {
                ProgressView()
            }
        }
        .aspectRatio(16.0 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: TVLook.card, style: .continuous))
    }
}

// One arrow or the centre of the D-pad: a press acts at once, holding repeats until you lift.
private struct PadKey<Face: View>: View {
    @EnvironmentObject var model: TVModel
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
        face(touching)
            .contentShape(Rectangle())
            // Resets by itself if the system takes the touch away, so a key can't get stuck.
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in begin() }
                .onEnded { _ in end(tapped: true) })
            .onChange(of: touching) { _, now in if !now { end(tapped: false) } }
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
    var body: some View {
        Button { model.key("play") } label: {
            Image(systemName: playing == nil ? "playpause.fill" : playing == true ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                .frame(width: size, height: size).background(tint, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(playing == true ? "Pause" : playing == false ? "Play" : "Play or pause")
    }
}
struct VolumeBar: View {
    @EnvironmentObject var model: TVModel
    func segment(_ icon: String, _ key: String, _ label: String) -> some View {
        Button { model.key(key) } label: { Image(systemName: icon).font(.system(size: 18, weight: .medium)).frame(maxWidth: .infinity, minHeight: 50).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
    var body: some View {
        HStack(spacing: 0) {
            segment("speaker.minus.fill", "voldown", "Volume down")
            Divider().frame(height: 24)
            segment("speaker.slash.fill", "mute", "Mute")
            Divider().frame(height: 24)
            segment("speaker.plus.fill", "volup", "Volume up")
        }
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

struct RemoteTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.horizontalSizeClass) private var size
    @Environment(\.paneLayout) private var panes
    @State private var typing = false
    @State private var text = ""
    var state: String {
        guard let s = model.status, s.online else { return "Connecting…" }
        return s.screen == "asleep" ? "Asleep. Press anything to wake it." : s.screen == "screensaver" ? "Screensaver" : "On " + (s.apps?.first { $0.pkg == s.app }?.name ?? "Home")
    }
    var keys: some View {
        VStack(spacing: 12) {
            HStack {
                GlassKey(icon: "chevron.left", label: "Back", key: "back"); Spacer()
                GlassKey(icon: "house.fill", label: "Home", key: "home"); Spacer()
                Button { typing = true } label: { Image(systemName: "keyboard").font(.system(size: 19, weight: .medium)).frame(width: 54, height: 54).contentShape(Circle()) }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Type on TV")
                Spacer()
                GlassKey(icon: "line.3.horizontal", label: "Menu", key: "menu")
            }
            HStack {
                GlassKey(icon: "backward.end.fill", label: "Previous", key: "previous", size: 50); Spacer()
                GlassKey(icon: "gobackward.10", label: "Rewind", key: "rewind", size: 50); Spacer()
                PlayKey(); Spacer()
                GlassKey(icon: "goforward.10", label: "Fast forward", key: "forward", size: 50); Spacer()
                GlassKey(icon: "forward.end.fill", label: "Next", key: "next", size: 50)
            }
            HStack(spacing: 12) {
                VolumeBar()
                GlassKey(icon: "power", label: "Sleep or wake", key: model.status?.screen == "asleep" ? "wake" : "sleep", size: 50)
            }
        }
    }
    func side(apps: Bool) -> some View {
        VStack(spacing: 14) {
            MirrorView(store: model.mirrorStore)
            if let m = model.status?.music { MiniPlayer(music: m) }
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
                } right: {
                    VStack(spacing: 14) { DPad().frame(maxHeight: .infinity); keys }.padding(.horizontal, 20).padding(.bottom, 16)
                }
            } else {
                // Folded, the pad gets the room until the screen is asked for.
                VStack(spacing: 14) {
                    if model.mirrorLive { MirrorView(store: model.mirrorStore) }
                    DPad().frame(minHeight: 150, maxHeight: .infinity)
                    keys
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .navigationSubtitle(state)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.setMirror(!model.mirrorLive) } label: { Label(model.mirrorLive ? "Hide the TV’s screen" : "Show the TV’s screen", systemImage: model.mirrorLive ? "eye.slash" : "eye") }
            }
        }
        .onDisappear { model.mirrorLive = false }
        .alert("Type on TV", isPresented: $typing) {
            TextField("Text", text: $text)
            Button("Send") { model.post("text", ["text": text]); text = "" }
            Button("Delete") { model.key("del") }
            Button("Cancel", role: .cancel) { text = "" }
        } message: { Text("Goes into the box that’s focused on the TV. Not for passwords.") }
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
        .scrollTargetBehavior(.viewAligned).frame(height: TVLook.bannerSize.height)
    }
}
struct MiniPlayer: View {
    @EnvironmentObject var model: TVModel
    let music: TVStatus.Music
    var body: some View {
        HStack(spacing: 12) {
            Button { model.tab = 2 } label: {
                HStack(spacing: 12) {
                    Art(url: URL(string: music.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                        .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(music.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(music.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Now playing: \(music.title)")
            PlayKey(playing: music.playing, size: 44)
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
    func open() { model.tick(); model.post("open", ["pkg": app.pkg], say: "Opening \(app.name)") }
    var body: some View {
        Button {
            // An app with something to choose from opens that here; the rest go straight to the TV.
            if browses, let s = MediaSource.of(pkg: app.pkg) { model.tick(); model.browsing = s }
            else if browses, app.pkg == "com.mint.letterboxd" { model.tick(); model.tab = 3 }
            else { open() }
        } label: {
            ZStack {
                TVLook.bannerTile
                if app.hasIcon, let u = model.url("/api/tv/icon?pkg=\(app.pkg)&v=2") {
                    Art(url: u) { i in
                        if app.wide == true { i.resizable().scaledToFill() }
                        else {
                            VStack(spacing: 4) { i.resizable().scaledToFit().frame(width: 30, height: 30); Text(app.name).font(.caption.weight(.medium)).lineLimit(1).padding(.horizontal, 8) }
                        }
                    } placeholder: { name }
                } else { name }
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
    var name: some View { Text(app.name).font(.footnote.weight(.medium)).multilineTextAlignment(.center).padding(6) }
}
struct BannerRow: View {
    let title: String, apps: [TVStatus.App]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowTitle(title).padding(.leading, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: TVLook.gap) { ForEach(apps) { Banner(app: $0, browses: true) } }.padding(.horizontal, 20).scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned).clipped()
        }
    }
}
struct AppsTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    static let listen = ["com.codex.musicwebtv", "com.google.android.youtube.tvmusic"]
    static let tools: Set<String> = ["com.android.tv.settings", "com.android.vending", "com.google.android.play.games", "com.cxinventor.file.explorer", "com.esaba.downloader", "flar2.homebutton", "com.macropinch.axe"]
    static let watchOrder = ["com.mint.letterboxd", "com.stremio.one", "com.google.android.youtube.tv", "com.google.android.youtube.tvunplugged", "com.netflix.ninja", "com.plexapp.android", "com.apple.atve.androidtv.appletv", "com.amazon.amazonvideo.livingroom", "com.cbs.ott"]
    var all: [TVStatus.App] { model.status?.apps ?? [] }
    static func watching(_ all: [TVStatus.App]) -> [TVStatus.App] {
        let rest = all.filter { !tools.contains($0.pkg) && !listen.contains($0.pkg) }
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
            ScrollView { VStack(alignment: .leading, spacing: 24) { SendBar().padding(.horizontal, 20); waiting }.padding(.vertical, 12) }
        } else if panes {
            FoldSplit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        SendBar().padding(.horizontal, 20)
                        row("Watch", watch)
                        row("Listen", listen)
                    }.padding(.vertical, 12)
                }
            } right: {
                ScrollView { row("Tools and settings", tools).padding(.vertical, 12) }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    SendBar().padding(.horizontal, 20)
                    row("Watch", watch)
                    row("Listen", listen)
                    row("Tools and settings", tools)
                }.padding(.vertical, 12)
            }
        }
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
        let v = AVRoutePickerView(); Self.current = v; v.tintColor = .white; v.activeTintColor = UIColor(TVLook.accent); v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
#endif

// Flick up to send the phone to the TV. Apple Music goes straight to Mint, from anywhere.
// Anything else opens the AirPlay list, since iOS lets only the owner of the phone choose a route.
struct FlickCard: View {
    @EnvironmentObject var model: TVModel
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
        } else {
            // Mint comes to the front first, ready to receive.
            model.post("music-now")
            if RoutePicker.open() { model.say("Choose Mint Music") } else { showPicker = true }
        }
        #endif
    }
    var body: some View {
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
            RoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
            #endif
        }
        .padding(12)
        .tvCard()
        .contentShape(Rectangle())
        .onTapGesture(perform: flick)
        .onAppear {
            refresh()
            #if os(iOS)
            MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications()
            openAirPlayIfAsked()
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: FlickRequest.airPlay)) { _ in openAirPlayIfAsked() }
        .onChange(of: model.tab) { _, _ in openAirPlayIfAsked() }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
        .alert("AirPlay to the TV", isPresented: $showPicker) { Button("OK", role: .cancel) {} } message: { Text("Tap the AirPlay button on this card and choose Mint Music. AirPlay only reaches the TV on home Wi-Fi.") }
        #endif
    }
}
struct NowControls: View {
    @EnvironmentObject var model: TVModel
    let music: TVStatus.Music
    static func clock(_ ms: Double) -> String { let t = Int(max(ms, 0) / 1000); return String(format: "%d:%02d", t / 60, t % 60) }
    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let raw = music.playing ? music.position + ctx.date.timeIntervalSince1970 * 1000 - music.sampledAt : music.position
                let now = min(max(raw, 0), max(music.duration, 0))
                VStack(spacing: 5) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18))
                            Capsule().fill(.white).frame(width: g.size.width * (music.duration > 0 ? now / music.duration : 0))
                        }
                    }.frame(height: 5)
                    HStack {
                        Text(Self.clock(now))
                        Spacer()
                        Text("−" + Self.clock(music.duration - now))
                    }.font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 26) {
                GlassKey(icon: "backward.fill", label: "Previous", key: "previous", size: 54)
                PlayKey(playing: music.playing, tint: .white, size: 74)
                GlassKey(icon: "forward.fill", label: "Next", key: "next", size: 54)
            }
        }
    }
}
struct PlayingTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    @State private var query = ""
    @State private var kind = "song"
    var music: TVStatus.Music? { model.status?.music }
    var otherAppIsActive: Bool {
        guard let s = model.status?.session, s.pkg != "com.codex.musicwebtv" else { return false }
        return s.playing || music == nil || music?.playing == false
    }
    var now: some View {
        VStack(spacing: 14) {
            // Sound from the phone that isn't music: not Mint's, whatever Mint last played.
            if let a = model.status?.airplay, a.active, a.kind == "unknown", let title = a.title, !title.isEmpty {
                Image(systemName: a.handoff == "youtube" ? "play.rectangle.fill" : "iphone").font(.system(size: 54, weight: .light)).foregroundStyle(TVLook.accent).padding(.top, 24)
                Text(title).font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                Text(a.handoff == "youtube" ? "Opened in YouTube on the TV" : "Playing from this iPhone").font(.subheadline).foregroundStyle(.secondary)
            } else if let m = music, !otherAppIsActive {
                Art(url: URL(string: m.art)) { i in i.resizable().scaledToFit() } placeholder: { Color.white.opacity(0.08) }
                    .aspectRatio(1, contentMode: .fit).frame(maxWidth: panes ? 300 : 180)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                VStack(spacing: 3) {
                    Text(m.title).font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                    Text([m.artist, m.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                NowControls(music: m)
                Button { model.post("music-now", say: "Showing on TV") } label: { Label("Show on TV", systemImage: "tv") }.font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            } else if let s = model.status?.session {
                Image(systemName: s.playing ? "play.tv.fill" : "pause.circle").font(.system(size: 54, weight: .light)).foregroundStyle(TVLook.accent).padding(.top, 24)
                Text(s.description.first ?? "Playing").font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                Text(model.status?.apps?.first { $0.pkg == s.pkg }?.name ?? s.pkg).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    GlassKey(icon: "gobackward.10", label: "Back 10 seconds", key: "rewind", size: 56)
                    PlayKey(playing: s.playing, tint: .white, size: 74)
                    GlassKey(icon: "goforward.10", label: "Forward 10 seconds", key: "forward", size: 56)
                }
                .padding(.top, 6)
                HStack(spacing: 18) {
                    GlassKey(icon: "captions.bubble", label: "Subtitles", key: "captions", size: 50)
                    GlassKey(icon: "waveform", label: "Audio track", key: "audiotrack", size: 50)
                }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note", description: Text("Search below, or flick something from this iPhone."))
            }
        }
        .frame(maxWidth: .infinity)
    }
    func play(shuffle: Bool = false) {
        guard !query.isEmpty else { return }
        model.post("music", ["query": query, "kind": kind, "shuffle": shuffle], say: shuffle ? "Shuffling on the TV" : "Sent to Mint Music")
        query = ""
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
                    TextField("What should play?", text: $query).autocorrectionDisabled().submitLabel(.go).onSubmit { play() }
                        .padding(.horizontal, 16).frame(height: 50).glassEffect(.regular, in: Capsule())
                    Button { play(shuffle: true) } label: { Image(systemName: "shuffle").font(.system(size: 18, weight: .medium)).frame(width: 50, height: 50).contentShape(Circle()) }
                        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).disabled(query.isEmpty).opacity(query.isEmpty ? 0.45 : 1).accessibilityLabel("Shuffle")
                }
            }
        }
    }
    var body: some View {
        Group {
            if panes {
                FoldSplit { ScrollView { now.padding(20) } } right: { ScrollView { send.padding(20) } }
            } else {
                ScrollView { VStack(spacing: 24) { now; send }.padding(.horizontal, 16).padding(.bottom, 16) }
            }
        }
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
            RowHeader(title: title) { FilmList(title: title, films: films) }.padding(.leading, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { ForEach(films) { FilmCard(film: $0) } }.padding(.horizontal, 20).scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned).clipped()
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
// Unfolded, a whole pane of posters is worth more than one row and a blank half screen.
struct FilmGrid: View {
    let title: String, films: [Film]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RowHeader(title: title) { FilmList(title: title, films: films) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 118), spacing: 14, alignment: .top)], alignment: .leading, spacing: 16) { ForEach(films) { FilmCard(film: $0) } }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}
struct FilmsTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    var body: some View {
        Group {
            if model.friends.isEmpty && model.watchlist.isEmpty {
                ScrollView { ContentUnavailableView(model.filmsNote ?? "No films yet", systemImage: "film").padding(.top, 80) }
            } else if panes {
                FoldSplit {
                    if model.recommended.isEmpty { FilmGrid(title: "Friends", films: model.friends) } else { FilmGrid(title: "Recommended for you", films: model.recommended) }
                } right: {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            if !model.recommended.isEmpty, !model.friends.isEmpty { FilmRow(title: "Friends", films: model.friends) }
                            if !model.watchlist.isEmpty { FilmRow(title: "Watchlist", films: model.watchlist) }
                        }.padding(.vertical, 12)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if !model.recommended.isEmpty { FilmRow(title: "Recommended for you", films: model.recommended) }
                        if !model.friends.isEmpty { FilmRow(title: "Friends", films: model.friends) }
                        if !model.watchlist.isEmpty { FilmRow(title: "Watchlist", films: model.watchlist) }
                    }.padding(.vertical, 12)
                }
            }
        }
        .refreshable { await model.loadFilms(force: true) }
        .task(id: model.tab) { if model.tab == 3 { await model.loadFilms() } }
    }
}
