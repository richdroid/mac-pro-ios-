import SwiftUI

// The Console tab (Richard, 2026-11-13: the Console on the Mac is "a full screen affair fully controllable from buttons
// on the mac pro app", and its controls are a "separate tab"). It shows what the Mac's screen is on right now and has a
// button for every page, board and setting. Each button says whether the Console did it: the bridge relays the command
// to the Console and answers with the Console's own ack (API.md "Console remote"), never with what was hoped for.

struct ConsoleState: Codable, Equatable {
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
    // The Console has stepped out of the way while the phone's Screen is open (the bridge says).
    var screenStepAside: Bool?
}

enum ConsolePlace {
    static let pages: [(id: String, name: String, symbol: String)] = [
        ("home", "Home", "house"), ("overview", "Mac Pro", "gauge.with.dots.needle.67percent"), ("temps", "Fans & heat", "thermometer.medium"),
        ("everything", "Everything", "checklist"), ("activity", "What’s happening", "clock.arrow.circlepath"), ("processes", "Processes", "cpu"),
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
        // Glance draws over every page and board on the Mac, so it is what the screen shows while it's on.
        if s.glance == true { return ("Glance", "bed.double") }
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
    // The Console as it last said, at once on opening, so the card doesn't sit on "Looking at the Mac…" (designer gate,
    // 2026-11-18); the first reading replaces it a moment later.
    // Not for the build's posed Consoles, which are set once as they're first read.
    private static let kept: ConsoleState? = MacConsole.pose.isEmpty ? UserDefaults.standard.data(forKey: "consoleState").flatMap { try? JSONDecoder().decode(ConsoleState.self, from: $0) } : nil
    @Published var state: ConsoleState? = ConsoleRemote.kept
    @Published var read = ConsoleRemote.kept != nil
    @Published var unsupported = false
    // The button waiting for the Console's answer, and what it said when it said no.
    @Published var busy: String?
    @Published var fail: (key: String, text: String)?
    // Counted when the Console's answer comes: the Dashboard's done and warn haptics (manifesto, haptic vocabulary).
    @Published var answered = 0
    @Published var refused = 0
    func refresh(_ model: AppModel) async {
        // A posed Console keeps what the posed buttons did to it; it is set once, as a real one would be read.
        if let posed = Self.posed(model.pose) {
            if !read { state = posed; read = true; if model.pose == "consolestarting" { busy = "show" } }
            return
        }
        do {
            let s = try await model.api.consoleState()
            unsupported = s == nil; state = s; read = true
            if let s, let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "consoleState") }
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
            if Self.posed(model.pose) != nil {
                // As the stand-in Mac answers: the Console's ack after a moment (Start takes longer), and its state after.
                try? await Task.sleep(nanoseconds: cmd == "show" ? 1_500_000_000 : 600_000_000)
                // The build's shot of a refusal: the Console didn't answer in time, said under the keys, then gone.
                if model.pose == "consolefail" {
                    withAnimation(Motion.quick) { busy = nil; fail = (key, "The Console didn’t answer."); refused += 1 }
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if fail?.key == key { withAnimation(Motion.quick) { fail = nil } }
                    return
                }
                withAnimation(Motion.quick) {
                    busy = nil; answered += 1
                    switch cmd {
                    case "show": state = ConsoleState(running: true, frontmost: true, fullscreen: true, page: state?.page ?? "home", board: state?.board, rotate: state?.rotate ?? false, animations: state?.animations ?? "full", display: "awake", glance: state?.glance ?? false)
                    case "hide": state?.frontmost = false
                    case "glance": state?.glance = arg == "on"
                    case "display": state?.display = arg == "wake" ? "awake" : "asleep"
                    case "page": state?.page = arg; state?.board = nil
                    case "board": state?.board = arg == "off" ? nil : arg
                    case "rotate": state?.rotate = arg == "on"
                    case "animations": state?.animations = arg
                    default: break
                    }
                }
                return
            }
            let (e, st) = await model.api.consoleCommand(cmd, arg)
            withAnimation(Motion.quick) {
                if let st { state = st }
                busy = nil
                if let e { fail = (key, e); refused += 1 } else { answered += 1 }
            }
            // An error is read once: gone after a few seconds, unless a newer one has taken its place.
            if let e {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if fail?.text == e, busy == nil { withAnimation(Motion.quick) { fail = nil } }
            }
            if e == nil, st == nil { await refresh(model) }
        }
    }
    // The build's shots: the Console up on a board, and not running.
    static func posed(_ pose: String) -> ConsoleState? {
        switch pose {
        case "console", "glancefilm": return ConsoleState(running: true, frontmost: true, fullscreen: true, page: "temps", board: nil, rotate: false, animations: "full", display: "awake")
        case "consoleboard": return ConsoleState(running: true, frontmost: true, fullscreen: true, page: "boards", board: "machine", rotate: true, animations: "gentle", display: "awake")
        // Glance on the Mac's screen, the display awake.
        case "consoleglance": return ConsoleState(running: true, frontmost: true, fullscreen: true, page: "home", board: nil, rotate: false, animations: "full", display: "awake", glance: true)
        case "consoleoff", "consolestarting": return ConsoleState(running: false)
        case "consolefail": return ConsoleState(running: true, frontmost: true, fullscreen: true, page: "home", board: nil, rotate: false, animations: "full", display: "awake", glance: false)
        // Open but not in front (another app is), and the display asleep under Glance, as the Mac was on 2026-11-16.
        case "consolebehind": return ConsoleState(running: true, frontmost: false, fullscreen: true, page: "everything", board: nil, rotate: true, animations: "full", display: "awake", glance: false)
        case "consoleasleep": return ConsoleState(running: true, frontmost: false, fullscreen: true, page: "everything", board: nil, rotate: true, animations: "full", display: "asleep", glance: true)
        case "consoleaside": return ConsoleState(running: true, frontmost: false, fullscreen: true, page: "home", board: nil, rotate: false, animations: "full", display: "awake", glance: false, screenStepAside: true)
        default: return nil
        }
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


// The Mac follows the phone (plan 2b; Richard, 2026-11-19: "show on mac buttons r out of place and the latter is dumb").
// While the app is in front, the page he settles on (about a second, once per change) is told to the Console as a
// "follow", never a "show": the Console turns to it only if it is already on screen with nothing he left running on it,
// and never starts itself or wakes the display (its side enforces that; nothing here ever sends a start). The ids are
// the ones "Show on Mac" sent. The Dashboard's chips stay the one deliberate push.
enum MacFollow {
    static let defaultsKey = "macFollows"
    // The Console page for where he is, or nil where there's none to follow to (the Dashboard itself, Settings, Control's
    // own list, a restart).
    @MainActor static func page(tab: Int, nav n: NavStore) -> String? {
        if n.settingsOpen && n.settingsTab == tab { return nil }
        func of(_ p: MacPage?) -> String? {
            switch p {
            case .health: "everything"
            case .fans: "temps"
            case .updates, .upgrade: "updates"
            case .storage: "storage"
            case .startup: "startup"
            default: nil
            }
        }
        func of(_ h: HistoryMetric?) -> String { h?.kind == .temperature ? "temps" : "overview" }
        switch tab {
        case 0: return n.processes != nil ? "processes" : of(n.history)
        case 1, 2: return "activity"
        case 4: return "updates"
        case 5: return of(n.macPage)
        case 6:
            if n.dashProcesses != nil { return "processes" }
            if let h = n.dashHistory { return of(h) }
            return of(n.dashPage)
        default: return nil
        }
    }
}
// Watches where he is and tells the Mac, settled and only on a change. Drawn as nothing, beside the tabs.
struct MacFollower: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var nav: NavStore
    @Environment(\.scenePhase) private var phase
    @AppStorage(MacFollow.defaultsKey) private var on = true
    @State private var sent: String?
    var body: some View {
        let page = on && phase == .active ? MacFollow.page(tab: model.tab, nav: nav) : nil
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: page) {
                // Nowhere to follow to (away, following off, or a page the Console hasn't): the next page is said even if
                // it's the last one again, since the Mac may have moved meanwhile (the Dashboard's chips, the desk).
                guard let page else { sent = nil; return }
                guard page != sent else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                sent = page
                _ = await model.api.consoleCommand("follow", page)
            }
    }
}
