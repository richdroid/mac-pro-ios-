import SwiftUI

@main
struct TVApp: App {
    @StateObject private var model = TVModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).preferredColorScheme(.dark).tint(Color.mintTV)
                .onChange(of: phase) { _, p in if p == .active { model.start() } else { model.stop() } }
                .onAppear { model.start() }
        }
    }
}
extension Color { static let mintTV = Color(red: 0.36, green: 0.92, blue: 0.72); static let cardTV = Color(white: 0.11) }

struct RootView: View {
    @EnvironmentObject var model: TVModel
    @State private var settings = false
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
            if !model.reachable || model.status?.online == false {
                Label(model.reachable ? "The Mac can’t reach the TV." : "Can’t reach the Mac. Is Tailscale on?", systemImage: "wifi.exclamationmark").font(.footnote.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8).background(.red.opacity(0.85), in: Capsule()).padding(.top, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast { Text(t).font(.footnote.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10).glassEffect().padding(.bottom, 24).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
    func page<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        NavigationStack {
            c().background(Color.black.ignoresSafeArea())
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

// MARK: - Remote
struct Mirror: View {
    @EnvironmentObject var model: TVModel
    var body: some View {
        ZStack {
            Color.cardTV
            if let m = model.mirror { Image(tv: m).resizable().scaledToFit() }
            else { ProgressView() }
        }
        .aspectRatio(16.0 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { model.mirrorOn = true; Task { await model.loadMirror() } }
        .onDisappear { model.mirrorOn = false }
    }
}

// Swipe in any direction to move, tap to select, hold to keep moving: like the real remote's touch surface.
struct TouchPad: View {
    @EnvironmentObject var model: TVModel
    @State private var moved = false
    @State private var repeatTask: Task<Void, Never>?
    @State private var last = CGSize.zero
    let step: CGFloat = 46
    func stopRepeat() { repeatTask?.cancel(); repeatTask = nil }
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color.cardTV)
            .overlay {
                Circle().stroke(.white.opacity(0.13), lineWidth: 1.5).padding(26)
                VStack { arrow("chevron.up"); Spacer(); arrow("chevron.down") }.padding(14)
                HStack { arrow("chevron.left"); Spacer(); arrow("chevron.right") }.padding(14)
                Circle().fill(Color(white: 0.17)).frame(width: 72, height: 72)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.translation.width - last.width, dy = v.translation.height - last.height
                    if abs(dx) > step || abs(dy) > step {
                        moved = true
                        model.key(abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up"))
                        last = v.translation
                    }
                }
                .onEnded { _ in
                    if !moved { model.key("ok") }
                    moved = false; last = .zero
                })
            .accessibilityLabel("Touch pad. Swipe to move, tap to select.")
    }
    func arrow(_ i: String) -> some View { Image(systemName: i).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.35)) }
}

struct RoundKey: View {
    @EnvironmentObject var model: TVModel
    let icon: String, label: String, key: String
    var size: CGFloat = 54
    var body: some View {
        Button { model.key(key) } label: {
            Image(systemName: icon).font(.system(size: size * 0.36)).frame(width: size, height: size)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel(label)
    }
}

struct RemoteTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.horizontalSizeClass) private var size
    @State private var typing = false
    @State private var text = ""
    var state: String {
        guard let s = model.status, s.online else { return "Connecting…" }
        return s.screen == "asleep" ? "TV is off" : s.screen == "screensaver" ? "Screensaver" : (s.apps?.first { $0.pkg == s.app }?.name ?? "TV is on")
    }
    var controls: some View {
        VStack(spacing: 16) {
            TouchPad().frame(height: 250)
            HStack { RoundKey(icon: "arrow.uturn.backward", label: "Back", key: "back"); Spacer(); RoundKey(icon: "house.fill", label: "Home", key: "home"); Spacer()
                Button { typing = true } label: { Image(systemName: "keyboard").font(.system(size: 19)).frame(width: 54, height: 54) }.buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Type on TV")
                Spacer(); RoundKey(icon: "line.3.horizontal", label: "Menu", key: "menu") }
            HStack { RoundKey(icon: "backward.end.fill", label: "Previous", key: "previous"); Spacer(); RoundKey(icon: "gobackward.10", label: "Rewind", key: "rewind"); Spacer(); RoundKey(icon: "playpause.fill", label: "Play or pause", key: "play", size: 64); Spacer(); RoundKey(icon: "goforward.10", label: "Fast forward", key: "forward"); Spacer(); RoundKey(icon: "forward.end.fill", label: "Next", key: "next") }
            HStack { RoundKey(icon: "speaker.minus.fill", label: "Volume down", key: "voldown"); Spacer(); RoundKey(icon: "speaker.slash.fill", label: "Mute", key: "mute"); Spacer(); RoundKey(icon: "speaker.plus.fill", label: "Volume up", key: "volup"); Spacer()
                RoundKey(icon: model.status?.screen == "asleep" ? "sun.max.fill" : "moon.fill", label: "Sleep or wake", key: model.status?.screen == "asleep" ? "wake" : "sleep") }
        }
    }
    var header: some View {
        HStack(spacing: 8) {
            Circle().fill(model.status?.online == true && model.status?.screen != "asleep" ? Color.mintTV : Color.gray).frame(width: 9, height: 9)
            Text(state).font(.headline).lineLimit(1)
            Spacer()
        }
    }
    var body: some View {
        Group {
            if size == .regular {
                FoldSplit {
                    ScrollView { VStack(alignment: .leading, spacing: 14) { header; Mirror() }.padding(14) }
                } right: {
                    ScrollView { controls.padding(14) }
                }
            } else {
                ScrollView { VStack(spacing: 14) { header; Mirror(); controls }.padding(14) }
            }
        }
        .alert("Type on TV", isPresented: $typing) {
            TextField("Text", text: $text)
            Button("Send") { model.post("text", ["text": text], say: "Typed"); text = "" }
            Button("Cancel", role: .cancel) { text = "" }
        } message: { Text("Goes into the box that’s focused on the TV. Not for passwords.") }
    }
}

// MARK: - Apps
struct AppCard: View {
    @EnvironmentObject var model: TVModel
    let app: TVStatus.App
    var current: Bool { model.status?.app == app.pkg }
    var body: some View {
        Button {
            model.tick(); model.post("open", ["pkg": app.pkg], say: "Opening \(app.name)")
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Color.cardTV
                    if app.hasIcon, let u = model.url("/api/tv/icon?pkg=\(app.pkg)") {
                        AsyncImage(url: u) { i in i.resizable().scaledToFit() } placeholder: { Text(app.name).font(.subheadline.weight(.semibold)) }
                    } else { Text(app.name).font(.subheadline.weight(.semibold)).padding(6).multilineTextAlignment(.center) }
                }
                .aspectRatio(16.0 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(current ? Color.mintTV : .clear, lineWidth: 2.5))
                Text(app.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.buttonStyle(.plain)
    }
}
struct AppsTab: View {
    @EnvironmentObject var model: TVModel
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                ForEach(model.status?.apps ?? []) { AppCard(app: $0) }
            }.padding(14)
        }
        .navigationTitle("Apps")
    }
}

// MARK: - Playing
struct PlayingTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.horizontalSizeClass) private var size
    @State private var query = ""
    @State private var kind = "song"
    var music: TVStatus.Music? { model.status?.music }
    var now: some View {
        VStack(spacing: 12) {
            if let m = music {
                AsyncImage(url: URL(string: m.art)) { i in i.resizable().scaledToFit() } placeholder: { Color.cardTV.overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)) }
                    .aspectRatio(1, contentMode: .fit).frame(maxWidth: 300).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(m.title).font(.title3.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text([m.artist, m.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let t = m.playing ? m.position + ctx.date.timeIntervalSince1970 * 1000 - m.sampledAt : m.position
                    ProgressView(value: min(max(t, 0), max(m.duration, 1)), total: max(m.duration, 1))
                }
                HStack(spacing: 18) {
                    RoundKey(icon: "backward.end.fill", label: "Previous", key: "previous")
                    RoundKey(icon: m.playing ? "pause.fill" : "play.fill", label: "Play or pause", key: "play", size: 68)
                    RoundKey(icon: "forward.end.fill", label: "Next", key: "next")
                }
                Button("Show Now Playing on TV") { model.post("music-now", say: "Showing on TV") }.font(.footnote)
            } else if let s = model.status?.session {
                Image(systemName: s.playing ? "play.circle.fill" : "pause.circle").font(.system(size: 60)).foregroundStyle(Color.mintTV)
                Text(s.description.first ?? "Playing").font(.title3.weight(.semibold)).lineLimit(2)
                Text(model.status?.apps?.first { $0.pkg == s.pkg }?.name ?? s.pkg).foregroundStyle(.secondary)
            } else {
                Text("Nothing playing").foregroundStyle(.secondary).padding(.vertical, 30)
            }
        }
        .frame(maxWidth: .infinity)
    }
    var send: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Play on TV").font(.headline)
            TextField("Song, album or artist", text: $query).padding(12).background(Color.cardTV, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).autocorrectionDisabled()
            Picker("Kind", selection: $kind) { Text("Song").tag("song"); Text("Album").tag("album"); Text("Playlist").tag("playlist") }.pickerStyle(.segmented)
            HStack {
                Button("Play") { model.post("music", ["query": query, "kind": kind], say: "Sending to Mint Music"); query = "" }.buttonStyle(.borderedProminent)
                Button("Shuffle") { model.post("music", ["query": query, "kind": kind, "shuffle": true], say: "Shuffling on the TV"); query = "" }.buttonStyle(.bordered)
            }.disabled(query.isEmpty)
        }
    }
    var body: some View {
        Group {
            if size == .regular {
                FoldSplit { ScrollView { now.padding(14) } } right: { ScrollView { send.padding(14) } }
            } else {
                ScrollView { VStack(spacing: 24) { now; send }.padding(14) }
            }
        }
        .navigationTitle("Playing")
    }
}

// MARK: - Films
struct FilmCard: View {
    @EnvironmentObject var model: TVModel
    let film: Film
    var body: some View {
        Button { model.tick(); model.post("film", ["slug": film.slug], say: "Opening on TV") } label: {
            VStack(alignment: .leading, spacing: 3) {
                AsyncImage(url: URL(string: film.poster)) { i in i.resizable().scaledToFill() } placeholder: { Color.cardTV.overlay(Text(film.title).font(.caption2).padding(6)) }
                    .aspectRatio(2.0 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(film.title).font(.caption.weight(.medium)).lineLimit(1)
                if !film.note.isEmpty { Text(film.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }.buttonStyle(.plain)
    }
}
struct FilmRow: View {
    let title: String, films: [Film]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) { ForEach(films) { FilmCard(film: $0).frame(width: 112) } }
            }
        }
    }
}
struct FilmsTab: View {
    @EnvironmentObject var model: TVModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !model.friends.isEmpty { FilmRow(title: "Friends", films: model.friends) }
                if !model.watchlist.isEmpty { FilmRow(title: "Watchlist", films: model.watchlist) }
                if model.friends.isEmpty && model.watchlist.isEmpty { Text("Loading from the TV…").foregroundStyle(.secondary) }
            }.padding(14)
        }
        .refreshable { await model.loadFilms() }
        .navigationTitle("Films")
    }
}
