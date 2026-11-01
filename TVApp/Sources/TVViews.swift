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
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).preferredColorScheme(.dark).tint(Mint.progress).foregroundStyle(Mint.text)
                .onChange(of: phase) { _, p in if p == .active { model.start() } else { model.stop() } }
                .onAppear { model.start() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: TVModel
    @State private var settings = false
    var problem: String? {
        if !model.reachable { return "Can’t reach the Mac. Is Tailscale on?" }
        if model.status?.online == false { return "The Mac can’t reach the TV" }
        return nil
    }
    var body: some View {
        ScreenMeasure {
            TabView(selection: $model.tab) {
                Tab("Remote", systemImage: "av.remote", value: 0) { page { RemoteTab() } }
                Tab("Apps", systemImage: "square.grid.2x2", value: 1) { page { AppsTab() } }
                Tab("Playing", systemImage: "play.circle", value: 2) { page { PlayingTab() } }
                Tab("Films", systemImage: "film", value: 3) { page { FilmsTab() } }
            }
            .onChange(of: model.tab) { _, t in UserDefaults.standard.set(t, forKey: "tab") }
        }
        .overlay(alignment: .top) {
            if let problem { Label(problem, systemImage: "wifi.exclamationmark").font(Mint.font(13, weight: 500)).padding(.horizontal, 14).padding(.vertical, 8).background(Color(hex: 0xB3261E), in: RoundedRectangle(cornerRadius: Mint.radius)).padding(.top, 4) }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast { Text(t).font(Mint.font(14)).padding(.horizontal, 16).padding(.vertical, 10).background(Mint.band, in: RoundedRectangle(cornerRadius: Mint.radius)).shadow(radius: 12, y: 6).padding(.bottom, 24).transition(.opacity) }
        }
        .animation(Mint.focus, value: model.toast)
        .onReceive(NotificationCenter.default.publisher(for: FlickRequest.airPlay)) { _ in model.tab = 2 }
    }
    func page<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        NavigationStack {
            c().background { Wall(art: model.status?.music?.art) }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .primaryAction) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Connection") } }
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

// The launcher's search row: the blue orb and a quiet prompt. Takes words or any link.
struct SendBar: View {
    @EnvironmentObject var model: TVModel
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 14) {
            Button {
                #if canImport(UIKit)
                if let s = UIPasteboard.general.string, !s.isEmpty { model.send(s) } else { focused = true }
                #endif
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 20, weight: .medium)).foregroundStyle(.white).frame(width: 46, height: 46).background(Mint.orb, in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("Send what you copied to the TV")
            TextField("Send a link or search", text: $text)
                .font(Mint.font(17, weight: 300)).focused($focused).autocorrectionDisabled()
                .onSubmit { if !text.isEmpty { model.send(text); text = "" } }
        }
    }
}

struct RowTitle: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View { Text(title).font(Mint.rowTitle()).frame(height: 32, alignment: .leading) }
}

// MARK: - Remote
struct MirrorView: View {
    @EnvironmentObject var model: TVModel
    var body: some View {
        ZStack {
            Mint.plane.opacity(0.5)
            if let m = model.mirror, model.mirrorLive { Image(tv: m).resizable().scaledToFit() }
            if !model.mirrorLive { MirrorToggle() }
        }
        .aspectRatio(16.0 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Mint.radius))
        .contentShape(Rectangle())
        .onTapGesture { if model.mirrorLive { model.mirrorLive = false } }
    }
}
struct MirrorToggle: View {
    @EnvironmentObject var model: TVModel
    var body: some View {
        Button {
            model.mirrorLive.toggle()
            if model.mirrorLive { Task { await model.loadMirror() } }
        } label: { Image(systemName: model.mirrorLive ? "eye.slash" : "eye").font(.system(size: 20)) }
        .buttonStyle(MintKeyStyle(diameter: 44))
        .accessibilityLabel(model.mirrorLive ? "Hide the TV’s screen" : "Show the TV’s screen")
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
    let step: CGFloat = 40
    // Repeats only once the finger has come to rest at the end of a swipe, so a slow swipe never overshoots.
    func hold(_ key: String) {
        guard heldKey != key else { return }
        heldKey = key
        repeater?.cancel()
        repeater = Task {
            while !Task.isCancelled {
                if Date().timeIntervalSince(restSince) > 0.3 { model.key(key, repeating: true) }
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }
    func finish() {
        repeater?.cancel(); repeater = nil; longTimer?.cancel(); longTimer = nil
        if !moved && !longFired { model.key("ok") }
        moved = false; began = false; longFired = false; heldKey = nil; ripple = nil
    }
    var body: some View {
        RoundedRectangle(cornerRadius: Mint.radius)
            .fill(Mint.plane)
            .overlay {
                if let ripple { Circle().fill(Mint.text.opacity(0.12)).frame(width: 88, height: 88).position(ripple).allowsHitTesting(false) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
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
                        moved = true; longTimer?.cancel()
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

struct GlyphKey: View {
    @EnvironmentObject var model: TVModel
    let icon: String, label: String, key: String
    var size: CGFloat = 56
    @State private var longPressed = false
    var body: some View {
        Button {
            if longPressed { longPressed = false } else { model.key(key) }
        } label: {
            Image(systemName: icon).font(.system(size: size * 0.38, weight: .regular))
        }
        .buttonStyle(MintKeyStyle(diameter: size))
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            longPressed = true; model.key(key, long: true)
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); longPressed = false }
        })
        .accessibilityLabel(label)
    }
}

struct RemoteTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.horizontalSizeClass) private var size
    @State private var typing = false
    @State private var text = ""
    var state: String {
        guard let s = model.status, s.online else { return "Connecting…" }
        return s.screen == "asleep" ? "Asleep. Press anything to wake it." : s.screen == "screensaver" ? "Screensaver" : (s.apps?.first { $0.pkg == s.app }?.name ?? "Home")
    }
    var keys: some View {
        VStack(spacing: 6) {
            HStack { GlyphKey(icon: "arrow.uturn.backward", label: "Back", key: "back"); Spacer(); GlyphKey(icon: "house", label: "Home", key: "home"); Spacer()
                Button { typing = true } label: { Image(systemName: "keyboard").font(.system(size: 21)) }.buttonStyle(MintKeyStyle()).accessibilityLabel("Type on TV")
                Spacer(); GlyphKey(icon: "line.3.horizontal", label: "Menu", key: "menu") }
            HStack { GlyphKey(icon: "backward.end", label: "Previous", key: "previous"); Spacer(); GlyphKey(icon: "gobackward.10", label: "Rewind", key: "rewind"); Spacer(); GlyphKey(icon: "playpause", label: "Play or pause", key: "play", size: 66); Spacer(); GlyphKey(icon: "goforward.10", label: "Fast forward", key: "forward"); Spacer(); GlyphKey(icon: "forward.end", label: "Next", key: "next") }
            HStack { GlyphKey(icon: "speaker.minus", label: "Volume down", key: "voldown"); Spacer(); GlyphKey(icon: "speaker.slash", label: "Mute", key: "mute"); Spacer(); GlyphKey(icon: "speaker.plus", label: "Volume up", key: "volup"); Spacer()
                GlyphKey(icon: "power", label: "Sleep or wake", key: model.status?.screen == "asleep" ? "wake" : "sleep") }
        }
    }
    var title: some View { Text(state).font(Mint.font(15.4)).foregroundStyle(Mint.text.opacity(0.8)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
    var body: some View {
        Group {
            if size == .regular {
                FoldSplit {
                    VStack(alignment: .leading, spacing: 12) { title; MirrorView(); SendBar(); Spacer(minLength: 0) }.padding(20)
                } right: {
                    VStack(spacing: 12) { TouchPad().frame(maxHeight: .infinity); keys }.padding(20)
                }
            } else {
                // Folded, the pad gets the room until the screen is asked for.
                VStack(spacing: 10) {
                    HStack { title; MirrorToggle() }
                    if model.mirrorLive { MirrorView() }
                    TouchPad().frame(minHeight: 120, maxHeight: .infinity)
                    keys
                }
                .padding(.horizontal, 14).padding(.bottom, 6)
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
                Mint.banner
                if app.hasIcon, let u = model.url("/api/tv/icon?pkg=\(app.pkg)") {
                    Art(url: u) { i in
                        if app.wide == true { i.resizable().scaledToFill() } else { i.resizable().scaledToFit().padding(14) }
                    } placeholder: { name }
                } else { name }
            }
            .frame(width: Mint.bannerSize.width, height: Mint.bannerSize.height)
            .clipShape(RoundedRectangle(cornerRadius: Mint.radius))
            .scaleEffect(current ? 1.14 : 1)
            .shadow(color: .black.opacity(current ? 0.6 : 0), radius: 10, y: 6)
            .animation(Mint.focus, value: current)
        }
        .buttonStyle(.plain).accessibilityLabel(app.name)
    }
    var name: some View { Text(app.name).font(Mint.font(14, condensed: true)).multilineTextAlignment(.center).padding(6) }
}
// Rows run edge to edge and stop at the tab rail, so nothing slides under the gear.
struct BannerRow: View {
    let title: String, apps: [TVStatus.App]
    var pad: CGFloat = 20
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowTitle(title).padding(.leading, pad)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Mint.gap) { ForEach(apps) { Banner(app: $0) } }.padding(.vertical, 10).padding(.horizontal, pad).scrollTargetLayout()
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
    var watch: [TVStatus.App] {
        let rest = all.filter { !Self.tools.contains($0.pkg) && !Self.listen.contains($0.pkg) }
        return rest.sorted { (Self.watchOrder.firstIndex(of: $0.pkg) ?? 99) < (Self.watchOrder.firstIndex(of: $1.pkg) ?? 99) }
    }
    var listen: [TVStatus.App] { Self.listen.compactMap { p in all.first { $0.pkg == p } } }
    var tools: [TVStatus.App] { all.filter { Self.tools.contains($0.pkg) } }
    @ViewBuilder func row(_ title: String, _ apps: [TVStatus.App], pad: CGFloat) -> some View {
        if !apps.isEmpty { BannerRow(title: title, apps: apps, pad: pad) }
    }
    var body: some View {
        if size == .regular {
            FoldSplit {
                ScrollView {
                    VStack(alignment: .leading, spacing: Mint.rowGap) {
                        SendBar().padding(.horizontal, 20)
                        row("Watch", watch, pad: 20)
                        row("Listen", listen, pad: 20)
                    }.padding(.vertical, 12)
                }
            } right: {
                ScrollView { row("Tools and settings", tools, pad: 20).padding(.vertical, 12) }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Mint.rowGap) {
                    SendBar().padding(.horizontal, 20)
                    row("Watch", watch, pad: 20)
                    row("Listen", listen, pad: 20)
                    row("Tools and settings", tools, pad: 20)
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
        let v = AVRoutePickerView(); Self.current = v; v.tintColor = UIColor(Mint.text); v.activeTintColor = UIColor(Mint.progress); v.prioritizesVideoDevices = false
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
    func flick() {
        model.tick()
        #if os(iOS)
        refresh()
        if !title.isEmpty {
            MPMusicPlayerController.systemMusicPlayer.pause()
            model.post("flick", ["title": title, "artist": artist], say: "Sent to the TV")
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
                Mint.band
                if let art { art.resizable().scaledToFill() } else { Image(systemName: "iphone").font(.title2).opacity(0.7) }
            }
            .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: Mint.radius))
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? "On this iPhone" : title).font(Mint.font(15.4)).lineLimit(1)
                Text(title.isEmpty ? "Flick up to AirPlay" : "\(artist). Flick up to send.").font(Mint.font(11.8)).opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: 0)
            #if os(iOS)
            RoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
            #endif
        }
        .padding(10)
        .background(Mint.plane, in: RoundedRectangle(cornerRadius: Mint.radius))
        .offset(y: offset)
        .gesture(DragGesture(minimumDistance: 12)
            .onChanged { v in offset = min(0, v.translation.height) * 0.7 }
            .onEnded { v in
                if v.translation.height < -50 || v.predictedEndTranslation.height < -140 { flick() }
                withAnimation(Mint.glide) { offset = 0 }
            })
        .onAppear {
            refresh()
            #if os(iOS)
            MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications()
            // Sent here by the Action Button or Siri, with nothing in Apple Music to send.
            if FlickRequest.wantsAirPlay {
                FlickRequest.wantsAirPlay = false
                Task { try? await Task.sleep(nanoseconds: 500_000_000); _ = RoutePicker.open() }
            }
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
        .alert("AirPlay to the TV", isPresented: $showPicker) { Button("OK", role: .cancel) {} } message: { Text("Tap the AirPlay button on this card and choose Mint Music. AirPlay only reaches the TV on home Wi-Fi.") }
        #endif
    }
}
// Mint's control band: cover colour, a hairline along the top, times at the ends and a round Play in the middle.
struct ControlBand: View {
    @EnvironmentObject var model: TVModel
    let music: TVStatus.Music
    @State private var tint = Mint.band
    static func clock(_ ms: Double) -> String { let t = Int(max(ms, 0) / 1000); return String(format: "%d:%02d", t / 60, t % 60) }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let raw = music.playing ? music.position + ctx.date.timeIntervalSince1970 * 1000 - music.sampledAt : music.position
            let now = min(max(raw, 0), max(music.duration, 0))
            VStack(spacing: 0) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Mint.text.opacity(0.22))
                        Rectangle().fill(Mint.text).frame(width: g.size.width * (music.duration > 0 ? now / music.duration : 0))
                    }
                }.frame(height: 2)
                HStack(spacing: 0) {
                    Text(Self.clock(now)).font(Mint.font(12)).monospacedDigit().frame(width: 44, alignment: .leading)
                    Spacer(minLength: 0)
                    GlyphKey(icon: "backward.end.fill", label: "Previous", key: "previous", size: 48)
                    Button { model.key("play") } label: {
                        Image(systemName: music.playing ? "pause.fill" : "play.fill").font(.system(size: 22)).foregroundStyle(Color.black.opacity(0.85))
                            .frame(width: 58, height: 58).background(Color.white.opacity(0.62).blendMode(.normal), in: Circle()).background(tint, in: Circle())
                    }.buttonStyle(.plain).padding(.horizontal, 14).accessibilityLabel(music.playing ? "Pause" : "Play")
                    GlyphKey(icon: "forward.end.fill", label: "Next", key: "next", size: 48)
                    Spacer(minLength: 0)
                    Text("−" + Self.clock(music.duration - now)).font(Mint.font(12)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 12).frame(height: 74)
            }
        }
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: Mint.radius))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        .animation(.easeOut(duration: 0.26), value: tint)
        .task(id: music.art) {
            if let u = URL(string: music.art), let i = await ImageStore.shared.load(u) { tint = CoverTint.of(i) } else { tint = Mint.band }
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
        VStack(spacing: 12) {
            // Another app's video outranks a song left paused in Mint.
            if let m = music, !otherAppIsActive {
                Art(url: URL(string: m.art)) { i in i.resizable().scaledToFit() } placeholder: { Mint.band }
                    .aspectRatio(1, contentMode: .fit).frame(maxWidth: size == .regular ? 280 : 190).clipShape(RoundedRectangle(cornerRadius: Mint.radius))
                Text(m.title).font(Mint.font(26, weight: 300)).lineLimit(2).multilineTextAlignment(.center)
                Text([m.artist, m.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(Mint.font(14)).opacity(0.7).lineLimit(1)
                ControlBand(music: m)
                Button("Show on TV") { model.post("music-now", say: "Showing on TV") }.font(Mint.font(13)).buttonStyle(.plain).opacity(0.8)
            } else if let s = model.status?.session {
                Image(systemName: s.playing ? "play" : "pause").font(.system(size: 44, weight: .light)).padding(.top, 20)
                Text(s.description.first ?? "Playing").font(Mint.font(22, weight: 300)).lineLimit(2)
                Text(model.status?.apps?.first { $0.pkg == s.pkg }?.name ?? s.pkg).font(Mint.font(14)).opacity(0.7)
            } else {
                Image(systemName: "music.note").font(.system(size: 44, weight: .light)).opacity(0.4).padding(.vertical, 30)
            }
        }
        .frame(maxWidth: .infinity)
    }
    var send: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlickCard()
            RowTitle("Play on TV")
            HStack(spacing: 6) {
                ForEach([("Song", "song"), ("Album", "album"), ("Playlist", "playlist"), ("Artist", "artist"), ("Station", "station")], id: \.1) { k in
                    Button(k.0) { kind = k.1 }.font(Mint.font(14, weight: kind == k.1 ? 500 : 400, condensed: true)).buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 7)
                        .background(kind == k.1 ? Mint.band : .clear, in: RoundedRectangle(cornerRadius: Mint.radius))
                }
            }
            TextField("What should play?", text: $query).font(Mint.font(16, weight: 300)).padding(12).background(Mint.plane, in: RoundedRectangle(cornerRadius: Mint.radius)).autocorrectionDisabled()
                .onSubmit { if !query.isEmpty { model.post("music", ["query": query, "kind": kind], say: "Sent to Mint Music"); query = "" } }
            Button("Shuffle") { model.post("music", ["query": query, "kind": kind, "shuffle": true], say: "Shuffling on the TV"); query = "" }.font(Mint.font(14)).buttonStyle(.plain).disabled(query.isEmpty).opacity(query.isEmpty ? 0.4 : 1)
        }
    }
    var body: some View {
        Group {
            if size == .regular {
                FoldSplit { ScrollView { now.padding(20) } } right: { ScrollView { send.padding(20) } }
            } else {
                ScrollView { VStack(spacing: 24) { now; send }.padding(14) }
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
            VStack(alignment: .leading, spacing: 0) {
                Art(url: URL(string: film.poster)) { i in i.resizable().scaledToFill() } placeholder: { Mint.banner }
                    .frame(width: 117, height: 176).clipped()
                VStack(alignment: .leading, spacing: 1) {
                    Text(film.title).font(Mint.font(13.4)).lineLimit(1)
                    if !film.note.isEmpty { Text(film.note).font(Mint.font(10.8)).opacity(0.7).lineLimit(1) }
                }
                .padding(.horizontal, 7).frame(width: 117, height: 44, alignment: .leading).background(Mint.band)
            }
            .clipShape(RoundedRectangle(cornerRadius: Mint.radius))
        }.buttonStyle(.plain).accessibilityLabel(film.title)
    }
}
struct FilmRow: View {
    let title: String, films: [Film]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowTitle(title).padding(.leading, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) { ForEach(films) { FilmCard(film: $0) } }.padding(.horizontal, 20).scrollTargetLayout()
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 117, maximum: 117), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) { ForEach(films) { FilmCard(film: $0) } }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}
struct FilmsTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.horizontalSizeClass) private var size
    var body: some View {
        Group {
            if size == .regular {
                FoldSplit { FilmGrid(title: "Friends", films: model.friends) } right: { FilmGrid(title: "Watchlist", films: model.watchlist) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Mint.rowGap) {
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
