import SwiftUI

// Run the TV from the phone, wherever the phone is: everything here goes through the Mac, over Tailscale.
struct ManageState: Decodable {
    struct App: Decodable, Identifiable {
        let pkg: String, name: String
        let removable: Bool, hasIcon: Bool
        var wide: Bool?
        var id: String { pkg }
    }
    var settings: [String: Double]
    var volume: Int?
    var volumeMax: Int?
    var apps: [App]
    var canArrange: Bool
}
@MainActor
final class ManageStore: ObservableObject {
    @Published var state: ManageState?
    @Published var failed = false
    @Published var note: String?
    func load() async {
        guard let d = await TVBridge.data(TVBridge.url("/api/tv/manage"), timeout: 15), let s = try? JSONDecoder().decode(ManageState.self, from: d) else { failed = state == nil; return }
        state = s; failed = false
    }
    func set(_ key: String, _ value: Double) {
        state?.settings[key] = value
        send("setting", ["key": key, "value": value])
    }
    func send(_ path: String, _ body: [String: Any], then: (() async -> Void)? = nil) {
        Task {
            do { try await TVBridge.post(path, body); await then?() }
            catch { note = "The TV didn’t get that."; await load() }
        }
    }
}

struct TVManageSections: View {
    @StateObject private var store = ManageStore()
    var body: some View {
        Section {
            NavigationLink { ManageAppsView(store: store) } label: { Label("Apps on the TV", systemImage: "square.grid.2x2") }
            NavigationLink { ManageSettingsView(store: store) } label: { Label("TV settings", systemImage: "slider.horizontal.3") }
        } footer: { Text("These work anywhere with Tailscale on, as long as the Mac is awake and can reach the TV.") }
    }
}

struct ManageAppsView: View {
    @ObservedObject var store: ManageStore
    @State private var removing: ManageState.App?
    var body: some View {
        List {
            if let s = store.state {
                Section {
                    ForEach(s.apps) { app in
                        HStack(spacing: 12) {
                            ZStack {
                                TVLook.bannerTile
                                if app.hasIcon, let u = TVBridge.url("/api/tv/icon?pkg=\(app.pkg)") {
                                    Art(url: u) { i in
                                        if app.wide == true { i.resizable().scaledToFill() } else { i.resizable().scaledToFit().padding(5) }
                                    } placeholder: { Color.clear }
                                }
                            }
                            .frame(width: 71, height: 40).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(app.name).lineLimit(1)
                            Spacer(minLength: 0)
                            if !app.removable { Image(systemName: "lock.fill").font(.footnote).foregroundStyle(.tertiary).accessibilityLabel("Can’t be removed") }
                        }
                        .swipeActions {
                            if app.removable { Button("Delete", role: .destructive) { removing = app } }
                        }
                    }
                    .onMove(perform: s.canArrange ? { from, to in
                        store.state?.apps.move(fromOffsets: from, toOffset: to)
                        store.send("app-layout", ["order": (store.state?.apps ?? []).map(\.pkg)])
                    } : nil)
                } footer: {
                    Text((s.canArrange ? "Drag to change the order on the TV’s home screen. " : "") + "Swipe an app to delete it from the TV. Locked apps are what this setup depends on.")
                }
            } else if store.failed {
                ContentUnavailableView("Can’t reach the TV", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again."))
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Apps on the TV")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if store.state?.canArrange == true { EditButton() } }
        .refreshable { await store.load() }
        .task { await store.load() }
        .confirmationDialog(removing.map { "Delete \($0.name) from the TV?" } ?? "", isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let app = removing {
                Button("Delete", role: .destructive) {
                    store.state?.apps.removeAll { $0.pkg == app.pkg }
                    store.send("uninstall", ["pkg": app.pkg]) { await store.load() }
                }
            }
        } message: { Text("Its data on the TV goes too. You’d have to install it again to get it back.") }
        .alert("That didn’t work", isPresented: .init(get: { store.note != nil }, set: { if !$0 { store.note = nil } })) { Button("OK") {} } message: { Text(store.note ?? "") }
    }
}

struct ManageSettingsView: View {
    @ObservedObject var store: ManageStore
    @State private var volume = 0.0
    @State private var dragging = false
    static let sleep: [(String, Double)] = [("30 minutes", 1800000), ("1 hour", 3600000), ("2 hours", 7200000), ("3 hours", 10800000), ("4 hours", 14400000), ("8 hours", 28800000), ("Never", -1)]
    static let saver: [(String, Double)] = [("5 minutes", 300000), ("10 minutes", 600000), ("15 minutes", 900000), ("30 minutes", 1800000), ("1 hour", 3600000)]
    static let speed: [(String, Double)] = [("Off", 0), ("Fast", 0.5), ("Normal", 1)]
    static let pages: [(String, String, String)] = [("Display", "display", "tv"), ("Sound", "sound", "speaker.wave.2"), ("Network", "network", "wifi"), ("Bluetooth and remotes", "bluetooth", "dot.radiowaves.left.and.right"), ("Apps", "apps", "square.grid.2x2"), ("All settings", "all", "gearshape")]
    func pick(_ title: String, _ key: String, _ options: [(String, Double)]) -> some View {
        Picker(title, selection: Binding(get: { store.state?.settings[key] ?? options[0].1 }, set: { store.set(key, $0) })) {
            ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
        }
    }
    var body: some View {
        Form {
            if let s = store.state {
                if let top = s.volumeMax, top > 0 {
                    Section("Volume") {
                        Slider(value: $volume, in: 0...Double(top), step: 1) { editing in
                            dragging = editing
                            if !editing { store.send("setting", ["key": "volume", "value": volume]) }
                        }
                        .accessibilityLabel("Volume")
                    }
                }
                Section {
                    pick("TV sleeps after", "sleep_after", Self.sleep)
                    pick("Screensaver starts after", "screensaver_after", Self.saver)
                    pick("Animations", "animations", Self.speed)
                    Toggle("Turn off with the TV", isOn: Binding(get: { (s.settings["cec_auto_off"] ?? 0) == 1 }, set: { store.set("cec_auto_off", $0 ? 1 : 0) }))
                }
                Section {
                    ForEach(Self.pages, id: \.1) { page in
                        Button { store.send("settings-page", ["page": page.1]) } label: { Label(page.0, systemImage: page.2) }
                    }
                } header: { Text("Open on the TV") } footer: { Text("These open the TV’s own settings screen, to use with the remote.") }
            } else if store.failed {
                ContentUnavailableView("Can’t reach the TV", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again."))
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("TV settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { await store.load() }
        .onChange(of: store.state?.volume) { _, v in if let v, !dragging { volume = Double(v) } }
        .alert("That didn’t work", isPresented: .init(get: { store.note != nil }, set: { if !$0 { store.note = nil } })) { Button("OK") {} } message: { Text(store.note ?? "") }
    }
}
