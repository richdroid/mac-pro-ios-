import SwiftUI

// Everything about how the app looks and behaves, in one place at the foot of the side bar.
struct MacSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("accent") private var accent = "blue"
    @AppStorage("celsius") private var celsius = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("liveEvery") private var liveEvery = 1.0
    @AppStorage("fullEvery") private var fullEvery = 10.0
    @AppStorage("startTab") private var startTab = -1
    @AppStorage("showQuick") private var showQuick = true
    @AppStorage("showTemps") private var showTemps = true
    @AppStorage("showDisk") private var showDisk = true
    @AppStorage("showAccess") private var showAccess = true
    @AppStorage("showThisMac") private var showThisMac = true
    @AppStorage("showProcesses") private var showProcesses = true
    @State private var connecting = false
    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(v) (\(b))"
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Colour") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(MacAccent.allCases) { a in
                                Button { withAnimation(.snappy) { accent = a.rawValue } } label: {
                                    Circle().fill(a.color).frame(width: 34, height: 34)
                                        .overlay { if accent == a.rawValue { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.black.opacity(0.7)) } }
                                        .overlay { Circle().strokeBorder(.white.opacity(accent == a.rawValue ? 0.9 : 0), lineWidth: 2).padding(-4) }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(a.name).accessibilityAddTraits(accent == a.rawValue ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 8).padding(.horizontal, 4)
                    }
                }
                Section {
                    Toggle("Quick actions", isOn: $showQuick)
                    Toggle("Temperatures", isOn: $showTemps)
                    Toggle("Disk", isOn: $showDisk)
                    Toggle("Remote access", isOn: $showAccess)
                    Toggle("This Mac", isOn: $showThisMac)
                    Toggle("Top processes", isOn: $showProcesses)
                } header: { Text("Status page") } footer: { Text("The Mac Pro, its live figures and any alerts always show.") }
                Section("Units and updates") {
                    Picker("Temperatures", selection: $celsius) { Text("Fahrenheit").tag(false); Text("Celsius").tag(true) }
                    Picker("Live figures", selection: $liveEvery) { Text("Every second").tag(1.0); Text("Every 2 seconds").tag(2.0); Text("Every 5 seconds").tag(5.0) }
                    Picker("Everything else", selection: $fullEvery) { Text("Every 10 seconds").tag(10.0); Text("Every 30 seconds").tag(30.0); Text("Every minute").tag(60.0) }
                }
                Section {
                    Picker("Open on", selection: $startTab) {
                        Text("The last tab used").tag(-1)
                        Text("Status").tag(0); Text("Apps").tag(1); Text("Claude").tag(2); Text("Usage").tag(3); Text("Updates").tag(4); Text("Control").tag(5)
                    }
                    Toggle("Haptics", isOn: $haptics)
                } header: { Text("Behaviour") }
                Section {
                    LabeledContent("Address", value: URL(string: model.address)?.host ?? "Not set")
                    Button("Change connection") { connecting = true }
                } header: { Text("Connection") }
                Section { LabeledContent("Version", value: version) }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $connecting) { SignInView().environmentObject(model) }
            // New intervals take hold straight away rather than after the current wait.
            .onChange(of: liveEvery) { _, _ in model.start() }
            .onChange(of: fullEvery) { _, _ in model.start() }
        }
    }
}
