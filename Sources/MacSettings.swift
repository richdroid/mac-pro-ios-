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
    @State private var customBudget = false
    @State private var budgetDraft = 200.0
    static let budgets: [Double] = [50, 100, 200, 500]
    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(v) (\(b))"
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                // The page's name as its first line, going up with the page, as on every other tab.
                Section {
                    Text("Settings").font(.largeTitle.weight(.bold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, TopEdge.statusBar < 20 ? 14 : 0)
                        .accessibilityAddTraits(.isHeader)
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
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
                    // Not "Temperatures": the Status page switch above has that name (designer, 2026-11-11).
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
                Section {
                    Picker("Open on", selection: $startTab) {
                        Text("The last tab used").tag(-1)
                        Text("Status").tag(0); Text("Apps").tag(1); Text("Claude").tag(2); Text("macOS").tag(4); Text("Control").tag(5)
                    }
                    Toggle("Haptics", isOn: $haptics)
                    Toggle("Natural scrolling on the screen", isOn: $naturalScroll)
                    // Was its own section of one row (designer, 2026-11-11: no lone rows).
                    OTASettings()
                } header: { Text("Behaviour") } footer: { Text(OTASettings.note) }
                Section {
                    LabeledContent("Address", value: URL(string: model.address)?.host ?? "Not set")
                    Button("Change connection") { connecting = true }
                } header: { Text("Connection") } footer: {
                    // A note under the last card, not a card of one row of its own.
                    Text("Mac Pro \(version)").monospacedDigit()
                }
            }
            .scrollsUnder()
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
