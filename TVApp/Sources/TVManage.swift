import SwiftUI

// Run the TV from the phone, wherever the phone is: everything here goes through the Mac, over Tailscale.
struct ManageState: Decodable {
    struct App: Decodable, Identifiable {
        let pkg: String, name: String
        let removable: Bool, hasIcon: Bool
        var wide: Bool?
        var row: String?
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
    func load() async {
        guard let d = await TVBridge.data(TVBridge.url("/api/tv/manage"), timeout: 15), let s = try? JSONDecoder().decode(ManageState.self, from: d) else { failed = state == nil; return }
        state = s; failed = false
    }
    func set(_ key: String, _ value: Double) {
        state?.settings[key] = value
        send("setting", ["key": key, "value": value])
    }
    // One change at a time, in the order made, so an older one can never land after a newer one.
    private var queue: Task<Void, Never>?
    func send(_ path: String, _ body: [String: Any], then: (() async -> Void)? = nil) {
        let before = queue
        queue = Task {
            await before?.value
            do { try await TVBridge.post(path, body); await then?() }
            // No alert with only an OK in it: what changed snaps back to what the TV really has, with the buzz for no.
            catch {
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                #endif
                await load()
            }
        }
    }
}

// The pages opened from Settings, as values, so tapping the tab again can close them.
enum ManagePage: Hashable { case apps, settings, connection }
struct TVManageSections: View {
    @Environment(TVModel.self) var model
    var body: some View {
        Section {
            NavigationLink(value: ManagePage.apps) { Label("Apps on the TV", systemImage: "square.grid.2x2") }.id(ManagePage.apps)
            NavigationLink(value: ManagePage.settings) { Label("TV settings", systemImage: "slider.horizontal.3") }
            // The one TV setting he goes looking for, a tap away rather than two pages down.
            SettingsAction(title: "Screensaver", icon: "photo") { model.post("settings-page", ["page": "screensaver"]) }
        }
        .listRowBackground(TVLook.glassRow)
    }
}
// A row that does something on the TV, drawn like the rows that open a page: the icon in the accent, the words in white.
struct SettingsAction: View {
    @Environment(TVModel.self) var model
    let title: String, icon: String
    let action: () -> Void
    var body: some View {
        Button { model.tick(); action() } label: {
            // Outline, like the links beside it: a button row otherwise drew its glyph filled and larger (r26).
            Label { Text(title).foregroundStyle(.primary) } icon: { Image(systemName: icon).symbolVariant(.none) }
        }
    }
}

struct ManageAppsView: View {
    @ObservedObject var store: ManageStore
    @State private var removing: ManageState.App?
    func rows(_ s: ManageState) -> [String] {
        var seen = Set<String>()
        return s.apps.map { $0.row ?? "APPS" }.filter { seen.insert($0).inserted }
    }
    func rowTitle(_ row: String) -> String { row.prefix(1).uppercased() + row.dropFirst().lowercased() }
    func move(in row: String, from: IndexSet, to: Int) {
        guard var apps = store.state?.apps else { return }
        var inRow = apps.filter { ($0.row ?? "APPS") == row }
        inRow.move(fromOffsets: from, toOffset: to)
        // Slots this row already held are refilled in the new order, leaving the other rows where they were.
        var next = inRow.makeIterator()
        for i in apps.indices where (apps[i].row ?? "APPS") == row { if let a = next.next() { apps[i] = a } }
        store.state?.apps = apps
        store.send("app-layout", ["order": apps.map(\.pkg)])
    }
    func appRow(_ app: ManageState.App) -> some View {
        HStack(spacing: 12) {
            ZStack {
                TVLook.bannerTile
                if app.hasIcon, let u = TVBridge.url("/api/tv/icon?pkg=\(app.pkg)&v=2") {
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
    var body: some View {
        List {
            Section { PageHeading("Apps on the TV") }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            if let s = store.state {
                // An app can only move within its own row on the TV, so that's how they're grouped here.
                ForEach(rows(s), id: \.self) { row in
                    Section(rowTitle(row)) {
                        ForEach(s.apps.filter { ($0.row ?? "APPS") == row }) { app in
                            appRow(app)
                        }
                        .onMove(perform: s.canArrange ? { from, to in move(in: row, from: from, to: to) } : nil)
                    }
                }
                Section {
                    if s.canArrange {
                        Button("Back to automatic order") {
                            store.send("app-layout", ["order": [String]()]) { await store.load() }
                        }
                    }
                } footer: {
                    Text((s.canArrange ? "Tap Edit to drag apps into your order on the TV’s home screen. " : "") + "Swipe an app to delete it from the TV. Locked apps are what this setup depends on.")
                }
            } else if store.failed {
                ContentUnavailableView("Can’t reach the TV", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again."))
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .summonsBar()
        .topShade().topFade()
        .navigationTitle("Apps on the TV")
        // Edit sits in the page's bar, beside the way back.
        .barPage { if store.state?.canArrange == true { EditButton().font(.subheadline.weight(.semibold)).padding(.leading, 6).padding(.trailing, 16).frame(height: 50) } }
        .refreshable { await store.load() }
        .task { await store.load() }
        // Asked from a swipe, which leaves nothing to point at, so it's a plain question in the middle.
        .alert(removing.map { "Delete \($0.name) from the TV?" } ?? "", isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let app = removing {
                Button("Delete", role: .destructive) {
                    store.state?.apps.removeAll { $0.pkg == app.pkg }
                    store.send("uninstall", ["pkg": app.pkg]) { await store.load() }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { Text("Its data on the TV goes too. You’d have to install it again to get it back.") }
    }
}

struct ManageSettingsView: View {
    @ObservedObject var store: ManageStore
    static let sleep: [(String, Double)] = [("30 minutes", 1800000), ("1 hour", 3600000), ("2 hours", 7200000), ("3 hours", 10800000), ("4 hours", 14400000), ("8 hours", 28800000), ("Never", -1)]
    static let saver: [(String, Double)] = [("5 minutes", 300000), ("10 minutes", 600000), ("15 minutes", 900000), ("30 minutes", 1800000), ("1 hour", 3600000)]
    static let speed: [(String, Double)] = [("Off", 0), ("Fast", 0.5), ("Normal", 1)]
    static let pages: [(String, String, String)] = [("Screensaver", "screensaver", "photo.on.rectangle.angled"), ("Display and sound", "display", "tv"), ("Network", "network", "wifi"), ("Bluetooth and remotes", "bluetooth", "dot.radiowaves.left.and.right"), ("Apps", "apps", "square.grid.2x2"), ("All settings", "all", "gearshape")]
    func pick(_ title: String, _ key: String, _ options: [(String, Double)]) -> some View {
        Picker(title, selection: Binding(get: { store.state?.settings[key] ?? options[0].1 }, set: { store.set(key, $0) })) {
            ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
        }
    }
    var body: some View {
        Form {
            Section { PageHeading("TV settings") }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            if let s = store.state {
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
        .summonsBar()
        .topShade().topFade()
        .navigationTitle("TV settings")
        .barPage()
        .refreshable { await store.load() }
        .task { await store.load() }
    }
}
