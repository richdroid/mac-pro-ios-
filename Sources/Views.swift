import Charts
import SwiftUI

@main
struct MacProApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    init() { AlertWatch.shared.install() }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(model.liveStore)
                .preferredColorScheme(.dark)   // black, like the machine and the web dashboard
                .onChange(of: phase) { _, p in
                    if p == .active { model.start() } else { model.stop() }
                    #if os(iOS)
                    if p == .background { AlertWatch.shared.scheduleRefresh() }
                    #endif
                }
                .onAppear {
                    model.start(); openScreenIfAsked(); AlertWatch.shared.askOnce(); TabTour.run([0, 1, 2, 3, 4, 5, 9]) { model.tab = $0 }
                    if let id = AlertWatch.pending { openAlert(id) }
                }
                .onReceive(NotificationCenter.default.publisher(for: AlertWatch.openAlert)) { n in openAlert(n.object as? String ?? "") }
                .onReceive(NotificationCenter.default.publisher(for: ScreenRequest.notification)) { _ in openScreenIfAsked() }
                .onOpenURL { if $0.host == "tab", let t = Int($0.lastPathComponent) { model.tab = t } }
        }
        #if os(iOS)
        // iOS decides when, and may not for hours. The banner on Status is always current.
        .backgroundTask(.appRefresh(AlertWatch.refreshID)) {
            await AlertWatch.shared.backgroundCheck()
            AlertWatch.shared.scheduleRefresh()
        }
        #endif
    }
    // A tapped notification opens where its problem can be dealt with: a waiting session on its own page.
    private func openAlert(_ id: String) {
        AlertWatch.pending = nil
        if id.hasPrefix("session:") { model.openSession(key: String(id.dropFirst(8))) } else { model.tab = 0 }
    }
    private func openScreenIfAsked() {
        if ScreenRequest.wanted || UserDefaults.standard.bool(forKey: "openScreen") { ScreenRequest.wanted = false; model.screenOpen = true }
    }
}

enum Side { case all, left, right }
extension View {
    @ViewBuilder func screenCover<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}
#if canImport(UIKit)
let groupedBackground = Color(uiColor: .systemGroupedBackground)
#else
let groupedBackground = Color.gray.opacity(0.1)
#endif
// One corner for every card the app draws itself, the same as the system's own list cards beside them.
let cardRadius: CGFloat = 26
let cardFill = Color(white: 0.11)

// A card that gives under the finger, as system rows highlight.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// A failure, said under the control that caused it.
struct FailText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}

// System tabs and navigation get Liquid Glass and move to the Duo's right edge by themselves.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("accent") private var accent = "blue"
    @AppStorage("celsius") private var celsius = false
    @State private var resets: [Int: Int] = [:]
    // A new colour redraws the other tabs; Settings, where it was picked, stays put so the swatch can animate.
    func key(_ t: Int) -> String { "\(accent)-\(resets[t, default: 0])" }
    var body: some View {
        PaneReader {
            TabView(selection: TabReset.binding($model.tab) { t in
                // Back to the tab's own start: anything opened on it closes, and it's rebuilt at the top.
                if t == 0 { model.history = nil; model.processes = nil }
                if t == 2 { model.sessionScreen = nil }
                resets[t, default: 0] += 1
            }) {
                Tab(value: 0) { Screen(tab: 0, title: "Status") { StatusTab($0, side: $1) }.id(key(0)) } label: { tabLabel("Status", "gauge.with.dots.needle.33percent") }
                Tab(value: 1) { Screen(tab: 1, title: "Apps") { AppsTab($0, side: $1) }.id(key(1)) } label: { tabLabel("Apps", "square.grid.2x2") }
                Tab(value: 2) { Screen(tab: 2, title: "Claude") { ClaudeTab($0, side: $1) }.id(key(2)) } label: { tabLabel("Claude", asset: "ClaudeTab") }
                Tab(value: 3) { Screen(tab: 3, title: "Usage") { UsageTab($0, side: $1) }.id(key(3)) } label: { tabLabel("Usage", "chart.bar") }
                Tab(value: 4) { Screen(tab: 4, title: "Updates", listed: false) { UpgradeTab($0, side: $1) }.id(key(4)) } label: { tabLabel("Updates", "arrow.up.circle") }
                Tab(value: 5) { Screen(tab: 5, title: "Control") { ControlTab($0, side: $1) }.id(key(5)) } label: { tabLabel("Control", "display") }
                // Last, so it sits at the foot of the side bar.
                Tab(value: 9) { MacSettings().id(resets[9, default: 0]) } label: { tabLabel("Settings", "gearshape") }
            }
            .tint(macBlue)
            .onChange(of: model.tab) { _, t in UserDefaults.standard.set(t, forKey: "tab") }
        }
        .onAppear { MacPrefs.shareWithWidgets() }
        .onChange(of: accent) { _, _ in MacPrefs.shareWithWidgets() }
        .onChange(of: celsius) { _, _ in MacPrefs.shareWithWidgets() }
        .screenCover(isPresented: $model.screenOpen) { NavigationStack { RemoteScreenView(model: model) } }
        .sheet(isPresented: $model.signInSheet) { SignInView().environmentObject(model) }
        // Up here, so unfolding doesn't close it and lose what's typed.
        .sheet(isPresented: $model.signingIn) {
            LoginSheet { u, p in
                let filled = u.isEmpty ? p : u + "\t" + p
                return await model.runSealed("type-text", secret: filled, extra: ["enter": true])
            }
        }
    }
}

// The Mac reports some states in capitals or lower case; the app says them one way.
func sentenceCase(_ t: String) -> String { t.prefix(1).uppercased() + t.dropFirst().lowercased() }

// Can't reach the Mac, or it wants its code: said once at the top of every tab, each with what to do about it.
struct Notice: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var retrying = false
    var body: some View {
        if model.needsSignIn {
            VStack(alignment: .leading, spacing: 10) {
                Label("Sign in needed", systemImage: "lock.fill").font(.body.weight(.semibold)).foregroundStyle(.orange)
                Text(model.address.isEmpty ? "Add the Mac’s address to connect." : "The Mac wants its access code for this address.").font(.footnote).foregroundStyle(.secondary)
                Button("Sign in") { model.signInSheet = true }.buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        } else if let p = model.problem {
            VStack(alignment: .leading, spacing: 10) {
                Label(p, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                HStack(spacing: 10) {
                    Button("Open Tailscale") { if let u = URL(string: "tailscale://") { openURL(u) } }.buttonStyle(.bordered)
                    Button {
                        Task { retrying = true; await model.refresh(); retrying = false }
                    } label: {
                        if retrying { ProgressView().frame(minWidth: 70) } else { Text("Try again").frame(minWidth: 70) }
                    }
                    .buttonStyle(.bordered).disabled(retrying)
                }
            }
            .padding(.vertical, 4)
        }
    }
    static func shows(_ model: AppModel) -> Bool { model.needsSignIn || model.problem != nil }
}

// Shared frame for each tab: a large title, the notice above, and pull to refresh. Updates draws its own page, so its
// header can stay put while the log scrolls.
struct Screen<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.paneLayout) private var panes
    let tab: Int
    let title: String
    let listed: Bool
    let content: (Status, Side) -> Content
    init(tab: Int, title: String, listed: Bool = true, @ViewBuilder content: @escaping (Status, Side) -> Content) {
        self.tab = tab; self.title = title; self.listed = listed; self.content = content
    }
    @ViewBuilder var connecting: some View {
        if !Notice.shows(model) { HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) } }
    }
    func list(_ side: Side) -> some View {
        ScrollViewReader { proxy in
            List {
                if side != .right, Notice.shows(model) { Section { Notice() } }
                if let s = model.status { content(s, side) }
                else if side != .right, !Notice.shows(model) { Section { connecting } }
            }
            // One gap between the blocks on Status, where they sit on the page's own background.
            .listSectionSpacing(tab == 0 ? .custom(28) : .default)
            .refreshable { await model.refresh() }
            .contentMargins(.top, 4, for: .scrollContent)
            .task {
                // The build's shot of Status scrolled down to the dials and the disk.
                guard tab == 0, side != .left, model.pose == "scrolled" else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                proxy.scrollTo("temps", anchor: .top)
            }
        }
    }
    func page(_ side: Side) -> some View {
        VStack(spacing: 12) {
            if side != .right, Notice.shows(model) {
                Notice().frame(maxWidth: .infinity, alignment: .leading).padding(16).background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            }
            if let s = model.status { content(s, side) }
            else if side != .right { connecting.frame(maxHeight: .infinity) }
        }
    }
    var body: some View {
        NavigationStack {
            Group {
                if listed {
                    if panes { FoldSplit { list(.left) } right: { list(.right) }.navigationBarTitleDisplayMode(.inline) }
                    else { list(.all) }
                } else {
                    if panes { FoldSplit { page(.left) } right: { page(.right) }.navigationBarTitleDisplayMode(.inline) }
                    else { page(.all) }
                }
            }
            .background(groupedBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationDestination(item: tab == 0 ? $model.history : Binding<HistoryMetric?>.constant(nil)) { HistoryView(metric: $0) }
            .navigationDestination(item: tab == 2 ? $model.sessionScreen : Binding<Status.Session?>.constant(nil)) { SessionTerminal(session: $0) }
        }
    }
}

struct StateRow: View {
    let label: String; let good: Bool; let value: String
    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) { Circle().fill(good ? Color.green : Color.red).frame(width: 9, height: 9); Text(value) }
        }
    }
}

// The web dashboard's tile: a label, a big number and a line you can drag along to read the past.
struct WebTile: View {
    let title: String, value: String, detail: String
    var spark: [Double] = []
    var top: Double?
    var read: (Double) -> String = { _ in "" }
    var open: () -> Void = {}
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                // Only the figure animates as it changes; the little chart just steps along, which costs nothing.
                Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: value)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if spark.count > 1 {
                    // Only a picture here: a touch on it belongs to the page's scrolling or opens the full history.
                    SparkLine(values: spark, top: top)
                        .frame(height: 42).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Show the past 24 hours", open)
    }
}

struct LiveTiles: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LiveStore
    let s: Status
    var body: some View {
        let cpu = store.live?.cpu ?? s.cpu, mem = store.live?.mem ?? s.mem, net = store.live?.net ?? s.net, h = store.live?.hist ?? s.hist, load = store.live?.load ?? s.load
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                WebTile(title: "CPU", value: "\(cpu.total)%", detail: String(format: "Load %.2f", load.first ?? 0), spark: h.cpu, top: 100, read: { "\(Int($0))%" }, open: { model.history = .cpu })
                WebTile(title: "Memory", value: Format.bytes(mem.used), detail: "of \(Format.bytes(mem.total))", spark: h.mem, top: 100, read: { "\(Int($0))%" }, open: { model.history = .memory })
            }
            HStack(spacing: 12) {
                WebTile(title: "Download", value: Format.rate(net.rxRate), detail: net.kind, spark: h.rx, read: Format.rate, open: { model.history = .download })
                WebTile(title: "Upload", value: Format.rate(net.txRate), detail: net.ip, spark: h.tx, read: Format.rate, open: { model.history = .upload })
            }
        }
    }
}

// One dial per sensor: the number and how far the ticks reach say it all.
struct TempDials: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LiveStore
    let s: Status
    var body: some View {
        let temps = store.live?.temps ?? s.temps ?? []
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 12, alignment: .top)], spacing: 16) {
            ForEach(temps) { t in
                VStack(spacing: 6) {
                    ArcGauge(Heat.level(t.c), heat: true, ticks: 32, length: 7, width: 2.2) {
                        Text("\(Heat.shown(t.c))°").font(.system(.body).weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                    }
                    Text(t.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.history = .temperature(t.name) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.vertical, 6)
    }
}

struct Hero: View {
    @EnvironmentObject var model: AppModel
    let s: Status
    var body: some View {
        VStack(spacing: 2) {
            Image("MacPro").resizable().scaledToFit().frame(height: 148)
                .background(RadialGradient(colors: [.white.opacity(0.18), .clear], center: .center, startRadius: 4, endRadius: 96).frame(width: 190, height: 190))
                .accessibilityLabel("Mac Pro, Late 2013")
            Text("Mac Pro").font(.system(size: 28, weight: .bold)).padding(.top, 6)
            Text("Late 2013 · macOS \(s.macos) · up \(Format.span(s.uptime))").font(.subheadline).foregroundStyle(.secondary)
            HeroChips(alerts: s.alerts ?? [], offline: model.stale, route: model.route, pulse: model.pulse).padding(.top, 9)
        }
        .frame(maxWidth: .infinity)
    }
}

// The machine's health, from its alerts alone, and how the phone is reaching it. Offline, only how long ago it last answered.
struct HeroChips: View {
    let alerts: [Status.Alert]
    let offline: Bool
    let route: String
    @ObservedObject var pulse: Pulse
    func chip<D: View>(@ViewBuilder _ dot: () -> D, _ text: String) -> some View {
        HStack(spacing: 6) { dot(); Text(text).lineLimit(1) }
            .font(.footnote.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 5).background(Color(white: 0.16), in: Capsule())
    }
    var health: (Color, String) {
        if alerts.isEmpty { return (.green, "All systems go") }
        return (alerts.contains { $0.level == "critical" } ? .red : .orange, "Needs attention")
    }
    var body: some View {
        if offline {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                chip({ Circle().fill(Color.gray).frame(width: 9, height: 9) }, pulse.lastFresh.map { "Last seen \(Format.ago(ms: $0.timeIntervalSince1970 * 1000))" } ?? "Not reached yet")
            }
        } else {
            HStack(spacing: 8) {
                chip({ Circle().fill(health.0).frame(width: 9, height: 9) }, health.1)
                // The dot beats each time the Mac answers.
                chip({
                    Circle().fill(Color.green).frame(width: 9, height: 9)
                        .keyframeAnimator(initialValue: 1.0, trigger: pulse.beats) { dot, k in dot.scaleEffect(k).opacity(2 - k) } keyframes: { _ in
                            KeyframeTrack {
                                CubicKeyframe(1.45, duration: 0.18)
                                CubicKeyframe(1.0, duration: 0.42)
                            }
                        }
                }, "Live · \(route)")
            }
        }
    }
}

// The things reached for most, one tap from the top of the app. Done shows as a tick on the button; a problem, under it.
struct QuickActions: View {
    @EnvironmentObject var model: AppModel
    @State private var done: Set<String> = []
    @State private var fails: [String: String] = [:]
    @State private var successes = 0
    func succeed(_ id: String) {
        fails[id] = nil; done.insert(id); successes += 1
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); done.remove(id) }
    }
    func fail(_ id: String, _ text: String) {
        fails[id] = text
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if fails[id] == text { fails[id] = nil } }
    }
    func button(_ id: String, _ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { face(id, icon, title) }.buttonStyle(.plain)
    }
    func face(_ id: String, _ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: done.contains(id) ? "checkmark" : icon).font(.system(size: 20))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 52).background(Color(white: 0.16), in: Circle())
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            if let f = fails[id] {
                Text(f).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            button("screen", "macwindow", "Screen") { model.screenOpen = true }
            DisplayHoldButton()
            button("copy", "square.and.arrow.down", "Copy from Mac") {
                fails["copy"] = nil
                Task {
                    guard let t = try? await model.api.clipboard() else { fail("copy", "Can’t reach the Mac"); return }
                    if t.isEmpty { fail("copy", "The Mac’s clipboard is empty"); return }
                    #if canImport(UIKit)
                    UIPasteboard.general.string = t
                    #endif
                    succeed("copy")
                }
            }
            button("send", "square.and.arrow.up", "Send to Mac") {
                fails["send"] = nil
                #if canImport(UIKit)
                let t = UIPasteboard.general.string ?? ""
                #else
                let t = ""
                #endif
                Task {
                    if t.isEmpty { fail("send", "Nothing copied on this iPhone"); return }
                    do { try await model.api.setClipboard(t); succeed("send") } catch { fail("send", "Can’t reach the Mac") }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: fails)
        .animation(.easeOut(duration: 0.2), value: done)
        .sensoryFeedback(trigger: successes) { _, _ in MacPrefs.haptics ? .impact(weight: .light) : nil }
    }
}

struct StatusTab: View {
    @EnvironmentObject var model: AppModel
    // What the page shows, chosen in Settings.
    @AppStorage("showQuick") private var showQuick = true
    @AppStorage("showTemps") private var showTemps = true
    @AppStorage("showDisk") private var showDisk = true
    @AppStorage("showAccess") private var showAccess = true
    @AppStorage("showThisMac") private var showThisMac = true
    @AppStorage("showProcesses") private var showProcesses = true
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    // Rows that sit on the page's background, spaced by the one section gap alone.
    let bare = EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
    // The figures, dimmed while they're only the last ones the Mac sent.
    @ViewBuilder var graphics: some View {
        let dim = model.stale ? 0.5 : 1
        Section { LiveTiles(s: s).opacity(dim) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        if showTemps, let temps = s.temps, !temps.isEmpty {
            Section("Temperatures") { TempDials(s: s).opacity(dim).id("temps") }
        }
        if showDisk {
            Section("Disk") {
                Button { model.history = .disk } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(Format.bytes(s.disk.free)) free").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        Text("\(Format.bytes(s.disk.used)) used of \(Format.bytes(s.disk.total))").font(.footnote).foregroundStyle(.secondary)
                        ProgressView(value: s.disk.used, total: s.disk.total).tint(s.disk.used / max(s.disk.total, 1) > 0.9 ? .red : macBlue).padding(.top, 8)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .opacity(dim)
                }
                .buttonStyle(PressStyle())
            }
        }
    }
    @ViewBuilder var text: some View {
        AlertSettings()
        if showAccess {
            Section("Remote access") {
                StateRow(label: "Remote control", good: s.claude.remoteControl, value: s.claude.remoteControl ? "Running" : "Stopped")
                StateRow(label: "Desktop app", good: s.claude.desktop, value: s.claude.desktop ? "Running" : "Stopped")
                StateRow(label: "Tailscale", good: s.tailscale.state == "Running", value: s.tailscale.state == "Running" ? "Connected" : "Off")
                StateRow(label: "Public link", good: s.publicLinkActive, value: s.publicLinkActive ? "Active" : s.publicUrl.isEmpty ? "Off" : "Down")
                StateRow(label: "Screen Sharing", good: s.sharing.vnc, value: s.sharing.vnc ? "On" : "Off")
                StateRow(label: "SSH", good: s.sharing.ssh, value: s.sharing.ssh ? "On" : "Off")
            }
        }
        if showThisMac {
            Section("This Mac") {
                LabeledContent("Model", value: s.model)
                LabeledContent("Processor", value: s.cpuModel.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "CPU ", with: ""))
                LabeledContent("Tailnet", value: s.tailscale.name ?? "Not signed in")
                Button("Change connection") { model.signInSheet = true }
            }
        }
        if showProcesses {
            Section("Top processes") {
                ForEach(s.procs) { p in LabeledContent(p.name, value: String(format: "%.0f%% · %.1f%% mem", p.cpu, p.mem)) }
                NavigationLink("All processes") { ProcessesView(first: .cpu) }
            }
        }
    }
    // Folded, one column in the approved order. Open, the machine and its actions on the left with the settings under
    // them, and the figures on the right, where they're all in view at once.
    var body: some View {
        if side != .right {
            if let alerts = s.alerts, !alerts.isEmpty { AlertBanner(alerts: alerts) }
            Section { Hero(s: s) }.listRowBackground(Color.clear).listRowInsets(bare).listRowSeparator(.hidden)
            if showQuick { Section { QuickActions() }.listRowBackground(Color.clear).listRowInsets(bare).listRowSeparator(.hidden) }
        }
        if side != .left { graphics }
        if side != .right { text }
    }
}

struct AppsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var pending: PendingQuit?
    @State private var alert: String?
    struct PendingQuit: Identifiable { let app: Status.App; let force: Bool; var id: String { "\(app.pid)\(force)" } }
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    var body: some View {
        if side != .right {
            if let seed = s.iosApps { SeedSection(seed: seed) }
        }
        if side != .left {
            Section("Open on the Mac (\(s.apps.count))") {
                ForEach(s.apps) { a in
                    VStack(alignment: .leading) {
                        Text(a.name)
                        Text(String(format: "%.0f%% CPU · %@", a.cpu ?? 0, Format.bytes(a.mem ?? 0))).font(.footnote).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Force Quit", role: .destructive) { pending = .init(app: a, force: true) }
                        Button("Quit") { pending = .init(app: a, force: false) }.tint(.orange)
                    }
                }
            }
            Section {
                Menu {
                    ForEach(s.installed, id: \.self) { name in Button(name) { Task { alert = await model.run("app-open", ["name": name]) } } }
                } label: { Label("Launch another app", systemImage: "plus.square.on.square") }
            } footer: { Text("Swipe an open app to quit it.") }
            // Asked from a swipe, which leaves nothing to point at, so it's a plain question in the middle.
            .alert(pending.map { ($0.force ? "Force quit " : "Quit ") + $0.app.name + "?" } ?? "", isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                if let p = pending {
                    Button(p.force ? "Force Quit" : "Quit", role: .destructive) { Task { alert = await model.run(p.force ? "app-kill" : "app-quit", ["pid": p.app.pid]) } }
                    Button("Cancel", role: .cancel) {}
                }
            } message: { if pending?.force == true { Text("Unsaved work is lost.") } }
            .alert("That did not work", isPresented: .init(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("OK") {} } message: { Text(alert ?? "") }
        }
    }
}

struct ClaudeTab: View {
    @EnvironmentObject var model: AppModel
    @State private var confirm = false
    @State private var restarting: String?
    @State private var sessionNote: String?
    @State private var rcFail: String?
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    func doRestart(_ x: Status.Session) async {
        guard let key = x.key else { return }
        sessionNote = nil
        restarting = key; defer { restarting = nil }
        do {
            let running = try await model.api.restartSession(key)
            // Back running speaks for itself in the row; only a session that couldn't start needs a word.
            sessionNote = running ? nil : "It will start when the Mac can reach Claude. It tries every two minutes."
        } catch { sessionNote = error.localizedDescription }
        await model.refresh()
    }
    // Sessions are what this tab is for, so they come first, and get the left pane when the Duo is open.
    var body: some View {
        if side != .right {
            Section("Sessions on this Mac (\(s.claude.sessions.count))") {
                if s.claude.sessions.isEmpty { Text("None running").foregroundStyle(.secondary) }
                ForEach(s.claude.sessions) { x in
                    let row = SessionRow(session: x, working: restarting != nil && restarting == x.key, restart: { Task { await doRestart(x) } })
                    // The whole row opens its page, on this tab's own stack, with Back where the system puts it.
                    if row.canOpen { NavigationLink { SessionTerminal(session: x) } label: { row } } else { row }
                }
                if let sessionNote { FailText(sessionNote) }
            }
        }
        if side != .left {
            Section {
                StateRow(label: "Remote control", good: s.claude.remoteControl, value: s.claude.remoteControl ? "Running" : "Stopped")
                StateRow(label: "Auto-restart", good: s.claude.keepAlive, value: s.claude.keepAlive ? "Armed" : "Off")
                StateRow(label: "Desktop app", good: s.claude.desktop, value: s.claude.desktop ? "Running" : "Stopped")
                LabeledContent("Version", value: s.claude.version.replacingOccurrences(of: " (Claude Code)", with: ""))
                LabeledContent("Service", value: sentenceCase(s.claude.service ?? "Unknown"))
                Link(destination: URL(string: "https://claude.ai/code")!) {
                    HStack { Text("Open in the Claude app"); Spacer(); Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                }
                // Each question hangs off the button that asked it, so it points at what was tapped.
                Button("Restart remote control") { confirm = true }
                    .confirmationDialog("Restart remote control?", isPresented: $confirm, titleVisibility: .visible) {
                        Button("Restart", role: .destructive) {
                            rcFail = nil
                            Task { rcFail = await model.run("rc-restart") }
                        }
                    } message: { Text("Connected sessions drop briefly, then reconnect.") }
                if let rcFail { FailText(rcFail) }
            }
        }
    }
}

// Model ids as people say them: "claude-opus-4-6" is Opus 4.6.
func modelName(_ id: String) -> String {
    let parts = id.lowercased().replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
    guard let family = parts.first(where: { ["opus", "sonnet", "haiku", "fable", "instant"].contains($0) }) else { return id }
    let numbers = parts.filter { $0.count <= 2 && Int($0) != nil }
    return family.prefix(1).uppercased() + family.dropFirst() + (numbers.isEmpty ? "" : " " + numbers.joined(separator: "."))
}
// How long until something starts again, said the same way on every dial.
func resetsIn(_ ms: Double) -> String {
    let left = ms / 1000 - Date().timeIntervalSince1970
    return left <= 0 ? "Reset" : "Resets in " + Format.span(left)
}

struct UsageTab: View {
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    var u: Status.Usage { s.usage }
    func limit(_ title: String, _ pct: Double?, _ resets: Double?) -> some View {
        let now = Date().timeIntervalSince1970 * 1000
        let over = (resets ?? .infinity) <= now
        let live = !over && pct != nil
        let v = pct ?? 0
        return VStack(spacing: 6) {
            ArcGauge(live ? v / 100 : 0, tint: v > 90 ? .red : v > 75 ? .orange : macBlue, ticks: 36, length: 9, width: 2.6) {
                Text(live ? "\(Int(v.rounded()))%" : "–").font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            }
            .frame(maxWidth: 110)
            Text(title).font(.footnote.weight(.medium))
            Text(over ? "Reset" : live ? (resets.map(resetsIn) ?? "") : "No reading").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    var models: [(key: String, value: Status.ModelTally)] { u.week.models.filter { $0.value.tokens > 0 }.sorted { $0.value.tokens > $1.value.tokens } }
    var body: some View {
        if side != .right {
            Section {
                // Only the limits Claude reports. It has stopped sending a 5-hour one for this plan; it shows again if that returns.
                HStack(alignment: .top, spacing: 16) {
                    if u.plan?.fiveHour != nil { limit("5 hours", u.plan?.fiveHour, u.plan?.fiveHourResets) }
                    limit("This week", u.plan?.sevenDay, u.plan?.sevenDayResets)
                }
                .padding(.vertical, 4)
            } header: { Text("Plan limits") } footer: {
                if let p = u.plan { Text("Updated \(Format.ago(ms: p.at))") }
            }
            APIUsageSection(usage: s.apiUsage)
            Section("Tokens per hour, last 24 hours") {
                VStack(alignment: .leading) {
                    Text(Format.count(u.day.tokens)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("\(u.day.messages.formatted()) replies on this Mac").font(.footnote).foregroundStyle(.secondary)
                    Chart(u.hours) { h in
                        BarMark(x: .value("Hour", Date(timeIntervalSince1970: h.t / 1000), unit: .hour), y: .value("Tokens", h.tokens), width: .ratio(0.7))
                            .foregroundStyle(macBlue).clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                    .frame(height: 90)
                }
            }
        }
        if side != .left {
            Section {
                LabeledContent("Last 5 hours", value: Format.count(u.fiveHours.tokens))
                LabeledContent("Last 7 days", value: Format.count(u.week.tokens))
            } header: { Text("Tokens on this Mac") } footer: { Text("Covers Claude Code and Cowork sessions on this Mac, not claude.ai or other devices.") }
            if !models.isEmpty {
                Section("By model, last 7 days") {
                    ForEach(models, id: \.key) { name, v in
                        LabeledContent(modelName(name), value: "\(Format.count(v.tokens)) tokens · \(v.messages.formatted()) replies")
                    }
                }
            }
        }
    }
}

// What the API key has cost this billing period, as a dial against a monthly budget drawn like the plan limits above
// it, with today and the week beside it.
struct APIUsageSection: View {
    @EnvironmentObject var model: AppModel
    let usage: Status.APIUsage?
    @State private var setup = false
    // Watched, so a new budget in Settings shows on the dial at once.
    @AppStorage("apiBudget") private var savedBudget = 200.0
    // Whole dollars once it's big enough that cents would crowd the dial.
    static func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 100 ? 0 : 2))) }
    var budget: Double { savedBudget > 0 ? savedBudget : MacPrefs.apiBudget }
    func figure(_ title: String, _ s: Status.APIUsage.Spend?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(s.map { Self.money($0.cost) } ?? "–").font(.title2.weight(.semibold)).monospacedDigit()
            Text("\(Format.count(s?.tokens ?? 0)) tokens").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Until the credit renews: the Mac says when (the 19th), and older Macs fall back to the month's end.
    var resets: String {
        if let r = usage?.renewsAt { return resetsIn(r) }
        guard let end = Calendar.current.dateInterval(of: .month, for: Date())?.end else { return "" }
        return resetsIn(end.timeIntervalSince1970 * 1000)
    }
    func block(_ u: Status.APIUsage) -> some View {
        let spent = u.month?.cost ?? 0, v = spent / budget
        return HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 6) {
                ArcGauge(min(v, 1), tint: v > 0.9 ? .red : v > 0.75 ? .orange : macBlue, ticks: 36, length: 9, width: 2.6) {
                    Text(u.month.map { Self.money($0.cost) } ?? "–").font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                        .minimumScaleFactor(0.7).lineLimit(1).padding(.horizontal, 10)
                }
                .frame(maxWidth: 110)
                Text("of \(Self.money(budget))").font(.footnote.weight(.medium))
                Text(resets).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 14) { figure("Today", u.today); figure("This week", u.week) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
    // Before a key: the same dial, empty and dimmed, so the section keeps its shape, and the whole of it adds the key.
    var empty: some View {
        Button { setup = true } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 6) {
                    ArcGauge(0, ticks: 36, length: 9, width: 2.6) {
                        Text("Add key").font(.footnote.weight(.semibold)).foregroundStyle(macBlue)
                    }
                    .frame(maxWidth: 110)
                    Text("Add your Admin key").font(.footnote.weight(.medium))
                    Text("of \(Self.money(budget)) a month").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 14) { figure("Today", nil); figure("This week", nil) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0.4)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Add your Admin key")
    }
    // A key Anthropic turned down needs adding again; anything else is just said.
    static func refused(_ e: String) -> Bool { ["refused", "invalid", "401", "unauthorized"].contains { e.localizedCaseInsensitiveContains($0) } }
    // The Mac's wording, without its "Couldn't read API usage:" lead-in, which the section header already says.
    static func plain(_ e: String) -> String {
        let t = e.replacingOccurrences(of: "Couldn’t read API usage: ", with: "").replacingOccurrences(of: "Couldn't read API usage: ", with: "")
        return "Couldn’t read the usage: " + t + "."
    }
    var body: some View {
        Section {
            if let u = usage, !u.configured {
                empty
            } else if let u = usage, let e = u.error, Self.refused(e) {
                Button { setup = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Anthropic turned the Admin key down.").font(.footnote).foregroundStyle(.red).lineLimit(3)
                            Text("Add it again").foregroundStyle(macBlue)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if let u = usage, let e = u.error, u.month == nil {
                Text(Self.plain(e)).font(.footnote).foregroundStyle(.red).lineLimit(3)
            } else if let u = usage {
                block(u)
                if let e = u.error { Text(Self.plain(e)).font(.footnote).foregroundStyle(.red).lineLimit(3) }
            } else {
                // Before the Mac's first read: the dial's shape, so nothing moves when the numbers come.
                block(.placeholder).redacted(reason: .placeholder)
            }
        } header: { Text("API usage") } footer: {
            if let at = usage?.at, usage?.configured == true { Text("Updated \(Format.ago(ms: at))") }
        }
        .sheet(isPresented: $setup) { APIKeySetup().environmentObject(model) }
        .task {
            // The build's shot of the sheet.
            if model.pose == "api-sheet" { try? await Task.sleep(nanoseconds: 1_200_000_000); setup = true }
        }
    }
}
extension Status.APIUsage {
    static var placeholder: Status.APIUsage {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Status.APIUsage.self, from: Data(#"{"configured":true,"month":{"cost":12.4,"tokens":1200000},"week":{"cost":4.1,"tokens":400000},"today":{"cost":0.8,"tokens":90000}}"#.utf8))
    }
    // For the build's shots: a reading taken a few minutes ago, part way through a period that renews on the 19th.
    static var sample: Status.APIUsage {
        var u = placeholder
        let now = Date().timeIntervalSince1970 * 1000
        u.month = .init(cost: 41.2, tokens: 3_900_000); u.week = .init(cost: 9.8, tokens: 920_000); u.today = .init(cost: 1.6, tokens: 140_000)
        u.at = now - 180_000; u.renewsAt = now + 15.5 * 86_400_000; u.periodStart = now - 15 * 86_400_000
        return u
    }
}
// Giving the Mac the Admin key that reads the API's costs. It goes straight to the Mac, sealed, and the phone forgets it.
struct APIKeySetup: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saving = false
    @State private var failure: String?
    func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !saving else { return }
        key = ""
        saving = true; failure = nil
        Task {
            // The Mac checks it, keeps it in its keychain and reads the usage at once, or says in a line why not.
            let err = await model.runSealed("api-admin-key", secret: k)
            saving = false
            if let err { failure = err } else { dismiss() }
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Not a password to iOS, so it never offers to save it.
                    SecureField("Admin key", text: $key).textContentType(.oneTimeCode).autocorrectionDisabled().submitLabel(.done).onSubmit(save)
                    if let failure { FailText(failure) }
                } footer: { Text("Made in the Claude Console under an organization. It goes to the Mac’s keychain and isn’t kept on this phone.") }
            }
            .navigationTitle("API usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { key = ""; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// The Updates page: where the machine stands, pinned, with the log scrolling on its own underneath.
struct UpgradeTab: View {
    @EnvironmentObject var model: AppModel
    @State private var fail: String?
    @State private var agentFail: String?
    @State private var agentPassword = ""
    @State private var confirmRun = false
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    var onTahoe: Bool { (Int(s.macos.split(separator: ".").first ?? "") ?? 0) >= 26 }
    var headline: String {
        s.upgrade.installed ? (s.upgrade.status.isEmpty ? "Starting…" : sentenceCase(s.upgrade.status)) : onTahoe ? "On Tahoe" : "Waiting for your password to start"
    }
    var oclp: String { s.upgrade.state["oclp_tag"] ?? s.oclp.version }
    // A seal for how it stands: done, working, or something to look at.
    var seal: (String, Color) {
        let t = s.upgrade.status.lowercased()
        if t.contains("fail") || t.contains("error") || t.contains("stuck") { return ("exclamationmark.triangle.fill", .orange) }
        if !s.upgrade.installed { return onTahoe ? ("checkmark.seal.fill", .green) : ("lock.fill", .secondary) }
        if t.isEmpty || ["install", "download", "patch", "running", "start", "wait", "check"].contains(where: t.contains) { return ("arrow.triangle.2.circlepath", macBlue) }
        return ("checkmark.seal.fill", .green)
    }
    var patched: String {
        s.oclp.patchedFor.isEmpty ? "No root patches yet" : "Root patched for \(s.oclp.patchedFor)" + (s.oclp.patchedAt.isEmpty ? "" : " · \(s.oclp.patchedAt)")
    }
    var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: seal.0).font(.system(size: 30)).foregroundStyle(seal.1).symbolRenderingMode(.hierarchical).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline).lineLimit(2)
                    Text("macOS \(s.macos) · OCLP \(oclp)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Text(patched).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if s.upgrade.installed {
                    Button { confirmRun = true } label: {
                        Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .accessibilityLabel("Run update check now")
                    .confirmationDialog("Run the update check now?", isPresented: $confirmRun, titleVisibility: .visible) {
                        Button("Run Now") { fail = nil; Task { fail = await model.run("upgrade-run") } }
                    } message: { Text("It may restart the Mac.") }
                }
            }
            if let fail { FailText(fail) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
    @ViewBuilder var agent: some View {
        if s.agentStale {
            VStack(alignment: .leading, spacing: 10) {
                Text("Update service improvements").font(.subheadline.weight(.semibold))
                Text("A newer version of the update service is ready. Your password is used once.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    SecureField("Mac password", text: $agentPassword).textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        agentFail = nil
                        let p = agentPassword; agentPassword = ""
                        Task { agentFail = await model.runSealed("agent-update", secret: p) }
                    }
                    .buttonStyle(.bordered).disabled(agentPassword.isEmpty)
                }
                if let agentFail { FailText(agentFail) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
    }
    var body: some View {
        switch side {
        case .all:
            VStack(spacing: 12) {
                summary
                agent
                UpdateLog(log: s.upgrade.log)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        case .left:
            ScrollView { VStack(spacing: 12) { summary; agent }.padding(.horizontal, 16) }
                .scrollBounceBehavior(.basedOnSize)
        case .right:
            VStack(alignment: .leading, spacing: 8) {
                Text("Log").font(.title3.weight(.semibold)).padding(.leading, 4)
                UpdateLog(log: s.upgrade.log)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }
}

// The update log, a line at a time, starting from its newest end. Errors read red and finished steps green.
struct UpdateLog: View {
    @EnvironmentObject var model: AppModel
    let log: String
    static let bad = try? NSRegularExpression(pattern: #"\b(error|errors|failed|failure|fatal|cannot|couldn[’']t|panic)\b|✗"#, options: .caseInsensitive)
    static let good = try? NSRegularExpression(pattern: #"\b(finished|complete|completed|succeeded|success|healthy|installed|nothing to do|up to date)\b|✓"#, options: .caseInsensitive)
    static func matches(_ r: NSRegularExpression?, _ s: String) -> Bool { r?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    static func tone(_ line: String) -> Color {
        if matches(bad, line) { return Color(red: 1, green: 0.42, blue: 0.4) }
        if matches(good, line) { return Color(red: 0.4, green: 0.86, blue: 0.5) }
        return Color(white: 0.85)
    }
    var body: some View {
        let lines = log.isEmpty ? ["No log yet"] : log.components(separatedBy: "\n")
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i].isEmpty ? " " : lines[i])
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(log.isEmpty ? Color.secondary : Self.tone(lines[i]))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(14)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: .infinity)
            .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .task {
                // The build's shot of the log read part way up.
                guard model.pose == "longlog" else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                proxy.scrollTo(lines.count / 2, anchor: .center)
            }
        }
    }
}
extension Status.Upgrade {
    // A night's worth of log, for the build's shot of it scrolled.
    static var longSample: Status.Upgrade {
        var lines: [String] = []
        for i in 0..<160 {
            let t = String(format: "%02d:%02d:%02d", 1 + i / 60, i % 60, (i * 7) % 60)
            switch i % 23 {
            case 5: lines.append("[\(t)] Download failed: the connection was reset. Trying again in 30 s.")
            case 11: lines.append("[\(t)] Root patch step finished. Nothing to do.")
            default: lines.append("[\(t)] Checking softwareupdate catalogue, pass \(i + 1) of 160")
            }
        }
        lines.append("[03:41:12] Update check finished. Nothing to do.")
        return Status.Upgrade(installed: true, status: "HEALTHY", state: ["oclp_tag": "3.0.0"], log: lines.joined(separator: "\n"))
    }
}

struct ControlTab: View {
    @EnvironmentObject var model: AppModel
    @State private var pressReturn = false
    @State private var appleEmail = ""
    @State private var applePassword = ""
    @State private var appleCode = ""
    @State private var confirmRestart = false
    @State private var confirmForget = false
    @State private var reveal = false
    @State private var restartService: Status.Service?
    // Each section's own failure, under the button that caused it, gone after a few seconds or the next action.
    @State private var fails: [String: String] = [:]
    @ObservedObject private var drafts = Drafts.shared
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }

    func act(_ key: String, _ work: @escaping () async -> String?) {
        fails = [:]
        Task {
            guard let e = await work() else { return }
            withAnimation { fails[key] = e }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if fails[key] == e { withAnimation { fails[key] = nil } }
        }
    }
    @ViewBuilder func failLine(_ key: String) -> some View { if let f = fails[key] { FailText(f) } }
    var locked: Bool { s.screen == "locked" }
    var displayOn: Bool { s.displayOn ?? (s.screen != "display off") }
    var typingReady: Bool { s.macLogin || s.typing == "trusted" }

    var body: some View {
        if side != .right {
            Section {
                if s.macLogin {
                    HStack(spacing: 8) {
                        Circle().fill(locked ? Color.orange : Color.green).frame(width: 9, height: 9)
                        Text(locked ? "Locked" : "Logged in")
                        Spacer()
                        Label(displayOn ? "Display on" : "Display off", systemImage: displayOn ? "sun.max.fill" : "moon.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if locked {
                        Button("Unlock") { act("unlock") { await model.run("mac-unlock") } }
                        failLine("unlock")
                    }
                    Button("Forget password", role: .destructive) { confirmForget = true }
                        .confirmationDialog("Forget the Mac’s password?", isPresented: $confirmForget, titleVisibility: .visible) {
                            Button("Forget Password", role: .destructive) { act("forget") { await model.run("mac-logout") } }
                        } message: { Text("After its next restart, the Mac waits at the login window until you log in again from here.") }
                    failLine("forget")
                } else {
                    SecureField("Mac password", text: $drafts.macPassword).textContentType(.password)
                    Button("Log in") {
                        let p = drafts.macPassword; drafts.macPassword = ""
                        act("login") { await model.runSealed("mac-login", secret: p) }
                    }.disabled(drafts.macPassword.isEmpty)
                    failLine("login")
                }
            } header: { Text(s.macLogin ? "Mac login" : "Log in to this Mac") } footer: {
                Text(s.macLogin ? "It stays logged in after restarts." : "Used once to log in, then saved in the Mac’s keychain. Forget password removes it.")
            }
            Section {
                Button("Open screen") { model.screenOpen = true }
            } header: { Text("Remote desktop") } footer: { Text("Tap to click · drag to move things · two fingers to scroll · pinch to zoom") }
            Section {
                Button { model.signingIn = true } label: { Label("Fill a saved login", systemImage: "key.fill") }
                    .disabled(!typingReady)
                    .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
                if typingReady {
                    HStack(spacing: 10) {
                        Group {
                            if reveal { TextField("Type a secret", text: $drafts.typed).autocorrectionDisabled().textInputAutocapitalization(.never) }
                            else { SecureField("Type a secret", text: $drafts.typed) }
                        }
                        Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel(reveal ? "Hide what’s typed" : "Show what’s typed")
                        Button {
                            // It's encrypted on this iPhone, and that has a size limit. Keep the text so nothing is lost.
                            guard drafts.typed.utf8.count <= 130 else { act("type") { "That’s too long to type in one go. Try under 130 characters." }; return }
                            let t = drafts.typed, enter = pressReturn
                            act("type") {
                                let e = await model.runSealed("type-text", secret: t, extra: ["enter": enter])
                                if e == nil { drafts.typed = "" }
                                return e
                            }
                        } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(drafts.typed.isEmpty ? Color.secondary : macBlue).disabled(drafts.typed.isEmpty).accessibilityLabel("Type on Mac")
                    }
                    Toggle("Press Return afterward", isOn: $pressReturn)
                    failLine("type")
                } else {
                    Text("Log in to this Mac above to use this.").foregroundStyle(.secondary)
                }
            } header: { Text("Passwords") } footer: {
                Text("Click the field on the Mac first. Saved logins stay on this iPhone behind Face ID.")
            }
        }
        if side != .left {
            // Installs and renewals live on the Apps tab; this only appears if Apple needs you again.
            if !s.ios.signedIn || s.ios.job.state == "code" {
                Section {
                    if s.ios.job.state == "code" {
                        TextField("6-digit code", text: $appleCode).textContentType(.oneTimeCode)
                        Button("Send code") {
                            let c = appleCode; appleCode = ""
                            act("apple") { await model.runSealed("ios-code", secret: c) }
                        }.disabled(appleCode.isEmpty)
                    } else {
                        TextField("Apple account email", text: $appleEmail).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Apple account password", text: $applePassword).textContentType(.password)
                        Button("Sign in to Apple") {
                            let secret = appleEmail + "\n" + applePassword; applePassword = ""
                            act("apple") { await model.runSealed("ios-login", secret: secret) }
                        }.disabled(appleEmail.isEmpty || applePassword.isEmpty)
                    }
                    failLine("apple")
                } header: { Text("Apple account") } footer: { Text("The Mac needs this to renew your apps.") }
            }
            if !s.publicUrl.isEmpty {
                Section {
                    if let u = URL(string: s.publicUrl) { Link("Open public link", destination: u) }
                } header: { Text("Public link") } footer: { Text("This address changes whenever the Mac restarts.") }
            }
            if let list = s.services {
                Section("Services") {
                    ForEach(list) { v in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(v.running ? Color.green : Color.red).frame(width: 9, height: 9)
                                Text(v.name)
                                Spacer()
                                // Only a service that's down has anything to restart.
                                if !v.running {
                                    Button("Restart") { restartService = v }.buttonStyle(.bordered).controlSize(.small)
                                        .confirmationDialog("Restart \(v.name)?", isPresented: .init(get: { restartService?.label == v.label }, set: { if !$0 { restartService = nil } }), titleVisibility: .visible) {
                                            Button("Restart") { act("svc:" + v.label) { await model.run("service-restart", ["label": v.label]) } }
                                        }
                                }
                            }
                            failLine("svc:" + v.label)
                        }
                    }
                }
            }
            Section("Connected devices") {
                if s.tailscale.peers.isEmpty { Text("No other devices yet").foregroundStyle(.secondary) }
                ForEach(s.tailscale.peers) { p in StateRow(label: p.name, good: p.online, value: p.os) }
            }
            Section("Power") {
                Button("Restart Mac", role: .destructive) { confirmRestart = true }
                    .confirmationDialog("Restart the Mac in one minute?", isPresented: $confirmRestart, titleVisibility: .visible) {
                        Button("Restart", role: .destructive) { act("restart") { await model.run("mac-restart") } }
                    }
                failLine("restart")
            }
        }
    }
}

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var note: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-mac.your-tailnet.ts.net", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Mac Pro address") } footer: { Text("Tailscale works from anywhere with the Tailscale app on and needs no code. The public link changes when the Mac restarts.") }
                Section {
                    SecureField("Access code", text: $code).textContentType(.oneTimeCode).textInputAutocapitalization(.characters)
                } header: { Text("Public link only") }
                if let note { Section { FailText(note) } }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Connect") { Task { await connect() } } }
            }
            .onAppear { address = model.address }
        }
    }
    func connect() async {
        note = nil
        model.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty {
            do { try await model.api.login(code: code) } catch { note = error.localizedDescription; return }
        }
        code = ""
        await model.refresh()
        if model.needsSignIn { note = "This address needs an access code." }
        else if model.problem != nil { note = "Can’t reach the Mac at this address." }
        else { dismiss() }
    }
}

// Apps the Mac can put on this iPhone, and what the iPhone itself reports having.
struct SeedSection: View {
    @EnvironmentObject var model: AppModel
    let seed: Status.SeedStatus
    @State private var picking = false
    @State private var linking = false
    @State private var link = ""
    @State private var uploading = false
    @State private var handing: String?
    // What went wrong, said in the row it happened to.
    @State private var rowFail: [String: String] = [:]
    @State private var addFail: String?
    @State private var shareFile: ShareFile?
    struct ShareFile: Identifiable { let url: URL; let app: String; var id: URL { url } }

    // Away from home, the Mac can't reach this iPhone, so SideStore installs it from here.
    func handOff(_ file: String, row: String) {
        Task {
            handing = file; defer { handing = nil }
            rowFail[row] = nil
            do { shareFile = ShareFile(url: try await model.api.download(file), app: row) }
            catch { rowFail[row] = error.localizedDescription }
        }
    }
    func daysLeft(_ a: Status.SeedApp) -> Int? {
        a.expires > 0 ? Int(ceil((a.expires / 1000 - Date().timeIntervalSince1970) / 86400)) : nil
    }
    func label(_ a: Status.SeedApp) -> (String, Color) {
        switch a.state {
        case "installing": return ("Installing…", .blue)
        case "waiting": return ("Build \(a.build) ready. Installs on home Wi-Fi.", .blue)
        case "failed": return ("Install failed", .red)
        case "missing": return ("Not on this iPhone", .orange)
        case "update": return ("Update ready: build \(a.build)", .blue)
        case "external": return ("Installed outside the Mac", .secondary)
        case "unknown": return ("Checking…", .secondary)
        default:
            if let days = daysLeft(a) { return (days > 0 ? "Up to date · \(days)d left" : "Expired", days > 1 ? .green : days > 0 ? .orange : .red) }
            return ("Up to date", .green)
        }
    }
    // Renewal is automatic, so a button only when something needs doing.
    func needsHand(_ a: Status.SeedApp) -> Bool {
        if ["missing", "update", "failed"].contains(a.state) { return true }
        if let d = daysLeft(a) { return d <= 1 }
        return false
    }
    var body: some View {
        Section {
            ForEach(seed.apps) { a in
                let l = label(a)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name)
                        Text(l.0).font(.footnote).foregroundStyle(l.1)
                        Text(a.version.isEmpty ? "Build \(a.phoneBuild.isEmpty ? a.build : a.phoneBuild)" : "\(a.version) (\(a.phoneBuild.isEmpty ? a.build : a.phoneBuild))").font(.caption2).foregroundStyle(.secondary)
                        if !a.message.isEmpty { Text(a.message).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                        if shareFile?.app == a.id { Text("Choose SideStore. LocalDevVPN needs to be on.").font(.caption2).foregroundStyle(.secondary) }
                        if let f = rowFail[a.id] { Text(f).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer()
                    if handing == a.file { ProgressView() }
                    else if a.own, needsHand(a) {
                        Button(seed.reachable ? (a.state == "missing" ? "Install" : a.state == "update" ? "Update" : "Renew") : "Via SideStore") {
                            rowFail[a.id] = nil
                            if seed.reachable { Task { rowFail[a.id] = await model.run("ios-seed", ["file": a.file]) } }
                            else { handOff(a.file, row: a.id) }
                        }.buttonStyle(.bordered).disabled(!seed.seeding.isEmpty || handing != nil)
                    }
                }
            }
            Menu {
                Button { picking = true } label: { Label("From Files", systemImage: "folder") }
                Button { linking = true } label: { Label("From a link", systemImage: "link") }
            } label: {
                HStack {
                    Label(uploading ? "Sending to the Mac…" : "Add an app", systemImage: "plus")
                    if uploading || seed.fetch?.state == "working" { Spacer(); ProgressView() }
                }
            }
            .disabled(uploading || seed.fetch?.state == "working")
            if let f = seed.fetch, f.state == "failed" { Text(f.message).font(.footnote).foregroundStyle(.red) }
            if let addFail { FailText(addFail) }
        } header: { Text("On this iPhone") } footer: {
            Text(seed.reachable ? "Connected to the Mac over \(seed.via == "USB" ? "USB" : "Wi-Fi"). New builds install by themselves." : "Away from the Mac. Install hands the app to SideStore, which installs it from anywhere. Everything else catches up on home Wi-Fi.")
        }
        .alert("Add from a link", isPresented: $linking) {
            TextField("https://…/app.ipa", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Get") {
                addFail = nil
                let u = link
                Task { addFail = await model.run("ios-fetch", ["url": u]); if addFail == nil { link = "" } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A link to an app’s .ipa file. The Mac downloads it and installs it here.") }
        .sheet(item: $shareFile) { ShareSheet(url: $0.url) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task {
                addFail = nil
                uploading = true; defer { uploading = false }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await model.api.upload(url)
                    await model.refresh()
                    // At home it installs by itself, and the new row says so.
                    if !seed.reachable { handOff(url.lastPathComponent, row: url.lastPathComponent) }
                }
                catch { addFail = error.localizedDescription }
            }
        }
    }
}

#if canImport(UIKit)
import UIKit
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheet: View { let url: URL; var body: some View { Text(url.lastPathComponent) } }
#endif
