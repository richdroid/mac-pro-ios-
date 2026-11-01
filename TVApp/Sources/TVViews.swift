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
                .onOpenURL { if $0.host == "tab", let t = Int($0.lastPathComponent) { model.tab = t } }
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
    var body: some View {
        Group {
            TabView(selection: $model.tab) {
                Tab("Remote", systemImage: "av.remote", value: 0) { Page(title: "Remote", alwaysInline: true) { RemoteTab() } }
                Tab("Apps", systemImage: "square.grid.2x2", value: 1) { Page(title: "Apps") { AppsTab() } }
                Tab("Playing", systemImage: "play.circle", value: 2) { Page(title: "Playing", alwaysInline: true) { PlayingTab() } }
                Tab("Films", systemImage: "film", value: 3) { Page(title: "Films") { FilmsTab() } }
            }
            .onChange(of: model.tab) { _, t in UserDefaults.standard.set(t, forKey: "tab") }
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
        .onAppear { followRequest() }
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
    @Environment(\.horizontalSizeClass) private var size
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
                .navigationBarTitleDisplayMode(alwaysInline || size == .regular ? .inline : .large)
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
                Section {
                    TextField("Address", text: $address).autocorrectionDisabled()
                } header: { Text("Mac Pro address") } footer: { Text("The TV is reached through your Mac, so this works anywhere with Tailscale on.") }
                Section {
                    Button("Refresh the TV’s recommendations") { model.post("refresh", say: "Refreshing") }
                    Button("Open launcher settings on the TV") { model.post("launcher-settings", say: "Opening") }
                }
            }
            .navigationTitle("Connection")
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

// Swipe to move, keep your finger down to keep moving, tap to select, hold to long-press. Lifting stops the TV at once.
struct TouchPad: View {
    @EnvironmentObject var model: TVModel
    @State private var moved = false
    @State private var anchor = CGPoint.zero
    @State private var began = false
    @State private var heldKey: String?
    @State private var repeater: Task<Void, Never>?
    @State private var longTimer: Task<Void, Never>?
    @State private var longFired = false
    @State private var ripple: CGPoint?
    @State private var restPoint = CGPoint.zero
    @State private var restSince = Date()
    // Resets by itself when the system takes the touch away, which ends the drag with no callback.
    @GestureState private var touching = false
    @AppStorage("padLearned") private var learned = false
    let step: CGFloat = 40
    // Repeats only once the finger has come to rest at the end of a swipe, so a slow swipe never overshoots.
    func hold(_ key: String) {
        guard heldKey != key else { return }
        heldKey = key
        repeater?.cancel()
        let started = Date()
        repeater = Task {
            // Ten seconds is further than any row goes; never run away.
            while !Task.isCancelled, Date().timeIntervalSince(started) < 10 {
                if Date().timeIntervalSince(restSince) > 0.3 { model.key(key, repeating: true) }
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }
    func finish() {
        let tapped = began && !moved && !longFired
        cancel()
        if tapped { model.key("ok") }
    }
    func cancel() {
        repeater?.cancel(); repeater = nil; longTimer?.cancel(); longTimer = nil
        moved = false; began = false; longFired = false; heldKey = nil; ripple = nil
    }
    var body: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.08))
                if let ripple {
                    Circle().fill(.white.opacity(0.14)).frame(width: 96, height: 96).position(ripple).allowsHitTesting(false)
                } else if !learned {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.draw").font(.system(size: 30, weight: .light))
                        Text("Swipe to move. Tap to select.").font(.footnote)
                    }
                    .foregroundStyle(.secondary).allowsHitTesting(false).transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .contentShape(Rectangle())
            .onChange(of: touching) { _, now in if !now { cancel() } }
            .onDisappear { cancel() }
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { v in
                    ripple = v.location
                    if hypot(v.location.x - restPoint.x, v.location.y - restPoint.y) > 6 { restPoint = v.location; restSince = Date() }
                    if !began {
                        began = true; anchor = v.startLocation
                        longTimer = Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            if !Task.isCancelled, !moved { longFired = true; model.key("ok", long: true) }
                        }
                    }
                    let dx = v.location.x - anchor.x, dy = v.location.y - anchor.y
                    if abs(dx) > step || abs(dy) > step {
                        moved = true; longTimer?.cancel(); learned = true
                        let k = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
                        model.key(k)
                        anchor = v.location
                        hold(k)
                    }
                }
                .onEnded { _ in finish() })
            .accessibilityLabel("Touch pad. Swipe to move, tap to select.")
    }
}

struct GlassKey: View {
    @EnvironmentObject var model: TVModel
    let icon: String, label: String, key: String
    var size: CGFloat = 54
    @State private var longPressed = false
    var body: some View {
        Button {
            if longPressed { longPressed = false } else { model.key(key) }
        } label: {
            Image(systemName: icon).font(.system(size: size * 0.36, weight: .medium)).frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            longPressed = true; model.key(key, long: true)
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); longPressed = false }
        })
        .accessibilityLabel(label)
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
                    ViewThatFits(in: .vertical) {
                        side(apps: true)
                        side(apps: false)
                    }
                } right: {
                    VStack(spacing: 14) { TouchPad().frame(maxHeight: .infinity); keys }.padding(.horizontal, 20).padding(.bottom, 16)
                }
            } else {
                // Folded, the pad gets the room until the screen is asked for.
                VStack(spacing: 14) {
                    if model.mirrorLive { MirrorView(store: model.mirrorStore) }
                    TouchPad().frame(minHeight: 150, maxHeight: .infinity)
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
    var current: Bool { model.status?.app == app.pkg }
    var body: some View {
        Button {
            model.tick(); model.post("open", ["pkg": app.pkg], say: "Opening \(app.name)")
        } label: {
            ZStack {
                TVLook.bannerTile
                if app.hasIcon, let u = model.url("/api/tv/icon?pkg=\(app.pkg)") {
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
        .buttonStyle(.plain).accessibilityLabel(app.name).accessibilityAddTraits(current ? .isSelected : [])
    }
    var name: some View { Text(app.name).font(.footnote.weight(.medium)).multilineTextAlignment(.center).padding(6) }
}
struct BannerRow: View {
    let title: String, apps: [TVStatus.App]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowTitle(title).padding(.leading, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: TVLook.gap) { ForEach(apps) { Banner(app: $0) } }.padding(.horizontal, 20).scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned).clipped()
        }
    }
}
struct AppsTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.horizontalSizeClass) private var size
    static let listen = ["com.codex.musicwebtv", "com.google.android.youtube.tvmusic"]
    static let tools: Set<String> = ["com.android.tv.settings", "com.android.vending", "com.google.android.play.games", "com.cxinventor.file.explorer", "com.esaba.downloader", "flar2.homebutton", "com.ionitech.airscreen", "com.macropinch.axe"]
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
        if all.isEmpty {
            ScrollView { VStack(alignment: .leading, spacing: 24) { SendBar().padding(.horizontal, 20); waiting }.padding(.vertical, 12) }
        } else if size == .regular {
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
        guard let b = current?.subviews.compactMap({ $0 as? UIButton }).first else { return false }
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
    @State private var offset: CGFloat = 0
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
        if let i = item?.artwork?.image(at: CGSize(width: 160, height: 160)) { art = Image(uiImage: i) } else { art = nil }
        #endif
    }
    #if os(iOS)
    // Sent here by the Action Button or Siri, with nothing in Apple Music to send.
    func openAirPlayIfAsked() {
        guard FlickRequest.wantsAirPlay else { return }
        FlickRequest.wantsAirPlay = false
        Task { try? await Task.sleep(nanoseconds: 500_000_000); _ = RoutePicker.open() }
    }
    #endif
    func flick() {
        model.tick()
        #if os(iOS)
        refresh()
        if !title.isEmpty {
            let song = title, by = artist
            Task {
                // The phone only stops once the TV has it, so a failed send never silences the music.
                do {
                    try await TVBridge.post("flick", ["title": song, "artist": by])
                    MPMusicPlayerController.systemMusicPlayer.pause()
                    model.say("Sent to the TV")
                } catch { model.say("The TV didn’t get that") }
            }
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
                Label(title.isEmpty ? "Flick up to AirPlay" : "Flick up to send", systemImage: "chevron.up").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            #if os(iOS)
            RoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
            #endif
        }
        .padding(12)
        .tvCard()
        .scaleEffect(offset < -20 ? 0.97 : 1)
        .offset(y: offset)
        .gesture(DragGesture(minimumDistance: 12)
            .onChanged { v in offset = min(0, v.translation.height) * 0.7 }
            .onEnded { v in
                if v.translation.height < -50 || v.predictedEndTranslation.height < -140 { flick() }
                withAnimation(.spring(duration: 0.35, bounce: 0.35)) { offset = 0 }
            })
        .onAppear {
            refresh()
            #if os(iOS)
            MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications()
            openAirPlayIfAsked()
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: FlickRequest.airPlay)) { _ in openAirPlayIfAsked() }
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
    @Environment(\.horizontalSizeClass) private var size
    @State private var query = ""
    @State private var kind = "song"
    var music: TVStatus.Music? { model.status?.music }
    var otherAppIsActive: Bool {
        guard let s = model.status?.session, s.pkg != "com.codex.musicwebtv" else { return false }
        return s.playing || music == nil || music?.playing == false
    }
    var now: some View {
        VStack(spacing: 14) {
            // Another app's video outranks a song left paused in Mint.
            if let m = music, !otherAppIsActive {
                Art(url: URL(string: m.art)) { i in i.resizable().scaledToFit() } placeholder: { Color.white.opacity(0.08) }
                    .aspectRatio(1, contentMode: .fit).frame(maxWidth: size == .regular ? 300 : 180)
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
                PlayKey(playing: s.playing, tint: .white, size: 74).padding(.top, 6)
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
            if size == .regular {
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
        Button { model.tick(); model.post("film", ["slug": film.slug], say: "Opening on TV") } label: {
            VStack(alignment: .leading, spacing: 6) {
                Art(url: URL(string: film.poster)) { i in i.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                    .frame(width: 118, height: 177).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(film.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    if !film.note.isEmpty { Text(film.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(width: 118, alignment: .leading)
            }
        }.buttonStyle(.plain).accessibilityLabel(film.title)
    }
}
struct FilmRow: View {
    let title: String, films: [Film]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowTitle(title).padding(.leading, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { ForEach(films) { FilmCard(film: $0) } }.padding(.horizontal, 20).scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned).clipped()
        }
    }
}
// Unfolded, a whole pane of posters is worth more than one row and a blank half screen.
struct FilmGrid: View {
    let title: String, films: [Film]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RowTitle(title)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 118), spacing: 14, alignment: .top)], alignment: .leading, spacing: 16) { ForEach(films) { FilmCard(film: $0) } }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}
struct FilmsTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.horizontalSizeClass) private var size
    var body: some View {
        Group {
            if model.friends.isEmpty && model.watchlist.isEmpty {
                ScrollView { ContentUnavailableView(model.filmsNote ?? "No films yet", systemImage: "film").padding(.top, 80) }
            } else if size == .regular {
                FoldSplit { FilmGrid(title: "Friends", films: model.friends) } right: { FilmGrid(title: "Watchlist", films: model.watchlist) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
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
