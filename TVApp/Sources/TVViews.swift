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
        if pose == "tour" { return }
        model.browsing = .stremio
        guard pose != "browse" else { return }
        Task {
            // The page is loading the same list, so wait for it rather than asking again.
            for _ in 0..<40 {
                if let item = BrowseStore.shared(.stremio).rows.flatMap(\.items).first(where: { $0.kind == (["streams", "flickdemo"].contains(pose) ? "movie" : "series") }) { model.flick(FlickTarget(item: item, source: .stremio)); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    @State private var resets: [Int: Int] = [:]
    var body: some View {
        PaneReader {
            TabView(selection: TabReset.binding($model.tab) { t in
                // Back to the tab's own start: anything opened on it closes, and it's rebuilt at the top.
                if t == 1 { model.browsing = nil; SendDraft.shared.text = "" }
                resets[t, default: 0] += 1
            }) {
                Tab(value: 0) { Page(title: "Remote", alwaysInline: true) { RemoteTab() }.id(resets[0, default: 0]) } label: { tabLabel("Remote", "av.remote") }
                Tab(value: 1) { Page(title: "Apps") { AppsTab() }.id(resets[1, default: 0]) } label: { tabLabel("Apps", "square.grid.2x2") }
                Tab(value: 2) { Page(title: "Playing", alwaysInline: true) { PlayingTab() }.id(resets[2, default: 0]) } label: {
                    // The cover of what's on, so the button says what's playing before it's pressed.
                    if let i = PlayingIcon.image(model) { Label { Text("Playing") } icon: { Image(tv: i) } } else { tabLabel("Playing", "play.circle") }
                }
                Tab(value: 3) { Page(title: "Watch") { FilmsTab() }.id(resets[3, default: 0]) } label: { tabLabel("Watch", "film") }
                Tab(value: 5) { Page(title: "Status") { DeviceTab() }.id(resets[5, default: 0]) } label: { tabLabel("Status", "gauge.with.dots.needle.33percent") }
                // Last, so it sits at the foot of the side bar, as in the other apps.
                Tab(value: 9) { TVSettingsTab().id(resets[9, default: 0]) } label: { tabLabel("Settings", "gearshape") }
            }
            .onChange(of: model.tab) { _, t in
                UserDefaults.standard.set(t, forKey: "tab")
                // Opening Playing shows what's on now, not what was on at the last look.
                if t == 2 { Task { await model.load() } }
            }
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
        .onAppear { followRequest(); poseForShots(); TabTour.run([0, 1, 2, 3, 5, 9]) { model.tab = $0 } }
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
    let title: String
    var alwaysInline = false
    @ViewBuilder let content: () -> C
    var body: some View {
        NavigationStack {
            content()
                .background { Ambience() }
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(alwaysInline || panes ? .inline : .large)
        }
    }
}

// The TV's own settings and this app's connection, as a tab at the foot of the side bar.
struct TVSettingsTab: View {
    @EnvironmentObject var model: TVModel
    @State private var address = ""
    var body: some View {
        NavigationStack {
            Form {
                TVManageSections()
                Section {
                    TextField("Address", text: $address).autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit { model.address = address.trimmingCharacters(in: .whitespacesAndNewlines); model.start() }
                } header: { Text("Mac Pro address") } footer: { Text("The TV is reached through your Mac, so this works anywhere with Tailscale on.") }
                Section {
                    Button("Refresh the TV’s recommendations") { model.post("refresh", say: "Refreshing") }
                    Button("Open launcher settings on the TV") { model.post("launcher-settings", say: "Opening") }
                }
            }
            .scrollContentBackground(.hidden)
            .background { Ambience() }
            .navigationTitle("Settings")
            .onAppear { address = model.address }
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
            TextField("Search, or send a link", text: $draft.text)
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
    var body: some View {
        Button { model.key("play") } label: {
            Image(systemName: playing == nil ? "playpause.fill" : playing == true ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size).background(tint, in: Circle())
                .shadow(color: tint.opacity(0.45), radius: 14, y: 4)
        }
        .buttonStyle(PressCard()).accessibilityLabel(playing == true ? "Pause" : playing == false ? "Play" : "Play or pause")
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
            // Power joins the top row like a real remote's, rather than sitting alone under everything.
            HStack {
                GlassKey(icon: "power", label: "Sleep or wake", key: model.status?.screen == "asleep" ? "wake" : "sleep"); Spacer()
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
            // No volume here: the TV refuses volume over HDMI, so only its own remote can change it.
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
        .frame(height: TVLook.bannerSize.height)
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
                // Some banners are a white logo on nothing, meant for a dark tile, like YouTube Music's.
                app.wide == true ? Color.black : TVLook.bannerTile
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
            .clipped()
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
        let link = t.contains("://") || t.lowercased().hasPrefix("www.") || (!t.contains(" ") && t.contains(".") && t.contains("/"))
        return t.count >= 2 && !link ? t : nil
    }
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
                        if let query { EverywhereSearch(text: query) } else {
                            row("Watch", watch)
                            row("Listen", listen)
                            row("Tools and settings", tools)
                        }
                    }.padding(.vertical, 12)
                }
            } right: {
                // Unfolded, the other side picks up where you left off, ready to flick.
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Shelf(source: .stremio, title: "Continue watching")
                        Shelf(source: .mint, title: "Recently played")
                    }.padding(.vertical, 12)
                }
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
                }.padding(.vertical, 12)
                .animation(.snappy, value: query == nil)
            }
        }
    }
}

// Ten seconds back or on in Stremio. It takes the TV a few seconds, so it shows it's working and takes no second tap
// until the first has landed, which would otherwise jump twice.
struct SeekButton: View {
    @EnvironmentObject var model: TVModel
    let icon: String, label: String, forward: Bool
    @State private var working = false
    var body: some View {
        Button {
            guard !working else { return }
            model.tick(); working = true
            Task {
                do { try await TVBridge.post("player-seek", ["forward": forward], timeout: 30); await model.load() }
                catch { model.say("Couldn’t move it") }
                working = false
            }
        } label: {
            ZStack {
                Image(systemName: icon).font(.system(size: 22, weight: .medium)).opacity(working ? 0.25 : 1)
                if working { ProgressView().controlSize(.small) }
            }
            .frame(width: 56, height: 56).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel(label)
        .animation(.easeOut(duration: 0.15), value: working)
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
        Group {
            if let row, !row.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    RowHeader(title: title) { MediaList(row: row, source: store.source) }.padding(.leading, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 10) {
                            ForEach(row.items) { item in
                                Button { model.flick(FlickTarget(item: item, source: store.source)) } label: { MediaCard(item: item, source: store.source, width: store.source == .mint ? 128 : 112) }
                                    .buttonStyle(PressCard()).accessibilityLabel("\(item.title), \(item.subtitle)")
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .clipped()
                }
            }
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
                RoutePicker().frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true)
                #else
                Color.clear.frame(height: 0)
                #endif
            } else { card }
        }
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
        .animation(.snappy, value: alreadyThere)
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
            RoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
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
        // A paused player only counts if it's the app in front, or a song would lose out to something long since left.
        return s.playing || music == nil || s.pkg == model.status?.app
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
                let appName = model.status?.apps?.first { $0.pkg == s.pkg }?.name ?? s.pkg
                // What was flicked, or the app's own banner when the app says nothing about what it's playing.
                Art(url: model.picture(for: s).flatMap(URL.init(string:))) { $0.resizable().scaledToFit() } placeholder: {
                    Image(systemName: "play.tv.fill").font(.system(size: 54, weight: .light)).foregroundStyle(TVLook.accent)
                }
                .frame(maxWidth: 300, maxHeight: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                .padding(.top, 20)
                // The series, then the episode under it, then where it's playing and whether it's paused.
                VStack(spacing: 3) {
                    Text(s.description.first ?? appName).font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                    if s.description.count > 1 { Text(s.description[1]).font(.headline).foregroundStyle(.white.opacity(0.85)).lineLimit(2).multilineTextAlignment(.center) }
                    Text("\(appName) · \(s.playing ? "Playing" : "Paused")").font(.subheadline).foregroundStyle(.secondary).contentTransition(.opacity)
                }
                if s.position != nil { VideoProgress(session: s).padding(.horizontal, 4) }
                HStack(spacing: 18) {
                    if s.pkg == "com.stremio.one" {
                        // Its player ignores the skip keys, so the bridge moves its seek bar instead.
                        seekButton("gobackward.10", "Back 10 seconds", forward: false)
                        PlayKey(playing: s.playing, tint: .white, size: 74)
                        seekButton("goforward.10", "Forward 10 seconds", forward: true)
                    } else {
                        GlassKey(icon: "gobackward.10", label: "Back 10 seconds", key: "rewind", size: 56)
                        PlayKey(playing: s.playing, tint: .white, size: 74)
                        GlassKey(icon: "goforward.10", label: "Forward 10 seconds", key: "forward", size: 56)
                    }
                }
                .padding(.top, 6)
                // Stremio's own menus can't be driven from here without risking a restart, so only other apps get these keys.
                if s.pkg != "com.stremio.one" {
                    HStack(spacing: 18) {
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
    func seekButton(_ icon: String, _ label: String, forward: Bool) -> some View {
        SeekButton(icon: icon, label: label, forward: forward)
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
        .environment(\.keysInScroll, true)
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
            .clipped()
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
// Films and shows to pick from: what's on the TV's own Stremio home, Letterboxd's picks and friends, and Stremio's
// catalogue, popular, top rated, new, by genre and by search. Every card flicks like anywhere else.
struct FilmsTab: View {
    @EnvironmentObject var model: TVModel
    @State private var kind = "movie"
    @StateObject private var films = BrowseStore(.stremio, base: "/api/tv/discover?type=movie")
    @StateObject private var shows = BrowseStore(.stremio, base: "/api/tv/discover?type=series")
    static let genres = ["Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama", "Family", "Fantasy", "History", "Horror", "Mystery", "Romance", "Sci-Fi", "Thriller", "War", "Western"]
    var body: some View {
        DiscoverColumn(store: kind == "movie" ? films : shows, kind: $kind)
            .id(kind)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: kind)
    }
}
struct DiscoverColumn: View {
    @EnvironmentObject var model: TVModel
    @ObservedObject var store: BrowseStore
    @Binding var kind: String
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
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
                    Chips(options: [("", "All")] + FilmsTab.genres.map { ($0, $0) }, selected: Binding(get: { store.genre }, set: { g in
                        store.genre = g
                        Task { await store.load(force: true) }
                    }))
                    .padding(.horizontal, 20)
                }
                if store.rows.isEmpty {
                    Group {
                        if store.loading { ForEach(0..<3, id: \.self) { _ in PlaceholderShelf() } }
                        else if store.failed { ContentUnavailableView("Can’t reach the TV", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again.")) }
                        else { ContentUnavailableView.search }
                    }
                    .frame(maxWidth: .infinity)
                }
                ForEach(store.rows) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        RowHeader(title: row.title) { MediaList(row: row, source: .stremio) }.padding(.leading, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 10) {
                                ForEach(row.items) { item in
                                    Button { model.flick(FlickTarget(item: item, source: .stremio)) } label: { MediaCard(item: item, source: .stremio, width: 124) }
                                        .buttonStyle(PressCard()).accessibilityLabel("\(item.title), \(item.subtitle)")
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .clipped()
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await store.load(force: true) }
        .task { await store.load() }
    }
}
// A row still on its way: a title bar and a few card shapes, breathing.
struct PlaceholderShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(.white.opacity(0.12)).frame(width: 150, height: 16).padding(.leading, 20)
            HStack(spacing: 10) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08)).frame(width: 124, height: 236) } }
                .padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading).clipped()
        .phaseAnimator([0.5, 1.0]) { c, o in c.opacity(o) } animation: { _ in .easeInOut(duration: 0.9) }
        .accessibilityHidden(true)
    }
}

// Where a film or video is, ticking along while it plays. Slide along it, or tap a spot, to jump there on the TV.
struct VideoProgress: View {
    @EnvironmentObject var model: TVModel
    let session: TVStatus.Session
    @State private var scrub: Double?
    @State private var across: Bool?
    @State private var seeking = false
    var duration: Double { session.duration ?? 0 }
    var canSeek: Bool { session.canSeek == true && duration > 0 && !seeking }
    func position(at date: Date) -> Double {
        let base = session.position ?? 0
        guard session.playing, let at = session.sampledAt else { return base }
        let now = base + max(0, date.timeIntervalSince1970 * 1000 - at)
        return duration > 0 ? min(now, duration) : now
    }
    func clock(_ ms: Double) -> String {
        let t = Int(max(0, ms) / 1000)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    func seek(to ms: Double) {
        seeking = true
        model.tick()
        Task {
            do { try await TVBridge.post("player-seek-to", ["ms": Int(ms)], timeout: 60); await model.load() }
            catch { model.say("Couldn’t move there") }
            withAnimation(.snappy) { scrub = nil; seeking = false }
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = position(at: ctx.date), shown = scrub ?? now
            VStack(spacing: 6) {
                if duration > 0 {
                    GeometryReader { g in
                        let f = min(1, max(0, shown / duration)), thick: CGFloat = scrub == nil ? 6 : 10
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18)).frame(height: thick)
                            Capsule().fill(seeking ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(TVLook.accent)).frame(width: max(thick, g.size.width * f), height: thick)
                        }
                        .frame(maxHeight: .infinity)
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: thick)
                        .contentShape(Rectangle())
                        // Only a sideways slide moves it, so scrolling the page past it never does.
                        .gesture(DragGesture(minimumDistance: 6)
                            .onChanged { v in
                                guard canSeek else { return }
                                if across == nil { across = abs(v.translation.width) > abs(v.translation.height) }
                                if across == true { scrub = duration * min(1, max(0, v.location.x / g.size.width)) }
                            }
                            .onEnded { _ in
                                if across == true, let t = scrub { seek(to: t) } else { scrub = nil }
                                across = nil
                            })
                        .onTapGesture { p in if canSeek { scrub = duration * min(1, max(0, p.x / g.size.width)); seek(to: scrub!) } }
                    }
                    .frame(height: 28)
                    .sensoryFeedback(.selection, trigger: scrub.map { Int($0 / 10000) })
                }
                HStack {
                    Text(clock(shown))
                    Spacer()
                    if seeking { Text("Moving there on the TV…").foregroundStyle(TVLook.accent) }
                    Spacer()
                    if duration > 0 { Text("-" + clock(duration - shown)) }
                }
                .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue(duration > 0 ? "\(clock(position(at: Date()))) of \(clock(duration))" : clock(position(at: Date())))
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
    // One picture shared by every page, so a page shows it the moment it appears instead of drawing it in.
    @MainActor private static var memo: [String: (image: TVImage, tint: Color?)] = [:]
    @State private var loaded = 0
    var art: String? {
        if let s = model.status?.session, s.pkg != "com.codex.musicwebtv" { return model.picture(for: s) }
        return model.status?.music?.art
    }
    var current: (image: TVImage, tint: Color?)? { art.flatMap { Ambience.memo[$0] } }
    var tint: Color { model.mood ?? current?.tint ?? Color(hex: 0x4A1A5C) }
    var body: some View {
        ZStack {
            Color.black
            if let small = current?.image {
                Color.clear
                    .overlay { Image(tv: small).resizable().interpolation(.high).scaledToFill().opacity(0.55) }
                    .clipped()
            }
            // Only the colour eases, and only the colour: an animation on the whole backdrop would grow it from a corner
            // as a page lays out.
            LinearGradient(colors: [tint.opacity(0.8), tint.opacity(0.45), .black.opacity(0.75)], startPoint: .topLeading, endPoint: .bottom)
                .animation(.easeInOut(duration: 0.7), value: tint)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: art) {
            guard let art, Ambience.memo[art] == nil, let u = URL(string: art), let i = await ImageStore.shared.load(u) else { return }
            let band = await ImageStore.shared.band(u)
            // Shrunk to a few pixels and stretched back: a heavy blur that costs nothing while scrolling.
            #if canImport(UIKit)
            let small = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 6)).image { _ in i.draw(in: CGRect(x: 0, y: 0, width: 6, height: 6)) }
            #else
            let small = i
            #endif
            if Ambience.memo.count > 40 { Ambience.memo.removeAll() }
            Ambience.memo[art] = (small, band)
            loaded += 1
        }
    }
}

// The Playing tab's icon: the cover of what's on, as a small rounded picture, or the plain symbol when nothing is.
struct PlayingIcon {
    // Drawn once per cover; the root redraws on every status.
    @MainActor private static var made: (String, TVImage)?
    @MainActor static func image(_ model: TVModel) -> TVImage? {
        #if canImport(UIKit)
        let session = model.status?.session
        guard let s = session.map({ $0.pkg != "com.codex.musicwebtv" }) == true ? model.picture(for: session!) : model.status?.music?.art,
              let u = URL(string: s), let i = ImageStore.shared.cached(u) else { return nil }
        if let made, made.0 == s { return made.1 }
        let side: CGFloat = 26
        let f = UIGraphicsImageRendererFormat(); f.scale = 3
        let icon = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { _ in
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 6).addClip()
            let k = max(side / i.size.width, side / i.size.height)
            i.draw(in: CGRect(x: (side - i.size.width * k) / 2, y: (side - i.size.height * k) / 2, width: i.size.width * k, height: i.size.height * k))
        }.withRenderingMode(.alwaysOriginal)
        made = (s, icon)
        return icon
        #else
        return nil
        #endif
    }
}
