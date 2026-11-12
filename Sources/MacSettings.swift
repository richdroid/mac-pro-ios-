import SwiftUI

// Everything about how the app looks and behaves, in one place at the foot of the side bar.
struct MacSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("accent") private var accent = "blue"
    @AppStorage("celsius") private var celsius = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("naturalScroll") private var naturalScroll = true
    @AppStorage("liveEvery") private var liveEvery = 1.0
    @AppStorage("fullEvery") private var fullEvery = 10.0
    @AppStorage("apiBudget") private var apiBudget = 200.0
    @AppStorage("startTab") private var startTab = -1
    @AppStorage("showQuick") private var showQuick = true
    @AppStorage("showTemps") private var showTemps = true
    @AppStorage("showDisk") private var showDisk = true
    @AppStorage("showAccess") private var showAccess = true
    @AppStorage("showThisMac") private var showThisMac = true
    @AppStorage("showProcesses") private var showProcesses = true
    @State private var connecting = false
    // A log of how smoothly the app runs (every reading, row height and late frame), for sending to the Mac, off unless he
    // turns it on for a check (resize regate, 2026-11-11).
    @AppStorage("smoothLog") private var smoothLog = false
    @State private var logSending = false
    @State private var logSent: String?
    @State private var customBudget = false
    @State private var budgetDraft = 200.0
    static let budgets: [Double] = [50, 100, 200, 500]
    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(v) (\(b))"
    }
    @Environment(\.paneLayout) private var panes
    // The page's name as its first line, going up with the page, as on every other tab; held blank over the right pane so
    // both panes' first cards start level.
    func heading(_ shown: Bool) -> some View {
        Section { PaneHeading(title: "Settings", shown: shown) }
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
    }
    // How the app looks and what it shows: on the left open flat.
    @ViewBuilder var looks: some View {
        // All seven in view, spread evenly across the row, never scrolled or cut off.
        Section("Colour") {
            HStack(spacing: 0) {
                ForEach(MacAccent.allCases) { a in
                    Button { withAnimation(.snappy) { accent = a.rawValue } } label: {
                        Circle().fill(a.color).frame(width: 32, height: 32)
                            .overlay { if accent == a.rawValue { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.black.opacity(0.7)) } }
                            .overlay { Circle().strokeBorder(.white.opacity(accent == a.rawValue ? 0.9 : 0), lineWidth: 2).padding(-4) }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.name).accessibilityAddTraits(accent == a.rawValue ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
        // What Status shows, as in build 276 (Richard, 2026-11-12: "u went too far on simplicity in status page").
        Section {
            Toggle("Quick actions", isOn: $showQuick)
            Toggle("Temperatures", isOn: $showTemps)
            Toggle("Disk", isOn: $showDisk)
            Toggle("Remote access", isOn: $showAccess)
            Toggle("This Mac", isOn: $showThisMac)
            Toggle("Top processes", isOn: $showProcesses)
        } header: { Text("Status page") } footer: { Text("The Mac Pro, its live figures and any alerts always show.") }
        // Units, how often figures refresh, and the API budget the Claude tab's dial fills against: everything about how the
        // figures read, in one card. The budget was a section of one row, drawn by the system as a capsule beside the
        // rounded cards (designer, 2026-11-11: merge lone rows into the section they belong with).
        Section("Figures") {
            Picker("Temperature unit", selection: $celsius) { Text("Fahrenheit").tag(false); Text("Celsius").tag(true) }
            Picker("Live figures", selection: $liveEvery) { Text("Every second").tag(1.0); Text("Every 2 seconds").tag(2.0); Text("Every 5 seconds").tag(5.0) }
            Picker("Everything else", selection: $fullEvery) { Text("Every 10 seconds").tag(10.0); Text("Every 30 seconds").tag(30.0); Text("Every minute").tag(60.0) }
            // The API dial on the Claude tab fills against this. Picked, not typed, so there's no keyboard to get stuck with.
            Picker("Monthly API budget", selection: Binding(get: { apiBudget }, set: { v in
                if v < 0 { budgetDraft = apiBudget; customBudget = true } else { apiBudget = v }
            })) {
                ForEach(Self.budgets, id: \.self) { Text(LimitsSection.money($0)).tag($0) }
                if !Self.budgets.contains(apiBudget) { Text(LimitsSection.money(apiBudget)).tag(apiBudget) }
                Text("Custom…").tag(-1.0)
            }
            .alert("Monthly API budget", isPresented: $customBudget) {
                TextField("Dollars", value: $budgetDraft, format: .number).keyboardType(.decimalPad)
                Button("Save") { if budgetDraft > 0 { apiBudget = budgetDraft } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("In dollars, for the API dial on the Claude tab.") }
            .id("claude")
        }
    }
    // How it behaves and where it connects: on the right open flat.
    @ViewBuilder var behaves: some View {
        Section {
            Picker("Open on", selection: $startTab) {
                Text("The last tab used").tag(-1)
                Text("Status").tag(0); Text("Apps").tag(1); Text("Claude").tag(2); Text("macOS").tag(4); Text("Control").tag(5)
            }
            Toggle("Haptics", isOn: $haptics)
            Toggle("Natural scrolling on the screen", isOn: $naturalScroll)
            AlertSettings()
            // A log of how smoothly the app runs (every reading, row height and late frame), for sending to the Mac; off
            // unless he turns it on for a check (resize regate, 2026-11-11).
            Toggle("Record smoothness log", isOn: $smoothLog)
                .onChange(of: smoothLog) { _, on in
                    if on { SwipeLog.restart() }
                    SwipeLog.on = on || UserDefaults.standard.bool(forKey: "swipeLog")
                    if on { SwipeLog.frames() }
                    logSent = nil
                }
            if smoothLog {
                Button {
                    Task {
                        guard let f = SwipeLog.file, FileManager.default.fileExists(atPath: f.path) else { logSent = "Nothing recorded yet"; return }
                        logSending = true; defer { logSending = false }
                        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
                        do { _ = try await MacFiles.send(f, as: "Mac Pro smoothness \(stamp).txt", size: MacFiles.size(f), to: model.api.base) { _ in }; logSent = "Sent to the Mac" }
                        catch { logSent = AppModel.say(error) }
                    }
                } label: {
                    HStack { Text("Send the log to the Mac"); Spacer(); if logSending { ProgressView() } else if let logSent { Text(logSent).foregroundStyle(.secondary) } }
                }
                .disabled(logSending)
            }
        } header: { Text("Behaviour") } footer: { Text(AlertSettings.note) }
        Section {
            LabeledContent("Address", value: URL(string: model.address)?.host ?? "Not set")
            Button("Change connection") { connecting = true }
        } header: { Text("Connection") } footer: {
            // A note under the last card, not a card of one row of its own.
            Text("Mac Pro \(version)").monospacedDigit()
        }
    }
    // Open flat, a pane each side of the hinge like the other tabs: one column ran every card, the colour swatches too,
    // across the fold (designer, 2026-11-11).
    func list(_ side: Side) -> some View {
        List {
            heading(side != .right)
            if side != .right { looks }
            if side != .left { behaves }
        }
        .scrollsUnder(side == .right ? 1 : 0)
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Group {
                if panes { FoldSplit { list(.left) } right: { list(.right) } }
                else { list(.all) }
            }
            .task {
                // The build's shots of the lower half, with the budget picker, and of its Custom alert.
                let pose = UserDefaults.standard.string(forKey: "pose") ?? ""
                guard pose == "settings-lower" || pose == "budget-custom" else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                proxy.scrollTo("claude", anchor: .center)
                if pose == "budget-custom" { try? await Task.sleep(nanoseconds: 600_000_000); budgetDraft = apiBudget; customBudget = true }
            }
            }
            // The same top edge as every other tab, rather than the system's band and hairline.
            .modifier(StatusBarFade())
            .topEdge()
            .navigationTitle("Settings")
            .toolbarVisibility(.hidden, for: .navigationBar)
            .screenCover(isPresented: $connecting) { SignInView().environmentObject(model) }
            // New intervals take hold straight away rather than after the current wait.
            .onChange(of: liveEvery) { _, _ in model.start() }
            .onChange(of: fullEvery) { _, _ in model.start() }
        }
    }
}
