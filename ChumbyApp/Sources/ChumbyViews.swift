import SwiftUI

@main
struct ChumbyApp: App {
    @StateObject private var model = ChumbyModel()
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
    @EnvironmentObject var model: ChumbyModel
    @State private var tab = UserDefaults.standard.integer(forKey: "tab")
    var body: some View {
        TabView(selection: $tab) {
            Page("My Chumby") { HomeTab() }.tabItem { Label("My Chumby", systemImage: "tv") }.tag(0)
            Page("Channels") { ChannelsTab() }.tabItem { Label("Channels", systemImage: "rectangle.stack") }.tag(1)
            Page("Alarms") { AlarmsTab() }.tabItem { Label("Alarms", systemImage: "alarm") }.tag(2)
            Page("Sounds") { SoundsTab() }.tabItem { Label("Sounds", systemImage: "music.note") }.tag(3)
            Page("Tinker") { TinkerTab() }.tabItem { Label("Tinker", systemImage: "wrench.adjustable") }.tag(4)
        }
        .modifier(AdaptiveTabs())
        .overlay(alignment: .top) {
            if let t = model.toast {
                Text(t).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 9).background(.regularMaterial, in: Capsule()).padding(.top, 6).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .sheet(isPresented: $model.needsAddress) { ConnectionView().environmentObject(model).interactiveDismissDisabled(model.api == nil) }
    }
}

struct AdaptiveTabs: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.tabViewStyle(.sidebarAdaptable) } else { content }
    }
}

struct Page<Content: View>: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var settings = false
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .toolbar { ToolbarItem(placement: .primaryAction) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Connection") } }
                .sheet(isPresented: $settings) { ConnectionView().environmentObject(model) }
                .safeAreaInset(edge: .top) {
                    if model.offline {
                        Label("Can’t reach the Chumby. Is Tailscale on?", systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.white).padding(8).frame(maxWidth: .infinity).background(.red)
                    }
                }
        }
    }
}

struct ConnectionView: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://chumby.local", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Chumby address") } footer: {
                    Text("At home, use your Chumby’s name, such as http://chumby.local. From anywhere, use your Mac Pro’s Tailscale proxy address with Tailscale on.")
                }
            }
            .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        model.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        if model.api != nil { model.needsAddress = false; model.start(); dismiss() }
                    }.disabled(address.isEmpty)
                }
            }
            .onAppear { address = model.address }
        }
    }
}

// MARK: - My Chumby
struct HomeTab: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.horizontalSizeClass) private var size
    @State private var moreInfo = false
    @State private var say: String?
    @State private var line = 0
    @State private var squish = false
    @State private var tapMark: CGPoint?
    private static let lines = ["hello, you!", "eight arms, one remote.", "blub.", "tap my screen!", "still ticking since 2008.", "who’s a good gadget?"]

    var device: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Image("Octopus").resizable().scaledToFit().frame(width: 92)
                    .scaleEffect(squish ? 1.18 : 1)
                    .accessibilityLabel("Octopus").accessibilityAddTraits(.isButton)
                    .onTapGesture {
                        say = Self.lines[line % Self.lines.count]; line += 1
                        withAnimation(.spring(duration: 0.25, bounce: 0.6)) { squish = true }
                        Task { try? await Task.sleep(nanoseconds: 220_000_000); withAnimation(.spring) { squish = false }
                               try? await Task.sleep(nanoseconds: 1_700_000_000); withAnimation { say = nil } }
                    }
                if let say {
                    Text(say).font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7).background(.regularMaterial, in: Capsule()).offset(y: -18).transition(.scale.combined(with: .opacity))
                }
            }
            .zIndex(1).padding(.bottom, -16)
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous).fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 12)
                liveScreen.padding(26)
            }
            .aspectRatio(1.28, contentMode: .fit)
            .frame(maxWidth: 380)
        }
    }

    var liveScreen: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let i = model.shot { Image(platform: i).resizable().interpolation(.medium) }
                else { ProgressView().tint(.white) }
                if let tapMark { Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: 26, height: 26).position(tapMark) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { p in
                tapMark = p
                model.cmd("tap", "\(Int(p.x / geo.size.width * 319)),\(Int(p.y / geo.size.height * 239))")
                Task { try? await Task.sleep(nanoseconds: 450_000_000); tapMark = nil; _ = await model.refreshShot() }
            }
            .accessibilityLabel("The Chumby’s screen, live. Tap to touch it.")
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .task {
            while !Task.isCancelled {
                let ok = await model.refreshShot()
                try? await Task.sleep(nanoseconds: ok ? 1_000_000_000 : 3_000_000_000)
            }
        }
    }

    var specs: some View {
        VStack(spacing: 2) {
            Text("Chumby Classic").font(.title2.bold())
            Text(model.sys.lock.isEmpty ? (model.sys.chan.isEmpty ? "Awake" : model.sys.chan) : "Busy: \(model.sys.lock)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text("Tap the screen to touch it. Tap the octopus to say hi.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
        }
    }

    var remote: some View {
        HStack(spacing: 14) {
            RemoteButton(icon: "moon.fill", label: "Night") { model.cmd("night", "on", "Goodnight") }
            RemoteButton(icon: "backward.fill", label: "Previous widget", big: true) { model.cmd("prev", nil, "Previous widget") }
            RemoteButton(icon: "forward.fill", label: "Next widget", big: true) { model.cmd("next", nil, "Next widget") }
            RemoteButton(icon: "sun.max.fill", label: "Wake") { model.cmd("night", "off"); model.cmd("screen", "bright", "Good morning") }
        }
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChoiceRow(title: "Night mode", options: [("Off", "off"), ("On", "on"), ("Dim", "dim"), ("Dark", "dark")]) { model.cmd("night", $0, "Night mode \($0)") }
            ChoiceRow(title: "Screen", options: [("Bright", "bright"), ("Dim", "dim"), ("Off", "off")]) { model.cmd("screen", $0, "Screen \($0)") }
            DisclosureGroup("More info", isExpanded: $moreInfo) {
                VStack(spacing: 8) {
                    Info("Awake for", duration(model.sys.up))
                    Info("Load", String(format: "%.2f", model.sys.load))
                    Info("Memory", "\(model.sys.memFree / 1024) MB free of \(model.sys.memTotal / 1024) MB")
                    Info("Flash storage", "\(model.sys.pspFree) KB free")
                    Info("Wi-Fi", model.sys.wifi >= 0 ? "\(model.sys.wifi) / 100" : "Not connected")
                    Info("Power", model.sys.wall == 1 ? "Wall power" : "Battery")
                    Info("Software", model.sys.cp.isEmpty ? "Unknown" : model.sys.cp)
                }.padding(.top, 8)
            }
        }
        .padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    var body: some View {
        ScrollView {
            if size == .regular {
                HStack(alignment: .top, spacing: 28) {
                    VStack(spacing: 14) { device; specs }.frame(maxWidth: .infinity)
                    VStack(spacing: 20) { remote; controls }.frame(maxWidth: .infinity)
                }.padding(.horizontal, 18).padding(.vertical, 10)
            } else {
                VStack(spacing: 18) { device; specs; remote; controls }.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }
}

func duration(_ s: Int) -> String {
    let d = s / 86400, h = s / 3600 % 24, m = s / 60 % 60
    return (d > 0 ? "\(d)d " : "") + (h > 0 ? "\(h)h " : "") + "\(m)m"
}

struct Info: View {
    let k: String, v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View { LabeledContent(k, value: v).font(.subheadline) }
}

struct RemoteButton: View {
    let icon: String, label: String
    var big = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(big ? .title2 : .title3).frame(width: big ? 72 : 56, height: 56)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityLabel(label)
    }
}

struct ChoiceRow: View {
    let title: String, options: [(String, String)]
    let action: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                ForEach(options, id: \.1) { o in
                    Button(o.0) { action(o.1) }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Channels
struct EditorRow: Identifiable, Equatable { let id: String; var name: String; var on: Bool; var secs: Int; var own: Int }
let widgetTimes = [10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600]
func timeText(_ t: Int) -> String { t < 60 ? "\(t) sec" : "\(t / 60) min" }

struct ChannelsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var picked = ""
    @State private var rows: [EditorRow] = []
    @State private var saveTask: Task<Void, Never>?
    @State private var categories: [(String, String)] = []
    @State private var category = ""
    @State private var catalog: [(String, String)] = []
    @State private var page = 1
    @State private var more = false
    @State private var busy = false

    var channels: [ChannelList.Channel] { model.channelData?.channels ?? [] }
    func title(_ c: ChannelList.Channel) -> String { c.list.first.flatMap { $0.count > 1 ? $0[1] : nil } ?? "Channel" }
    var allWidgets: [[String]] {
        var m: [String: [String]] = [:]
        for n in model.channelData?.names ?? [] where n.count > 1 { m[n[0]] = [n[0], n[1], "0"] }
        for c in channels { for l in c.list where l.first != "#" && l.count > 1 { m[l[0]] = l } }
        return m.values.sorted { $0[1].localizedCaseInsensitiveCompare($1[1]) == .orderedAscending }
    }

    func pick() {
        guard let ch = channels.first(where: { $0.id == picked }) else { rows = []; return }
        let all = ch.list.filter { $0.first != "#" }
        var seen = Set<String>(), out: [EditorRow] = []
        for f in ch.conf where f.count > 2 {
            if let w = all.first(where: { $0[0] == f[0] }) ?? allWidgets.first(where: { $0[0] == f[0] }) {
                seen.insert(f[0])
                out.append(EditorRow(id: f[0], name: w[1], on: f[1] == "1", secs: Int(f[2]) ?? 0, own: w.count > 2 ? Int(w[2]) ?? 0 : 0))
            }
        }
        for w in all where !seen.contains(w[0]) && w.count > 1 {
            out.append(EditorRow(id: w[0], name: w[1], on: true, secs: 0, own: w.count > 2 ? Int(w[2]) ?? 0 : 0))
        }
        rows = out
    }
    func changed() {
        saveTask?.cancel()
        let snapshot = rows, id = picked
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            var o: [(String, String)] = [("n", "\(snapshot.count)")]
            for (i, w) in snapshot.enumerated() { o += [("\(i)_id", w.id), ("\(i)_on", w.on ? "1" : "0"), ("\(i)_secs", "\(w.secs)")] }
            do {
                let j = try await model.api?.post("chedit", extra: "&p=" + ChumbyAPI.enc(id), body: ChumbyAPI.form(o))
                model.say(j?["missing"] != nil ? "Saved, but a widget couldn’t be downloaded" : "Channel saved")
            } catch { model.say("Couldn’t: \(error.localizedDescription)") }
        }
    }
    func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
    func matches(_ pattern: String, _ text: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) else { return nil }
            return (String(text[a]), decode(String(text[b])))
        }
    }
    func loadCategories() async {
        guard categories.isEmpty, let t = try? await model.api?.text("a=cat") else { return }
        var seen = Set<String>()
        categories = matches(#"/guide/([0-9A-F-]+)/category"><img alt="([^"]*)""#, t).filter { seen.insert($0.0).inserted }
    }
    func loadCatalog() async {
        guard !category.isEmpty else { return }
        busy = true; defer { busy = false }
        guard let t = try? await model.api?.text("a=cat&c=\(category)&p=\(page)") else { model.say("Couldn’t reach the catalog"); return }
        var seen = Set(catalog.map { $0.0 })
        catalog += matches(#"/guide/([0-9A-F-]+)/widget">([^<]+)</a>"#, t).filter { seen.insert($0.0).inserted }
        more = t.contains("category?page=\(page + 1)")
    }

    var body: some View {
        List {
            Section("Now playing") {
                Picker("Channel", selection: Binding(get: { model.state.channel }, set: { n in model.state.channel = n; model.cmd("channel", n, "Switching channel") })) {
                    ForEach(model.state.channelNames, id: \.self) { Text($0).tag($0) }
                    if !model.state.channelNames.contains(model.state.channel) { Text(model.state.channel).tag(model.state.channel) }
                }
                Menu("Jump to a widget") {
                    ForEach(model.state.widgetNames.sorted(), id: \.self) { n in Button(n) { model.cmd("widget", n, "Jumping") } }
                }
                Toggle("Shuffle", isOn: Binding(get: { model.state.shuffle == 1 }, set: { on in model.state.shuffle = on ? 1 : 0; model.cmd("shuffle", on ? "1" : "0", on ? "Shuffle on" : "Shuffle off") }))
            }
            Section {
                Picker("Edit channel", selection: $picked) { ForEach(channels, id: \.id) { Text(title($0)).tag($0.id) } }
                    .onChange(of: picked) { _, _ in pick() }
                ForEach($rows) { $w in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(w.name).lineLimit(1).opacity(w.on ? 1 : 0.45)
                            Spacer()
                            Toggle("On", isOn: $w.on).labelsHidden().onChange(of: w.on) { _, _ in changed() }
                        }
                        Picker("Time on screen", selection: $w.secs) {
                            Text(w.own > 0 ? "Auto (\(w.own)s)" : "Auto").tag(0)
                            ForEach(widgetTimes, id: \.self) { Text(timeText($0)).tag($0) }
                        }.font(.footnote).onChange(of: w.secs) { _, _ in changed() }
                    }
                    .swipeActions(edge: .leading) {
                        Button("To top") { if let i = rows.firstIndex(of: w) { rows.insert(rows.remove(at: i), at: 0); changed() } }.tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Up") { if let i = rows.firstIndex(of: w), i > 0 { rows.swapAt(i, i - 1); changed() } }.tint(.indigo)
                        Button("Down") { if let i = rows.firstIndex(of: w), i < rows.count - 1 { rows.swapAt(i, i + 1); changed() } }.tint(.teal)
                    }
                }
                Menu("Add a widget") {
                    ForEach(allWidgets.filter { w in !rows.contains { $0.id == w[0] } }, id: \.self) { w in
                        Button(w[1]) { rows.insert(EditorRow(id: w[0], name: w[1], on: true, secs: 0, own: w.count > 2 ? Int(w[2]) ?? 0 : 0), at: 0); changed() }
                    }
                }
            } header: { Text("Edit channel") } footer: {
                Text((model.state.shuffle == 1 ? "Shuffle is on, so your order won’t show until you turn it off. " : "") + "Swipe a widget to reorder it. New widgets go to the top, and changes apply within a few seconds.")
            }
            Section("Catalog") {
                Picker("Category", selection: $category) {
                    Text("Choose…").tag("")
                    ForEach(categories, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: category) { _, _ in catalog = []; page = 1; Task { await loadCatalog() } }
                if busy { ProgressView() }
                ForEach(catalog.filter { c in !rows.contains { $0.id == c.0 } }, id: \.0) { c in
                    Button(c.1) { rows.insert(EditorRow(id: c.0, name: c.1, on: true, secs: 0, own: 0), at: 0); changed() }
                }
                if more { Button("Load more") { page += 1; Task { await loadCatalog() } } }
            }
        }
        .task { await model.loadChannels(); if picked.isEmpty { picked = (model.channelData?.cur ?? "").trimmingCharacters(in: .whitespacesAndNewlines); if picked.isEmpty { picked = channels.first?.id ?? "" }; pick() }; await loadCategories() }
        .refreshable { await model.loadChannels(); await model.loadState(); pick() }
    }
}

// MARK: - Alarms
struct AlarmsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var editing: EditTarget?
    struct EditTarget: Identifiable { let index: Int; var id: Int { index } }
    static let actions = [("night", "on", "Night mode on"), ("night", "dim", "Night mode dim"), ("night", "dark", "Night mode dark"), ("night", "off", "Night mode off"), ("screen", "bright", "Screen bright"), ("screen", "dim", "Screen dim"), ("screen", "off", "Screen off")]

    var body: some View {
        List {
            Section {
                let shown = model.state.alarms.enumerated().filter { !$0.element.isPlaceholder }.sorted { $0.element.localMinutes < $1.element.localMinutes }
                if shown.isEmpty { Text("No alarms yet. Tap + to add one.").foregroundStyle(.secondary) }
                ForEach(shown, id: \.element.id) { i, a in
                    HStack {
                        Button { editing = EditTarget(index: i) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text(a.clock).font(.system(size: 38, weight: .light)).monospacedDigit()
                                    Text(a.meridiem).font(.subheadline)
                                }
                                Text([a.name, a.whenText, a.soundText].filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .opacity(a.isOn ? 1 : 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Toggle("On", isOn: Binding(get: { a.isOn }, set: { on in
                            model.state.alarms[i].enabled = on ? "1" : "0"
                            Task { await model.saveAlarms(on ? "Alarm on" : "Alarm off") }
                        })).labelsHidden()
                    }
                }
            } header: {
                if let n = model.nextAlarm() { Text("Next: " + n.formatted(.dateTime.weekday(.wide).hour().minute())) } else { Text("No alarm set") }
            } footer: { if model.state.pending { Text("Updating the Chumby…") } }
            Section {
                ForEach($model.state.schedule) { $e in
                    HStack {
                        DatePicker("Time", selection: Binding(get: { Self.date(e.time) }, set: { e.time = Self.hhmm($0); Task { await model.saveSchedule() } }), displayedComponents: .hourAndMinute).labelsHidden()
                        Picker("Action", selection: Binding(get: { e.cmd + ":" + e.val }, set: { v in
                            let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                            e.cmd = parts[0]; e.val = parts.count > 1 ? parts[1] : ""
                            Task { await model.saveSchedule() }
                        })) {
                            ForEach(Self.actions, id: \.2) { Text($0.2).tag($0.0 + ":" + $0.1) }
                            ForEach(model.state.channelNames, id: \.self) { Text("Channel: " + $0).tag("channel:" + $0) }
                        }.labelsHidden()
                    }
                }
                .onDelete { model.state.schedule.remove(atOffsets: $0); Task { await model.saveSchedule() } }
                Button("Add a time") { model.state.schedule.append(ScheduleItem()); Task { await model.saveSchedule() } }
            } header: { Text("Daily schedule") } footer: { Text("Runs every day at these times, even with your phone away.") }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = EditTarget(index: -1) } label: { Image(systemName: "plus") }.accessibilityLabel("Add alarm")
                    .disabled(model.state.alarms.count >= 16)
            }
        }
        .sheet(item: $editing) { t in AlarmEditor(index: t.index).environmentObject(model) }
        .refreshable { await model.loadState() }
    }
    static func date(_ s: String) -> Date {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 22, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }
    static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

struct AlarmEditor: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    let index: Int
    @State private var alarm = Alarm()
    @State private var time = Date()
    @State private var date = Date()
    @State private var repeatMode = "daily"
    @State private var day = 1
    @State private var kind = "beep"
    @State private var tone = "Beep"
    @State private var streamIndex = 0
    @State private var pandoraID = ""
    @State private var after = ""
    @State private var confirmDelete = false

    var stations: [NamedID] {
        var out = model.state.pandora
        for a in model.state.alarms where a.arg == "pandora" && !a.param.isEmpty {
            let p = a.param.components(separatedBy: "##")
            if !out.contains(where: { $0.id == p[0] }) { out.append(NamedID(id: p[0], name: p.count > 1 ? p[1] : a.param_description)) }
        }
        return out
    }
    var afterOptions: [(String, String)] {
        var o = [("", "Return to what was on screen"), ("nightmode|on", "Night mode on"), ("nightmode|off", "Night mode off"), ("bright|bright", "Screen bright"), ("bright|dim", "Screen dim"), ("bright|off", "Screen off")]
        for c in model.state.channels { o.append(("profile|" + c.id, "Switch channel to “\(c.name)”")) }
        let cur = alarm.action.isEmpty ? "" : alarm.action + "|" + alarm.action_param
        if !cur.isEmpty && !o.contains(where: { $0.0 == cur }) { o.append((cur, alarm.action == "profile" ? "Switch channel (set on the Chumby)" : cur)) }
        return o
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity) }
                Section("Repeat") {
                    Picker("Repeat", selection: $repeatMode) {
                        Text("Once").tag("once"); Text("Daily").tag("daily"); Text("Weekdays").tag("weekday"); Text("Weekends").tag("weekend"); Text("One day").tag("day")
                    }
                    if repeatMode == "day" {
                        Picker("Day", selection: $day) { ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) } }
                    }
                    if repeatMode == "once" { DatePicker("Date", selection: $date, displayedComponents: .date) }
                    TextField("Label", text: $alarm.name)
                }
                Section("Sound") {
                    Picker("Plays", selection: $kind) {
                        Text("Tone").tag("beep"); Text("Radio").tag("stream"); Text("Pandora").tag("pandora"); Text("Silent").tag("none")
                        if kind == "keep" { Text("Current").tag("keep") }
                    }
                    if kind == "beep" {
                        Picker("Tone", selection: $tone) { ForEach(model.state.tones, id: \.self) { Text($0).tag($0) } }
                        Button("Play on the Chumby") {
                            Task { do { try await model.api?.post("test", extra: "&tone=" + ChumbyAPI.enc(tone)); model.say("Playing on the Chumby") } catch { model.say("Couldn’t play: \(error.localizedDescription)") } }
                        }
                    }
                    if kind == "stream" {
                        if model.state.streams.isEmpty { Text("Add a radio stream on the Sounds tab first.").foregroundStyle(.secondary) }
                        else { Picker("Station", selection: $streamIndex) { ForEach(model.state.streams.indices, id: \.self) { i in Text(model.state.streams[i].name.isEmpty ? model.state.streams[i].url : model.state.streams[i].name).tag(i) } } }
                    }
                    if kind == "pandora" {
                        if stations.isEmpty { Text("No Pandora stations on the Chumby yet.").foregroundStyle(.secondary) }
                        else { Picker("Station", selection: $pandoraID) { ForEach(stations) { Text($0.name).tag($0.id) } } }
                    }
                    if kind == "keep" { LabeledContent("Plays", value: alarm.soundText) }
                    if kind != "none" {
                        Picker("Plays for", selection: $alarm.duration) {
                            ForEach([("1", "1 minute"), ("5", "5 minutes"), ("10", "10 minutes"), ("15", "15 minutes"), ("30", "30 minutes"), ("60", "1 hour"), ("120", "2 hours"), ("-1", "Until stopped")], id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                    Picker("Snooze", selection: $alarm.snooze) {
                        ForEach(["1", "3", "5", "9", "10", "15", "20", "30", "60"], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Toggle("Stop on its own", isOn: Binding(get: { alarm.auto_dismiss == "1" }, set: { alarm.auto_dismiss = $0 ? "1" : "0" }))
                }
                Section("Afterwards") {
                    Picker("Then", selection: $after) { ForEach(afterOptions, id: \.0) { Text($0.1).tag($0.0) } }
                    Toggle("Backup beep", isOn: Binding(get: { alarm.backup == "1" }, set: { alarm.backup = $0 ? "1" : "0" }))
                    if alarm.backup == "1" {
                        Picker("Backup after", selection: $alarm.backupDelay) { ForEach(["1", "2", "5", "10", "15", "30"], id: \.self) { Text("\($0) min").tag($0) } }
                    }
                }
                if index >= 0 { Section { Button("Delete Alarm", role: .destructive) { confirmDelete = true } } }
            }
            .navigationTitle(index >= 0 ? "Edit Alarm" : "Add Alarm").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stopTest(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .confirmationDialog("Delete this alarm?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Alarm", role: .destructive) {
                    model.state.alarms.remove(at: index); dismiss()
                    Task { await model.saveAlarms("Alarm deleted") }
                }
            }
            .onAppear { load(); model.editingAlarm = true }
            .onDisappear { model.editingAlarm = false }
        }
    }
    func stopTest() { Task { try? await model.api?.post("test", extra: "&stop=1") } }

    func load() {
        if index >= 0, model.state.alarms.indices.contains(index) { alarm = model.state.alarms[index] }
        let m = alarm.localMinutes
        time = Calendar.current.date(bySettingHour: m / 60 % 24, minute: m % 60, second: 0, of: Date()) ?? Date()
        if let d = Alarm.dayKeys.firstIndex(of: alarm.when) { day = d; repeatMode = "day" } else { repeatMode = alarm.when }
        if alarm.when == "once" { date = Date(timeIntervalSince1970: (Double(alarm.time) ?? 0) * 60) }
        kind = alarm.type == "beep" ? "beep" : alarm.type == "none" ? "none" : alarm.arg == "directurl" ? "stream" : alarm.arg == "pandora" ? "pandora" : "keep"
        tone = model.state.tones.contains(alarm.arg) ? alarm.arg : (model.state.tones.first ?? "Beep")
        if kind == "stream", let k = model.state.streams.firstIndex(where: { (!$0.id.isEmpty && alarm.param.contains($0.id)) || alarm.param.contains($0.url.replacingOccurrences(of: "&", with: "&amp;")) }) { streamIndex = k }
        pandoraID = kind == "pandora" ? (alarm.param.components(separatedBy: "##").first ?? "") : (stations.first?.id ?? "")
        after = alarm.action.isEmpty ? "" : alarm.action + "|" + alarm.action_param
    }

    func save() {
        var a = alarm
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let h = c.hour ?? 7, m = c.minute ?? 0
        if repeatMode == "once" {
            guard let when = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: date), when > Date() else { model.say("That time has already passed"); return }
            a.when = "once"; a.time = String(Int((when.timeIntervalSince1970 / 60).rounded()))
        } else {
            a.when = repeatMode == "day" ? Alarm.dayKeys[day] : repeatMode
            a.time = String(h * 60 + m)
        }
        a.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "beep": a.type = "beep"; a.arg = tone; a.param = ""; a.param_description = tone
        case "none": a.type = "none"; a.arg = ""; a.param = ""; a.param_description = "None"
        case "stream":
            guard model.state.streams.indices.contains(streamIndex) else { model.say("Add a radio stream first"); return }
            let s = model.state.streams[streamIndex]
            func esc(_ v: String) -> String { v.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
            a.type = "audio"; a.arg = "directurl"; a.param_description = s.name.isEmpty ? s.url : s.name
            a.param = "<stream url=\"\(esc(s.url))\" id=\"\(esc(s.id))\" mimetype=\"\(esc(s.mimetype))\" name=\"\(esc(s.name.isEmpty ? s.url : s.name))\" />"
        case "pandora":
            guard !pandoraID.isEmpty else { model.say("No Pandora station to pick"); return }
            let name = stations.first { $0.id == pandoraID }?.name ?? "Pandora"
            a.type = "audio"; a.arg = "pandora"; a.param = pandoraID + "##" + name; a.param_description = name
        default: break
        }
        if kind == "none" { a.duration = "0" }
        let parts = after.components(separatedBy: "|")
        a.action = parts.first ?? ""; a.action_param = parts.count > 1 ? parts[1] : ""
        a.enabled = "1"
        if index < 0 {
            guard model.state.alarms.count < 16 else { model.say("The Chumby holds 16 alarms at most"); return }
            model.state.alarms.append(a)
        } else { model.state.alarms[index] = a }
        stopTest(); dismiss()
        Task { await model.saveAlarms(index < 0 ? "Alarm added" : "Alarm saved") }
    }
}

// MARK: - Sounds
struct SoundsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @AppStorage("lastVolume") private var lastVolume = 4
    @State private var volume = 0.0
    @State private var dragging = false
    @State private var alarmVolume = 100.0
    @State private var addStream = false
    @State private var streamURL = ""
    @State private var streamName = ""
    @State private var pendingRemoval: Stream?

    func set(_ v: Int, _ msg: String?) { volume = Double(v); model.cmd("volume", String(v), msg) }
    var scanNote: String? {
        switch model.state.pandoraScan.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "waiting": return "Listening for 4 minutes. On the Chumby, open Music, then Pandora Radio."
        case "timeout": return "Didn’t see the station list. Tap again, then open Pandora on the Chumby."
        case "error": return "That didn’t work. Try again."
        default: return nil
        }
    }

    var body: some View {
        List {
            Section("Now") {
                LabeledContent("Volume", value: "\(Int(volume))%")
                Slider(value: $volume, in: 0...100, step: 1) { e in
                    dragging = e
                    if !e { if volume > 0 { lastVolume = Int(volume) }; model.cmd("volume", String(Int(volume))) }
                }.accessibilityLabel("Volume")
                HStack {
                    Button("Mute") { if volume > 0 { lastVolume = Int(volume) }; set(0, "Muted") }
                    Spacer()
                    Button("Unmute") { set(lastVolume > 0 ? lastVolume : 4, "Unmuted") }
                    Spacer()
                    Button("Stop music") { model.cmd("stopmusic", nil, "Music stopped") }
                }.buttonStyle(.bordered)
                Toggle("AirPlay receiver", isOn: Binding(get: { model.sys.airplayOn }, set: { on in model.sys.airplayOn = on; model.cmd("airplay", on ? "1" : "0", on ? "AirPlay on" : "AirPlay off") }))
            }
            Section {
                ForEach(model.state.pandora) { Text($0.name) }
                Button(model.state.pandora.isEmpty ? "Get my stations" : "Update station list") {
                    Task {
                        do { try await model.api?.post("pscan"); model.state.pandoraScan = "waiting"; model.say("Now open Pandora on the Chumby") }
                        catch { model.say("Couldn’t: \(error.localizedDescription)") }
                    }
                }
            } header: { Text("Pandora") } footer: { if let scanNote { Text(scanNote) } }
            Section("Alarm sound") {
                LabeledContent("Alarm volume", value: "\(Int(alarmVolume))%")
                Slider(value: $alarmVolume, in: 0...100, step: 5) { e in
                    if !e { model.state.volume = Int(alarmVolume); Task { await model.saveAlarms("Volume saved") } }
                }.accessibilityLabel("Alarm volume")
                Picker("Fade in", selection: Binding(get: { model.state.fade }, set: { model.state.fade = $0; Task { await model.saveAlarms("Fade saved") } })) {
                    ForEach([(-1, "Chumby default"), (0, "Off"), (5, "5 seconds"), (15, "15 seconds"), (30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes")], id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Section("Radio streams") {
                ForEach(model.state.streams, id: \.key) { s in
                    HStack {
                        Text(s.name.isEmpty ? s.url : s.name).lineLimit(1)
                        Spacer()
                        Button("Remove", role: .destructive) { pendingRemoval = s }.buttonStyle(.borderless)
                    }
                }
                Button("Add a stream…") { addStream = true }
            }
        }
        .task(id: model.sys.vol) { if !dragging && model.sys.vol >= 0 { volume = Double(model.sys.vol) } }
        .task(id: model.state.volume) { alarmVolume = Double(model.state.volume) }
        .refreshable { await model.loadSys(); await model.loadState() }
        .alert("Add a stream", isPresented: $addStream) {
            TextField("MP3 stream address", text: $streamURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("Station name", text: $streamName)
            Button("Add") {
                guard streamURL.hasPrefix("http://") || streamURL.hasPrefix("https://") else { model.say("That isn’t a web address"); return }
                model.state.streams.append(Stream(name: streamName.isEmpty ? streamURL : streamName, url: streamURL))
                streamURL = ""; streamName = ""
                Task { await model.saveStreams() }
            }
            Button("Cancel", role: .cancel) { streamURL = ""; streamName = "" }
        }
        .confirmationDialog("Remove \(pendingRemoval?.name ?? "this stream")?", isPresented: .init(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let p = pendingRemoval { model.state.streams.removeAll { $0.key == p.key }; Task { await model.saveStreams() } }
            }
        }
    }
}

// MARK: - Tinker
struct TinkerTab: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var accounts = ""
    @State private var edited = false
    @State private var confirm: String?

    func romName(_ f: String) -> String { f.replacingOccurrences(of: ".nes.gz", with: "").replacingOccurrences(of: ".nes", with: "").replacingOccurrences(of: "_", with: " ") }

    var body: some View {
        List {
            Section {
                TextField("NASA, BBCBreaking", text: $accounts).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: accounts) { _, n in edited = n != model.sys.tw.joined(separator: ", ") }
                Button("Save") {
                    Task {
                        do { try await model.api?.post("twset", body: ChumbyAPI.form([("v", accounts)])); model.say("Saved. Applies from its next turn"); edited = false; await model.loadSys() }
                        catch { model.say("Couldn’t: \(error.localizedDescription)") }
                    }
                }.disabled(!edited)
            } header: { Text("X (Twitter) accounts") }
            Section("NES") {
                ForEach(model.sys.roms, id: \.self) { f in
                    HStack { Text(romName(f)); Spacer(); Button("Play") { model.cmd("nes", f, "Starting on the Chumby") }.buttonStyle(.borderless) }
                }
                Button("Stop game", role: .destructive) { model.cmd("nesstop", nil, "Back to the channel") }
            }
            Section("Time on screen: your widgets") {
                ForEach(model.state.mine) { w in
                    Picker(w.name, selection: Binding(get: { w.secs }, set: { s in
                        Task {
                            do { try await model.api?.post("wtime", extra: "&w=" + ChumbyAPI.enc(w.name) + "&s=\(s)"); model.say(w.name + ": saved"); await model.loadState() }
                            catch { model.say("Couldn’t: \(error.localizedDescription)") }
                        }
                    })) {
                        ForEach(widgetTimes.contains(w.secs) ? widgetTimes : (widgetTimes + [w.secs]).sorted(), id: \.self) { Text(timeText($0)).tag($0) }
                    }
                }
            }
            Section("The Chumby itself") {
                Button("Restart channel") { confirm = "restart" }
                Button("Reboot", role: .destructive) { confirm = "reboot" }
            }
        }
        .task(id: model.sys.tw) { if !edited { accounts = model.sys.tw.joined(separator: ", ") } }
        .refreshable { await model.loadSys(); await model.loadState() }
        .confirmationDialog(confirm == "reboot" ? "Reboot the Chumby? It takes a few minutes to come back." : "Restart the channel? The screen goes away for about two minutes.", isPresented: .init(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm == "reboot" ? "Reboot" : "Restart", role: .destructive) {
                let c = confirm ?? ""
                model.cmd(c, nil, c == "reboot" ? "Rebooting" : "Restarting")
            }
        }
    }
}
