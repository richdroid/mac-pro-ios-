import Charts
import SwiftUI

@main
struct MacProApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .onChange(of: phase) { _, p in if p == .active { model.start() } else { model.stop() } }
                .onAppear { model.start() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        // The system tab bar picks up Liquid Glass by itself on iOS 26 and later.
        TabView {
            Screen { StatusTab($0) }.tabItem { Label("Status", systemImage: "gauge.with.dots.needle.33percent") }
            Screen { AppsTab($0) }.tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            Screen { ClaudeTab($0) }.tabItem { Label("Claude", systemImage: "sparkle") }
            Screen { UsageTab($0) }.tabItem { Label("Usage", systemImage: "chart.bar") }
            Screen { UpgradeTab($0) }.tabItem { Label("Updates", systemImage: "arrow.up.circle") }
            Screen { ControlTab($0) }.tabItem { Label("Control", systemImage: "display") }
        }
        .modifier(AdaptiveTabs())
        .sheet(isPresented: $model.needsSignIn) { SignInView().environmentObject(model) }
    }
}

// Unfolded, the iPhone Duo's wide screen gets the system's adaptable tabs; folded stays a normal tab bar.
struct AdaptiveTabs: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.tabViewStyle(.sidebarAdaptable) } else { content }
    }
}

let tileColumns = [GridItem(.adaptive(minimum: 170), spacing: 18, alignment: .top)]

// Shared frame for each tab: a large title, the unreachable notice, and pull to refresh.
struct Screen<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @State private var settings = false
    let content: (Status) -> Content
    init(@ViewBuilder content: @escaping (Status) -> Content) { self.content = content }
    var body: some View {
        NavigationStack {
            List {
                if let p = model.problem { Section { Label(p, systemImage: "wifi.exclamationmark").foregroundStyle(.red) } }
                if let s = model.status { content(s) }
                else if model.problem == nil { Section { HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) } } }
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Mac Pro")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { settings = true } label: { Image(systemName: "gearshape") } } }
            .sheet(isPresented: $settings) { SignInView().environmentObject(model) }
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

struct Spark: View {
    let values: [Double]; var top: Double?
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("Sample", i), y: .value("Value", v)).foregroundStyle(Color.accentColor.opacity(0.15))
            LineMark(x: .value("Sample", i), y: .value("Value", v)).foregroundStyle(Color.accentColor).lineStyle(.init(lineWidth: 2))
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...(top ?? max(values.max() ?? 1, 1)))
        .frame(height: 40)
        .accessibilityLabel("Recent history")
    }
}

struct Tile: View {
    let title: String; let value: String; let detail: String; var spark: [Double] = []; var top: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            if spark.count > 1 { Spark(values: spark, top: top).padding(.top, 6) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Hero: View {
    @Environment(\.horizontalSizeClass) private var size
    let s: Status
    var healthy: Bool { s.claude.remoteControl && (s.tailscale.state == "Running" || !s.publicUrl.isEmpty) }
    var body: some View {
        let wide = size == .regular
        let art = Image("MacPro").resizable().scaledToFit().frame(height: wide ? 120 : 140).accessibilityLabel("Mac Pro, Late 2013")
        let text = VStack(alignment: wide ? .leading : .center, spacing: 2) {
            Text("Mac Pro").font(.title.bold())
            Text("Late 2013 · macOS \(s.macos) · up \(Format.span(s.uptime))").font(.subheadline).foregroundStyle(.secondary)
            Label(healthy ? "All systems go" : "Needs attention", systemImage: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium)).foregroundStyle(healthy ? Color.green : Color.orange).padding(.top, 6)
        }
        Group {
            if wide { HStack(spacing: 20) { art; text } } else { VStack(spacing: 2) { art; text } }
        }
        .frame(maxWidth: .infinity)
    }
}

struct StatusTab: View {
    @EnvironmentObject var model: AppModel
    let s: Status
    init(_ s: Status) { self.s = s }
    var body: some View {
        Section { Hero(s: s) }.listRowBackground(Color.clear)
        Section("Live") {
            LazyVGrid(columns: tileColumns, spacing: 18) {
                Tile(title: "CPU", value: "\(s.cpu.total)%", detail: String(format: "Load %.2f", s.load.first ?? 0), spark: s.hist.cpu, top: 100)
                Tile(title: "Memory", value: Format.bytes(s.mem.used), detail: "of \(Format.bytes(s.mem.total))", spark: s.hist.mem, top: 100)
                Tile(title: "Download", value: Format.rate(s.net.rxRate), detail: s.net.kind, spark: s.hist.rx)
                Tile(title: "Upload", value: Format.rate(s.net.txRate), detail: s.net.ip, spark: s.hist.tx)
            }
            .padding(.vertical, 4)
        }
        if let temps = s.temps, !temps.isEmpty {
            Section("Temperatures") {
                LazyVGrid(columns: tileColumns, spacing: 14) {
                    ForEach(temps) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.footnote).foregroundStyle(.secondary)
                            Text("\(Int(t.c.rounded()))°C").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(t.c >= 90 ? .red : t.c >= 75 ? .orange : .primary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.vertical, 4)
            }
        }
        Section("Disk") {
            VStack(alignment: .leading) {
                Text("\(Format.bytes(s.disk.free)) free").font(.title3.weight(.semibold))
                ProgressView(value: s.disk.used, total: s.disk.total)
                Text("\(Format.bytes(s.disk.used)) used of \(Format.bytes(s.disk.total))").font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section("Remote access") {
            StateRow(label: "Claude remote control", good: s.claude.remoteControl, value: s.claude.remoteControl ? "Running" : "Stopped")
            StateRow(label: "Claude desktop", good: s.claude.desktop, value: s.claude.desktop ? "Running" : "Stopped")
            StateRow(label: "Tailscale", good: s.tailscale.state == "Running", value: s.tailscale.state == "Running" ? "Connected" : "Off")
            StateRow(label: "Public link", good: !s.publicUrl.isEmpty, value: s.publicUrl.isEmpty ? "Off" : "Active")
            StateRow(label: "Screen Sharing", good: s.sharing.vnc, value: s.sharing.vnc ? "On" : "Off")
            StateRow(label: "SSH", good: s.sharing.ssh, value: s.sharing.ssh ? "On" : "Off")
        }
        Section("This Mac") {
            LabeledContent("Model", value: s.model)
            LabeledContent("Processor", value: s.cpuModel.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "CPU ", with: ""))
            LabeledContent("Tailnet", value: s.tailscale.name ?? "Not signed in")
            Button("Change connection") { model.needsSignIn = true }
        }
        Section("Top processes") {
            ForEach(s.procs) { p in LabeledContent(p.name, value: String(format: "%.0f%% · %.1f%% mem", p.cpu, p.mem)) }
        }
    }
}

struct AppsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var picked = ""
    @State private var pending: PendingQuit?
    @State private var alert: String?
    struct PendingQuit: Identifiable { let app: Status.App; let force: Bool; var id: String { "\(app.pid)\(force)" } }
    let s: Status
    init(_ s: Status) { self.s = s }
    var body: some View {
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
            Picker("App", selection: $picked) { ForEach(s.installed, id: \.self) { Text($0).tag($0) } }
            Button("Open on Mac") { Task { alert = await model.run("app-open", ["name": picked.isEmpty ? (s.installed.first ?? "") : picked]) } }
        } header: { Text("Open an app") } footer: { Text("Swipe an open app to quit it.") }
        .confirmationDialog(pending.map { ($0.force ? "Force quit " : "Quit ") + $0.app.name } ?? "", isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let p = pending {
                Button(p.force ? "Force Quit" : "Quit", role: .destructive) { Task { alert = await model.run(p.force ? "app-kill" : "app-quit", ["pid": p.app.pid]) } }
            }
        } message: { if pending?.force == true { Text("Unsaved work is lost.") } }
        .alert("That did not work", isPresented: .init(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("OK") {} } message: { Text(alert ?? "") }
    }
}

struct ClaudeTab: View {
    @EnvironmentObject var model: AppModel
    @State private var confirm = false
    let s: Status
    init(_ s: Status) { self.s = s }
    var body: some View {
        Section("Claude") {
            StateRow(label: "Remote control", good: s.claude.remoteControl, value: s.claude.remoteControl ? "Running" : "Stopped")
            StateRow(label: "Auto-restart", good: s.claude.keepAlive, value: s.claude.keepAlive ? "Armed" : "Off")
            StateRow(label: "Desktop app", good: s.claude.desktop, value: s.claude.desktop ? "Running" : "Stopped")
            LabeledContent("Claude Code", value: s.claude.version.replacingOccurrences(of: " (Claude Code)", with: ""))
            LabeledContent("Claude service", value: s.claude.service ?? "Unknown")
            Link("Open Claude Code", destination: URL(string: "https://claude.ai/code")!)
            Button("Restart remote control") { confirm = true }
        }
        .confirmationDialog("Restart remote control?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { _ = await model.run("rc-restart") } }
        } message: { Text("Connected sessions drop briefly, then reconnect.") }
        Section("Sessions on this Mac (\(s.claude.sessions.count))") {
            if s.claude.sessions.isEmpty { Text("None running").foregroundStyle(.secondary) }
            ForEach(s.claude.sessions) { x in
                LabeledContent {
                    Text(x.status)
                } label: {
                    Text(x.name)
                    Text(x.cwd + (x.remote ? " · remote" : ""))
                }
            }
        }
    }
}

struct UsageTab: View {
    let s: Status
    init(_ s: Status) { self.s = s }
    var u: Status.Usage { s.usage }
    func limit(_ title: String, _ pct: Double?, _ resets: Double?) -> some View {
        let now = Date().timeIntervalSince1970 * 1000
        let over = (resets ?? .infinity) <= now
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            if let pct, !over {
                Text("\(Int(pct.rounded()))%").font(.title2.weight(.semibold)).monospacedDigit()
                ProgressView(value: min(pct, 100), total: 100).tint(pct > 90 ? .red : pct > 75 ? .orange : .accentColor)
                if let resets { Text("Resets in \(Format.span((resets - now) / 1000))").font(.footnote).foregroundStyle(.secondary) }
            } else {
                Text(over ? "Reset" : "No reading").font(.title2.weight(.semibold))
                Text(over ? "Waiting for the next response" : "Use Claude Code in a terminal to get one").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    var body: some View {
        Section {
            LazyVGrid(columns: tileColumns, spacing: 18) {
                limit("5-hour limit", u.plan?.fiveHour, u.plan?.fiveHourResets)
                limit("7-day limit", u.plan?.sevenDay, u.plan?.sevenDayResets)
            }
            .padding(.vertical, 4)
        } header: { Text("Plan limits") } footer: {
            if let p = u.plan { Text("Reading \(Format.ago(ms: p.at)) from \(p.source). It updates with each response in a terminal Claude session.") }
        }
        Section("Tokens per hour, last 24 hours") {
            VStack(alignment: .leading) {
                Text(Format.count(u.day.tokens)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("\(u.day.messages) responses on this Mac").font(.footnote).foregroundStyle(.secondary)
                Chart(u.hours) { h in
                    BarMark(x: .value("Hour", Date(timeIntervalSince1970: h.t / 1000), unit: .hour), y: .value("Tokens", h.tokens), width: .ratio(0.7))
                        .foregroundStyle(Color.accentColor).clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .chartYAxis(.hidden).frame(height: 90)
            }
        }
        Section {
            LabeledContent("Last 5 hours", value: Format.count(u.fiveHours.tokens))
            LabeledContent("Last 24 hours", value: Format.count(u.day.tokens))
            LabeledContent("Last 7 days", value: Format.count(u.week.tokens))
            LabeledContent("Cache, last 7 days", value: Format.count(u.week.cache))
        } header: { Text("Tokens on this Mac") } footer: { Text("Covers Claude Code and Cowork sessions on this Mac, not claude.ai or other devices.") }
        Section("By model, last 7 days") {
            ForEach(u.week.models.sorted { $0.value.tokens > $1.value.tokens }, id: \.key) { name, v in
                LabeledContent(name.replacingOccurrences(of: "claude-", with: ""), value: "\(Format.count(v.tokens)) · \(v.messages)")
            }
        }
    }
}

struct UpgradeTab: View {
    @EnvironmentObject var model: AppModel
    @State private var note: String?
    @State private var agentPassword = ""
    let s: Status
    init(_ s: Status) { self.s = s }
    var onTahoe: Bool { (Int(s.macos.split(separator: ".").first ?? "") ?? 0) >= 26 }
    var body: some View {
        Section("macOS and OCLP") {
            Text(s.upgrade.installed ? (s.upgrade.status.isEmpty ? "Starting…" : s.upgrade.status) : onTahoe ? "On Tahoe" : "Waiting for your password to start").font(.headline)
            LabeledContent("Running", value: "\(s.macos) (\(s.build))")
            LabeledContent("OCLP", value: s.upgrade.state["oclp_tag"] ?? s.oclp.version)
            LabeledContent("Root patches for", value: s.oclp.patchedFor.isEmpty ? "None yet" : s.oclp.patchedFor)
            LabeledContent("KDK", value: s.oclp.kdk.isEmpty ? "None" : s.oclp.kdk)
            if s.upgrade.installed { Button("Run update check now") { Task { note = await model.run("upgrade-run") } } }
        }
        if s.agentStale {
            Section {
                SecureField("Mac password", text: $agentPassword)
                Button("Apply update") {
                    Task { note = await model.runSealed("agent-update", secret: agentPassword) ?? "Applied."; agentPassword = "" }
                }.disabled(agentPassword.isEmpty)
            } header: { Text("Update service improvements") } footer: { Text("A newer version of the update service is ready. Your password is used once.") }
        }
        if let note { Section { Text(note) } }
        Section("Log") {
            Text(s.upgrade.log.isEmpty ? "No log yet" : s.upgrade.log).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

struct ControlTab: View {
    @EnvironmentObject var model: AppModel
    @State private var macPassword = ""
    @State private var text = ""
    @State private var pressReturn = false
    @State private var note: String?
    @State private var appleEmail = ""
    @State private var applePassword = ""
    @State private var appleCode = ""
    @State private var confirmRestart = false
    let s: Status
    init(_ s: Status) { self.s = s }

    func when(_ ms: Double) -> String {
        ms > 0 ? Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .shortened) : "Not yet"
    }

    var body: some View {
        Section {
            StateRow(label: "Screen", good: s.screen != "locked", value: s.screen == "locked" ? "Locked" : s.screen == "display off" ? "Display off" : "Unlocked")
            if s.macLogin {
                if s.screen == "locked" { Button("Unlock") { Task { note = await model.run("mac-unlock") } } }
                Button("Forget password", role: .destructive) { Task { note = await model.run("mac-logout") } }
            } else {
                SecureField("Mac password", text: $macPassword)
                Button("Log in") {
                    Task { note = await model.runSealed("mac-login", secret: macPassword); macPassword = "" }
                }.disabled(macPassword.isEmpty)
            }
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Log in to this Mac") } footer: {
            Text(s.macLogin ? "Logged in, and it stays that way after restarts." : "Used once to log in, then saved in the Mac’s keychain. Forget password removes it.")
        }
        Section {
            NavigationLink("Open screen") { RemoteScreenView() }
            Button("Sign in to Chrome") { Task { note = await model.run("chrome-signin") } }
        } header: { Text("Remote desktop") } footer: { Text("Tap to click, pinch to zoom, and drag to scroll. Drag moves the view while zoomed.") }
        Section {
            if s.macLogin || s.typing == "trusted" {
                SecureField("Text or password", text: $text)
                Toggle("Press Return afterward", isOn: $pressReturn)
                Button("Type on Mac") {
                    Task { note = await model.runSealed("type-text", secret: text, extra: ["enter": pressReturn]) ?? "Typed."; text = "" }
                }.disabled(text.isEmpty)
            } else {
                Text("Log in to this Mac above to use this.").foregroundStyle(.secondary)
            }
        } header: { Text("Sign-ins on the Mac") } footer: {
            Text("For Apple ID or any other prompt. It is encrypted on this phone and typed once. Nothing is saved.")
        }
        Section {
            LabeledContent("iPhone on USB", value: s.iphone ? "Connected" : "Not connected")
            LabeledContent("Apple account", value: s.ios.signedIn ? "Signed in" : "Needed")
            LabeledContent("Last installed", value: when(s.ios.installedAt))
            LabeledContent("Next re-sign", value: when(s.ios.nextDue))
            if !s.ios.lastResult.isEmpty { Text(s.ios.lastResult).font(.footnote).foregroundStyle(.secondary) }
            if s.ios.job.state == "code" {
                TextField("6-digit code", text: $appleCode)
                Button("Send code") { Task { note = await model.runSealed("ios-code", secret: appleCode); appleCode = "" } }.disabled(appleCode.isEmpty)
            } else if !s.ios.signedIn {
                TextField("Apple account email", text: $appleEmail).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Apple account password", text: $applePassword)
                Button("Sign in to Apple") {
                    Task { note = await model.runSealed("ios-login", secret: appleEmail + "\n" + applePassword); applePassword = "" }
                }.disabled(appleEmail.isEmpty || applePassword.isEmpty)
            } else {
                Button(s.ios.resigning ? "Working…" : "Re-sign now") { Task { note = await model.run("ios-resign") } }.disabled(s.ios.resigning)
                Button("Sign out of Apple account", role: .destructive) { Task { note = await model.run("ios-logout") } }
            }
        } header: { Text("App re-signing") } footer: {
            Text("The Mac renews both apps a day before the 7-day limit, and installs new builds, whenever this iPhone is on the same Wi-Fi or plugged in.")
        }
        if !s.publicUrl.isEmpty {
            Section {
                Link("Open public link", destination: URL(string: s.publicUrl)!)
            } header: { Text("Public link") } footer: { Text("This address changes whenever the Mac restarts.") }
        }
        Section("Connected devices") {
            if s.tailscale.peers.isEmpty { Text("No other devices yet").foregroundStyle(.secondary) }
            ForEach(s.tailscale.peers) { p in StateRow(label: p.name, good: p.online, value: p.os) }
        }
        Section("Power") {
            Button("Restart Mac", role: .destructive) { confirmRestart = true }
        }
        .confirmationDialog("Restart the Mac in one minute?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { note = await model.run("mac-restart") } }
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
