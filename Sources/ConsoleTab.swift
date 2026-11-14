import SwiftUI

// The Console tab (Richard, 2026-11-13: the Console on the Mac is "a full screen affair fully controllable from buttons
// on the mac pro app", and its controls are a "separate tab"). It shows what the Mac's screen is on right now and has a
// button for every page, board and setting. Each button says whether the Console did it: the bridge relays the command
// to the Console and answers with the Console's own ack (API.md "Console remote"), never with what was hoped for.

struct ConsoleState: Decodable, Equatable {
    var running: Bool
    var frontmost: Bool?
    var fullscreen: Bool?
    var page: String?
    var board: String?
    var rotate: Bool?
    var animations: String?
    var display: String?
    // Glance from bed: big, dim figures to read across the room (Richard, 2026-11-13).
    var glance: Bool?
}

enum ConsolePlace {
    static let pages: [(id: String, name: String, symbol: String)] = [
        ("home", "Home", "house"), ("overview", "Mac Pro", "gauge.with.dots.needle.67percent"), ("temps", "Temperatures", "thermometer.medium"),
        ("everything", "Everything", "checklist"), ("activity", "Activity", "clock.arrow.circlepath"), ("processes", "Processes", "cpu"),
        ("tv", "Google TV", "tv"), ("chumby", "Chumby", "alarm"), ("storage", "Storage", "internaldrive"),
        ("startup", "Startup", "power"), ("updates", "Updates", "arrow.down.circle"), ("logs", "Logs", "doc.text.magnifyingglass"),
        ("terminal", "Terminal", "terminal"), ("settings", "Settings", "gearshape"),
    ]
    static let boards: [(id: String, name: String, symbol: String, about: String)] = [
        ("machine", "The machine", "cpu", "All eight temperatures, the processors, memory, fan, network and disk"),
        ("media", "Playing", "play.tv", "What’s on the TV, music on the Chumby, Stremio’s continue watching"),
        ("home", "The room", "alarm", "The time, the Chumby’s next alarm and the weather"),
        ("work", "Work", "hammer", "Claude sessions, builds, tests and TestFlight"),
    ]
    static func name(_ s: ConsoleState) -> (String, String) {
        if let b = s.board, let x = boards.first(where: { $0.id == b }) { return (x.name, x.symbol) }
        if let p = s.page, let x = pages.first(where: { $0.id == p }) { return (x.name, x.symbol) }
        if s.page == "boards" { return ("Boards", "rectangle.on.rectangle.angled") }
        return ("The Console is open", "macwindow")
    }
}

extension API {
    private func consoleRequest(_ path: String, body: [String: String]? = nil, timeout: TimeInterval = 15) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            r.httpMethod = "POST"
            r.setValue(MacFiles.origin(base), forHTTPHeaderField: "Origin")
            r.setValue("1", forHTTPHeaderField: "x-dash")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }
    // nil: this Mac's bridge has no Console routes yet (404).
    func consoleState() async throws -> ConsoleState? {
        let (d, resp) = try await session.data(for: consoleRequest("/api/mac/console"))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw SendError.say(MacFiles.reason(code, d)) }
        return try JSONDecoder().decode(ConsoleState.self, from: d)
    }
    struct ConsoleAnswer: Decodable { let ok: Bool?; let acked: Bool?; let error: String?; let console: ConsoleState? }
    // What the Console said: ok, or why not, and its state after.
    func consoleCommand(_ cmd: String, _ arg: String = "") async -> (error: String?, state: ConsoleState?) {
        var b = ["cmd": cmd]; if !arg.isEmpty { b["arg"] = arg }
        do {
            let (d, resp) = try await session.data(for: consoleRequest("/api/mac/console/command", body: b, timeout: cmd == "show" ? 35 : 15))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let a = try? JSONDecoder().decode(ConsoleAnswer.self, from: d)
            if code == 200, a?.ok == true { return (nil, a?.console) }
            return (a?.error ?? MacFiles.reason(code, d), a?.console)
        } catch { return (MacFiles.unreachable(error) ? Phrase.macAway : error.localizedDescription, nil) }
    }
}

@MainActor
final class ConsoleRemote: ObservableObject {
    static let shared = ConsoleRemote()
    @Published var state: ConsoleState?
    @Published var read = false
    @Published var unsupported = false
    // The button waiting for the Console's answer, and what it said when it said no.
    @Published var busy: String?
    @Published var fail: (key: String, text: String)?
    func refresh(_ model: AppModel) async {
        if let posed = Self.posed(model.pose) { state = posed; read = true; return }
        do {
            let s = try await model.api.consoleState()
            unsupported = s == nil; state = s; read = true
        } catch is CancellationError {
        } catch { read = true }
    }
    func loop(_ model: AppModel) async {
        while !Task.isCancelled {
            if busy == nil { await refresh(model) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
    func send(_ model: AppModel, _ key: String, _ cmd: String, _ arg: String = "") {
        guard busy == nil else { return }
        withAnimation(Motion.quick) { busy = key; fail = nil }
        Task {
            if Self.posed(model.pose) != nil { try? await Task.sleep(nanoseconds: 600_000_000); withAnimation(Motion.quick) { busy = nil }; return }
            let (e, st) = await model.api.consoleCommand(cmd, arg)
            withAnimation(Motion.quick) {
                if let st { state = st }
                busy = nil
                if let e { fail = (key, e) }
            }
            if e == nil, st == nil { await refresh(model) }
        }
    }
    // The build's shots: the Console up on a board, and not running.
    static func posed(_ pose: String) -> ConsoleState? {
        switch pose {
        case "console": return ConsoleState(running: true, frontmost: true, fullscreen: true, page: "temps", board: nil, rotate: false, animations: "full", display: "awake")
        case "consoleboard": return ConsoleState(running: true, frontmost: true, fullscreen: true, page: "boards", board: "machine", rotate: true, animations: "gentle", display: "awake")
        case "consoleoff": return ConsoleState(running: false)
        default: return nil
        }
    }
}

struct ConsoleTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var remote = ConsoleRemote.shared
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    var st: ConsoleState? { remote.state }
    var running: Bool { st?.running == true }

    // A button's state at its end: the wait for the Console's answer.
    @ViewBuilder func trailing(_ key: String, on: Bool = false) -> some View {
        if remote.busy == key { ProgressView() }
        else if on { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(macBlue).accessibilityLabel("On the screen now") }
    }
    @ViewBuilder func failLine(_ keys: [String]) -> some View {
        if let f = remote.fail, keys.contains(where: { f.key.hasPrefix($0) }) { FailText(f.text) }
    }

    // What the Mac's screen shows now.
    var nowCard: some View {
        Section {
            if remote.unsupported {
                HeroCard(symbol: "display", color: .secondary, title: "Not on this Mac yet", detail: "The Mac needs the newer dashboard to take the Console’s buttons.") { EmptyView() }
            } else if !remote.read {
                HeroCard(symbol: nil, color: .secondary, title: "Looking at the Mac…", detail: nil) { EmptyView() }
            } else if let st, st.running {
                let (name, symbol) = ConsolePlace.name(st)
                HeroCard(symbol: symbol, color: macBlue, title: name, detail: facts(st)) {
                    HStack(spacing: 10) {
                        if st.frontmost != true || st.fullscreen != true {
                            Button { remote.send(model, "show", "show") } label: { busyLabel("Bring to front", "show") }.buttonStyle(.borderedProminent).tint(macBlue)
                        } else {
                            Button { remote.send(model, "hide", "hide") } label: { busyLabel("Hide", "hide") }.buttonStyle(.bordered)
                        }
                        if st.display == "asleep" {
                            // Wake only on his tap (API.md): never sent by itself.
                            Button { remote.send(model, "display:wake", "display", "wake") } label: { busyLabel("Wake display", "display:wake") }.buttonStyle(.bordered)
                        } else {
                            Button { remote.send(model, "display:sleep", "display", "sleep") } label: { busyLabel("Sleep display", "display:sleep") }.buttonStyle(.bordered)
                        }
                    }
                }
            } else {
                HeroCard(symbol: "moon.zzz", color: .secondary, title: "The Console isn’t open", detail: nil) {
                    Button { remote.send(model, "show", "show") } label: { busyLabel("Start", "show") }.buttonStyle(.borderedProminent).tint(macBlue)
                }
            }
        } footer: { failLine(["show", "hide", "display"]) }
        .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
    }
    func busyLabel(_ t: String, _ key: String) -> some View {
        HStack(spacing: 6) { if remote.busy == key { ProgressView().controlSize(.small) }; Text(t) }
    }
    // Only what the Console has said: before its first word about itself, nothing.
    func facts(_ st: ConsoleState) -> String? {
        guard st.fullscreen != nil || st.frontmost != nil || st.display != nil else { return nil }
        var f: [String] = []
        f.append(st.fullscreen == true ? "Full screen" : "In a window")
        if st.frontmost != true { f.append("behind other windows") }
        if st.display == "asleep" { f.append("display asleep") }
        return f.joined(separator: " · ")
    }

    var boards: some View {
        Section {
            ForEach(Array(ConsolePlace.boards.enumerated()), id: \.offset) { i, b in
                Button { remote.send(model, "board:" + b.id, "board", b.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: b.symbol).foregroundStyle(macBlue).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name).foregroundStyle(.primary)
                            Text(b.about).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        trailing("board:" + b.id, on: running && st?.board == b.id)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(OwnSeparator(first: i == 0, ends: 9)).ownSeparatorRow()
            }
            if running, st?.board != nil {
                Button { remote.send(model, "board:off", "board", "off") } label: {
                    HStack { Text("Leave the board"); Spacer(); trailing("board:off") }
                }
                .modifier(OwnSeparator(first: false, ends: 9)).ownSeparatorRow()
            }
            Toggle(isOn: Binding(get: { st?.rotate == true }, set: { on in remote.send(model, "rotate", "rotate", on ? "on" : "off") })) {
                HStack { Text("Take turns"); if remote.busy == "rotate" { ProgressView().padding(.leading, 6) } }
            }
            .tint(macBlue)
            .modifier(OwnSeparator(first: false, ends: 9)).ownSeparatorRow()
        } header: { Text("Boards") } footer: { failLine(["board", "rotate"]) }
        .disabled(!running || remote.busy != nil)
    }

    var pages: some View {
        Section {
            // Two columns in every posture: the 14 pages fill every row, where three left a half-empty last row that read as a
            // missing tile (designer gate, 2026-11-13).
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                ForEach(ConsolePlace.pages, id: \.id) { p in
                    let on = running && st?.board == nil && st?.page == p.id
                    Button { remote.send(model, "page:" + p.id, "page", p.id) } label: {
                        HStack(spacing: 8) {
                            if remote.busy == "page:" + p.id { ProgressView().controlSize(.small).frame(width: 22) }
                            else { Image(systemName: p.symbol).frame(width: 22) }
                            Text(p.name).font(.subheadline).lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(on ? macBlue : Color(white: 0.17), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 12)
        } header: { Text("Pages") } footer: { failLine(["page"]) }
        .disabled(!running || remote.busy != nil)
    }

    var motion: some View {
        Section {
            Picker("Animations", selection: Binding(get: { st?.animations ?? "full" }, set: { remote.send(model, "animations", "animations", $0) })) {
                Text("Full").tag("full"); Text("Gentle").tag("gentle"); Text("Off").tag("off")
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 6)
        } header: { Text("Animations") } footer: { failLine(["animations"]) }
        .disabled(!running || remote.busy != nil)
    }

    // Glance mode, first under what's on the screen: the one he reaches for from bed.
    var glance: some View {
        Section {
            Toggle(isOn: Binding(get: { st?.glance == true }, set: { on in remote.send(model, "glance", "glance", on ? "on" : "off") })) {
                HStack(spacing: 12) {
                    Image(systemName: "bed.double").foregroundStyle(macBlue).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Glance mode").font(.headline)
                        Text("Big, dim figures to read from bed").font(.footnote).foregroundStyle(.secondary)
                    }
                    if remote.busy == "glance" { ProgressView().padding(.leading, 6) }
                }
            }
            .tint(macBlue)
        } footer: { failLine(["glance"]) }
        .disabled(!running || remote.busy != nil)
    }
    var body: some View {
        Group {
            switch side {
            case .all: nowCard; glance; boards; pages; motion
            case .left: nowCard; glance; boards
            case .right: pages; motion
            }
        }
        .task(id: side) { if side != .right { await remote.loop(model) } }
    }
}

// MARK: - The Mac and the app, linked (Richard, 2026-11-13: "make sure dashboard and app are inextricably linked")

// Restart Safely, Bring Everything Up or Send to Mac under way or just over, whichever side started it.
struct MacAction: Decodable, Equatable {
    struct Part: Decodable, Equatable, Identifiable { let part: String; var label: String?; let state: String; var say: String?; var id: String { part } }
    struct File: Decodable, Equatable { let name: String; var bytes: Double?; var total: Double? }
    let id: String; let kind: String; let by: String; let state: String
    var say: String?; let startedAt: Double; var endedAt: Double?
    var parts: [Part]?; var file: File?
}

// An action's progress as the Mac reports it: each part by its name as it comes back, or a bar for a file landing.
struct MacActionProgress: View {
    let action: MacAction
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let f = action.file, let total = f.total, total > 0 {
                ProgressView(value: min(f.bytes ?? 0, total), total: total).tint(macBlue)
                Text("\(f.name) · \(MacSendSize.bytes(f.bytes ?? 0)) of \(MacSendSize.bytes(total))").font(.footnote).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).truncationMode(.middle)
            }
            ForEach(action.parts ?? []) { p in
                HStack(spacing: 8) {
                    Image(systemName: p.state == "bad" ? "exclamationmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(p.state == "bad" ? Color.red : Color.green)
                    Text(p.label ?? MacParts.name(p.part)).font(.subheadline)
                    Spacer(minLength: 8)
                    if p.state == "fixed" { Text("Brought back").font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
extension API {
    func macActionNow() async -> MacAction? {
        struct W: Decodable { let action: MacAction? }
        guard let (d, r) = try? await session.data(for: consoleRequest("/api/mac/actions/current", timeout: 8)), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(W.self, from: d))?.action
    }
    // Put away here, put away on the Mac's Console too (the bridge keeps it until the alert is news again).
    func alertDismiss(_ id: String) async { _ = try? await session.data(for: consoleRequest("/api/mac/alerts/dismiss", body: ["id": id], timeout: 8)) }
}

@MainActor
enum MacMirror {
    private static var seenRestart: String?
    // A restart asked on the Mac is followed here as if asked from the phone: Everything says it going down and coming back.
    static func follow(_ a: MacAction?) {
        guard let a, a.kind == "restart", a.by == "console", a.state == "done", seenRestart != a.id else { return }
        seenRestart = a.id
        let at = Date(timeIntervalSince1970: a.startedAt / 1000)
        if let asked = RestartWatch.shared.askedAt, asked >= at.addingTimeInterval(-5) { return }
        RestartWatch.shared.asked(); RestartWatch.shared.askedAt = at
    }
    static func loop(_ model: AppModel) async {
        guard model.pose.isEmpty else { return }
        while !Task.isCancelled {
            if !model.screenOpen { follow(await model.api.macActionNow()) }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
}

// "Show on Mac": the page he is on, put on the Mac's Console (started first when it isn't open). The button says what the
// Console answered: a tick when it acked, a mark and the reason when it didn't.
struct ShowOnMacButton: View {
    @EnvironmentObject var model: AppModel
    let page: String
    @State private var phase = 0   // 0 idle, 1 waiting, 2 acked, 3 failed
    @State private var why: String?
    var body: some View {
        Button { go() } label: {
            Group {
                switch phase {
                case 1: ProgressView()
                case 2: Image(systemName: "checkmark").foregroundStyle(.green)
                case 3: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                default: Image(systemName: "macwindow").foregroundStyle(macBlue)
                }
            }
            .font(.title2).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phase == 1)
        .accessibilityLabel("Show on the Mac")
        .alert("Not shown on the Mac", isPresented: Binding(get: { why != nil }, set: { if !$0 { why = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(why ?? "") }
    }
    func go() {
        phase = 1
        Task {
            var e: String?
            if model.pose.isEmpty {
                if (try? await model.api.consoleState())??.running != true { e = await model.api.consoleCommand("show").error }
                if e == nil { e = await model.api.consoleCommand("page", page).error }
            } else { try? await Task.sleep(nanoseconds: 500_000_000) }
            withAnimation(Motion.quick) { phase = e == nil ? 2 : 3 }
            if let e { why = e }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(Motion.quick) { phase = 0 }
        }
    }
}
