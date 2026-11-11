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
// Settings' pages are drawn as glass sections of the app's own, not a Form's: iOS 26 rounds a one-row section into a
// capsule beside its rounded-rectangle neighbours, so one page had two kinds of edge (gate 276, Settings › Connection).
// Every glass section here has one corner, whatever it holds: 25 pt continuous with rows 20 pt in, as the Chumby app's
// SoloCard. A lone one-line row would still read as a capsule at that corner, so none is left alone: it joins the card it
// belongs with, or carries its note as a second line (the designer's cures, 2026-11-11).
enum GlassCard { static let radius: CGFloat = 25, inset: CGFloat = 20 }
struct GlassSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    // The room of a heading with none shown, so a card beside a headed one starts level with it (open flat).
    var headerRoom = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if header == nil && headerRoom { Text(" ").font(.footnote.weight(.semibold)).accessibilityHidden(true) }
            if let header {
                Text(header).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, GlassCard.inset)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        row
                        // The rule between rows starts under the words, as a list's does.
                        if i < rows.count - 1 { Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).padding(.leading, GlassRow.textInset) }
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: GlassCard.radius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: GlassCard.radius, style: .continuous))
            if let footer { Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, GlassCard.inset).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
// One row of a glass section: its glyph in the accent and its words, and a chevron when it opens a page here.
struct GlassRow: View {
    static let textInset: CGFloat = 64
    let title: String, icon: String?
    var opens = false
    // A row that does something on the TV says so in the accent, as a list's action rows do.
    var acts = false
    var body: some View {
        HStack(spacing: 0) {
            if let icon {
                Image(systemName: icon).symbolVariant(.none).font(.system(size: 19)).foregroundStyle(TVLook.accent)
                    .frame(width: 28).padding(.leading, GlassCard.inset).frame(width: Self.textInset, alignment: .leading)
            }
            Text(title).foregroundStyle(acts ? TVLook.accent : .primary).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, icon == nil ? GlassCard.inset : 0)
            Spacer(minLength: 8)
            if opens { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).padding(.trailing, GlassCard.inset) }
        }
        .padding(.vertical, 12).frame(minHeight: 52).contentShape(Rectangle())
    }
}
// Pressed, a row lights as a list's row does.
struct GlassRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(.white.opacity(configuration.isPressed ? 0.12 : 0))
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.25), value: configuration.isPressed)
    }
}

// Settings' own rows. Pages on this phone in one group; what happens on the TV in another, each said in full, so no row
// reads as a second door to a page above it (gate 276: "Screensaver" and "Home screen settings" were cyan action rows
// among page links, and "TV settings ›" beside "Home screen settings" read as two ways to one place).
struct TVManageSections: View {
    var level = false
    var body: some View {
        GlassSection(headerRoom: level) {
            NavigationLink(value: ManagePage.apps) { GlassRow(title: "Apps on the TV", icon: "square.grid.2x2", opens: true) }.id(ManagePage.apps)
            NavigationLink(value: ManagePage.settings) { GlassRow(title: "TV settings", icon: "slider.horizontal.3", opens: true) }
            NavigationLink(value: ManagePage.connection) { GlassRow(title: "Connection", icon: "network", opens: true) }
        }
        .buttonStyle(GlassRowPress())
    }
}
struct TVActionSections: View {
    @Environment(TVModel.self) var model
    var body: some View {
        GlassSection(header: "On the TV") {
            // The one TV setting he goes looking for, a tap away rather than two pages down.
            SettingsAction(title: "Start the screensaver", icon: "photo") { model.post("settings-page", ["page": "screensaver"]) }
            // The card's heading says where, so the words needn't (gate 276, second pass). Home screen settings is in TV
            // settings with the TV's other settings screens (third pass): what's here happens at once.
            SettingsAction(title: "Refresh recommendations", icon: "arrow.clockwise") { model.post("refresh") }
        }
    }
}
// A row that does something on the TV.
struct SettingsAction: View {
    @Environment(TVModel.self) var model
    let title: String, icon: String
    let action: () -> Void
    var body: some View {
        Button { model.tick(); action() } label: { GlassRow(title: title, icon: icon, acts: true) }
            .buttonStyle(GlassRowPress())
    }
}

struct ManageAppsView: View {
    @Environment(TVModel.self) private var model
    @ObservedObject var store: ManageStore
    @State private var removing: ManageState.App?
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif
    // Edit, then Done: the list's own edit mode, switched the way EditButton switches it, but as an item with a glyph, so
    // on the Duo it sits in the side bar under Back as the HIG orders a page's prominent action. EditButton is its words
    // alone, and iOS sets no title-only item vertically.
    @ViewBuilder var editToggle: some View {
        #if os(iOS)
        let on = editMode?.wrappedValue.isEditing == true
        Button { model.tick(); withAnimation(.snappy) { editMode?.wrappedValue = on ? .inactive : .active } } label: {
            Label(on ? "Done" : "Edit", systemImage: on ? "checkmark" : "pencil")
        }
        #else
        EmptyView()
        #endif
    }
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
                // Mint's tile as the Apps tab draws it, not the APK's home-made banner.
                if app.pkg == MintBanner.pkg { MintBanner() }
                else if app.hasIcon, let u = TVBridge.url("/api/tv/icon?pkg=\(app.pkg)&v=2") {
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
                        let inRow = s.apps.filter { ($0.row ?? "APPS") == row }
                        ForEach(inRow) { app in
                            // Edit shows the system's minus on the apps that can go, and nothing on the locked ones.
                            appRow(app).deleteDisabled(!app.removable).listRowBackground(TVLook.glassRow)
                        }
                        .onMove(perform: s.canArrange ? { from, to in move(in: row, from: from, to: to) } : nil)
                        // Deleting from Edit mode asks the same question as the swipe: Edit showed only drag handles, and
                        // the one way to delete was a swipe the footer had to explain (the 2026-11-10 logic pass).
                        .onDelete { at in if let i = at.first, inRow[i].removable { removing = inRow[i] } }
                    }
                }
                // Plain words under the groups, not a one-row glass section (iOS draws one as a capsule; gate 276).
                Section {
                    if s.canArrange {
                        Button("Back to automatic order") {
                            store.send("app-layout", ["order": [String]()]) { await store.load() }
                        }
                        .foregroundStyle(TVLook.accent)
                        .listRowBackground(Color.clear)
                    }
                } footer: {
                    Text((s.canArrange ? "Tap Edit to drag apps into your order on the TV’s home screen, or to delete one. " : "Swipe an app to delete it from the TV. ") + "Locked apps are what this setup depends on.")
                }
            } else if store.failed {
                ContentUnavailableView("Can’t reach the TV", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again."))
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        // The rows fade in over the spinner, and the one that's deleted goes with the list's own motion, rather than the
        // list redrawing in a frame (the 2026-11-10 motion pass).
        .settledAnimation(.easeOut(duration: 0.25), value: store.state == nil)
        .settledAnimation(.easeOut(duration: 0.25), value: store.state?.apps.map(\.pkg))
        // Its rows in the cards' glass, over the wall (set after the top fade, so the fade never blacks the wall out).
        .scrollContentBackground(.hidden)
        .summonsBar()
        .topShade().topFade()
        // The same wall as the rest of Settings, outside the fade's mask so its top isn't a black band.
        .background { Ambience() }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        // Edit is the system's own item in the page's bar: on the Duo, in the side bar under Back (folded, and open in
        // landscape), in the top bar open in portrait. It sat in a glass capsule of this page's own at the foot (ruling
        // 2026-11-10: a page's actions go through the system's bar, never a hand-built pill).
        .barPage()
        .toolbar { if store.state?.canArrange == true { ToolbarItem(placement: .primaryAction) { editToggle } } }
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
        HStack(spacing: 8) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Picker(title, selection: Binding(get: { store.state?.settings[key] ?? options[0].1 }, set: { store.set(key, $0) })) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.menu).labelsHidden().tint(.secondary)
        }
        .padding(.leading, GlassCard.inset).padding(.trailing, 8).frame(minHeight: 52)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading("TV settings").padding(.horizontal, 4)
                if let s = store.state {
                    GlassSection {
                        pick("TV sleeps after", "sleep_after", Self.sleep)
                        pick("Screensaver starts after", "screensaver_after", Self.saver)
                        pick("Animations", "animations", Self.speed)
                        Toggle("Turn off with the TV", isOn: Binding(get: { (s.settings["cec_auto_off"] ?? 0) == 1 }, set: { store.set("cec_auto_off", $0 ? 1 : 0) }))
                            .padding(.horizontal, GlassCard.inset).frame(minHeight: 52)
                    }
                    GlassSection(header: "Open on the TV", footer: "These open the TV’s own settings screens, to use with the remote.") {
                        ForEach(Self.pages, id: \.1) { page in
                            Button { store.send("settings-page", ["page": page.1]) } label: { GlassRow(title: page.0, icon: page.2, acts: true) }
                                .buttonStyle(GlassRowPress())
                        }
                        // The launcher's own settings: one more of the TV's settings screens, so here with the rest rather
                        // than a second door on Settings (gate 276, third pass).
                        Button { store.send("launcher-settings", [:]) } label: { GlassRow(title: "Home screen settings", icon: "rectangle.grid.1x2", acts: true) }
                            .buttonStyle(GlassRowPress())
                    }
                } else if store.failed {
                    ContentUnavailableView("Can’t reach the TV", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again."))
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 40)
                }
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
        }
        // As the apps page: the settings fade in over the spinner.
        .settledAnimation(.easeOut(duration: 0.25), value: store.state == nil)
        .summonsBar()
        .topShade().topFade()
        // The same wall as Settings and Connection, outside the fade's mask so its top isn't a black band.
        .background { Ambience() }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .barPage()
        .refreshable { await store.load() }
        .task { await store.load() }
    }
}
