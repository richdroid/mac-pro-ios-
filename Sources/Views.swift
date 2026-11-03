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
                .onAppear { model.start(); openScreenIfAsked(); AlertWatch.shared.askOnce(); TabTour.run([0, 1, 2, 3, 4, 5, 9]) { model.tab = $0 } }
                .onReceive(NotificationCenter.default.publisher(for: AlertWatch.openStatus)) { _ in model.tab = 0 }
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

// System tabs and navigation get Liquid Glass and move to the Duo's right edge by themselves.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("accent") private var accent = "blue"
    @State private var resets: [Int: Int] = [:]
    var body: some View {
        PaneReader {
            TabView(selection: TabReset.binding($model.tab) { t in
                // Back to the tab's own start: anything opened on it closes, and it's rebuilt at the top.
                if t == 0 { model.history = nil; model.processes = nil; model.sessionScreen = nil }
                resets[t, default: 0] += 1
            }) {
                Tab(value: 0) { Screen(title: "Status") { StatusTab($0, side: $1) }.id(resets[0, default: 0]) } label: { tabLabel("Status", "gauge.with.dots.needle.33percent") }
                Tab(value: 1) { Screen(title: "Apps") { AppsTab($0, side: $1) }.id(resets[1, default: 0]) } label: { tabLabel("Apps", "square.grid.2x2") }
                Tab(value: 2) { Screen(title: "Claude") { ClaudeTab($0, side: $1) }.id(resets[2, default: 0]) } label: { tabLabel("Claude", asset: "ClaudeTab") }
                Tab(value: 3) { Screen(title: "Usage") { UsageTab($0, side: $1) }.id(resets[3, default: 0]) } label: { tabLabel("Usage", "chart.bar") }
                Tab(value: 4) { Screen(title: "Updates") { UpgradeTab($0, side: $1) }.id(resets[4, default: 0]) } label: { tabLabel("Updates", "arrow.up.circle") }
                Tab(value: 5) { Screen(title: "Control") { ControlTab($0, side: $1) }.id(resets[5, default: 0]) } label: { tabLabel("Control", "display") }
                // Last, so it sits at the foot of the side bar.
                Tab(value: 9) { MacSettings().id(resets[9, default: 0]) } label: { tabLabel("Settings", "gearshape") }
            }
            // A new colour is redrawn everywhere at once.
            .id(accent)
            .tint(macBlue)
            .onChange(of: model.tab) { _, t in UserDefaults.standard.set(t, forKey: "tab") }
        }
        .screenCover(isPresented: $model.screenOpen) { NavigationStack { RemoteScreenView(model: model) } }
        .sheet(isPresented: $model.needsSignIn) { SignInView().environmentObject(model) }
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

let tileColumns = [GridItem(.adaptive(minimum: 170), spacing: 18, alignment: .top)]

// Shared frame for each tab: a large title, the unreachable notice, and pull to refresh.
struct Screen<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.paneLayout) private var panes
    let title: String
    let content: (Status, Side) -> Content
    init(title: String, @ViewBuilder content: @escaping (Status, Side) -> Content) { self.title = title; self.content = content }
    func list(_ side: Side) -> some View {
        List {
            if side != .right, let p = model.problem { Section { Label(p, systemImage: "wifi.exclamationmark").foregroundStyle(.red) } }
            if let s = model.status { content(s, side) }
            else if side != .right, model.problem == nil { Section { HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) } } }
        }
        .refreshable { await model.refresh() }
        .contentMargins(.top, 4, for: .scrollContent)
    }
    var body: some View {
        NavigationStack {
            Group {
                if panes { FoldSplit { list(.left) } right: { list(.right) }.navigationBarTitleDisplayMode(.inline) }
                else { list(.all) }
            }
            .background(groupedBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationDestination(item: title == "Status" ? $model.history : Binding<HistoryMetric?>.constant(nil)) { HistoryView(metric: $0) }
            .navigationDestination(item: title == "Status" ? $model.sessionScreen : Binding<Status.Session?>.constant(nil)) { SessionTerminal(session: $0) }
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
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
    let s: Status
    var healthy: Bool { s.claude.remoteControl && (s.tailscale.state == "Running" || !s.publicUrl.isEmpty) && (s.alerts ?? []).isEmpty }
    var body: some View {
        VStack(spacing: 2) {
            Image("MacPro").resizable().scaledToFit().frame(height: 148)
                .background(RadialGradient(colors: [.white.opacity(0.18), .clear], center: .center, startRadius: 4, endRadius: 96).frame(width: 190, height: 190))
                .accessibilityLabel("Mac Pro, Late 2013")
            Text("Mac Pro").font(.system(size: 28, weight: .bold)).padding(.top, 6)
            Text("Late 2013 · macOS \(s.macos) · up \(Format.span(s.uptime))").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle().fill(healthy ? Color.green : Color.orange).frame(width: 9, height: 9)
                Text(healthy ? "All systems go" : "Needs attention")
            }
            .font(.footnote.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 5).background(Color(white: 0.16), in: Capsule()).padding(.top, 9)
        }
        .frame(maxWidth: .infinity)
    }
}

// The things reached for most, one tap from the top of the app.
struct QuickActions: View {
    @EnvironmentObject var model: AppModel
    @State private var toast: String?
    func button(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { face(icon, title) }.buttonStyle(.plain)
    }
    func face(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20)).frame(width: 52, height: 52).background(Color(white: 0.16), in: Circle())
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
    func say(_ t: String) {
        toast = t
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); toast = nil }
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                button("macwindow", "Screen") { model.screenOpen = true }
                DisplayHoldButton(say: say)
                button("square.and.arrow.down", "Copy from Mac") {
                    Task {
                        guard let t = try? await model.api.clipboard() else { say("Couldn’t reach the Mac"); return }
                        #if canImport(UIKit)
                        UIPasteboard.general.string = t
                        #endif
                        say(t.isEmpty ? "The Mac’s clipboard is empty" : "Copied from the Mac")
                    }
                }
                button("square.and.arrow.up", "Send to Mac") {
                    #if canImport(UIKit)
                    let t = UIPasteboard.general.string ?? ""
                    #else
                    let t = ""
                    #endif
                    Task {
                        if t.isEmpty { say("Nothing copied on this iPhone"); return }
                        do { try await model.api.setClipboard(t); say("On the Mac’s clipboard") } catch { say("Couldn’t reach the Mac") }
                    }
                }
            }
            if let toast { Text(toast).font(.footnote).foregroundStyle(.secondary).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
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
    var body: some View {
        if side != .right {
        if let alerts = s.alerts, !alerts.isEmpty { AlertBanner(alerts: alerts) }
        Section { Hero(s: s) }.listRowBackground(Color.clear).listRowSeparator(.hidden)
        if showQuick { Section { QuickActions() }.listRowBackground(Color.clear).listRowSeparator(.hidden) }
        Section { LiveTiles(s: s) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        if showTemps, let temps = s.temps, !temps.isEmpty {
            Section("Temperatures") { TempDials(s: s) }
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
            }
            .buttonStyle(.plain)
        }
        }
        }
        if side != .left {
        AlertSettings(clear: (s.alerts ?? []).isEmpty)
        if showAccess {
        Section("Remote access") {
            StateRow(label: "Claude remote control", good: s.claude.remoteControl, value: s.claude.remoteControl ? "Running" : "Stopped")
            StateRow(label: "Claude desktop (Dispatch)", good: s.claude.desktop, value: s.claude.desktop ? "Running" : "Stopped")
            StateRow(label: "Tailscale", good: s.tailscale.state == "Running", value: s.tailscale.state == "Running" ? "Connected" : "Off")
            StateRow(label: "Public link", good: !s.publicUrl.isEmpty, value: s.publicUrl.isEmpty ? "Off" : "Active")
            StateRow(label: "Screen Sharing", good: s.sharing.vnc, value: s.sharing.vnc ? "On" : "Off")
            StateRow(label: "SSH", good: s.sharing.ssh, value: s.sharing.ssh ? "On" : "Off")
        }
        }
        if showThisMac {
        Section("This Mac") {
            LabeledContent("Model", value: s.model)
            LabeledContent("Processor", value: s.cpuModel.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "CPU ", with: ""))
            LabeledContent("Tailnet", value: s.tailscale.name ?? "Not signed in")
            Button("Change connection") { model.needsSignIn = true }
        }
        }
        if showProcesses {
        Section("Top processes") {
            ForEach(s.procs) { p in LabeledContent(p.name, value: String(format: "%.0f%% · %.1f%% mem", p.cpu, p.mem)) }
            NavigationLink("All processes") { ProcessesView(first: .cpu) }
        }
        }
        }
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
        Section("Open apps (\(s.apps.count))") {
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
            } label: { Label("Open an app on the Mac", systemImage: "plus.square.on.square") }
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
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    func doRestart(_ x: Status.Session) async {
        guard let key = x.key else { return }
        restarting = key; defer { restarting = nil }
        do {
            let running = try await model.api.restartSession(key)
            // Back running speaks for itself in the row; only a session that couldn't start needs a word.
            sessionNote = running ? nil : "It will start when the Mac can reach Claude. It tries every two minutes."
        } catch { sessionNote = error.localizedDescription }
        await model.refresh()
    }
    var body: some View {
        if side != .right {
        Section("Claude") {
            StateRow(label: "Remote control", good: s.claude.remoteControl, value: s.claude.remoteControl ? "Running" : "Stopped")
            StateRow(label: "Auto-restart", good: s.claude.keepAlive, value: s.claude.keepAlive ? "Armed" : "Off")
            StateRow(label: "Desktop app", good: s.claude.desktop, value: s.claude.desktop ? "Running" : "Stopped")
            LabeledContent("Claude Code", value: s.claude.version.replacingOccurrences(of: " (Claude Code)", with: ""))
            LabeledContent("Claude service", value: sentenceCase(s.claude.service ?? "Unknown"))
            Link("Open Claude Code", destination: URL(string: "https://claude.ai/code")!)
            // Each question hangs off the button that asked it, so it points at what was tapped.
            Button("Restart remote control") { confirm = true }
                .confirmationDialog("Restart remote control?", isPresented: $confirm, titleVisibility: .visible) {
                    Button("Restart", role: .destructive) { Task { _ = await model.run("rc-restart") } }
                } message: { Text("Connected sessions drop briefly, then reconnect.") }
        }
        }
        if side != .left {
        Section("Sessions on this Mac (\(s.claude.sessions.count))") {
            if s.claude.sessions.isEmpty { Text("None running").foregroundStyle(.secondary) }
            ForEach(s.claude.sessions) { x in
                let row = SessionRow(session: x, working: restarting != nil && restarting == x.key, restart: { Task { await doRestart(x) } })
                // The whole row opens its screen as a page, with Back where the system puts it.
                if row.canOpen { NavigationLink { SessionTerminal(session: x) } label: { row } } else { row }
            }
            if let sessionNote { Text(sessionNote).font(.footnote).foregroundStyle(.secondary) }
        }
        }
    }
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
            Text(over ? "Reset" : live ? (resets.map { "in \(Format.span(($0 - now) / 1000))" } ?? "") : "No reading").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
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
            if let p = u.plan { Text("Reading \(Format.ago(ms: p.at)) from \(p.source). It updates with each response in a terminal Claude session.") }
        }
        APIUsageSection(usage: s.apiUsage)
        Section("Tokens per hour, last 24 hours") {
            VStack(alignment: .leading) {
                Text(Format.count(u.day.tokens)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("\(u.day.messages) responses on this Mac").font(.footnote).foregroundStyle(.secondary)
                Chart(u.hours) { h in
                    BarMark(x: .value("Hour", Date(timeIntervalSince1970: h.t / 1000), unit: .hour), y: .value("Tokens", h.tokens), width: .ratio(0.7))
                        .foregroundStyle(Color.accentColor).clipShape(RoundedRectangle(cornerRadius: 2))
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
            LabeledContent("Last 24 hours", value: Format.count(u.day.tokens))
            LabeledContent("Last 7 days", value: Format.count(u.week.tokens))
            LabeledContent("Cache, last 7 days", value: Format.count(u.week.cache))
        } header: { Text("Tokens on this Mac") } footer: { Text("Covers Claude Code and Cowork sessions on this Mac, not claude.ai or other devices.") }
        Section("By model, last 7 days") {
            ForEach(u.week.models.sorted { $0.value.tokens > $1.value.tokens }, id: \.key) { name, v in
                LabeledContent(name.replacingOccurrences(of: "claude-", with: ""), value: "\(Format.count(v.tokens)) tokens · \(v.messages) replies")
            }
        }
        }
    }
}

// What the API key has cost this month, as a dial against a monthly budget drawn like the plan limits above it, with
// today and the week beside it.
struct APIUsageSection: View {
    @EnvironmentObject var model: AppModel
    let usage: Status.APIUsage?
    @State private var setup = false
    // Watched, so a new budget in Settings shows on the dial at once.
    @AppStorage("apiBudget") private var savedBudget = 200.0
    // Whole dollars once it's big enough that cents would crowd the dial.
    static func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 100 ? 0 : 2))) }
    func figure(_ title: String, _ s: Status.APIUsage.Spend?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(s.map { Self.money($0.cost) } ?? "–").font(.title2.weight(.semibold)).monospacedDigit()
            Text("\(Format.count(s?.tokens ?? 0)) tokens").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Days until the month turns over, when the spend starts again.
    var resets: String {
        let cal = Calendar.current, now = Date()
        guard let start = cal.dateInterval(of: .month, for: now)?.end else { return "" }
        let left = start.timeIntervalSince(now)
        return "Resets in " + (left >= 86400 ? "\(Int((left / 86400).rounded(.up)))d" : Format.span(left))
    }
    func block(_ u: Status.APIUsage) -> some View {
        let budget = savedBudget > 0 ? savedBudget : MacPrefs.apiBudget, spent = u.month?.cost ?? 0, v = spent / budget
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
    func chevronRow<L: View>(@ViewBuilder _ label: () -> L) -> some View {
        Button { setup = true } label: {
            HStack {
                label()
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    // A key Anthropic turned down needs setting up again; anything else is just said.
    static func refused(_ e: String) -> Bool { ["refused", "invalid", "401", "unauthorized"].contains { e.localizedCaseInsensitiveContains($0) } }
    var body: some View {
        Section {
            if let u = usage, !u.configured {
                chevronRow { Text("Set up on the Mac") }
            } else if let u = usage, let e = u.error, Self.refused(e) {
                chevronRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Text("Set up again")
                    }
                }
            } else if let u = usage, let e = u.error, u.month == nil {
                Text(e).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            } else if let u = usage {
                block(u)
                if let e = u.error { Text(e).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            } else {
                // Before the Mac's first read: the dial's shape, so nothing moves when the numbers come.
                block(.placeholder).redacted(reason: .placeholder)
            }
        } header: { Text("API usage") } footer: {
            if let at = usage?.at, usage?.configured == true { Text("Reading \(Format.ago(ms: at)) from your Admin key.") }
        }
        .sheet(isPresented: $setup) { APIKeySetup().environmentObject(model) }
    }
}
extension Status.APIUsage {
    static var placeholder: Status.APIUsage {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Status.APIUsage.self, from: Data(#"{"configured":true,"month":{"cost":12.4,"tokens":1200000},"week":{"cost":4.1,"tokens":400000},"today":{"cost":0.8,"tokens":90000}}"#.utf8))
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
                    SecureField("Admin key", text: $key).textContentType(.password).autocorrectionDisabled().submitLabel(.done).onSubmit(save)
                    if let failure { Text(failure).font(.footnote).foregroundStyle(.red).lineLimit(2) }
                } footer: { Text("Made in the Claude Console under an organization. It goes to the Mac’s keychain and isn’t kept on this phone.") }
            }
            .navigationTitle("API Usage")
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

struct UpgradeTab: View {
    @EnvironmentObject var model: AppModel
    @State private var note: String?
    @State private var agentPassword = ""
    @State private var confirmRun = false
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    var onTahoe: Bool { (Int(s.macos.split(separator: ".").first ?? "") ?? 0) >= 26 }
    var body: some View {
        if side != .right {
        Section("macOS and OCLP") {
            Text(s.upgrade.installed ? (s.upgrade.status.isEmpty ? "Starting…" : sentenceCase(s.upgrade.status)) : onTahoe ? "On Tahoe" : "Waiting for your password to start").font(.headline)
            LabeledContent("Running", value: "\(s.macos) (\(s.build))")
            LabeledContent("OCLP", value: s.upgrade.state["oclp_tag"] ?? s.oclp.version)
            LabeledContent("Root patches for", value: s.oclp.patchedFor.isEmpty ? "None yet" : s.oclp.patchedFor)
            LabeledContent("Patched", value: s.oclp.patchedAt.isEmpty ? "Not yet" : s.oclp.patchedAt)
            if s.upgrade.installed {
                Button("Run update check now") { confirmRun = true }
                    .confirmationDialog("Run the update service now?", isPresented: $confirmRun, titleVisibility: .visible) {
                        Button("Run Now") { Task { note = await model.run("upgrade-run") } }
                    } message: { Text("It may restart the Mac.") }
            }
        }
        if s.agentStale {
            Section {
                SecureField("Mac password", text: $agentPassword)
                Button("Apply update") {
                    Task { note = await model.runSealed("agent-update", secret: agentPassword); agentPassword = "" }
                }.disabled(agentPassword.isEmpty)
            } header: { Text("Update service improvements") } footer: { Text("A newer version of the update service is ready. Your password is used once.") }
        }
        if let note { Section { Text(note) } }
        }
        if side != .left {
        Section("Log") {
            Text(s.upgrade.log.isEmpty ? "No log yet" : s.upgrade.log).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
        }
        }
    }
}

struct ControlTab: View {
    @EnvironmentObject var model: AppModel
    @State private var pressReturn = false
    @State private var appleEmail = ""
    @State private var applePassword = ""
    @State private var appleCode = ""
    @State private var confirmRestart = false
    @ObservedObject private var drafts = Drafts.shared
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }

    var body: some View {
        if side != .right {
        Section {
            StateRow(label: "Screen", good: s.screen != "locked", value: s.screen == "locked" ? "Locked" : s.screen == "display off" ? "Display off" : "Unlocked")
            if s.macLogin {
                if s.screen == "locked" { Button("Unlock") { Task { model.note = await model.run("mac-unlock") } } }
                Button("Forget password", role: .destructive) { Task { model.note = await model.run("mac-logout") } }
            } else {
                SecureField("Mac password", text: $drafts.macPassword).textContentType(.password)
                Button("Log in") {
                    Task { model.note = await model.runSealed("mac-login", secret: drafts.macPassword); drafts.macPassword = "" }
                }.disabled(drafts.macPassword.isEmpty)
            }
            if let note = model.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Log in to this Mac") } footer: {
            Text(s.macLogin ? "Logged in, and it stays that way after restarts." : "Used once to log in, then saved in the Mac’s keychain. Forget password removes it.")
        }
        Section {
            Button("Open screen") { model.screenOpen = true }
        } header: { Text("Remote desktop") } footer: { Text("Tap to click, pinch to zoom, and drag to scroll. Drag moves the view while zoomed.") }
        Section {
            Button { model.signingIn = true } label: { Label("Sign in on the Mac", systemImage: "key.fill") }.disabled(!(s.macLogin || s.typing == "trusted"))
            if s.macLogin || s.typing == "trusted" {
                HStack {
                    SecureField("Or type any text", text: $drafts.typed)
                    Button {
                        // It's encrypted on this iPhone, and that has a size limit. Keep the text so nothing is lost.
                        guard drafts.typed.utf8.count <= 130 else { model.note = "That’s too long to type in one go. Try under 130 characters."; return }
                        Task { model.note = await model.runSealed("type-text", secret: drafts.typed, extra: ["enter": pressReturn]); drafts.typed = "" }
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(drafts.typed.isEmpty ? Color.secondary : macBlue).disabled(drafts.typed.isEmpty).accessibilityLabel("Type on Mac")
                }
                Toggle("Press Return afterward", isOn: $pressReturn)
            } else {
                Text("Log in to this Mac above to use this.").foregroundStyle(.secondary)
            }
        } header: { Text("Sign-ins on the Mac") } footer: {
            Text("Click the field on the Mac first. Saved logins stay on this iPhone behind Face ID.")
        }
        }
        if side != .left {
        // Installs and renewals live on the Apps tab; this only appears if Apple needs you again.
        if !s.ios.signedIn || s.ios.job.state == "code" {
            Section {
                if s.ios.job.state == "code" {
                    TextField("6-digit code", text: $appleCode)
                    Button("Send code") { Task { model.note = await model.runSealed("ios-code", secret: appleCode); appleCode = "" } }.disabled(appleCode.isEmpty)
                } else {
                    TextField("Apple account email", text: $appleEmail).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Apple account password", text: $applePassword).textContentType(.password)
                    Button("Sign in to Apple") {
                        Task { model.note = await model.runSealed("ios-login", secret: appleEmail + "\n" + applePassword); applePassword = "" }
                    }.disabled(appleEmail.isEmpty || applePassword.isEmpty)
                }
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
                    HStack {
                        Circle().fill(v.running ? Color.green : Color.red).frame(width: 9, height: 9)
                        Text(v.name)
                        Spacer()
                        Button("Restart") { Task { model.note = await model.run("service-restart", ["label": v.label]) } }.buttonStyle(.bordered).controlSize(.small)
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
                    Button("Restart", role: .destructive) { Task { model.note = await model.run("mac-restart") } }
                }
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
                    SecureField("Access code", text: $code).textContentType(.password).textInputAutocapitalization(.characters)
                } header: { Text("Public link only") }
                if let note { Section { Text(note).foregroundStyle(.red) } }
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
        model.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty {
            do { try await model.api.login(code: code) } catch { note = error.localizedDescription; return }
        }
        code = ""
        await model.refresh()
        if model.needsSignIn { note = "This address needs an access code." } else { dismiss() }
    }
}

// Apps the Mac can put on this iPhone, and what the iPhone itself reports having.
struct SeedSection: View {
    @EnvironmentObject var model: AppModel
    let seed: Status.SeedStatus
    @State private var picking = false
    @State private var note: String?
    @State private var uploading = false
    @State private var link = ""
    @State private var handing: String?
    @State private var shareFile: ShareFile?
    struct ShareFile: Identifiable { let url: URL; var id: URL { url } }

    // Away from home, the Mac can't reach this iPhone, so SideStore installs it from here.
    func handOff(_ file: String) {
        Task {
            handing = file; defer { handing = nil }
            note = "Getting it from the Mac…"
            do { shareFile = ShareFile(url: try await model.api.download(file)); note = "Choose SideStore. LocalDevVPN needs to be on." }
            catch { note = error.localizedDescription }
        }
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
            if a.expires > 0 {
                let days = Int(ceil((a.expires / 1000 - Date().timeIntervalSince1970) / 86400))
                return (days > 0 ? "Up to date · \(days)d left" : "Expired", days > 1 ? .green : days > 0 ? .orange : .red)
            }
            return ("Up to date", .green)
        }
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
                    }
                    Spacer()
                    if a.own {
                        Button(seed.reachable ? (a.state == "missing" ? "Install" : a.state == "update" ? "Update" : "Renew") : "Via SideStore") {
                            if seed.reachable { Task { note = await model.run("ios-seed", ["file": a.file]) } }
                            else { handOff(a.file) }
                        }.buttonStyle(.bordered).disabled(!seed.seeding.isEmpty || handing != nil)
                    }
                }
            }
            HStack {
                TextField("Paste a link to an .ipa", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Get") { Task { note = await model.run("ios-fetch", ["url": link]); if note == nil { link = "" } } }
                    .buttonStyle(.bordered).disabled(link.isEmpty || seed.fetch?.state == "working")
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            if let f = seed.fetch, f.state != "idle" { Text(f.message).font(.footnote).foregroundStyle(f.state == "failed" ? .red : .secondary) }
            Button(uploading ? "Sending to the Mac…" : "Add an app (.ipa)") { picking = true }.disabled(uploading)
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("On this iPhone") } footer: {
            Text(seed.reachable ? "Connected to the Mac over \(seed.via == "USB" ? "USB" : "Wi-Fi"). New builds install by themselves." : "Away from the Mac. Install hands the app to SideStore, which installs it from anywhere. Everything else catches up on home Wi-Fi.")
        }
        .sheet(item: $shareFile) { ShareSheet(url: $0.url) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task {
                uploading = true; defer { uploading = false }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await model.api.upload(url)
                    await model.refresh()
                    if seed.reachable { note = "Sent to the Mac. It installs on this iPhone by itself within 5 minutes." }
                    else { handOff(url.lastPathComponent) }
                }
                catch { note = error.localizedDescription }
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
