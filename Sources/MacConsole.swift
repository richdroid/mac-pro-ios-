import Charts
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The Mac Pro as a control surface (Richard, 2026-11-13: "have all the proxies and stuff status and such accessible be able
// to control updates everything fan speed perhaps also build that into the ios app like i want this to be powerful").
// Five pages on the Control tab, each read from the bridge's /api/mac/* feeds, the same ones MacPro Console reads on the
// Mac (one source of truth): Connections, Fans & temperatures, Updates, Storage, Startup items.
// A bridge without a feed (an older one) answers 404: its row and page are simply not there, never an error.
// Every action says what really happened (the bridge checks after the fact), asks first before anything that stops,
// restarts or changes the Mac, and nothing read while the Mac is away passes for live.

// MARK: - Feeds

struct MacLink: Decodable, Identifiable, Equatable {
    struct Failure: Decodable, Equatable { let text: String; var t: Double? }
    let id: String; var state: String
    // The Mac's own name for it ("Tailscale Serve", "Chumby proxy"), said in his words here (Richard, 2026-11-13: no
    // plumbing words on any page).
    private let rawName: String
    var name: String {
        switch id {
        case "serve": return "Phone link"
        case "funnel": return "Fixed public address"
        case "bridge": return "Mac dashboard"
        case "public": return "Public link"
        case "novnc": return "Screen link"
        case "letterboxd": return "Letterboxd sign-in"
        case "tv": return "TV"
        case "chumby-remote": return "Chumby link"
        default: return rawName
        }
    }
    enum CodingKeys: String, CodingKey { case id, state, rawName = "name", detail, endpoint, pid, uptime, lastExit, lastError, checkedAt, can, via, note, since }
    init(id: String, name: String, state: String, detail: String? = nil, endpoint: String? = nil, pid: Int? = nil, uptime: Double? = nil, lastExit: Int? = nil, lastError: Failure? = nil, checkedAt: Double? = nil, can: [String]? = nil, via: String? = nil, note: String? = nil, since: Double? = nil) {
        self.id = id; self.rawName = name; self.state = state; self.detail = detail; self.endpoint = endpoint; self.pid = pid; self.uptime = uptime
        self.lastExit = lastExit; self.lastError = lastError; self.checkedAt = checkedAt; self.can = can; self.via = via; self.note = note; self.since = since
    }
    var detail: String?; var endpoint: String?; var pid: Int?; var uptime: Double?; var lastExit: Int?
    var lastError: Failure?; var checkedAt: Double?; var can: [String]?; var via: String?; var note: String?; var since: Double?
    var up: Bool { state == "up" }
    // What the row says under its name, in his words. The Mac's own line ("https → the bridge, tailnet only", "Cloudflare
    // tunnel up", "Running, listening on 8767") was plumbing (designer gate, 2026-11-13); a failure the app has no words
    // for is still said as the Mac says it, since it is news.
    var plainDetail: String? {
        let d = detail ?? ""
        // A second line only when it adds a fact: "Working" or "Answering" beside "Up", "Off, as it should be" beside "Off"
        // said the state twice (designer gate, 2026-11-14).
        let filler: Set<String> = ["connected", "working", "answering", "running", "up", "off", "ok", "listening", "off, as it should be"]
        switch (id, state) {
        case ("serve", "up"): return nil
        case ("serve", "down"): return "This app’s link isn’t set up"
        case ("funnel", "look"): return "On: the Mac dashboard is open to the internet"
        case ("funnel", "off"): return nil
        case ("public", "up"), ("novnc", "up"), ("letterboxd", "up") where !d.contains("not listening"): return nil
        case ("letterboxd", "up"): return "Running, but not answering"
        case ("public", "starting"): return "Starting, no address yet"
        case ("bridge", _):
            if d.contains("TestFlight") { return "Sending a build to TestFlight" }
            return state == "up" ? nil : d
        case ("tv", "down"):
            // The Mac's reason ("no adb server is running") is behind the tap with the other parts.
            if let c = d.range(of: ": ") { return String(d[..<c.lowerBound]) }
            return d.isEmpty ? nil : d
        case ("sessions", _):
            if let r = d.range(of: #"(\d+) of (\d+) kept running"#, options: .regularExpression) {
                let n = d[r].split(separator: " "); return n[0] == n[2] ? "All \(n[2]) running" : "\(n[0]) of \(n[2]) running"
            }
            return d
        case ("tailscale", _) where state == "up":
            // "Running · 4 of 6 devices online": the state is said by the row; the count is the news.
            return d.hasPrefix("Running · ") ? String(d.dropFirst(10)) : (filler.contains(d.lowercased()) ? nil : d)
        case (_, "down") where ["not running", "down", "not answering"].contains(d.lowercased()): return nil
        default:
            if state != "down", filler.contains(d.lowercased()) { return nil }
            return d.isEmpty ? nil : d.replacingOccurrences(of: "the bridge", with: "the Mac dashboard").replacingOccurrences(of: "Tailscale didn’t", with: "Remote access didn’t")
        }
    }
    // What a row keeps behind its tap beside the addresses: the Mac's reason for a TV link that is down.
    var reason: String? {
        guard id == "tv", state == "down", let d = detail, let c = d.range(of: ": ") else { return nil }
        let t = String(d[c.upperBound...]); return t.prefix(1).uppercased() + t.dropFirst()
    }
    // Off is a state of its own (Funnel is meant to be off), not a fault.
    var down: Bool { state == "down" }
}
struct LinksFeed: Decodable, Equatable { let t: Double; var healthAt: Double?; var links: [MacLink] }

struct MacFan: Decodable, Identifiable, Equatable {
    let index: Int; let name: String; let rpm: Double; let min: Double; let max: Double; var target: Double?; var mode: String?
    var id: Int { index }
    // Where the speed sits between the fan's own floor and ceiling.
    var level: Double { max > min ? Swift.min(Swift.max((rpm - min) / (max - min), 0), 1) : 0 }
}
struct FansFeed: Decodable, Equatable {
    // The fan floor helper (installed once by Richard): "needs-setup" until it answers, then "ready" with its mode
    // ("auto" or "floor") and the presets it may raise the floor to. It can only make the fan faster than the Mac would.
    struct Control: Decodable, Equatable {
        struct Preset: Decodable, Equatable, Identifiable { let name: String; let rpm: Int; var id: Int { rpm } }
        let state: String; var title: String?; var note: String?; var setup: String?; var mode: String?; var floor: Int?; var factoryFloor: Int?; var max: Int?; var presets: [Preset]?
        var ready: Bool { state == "ready" }
    }
    var t: Double?; var stale: Bool?; let fans: [MacFan]; var control: Control?
}
struct TempsFeed: Decodable, Equatable {
    struct Named: Decodable, Identifiable, Equatable { let name: String; var key: String?; let c: Double; var warn: Double?; var hot: Double?; var id: String { name } }
    struct Sensor: Decodable, Identifiable, Equatable { let key: String; let group: String; let label: String; let c: Double; var id: String { key } }
    struct Hottest: Decodable, Equatable { let name: String; let c: Double }
    var t: Double?; var stale: Bool?; let named: [Named]; let all: [Sensor]; var hottest: Hottest?; var verdict: String?
}
struct UpdatesFeed: Decodable, Equatable {
    struct Pending: Decodable, Identifiable, Equatable { let label: String; var version: String?; var size: String?; var restart: Bool?; var id: String { label } }
    struct MacOS: Decodable, Equatable { let current: String; var checkedAt: Double?; var checking: Bool?; var pending: [Pending]?; var error: String?; var autoInstall: Bool?; var command: String?; var risk: String? }
    struct OCLP: Decodable, Equatable { var installed: String?; var latest: String?; var latestPre: Bool?; var newer: Bool?; var patchedFor: String?; var patchedAt: String?; var patches: String?; var healthy: Bool?; var command: String? }
    struct Package: Decodable, Identifiable, Equatable { let name: String; var installed: String?; var latest: String?; var id: String { name } }
    struct Job: Decodable, Equatable { let state: String; var startedAt: Double?; var endedAt: Double?; var say: String? }
    struct Brew: Decodable, Equatable { var outdated: [Package]?; var error: String?; var job: Job? }
    struct AppVersion: Decodable, Identifiable, Equatable { let name: String; var installed: String?; var latest: String?; var how: String?; var id: String { name } }
    var t: Double?; let macos: MacOS; var oclp: OCLP?; var brew: Brew?; var apps: [AppVersion]?
}
struct StorageFeed: Decodable, Equatable {
    struct Volume: Decodable, Identifiable, Equatable {
        let name: String; let mount: String; let total: Double; let free: Double; var kind: String?; var isInternal: Bool?
        var id: String { mount }
        enum CodingKeys: String, CodingKey { case name, mount, total, free, kind, isInternal = "internal" }
    }
    struct Folder: Decodable, Identifiable, Equatable { let path: String; let name: String; var bytes: Double?; var dir: Bool?; var id: String { path } }
    var t: Double?; let volumes: [Volume]; var home: [Folder]?; var homeAt: Double?
}
struct FolderFeed: Decodable, Equatable {
    struct Child: Decodable, Identifiable, Equatable { let name: String; var bytes: Double?; var dir: Bool?; var `private`: Bool?; var id: String { name } }
    let path: String; var measuring: Bool?; var children: [Child]?; var at: Double?; var error: String?
}
struct StartupItem: Decodable, Identifiable, Equatable {
    let label: String; let kind: String; let domain: String; let path: String
    var program: String?; var loaded: Bool; var pid: Int?; var lastExit: Int?; var runAtLoad: Bool?; var keepAlive: Bool?; var interval: Double?
    var disabled: Bool?; var `protected`: String?; var editable: Bool?; var command: String?
    var id: String { label }
    var running: Bool { pid != nil }
    var mine: Bool { editable == true }
}
struct StartupFeed: Decodable, Equatable { var t: Double?; var items: [StartupItem] }

// What the Mac said an action did: done with its words, or why not.
struct MacActionResult: Decodable, Equatable {
    var ok: Bool?; var say: String?; var error: String?; var pending: Bool?; var command: String?
    var done: Bool { ok == true }
}

extension API {
    // A feed, or nil when this Mac's bridge doesn't have it (404: an older bridge).
    func macFeed<T: Decodable>(_ path: String, timeout: TimeInterval = 20) async throws -> T? {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        if code == 401 || code == 403 { throw APIError.signInNeeded }
        guard code == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(T.self, from: d)
    }
    // An action. Only a request that never got an answer throws; a refusal comes back as the Mac's reason.
    func macDo(_ path: String, _ body: [String: Any], timeout: TimeInterval = 60) async throws -> MacActionResult {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.setValue(MacFiles.origin(base), forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404, (try? JSONDecoder().decode(MacActionResult.self, from: d))?.error == nil { return MacActionResult(ok: false, error: "The Mac doesn’t know how to do that yet.") }
        var a = (try? JSONDecoder().decode(MacActionResult.self, from: d)) ?? MacActionResult(ok: false, error: "The Mac sent an unexpected reply (error \(code)).")
        if code != 200 { a.ok = false; if a.error == nil { a.error = a.say ?? "The Mac refused (error \(code))." } }
        return a
    }
}

// One feed read every few seconds while its page is up: what it last said, when, and whether the Mac has gone quiet.
@MainActor
final class FeedReader<T: Decodable & Equatable>: ObservableObject {
    @Published var value: T?
    @Published var lastRead: Date?
    // The Mac hasn't answered for a while: what's shown is old, said so, and nothing acts on it.
    @Published var away = false
    // This Mac's bridge has no such feed.
    @Published var unsupported = false
    let path: String
    private var misses = MissClock()
    init(_ path: String) { self.path = path }
    func set(_ v: T) { value = v; lastRead = Date(); away = false }
    func read(_ api: API, query: String = "") async {
        do {
            let v: T? = try await api.macFeed(path + query)
            misses.hit(); away = false
            guard let v else { unsupported = true; return }
            unsupported = false
            if v != value { withAnimation(Motion.quick) { value = v } }
            lastRead = Date()
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch is DecodingError {
            // An answer this build can't read is a bridge that doesn't have the feed in this shape: not shown.
            unsupported = value == nil
        } catch {
            if misses.miss() { away = true }
        }
    }
    func loop(_ model: AppModel, every: Double) async {
        while !Task.isCancelled {
            // Not under the Mac's screen, which has the link to itself while it's open.
            if !model.screenOpen { await read(model.api) }
            try? await Task.sleep(nanoseconds: UInt64((away ? min(every, 4) : every) * 1e9))
        }
    }
}

enum MacConsole {
    static func degrees(_ c: Double) -> String { "\(Heat.shown(c))°" }
    static func rpm(_ v: Double) -> String { "\(Int(v.rounded())) rpm" }
    static func since(_ ms: Double?) -> String? { ms.map { Format.ago(ms: $0) } }
    // "2 down: TV link, Chumby" — a count always names its parts (Richard, 2026-11-12).
    static func named(_ n: [String], _ word: String) -> String {
        n.isEmpty ? "" : n.count <= 2 ? "\(n.joined(separator: ", ")) \(word)" : "\(n.count) \(word): \(n.prefix(2).joined(separator: ", ")) and \(n.count - 2) more"
    }
    // Green only when every link is known to be up (or off as it should be); anything else is named.
    static func linkSummary(_ f: LinksFeed) -> (good: Bool, text: String) {
        let down = f.links.filter(\.down).map(\.name)
        let look = f.links.filter { $0.state == "look" }.map(\.name)
        let starting = f.links.filter { $0.state == "starting" }.map(\.name)
        let unsure = f.links.filter { !["up", "off", "down", "look", "starting"].contains($0.state) }.map(\.name)
        if !down.isEmpty { return (false, named(down, "down")) }
        if !look.isEmpty { return (false, named(look, look.count == 1 ? "needs a look" : "need a look")) }
        if !starting.isEmpty { return (false, named(starting, "starting")) }
        if !unsure.isEmpty { return (false, named(unsure, "not known")) }
        return (true, "All \(f.links.filter(\.up).count) working")
    }
    // What a row's summary gives up when it can't fit whole, longest first: a part goes by design, never a cut with an
    // ellipsis (designer gate, 2026-11-14: "1184 rpm ·…").
    static func shorter(_ t: String) -> [String] {
        var out = [t]
        var cur = t
        while let r = cur.range(of: " · ", options: .backwards) { cur = String(cur[..<r.lowerBound]); out.append(cur) }
        if let r = t.range(of: ": ") { out.append(String(t[..<r.lowerBound])) }
        else if t.contains(", "), let last = t.split(separator: " ").last { out.append("\(t.components(separatedBy: ", ").count) \(last)") }
        if t.hasSuffix(" waiting"), !(t.first?.isNumber ?? false) { out.append("1 waiting") }
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    static func exitText(_ code: Int) -> String {
        code < 0 ? "stopped by signal \(-code)" : code == 0 ? "exited cleanly" : "exited with code \(code)"
    }
    // The build's shots: one link down, a restart's result, a bridge with none of these feeds.
    static var pose: String { UserDefaults.standard.string(forKey: "pose") ?? "" }
}

extension MacPage {
    // The build's shots of each page, opened on the Control tab.
    static func consolePosed(_ pose: String) -> MacPage? {
        switch pose {
        case "links", "linksbad", "linkconfirm", "linkdone", "linkstarting", "linkrestartfilm", "linkopenfilm": return .links
        case "fans", "fanready": return .fans
        case "updates", "updateswaiting": return .updates
        case "storage": return .storage
        case "startup", "startupconfirm": return .startup
        case "actions": return .actions
        default: return nil
        }
    }
}

// MARK: - The Control tab's section

// Rows into each page, each with what the Mac last said, in words that name the part. Read every 30 s while Control is
// up; a row whose feed the bridge lacks is left out, and the section goes when none is there.
struct MacConsoleSections: View {
    @EnvironmentObject private var noticeState: NoticeStore
    @EnvironmentObject var model: AppModel
    // Read by ConsoleSummary, whose loop hangs off the Health card (always on the page): a .task here would never start
    // while this section has nothing to show, so it never would have (CI ee040e3: no This Mac card at all).
    @ObservedObject private var summary = ConsoleSummary.shared
    @ObservedObject private var links = ConsoleSummary.shared.links
    @ObservedObject private var fans = ConsoleSummary.shared.fans
    @ObservedObject private var temps = ConsoleSummary.shared.temps
    @ObservedObject private var updates = ConsoleSummary.shared.updates
    @ObservedObject private var storage = ConsoleSummary.shared.storage
    @ObservedObject private var startup = ConsoleSummary.shared.startup
    var mp: Bool { summary.mp }
    // Nothing is said while the Mac is away: the summaries are only ever what it said last, never passed off as now.
    var quiet: Bool { model.problem != nil }
    var anything: Bool { [mp, links.value != nil, fans.value != nil, updates.value != nil, storage.value != nil, startup.value != nil].contains(true) }

    func row(_ title: String, _ symbol: String, _ page: MacPage, summary: String?, good: Bool? = nil, alts: [String]? = nil) -> some View {
        Button { model.macPage = page } label: {
            HStack(spacing: 10) {
                // The row's name is never cut; its summary gives way first (CI 9abf65f: "Fans & tem…"). An icon column and a
                // fixed-size name, not a Label: a fixed-size Label drew its icon and no name (CI d9c229c).
                Image(systemName: symbol).foregroundStyle(macBlue).frame(width: 28)
                Text(title).foregroundStyle(Color.primary).lineLimit(1).fixedSize().layoutPriority(1)
                Spacer(minLength: 8)
                if let summary, !quiet {
                    HStack(spacing: 6) {
                        if let good { Circle().fill(good ? Color.green : Color.red).frame(width: 8, height: 8) }
                        // The longest that fits whole.
                        ViewThatFits(in: .horizontal) {
                            ForEach(alts ?? MacConsole.shorter(summary), id: \.self) { t in Text(t).lineLimit(1).fixedSize().monospacedDigit() }
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    var fanLine: String? {
        let f = fans.value?.fans.first, h = temps.value?.hottest
        switch (f, h) {
        case let (f?, h?): return "\(MacConsole.rpm(f.rpm)) · \(h.name) \(MacConsole.degrees(h.c))"
        case let (f?, nil): return MacConsole.rpm(f.rpm)
        case let (nil, h?): return "\(h.name) \(MacConsole.degrees(h.c))"
        default: return nil
        }
    }
    var updateLine: (String, Bool?)? {
        guard let u = updates.value else { return nil }
        let waiting = (u.macos.pending ?? []).count + ((u.brew?.outdated ?? []).count)
        if u.macos.pending == nil { return (u.macos.checking == true ? "Checking…" : "macOS \(u.macos.current.split(separator: " ").first ?? "")", nil) }
        if waiting == 0 { return ("Up to date", true) }
        let first = u.macos.pending?.first?.label ?? u.brew?.outdated?.first?.name ?? ""
        // Never a string ending in an ellipsis: the row drops the name when the room is short (MacConsole.shorter).
        return (waiting == 1 ? "\(first) waiting" : "\(waiting) waiting: \(first)", nil)
    }
    var storageLine: String? {
        guard let v = storage.value?.volumes.first(where: { $0.isInternal == true }) ?? storage.value?.volumes.first else { return nil }
        return "\(Format.bytes(v.free)) free of \(Format.bytes(v.total))"
    }
    // Kept-running agents that aren't, by name; timed ones idle between runs by design and aren't counted.
    var startupLine: (String, Bool)? {
        guard let items = startup.value?.items else { return nil }
        let mine = items.filter(\.mine)
        let stopped = StartupView.stopped(mine).map(StartupRow.name)
        return stopped.isEmpty ? ("None stopped", true) : (MacConsole.named(stopped, "stopped"), false)
    }

    var body: some View {
        Group {
            if anything {
                Section {
                    if let l = links.value { let s = MacConsole.linkSummary(l); row("Connections", "point.3.connected.trianglepath.dotted", .links, summary: s.text, good: s.good).id("macctl") }
                    if fans.value != nil || temps.value != nil { row("Fans & temperatures", "fan", .fans, summary: fanLine).id(links.value == nil ? "macctl" : "macfansrow") }
                    if updates.value != nil { row("Updates", "arrow.down.circle", .updates, summary: updateLine?.0, good: updateLine?.1) }
                    if storage.value != nil { row("Storage", "internaldrive", .storage, summary: storageLine) }
                    if startup.value != nil { row("Startup items", "power", .startup, summary: startupLine?.0, good: startupLine?.1) }
                    if mp { row("Actions", "bolt", .actions, summary: "Clean, ship, tests") }
                } header: { Text("This Mac") }
            }
        }
    }
}

// The This Mac card's readings, every 30 s while Control is up, and at once on coming back from one of its pages.
@MainActor
final class ConsoleSummary: ObservableObject {
    static let shared = ConsoleSummary()
    let links = FeedReader<LinksFeed>("/api/mac/links")
    let fans = FeedReader<FansFeed>("/api/mac/fans")
    let temps = FeedReader<TempsFeed>("/api/mac/temps")
    let updates = FeedReader<UpdatesFeed>("/api/mac/updates")
    let storage = FeedReader<StorageFeed>("/api/mac/storage")
    let startup = FeedReader<StartupFeed>("/api/mac/startup")
    @Published var mp = false
    func readAll(_ api: API) async {
        // Asked again until it answers: a Mac away at the first look mustn't hide Actions for good.
        if !mp { let m = await api.mpAvailable(); if m != mp { mp = m } }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await self.links.read(api) }; g.addTask { await self.fans.read(api) }; g.addTask { await self.temps.read(api) }
            g.addTask { await self.updates.read(api) }; g.addTask { await self.storage.read(api) }; g.addTask { await self.startup.read(api) }
        }
    }
    func loop(_ model: AppModel) async {
        if MacConsole.pose == "oldbridge" { return }
        while !Task.isCancelled {
            if !model.screenOpen { await readAll(model.api) }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }
}

// MARK: - Page frame

// A pushed page's frame, as Everything on the Mac draws it: its name first, one pane or two, and the stale line when the
// Mac has gone quiet (what's below stays, dimmed, and takes no taps).
struct ConsolePage<Left: View, Right: View>: View {
    @Environment(\.paneLayout) private var panes
    @Environment(\.statusBarTop) private var statusBarTop
    let title: String
    let place: String
    let away: Bool
    let lastRead: Date?
    // The build's film: the row to open the page at, once it's there (the public link, for its restart).
    var startAt: String? = nil
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right
    func list(_ side: Side) -> some View {
        ScrollViewReader { proxy in
            List {
                Section { PaneHeading(title: title, shown: side != .right, roomAbove: false, onMac: ["macfans": "temps", "macupdates": "updates", "macstorage": "storage", "macstartup": "startup"][place]) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
                if away, side != .right { Section { StaleLine(lastRead: lastRead) } }
                Group {
                    if side != .right { left() }
                    if side != .left { right() }
                }
                .opacity(away ? staleDim : 1)
                .disabled(away)
            }
            // The title's room under a side status bar is the list's margin, not the row's: inside the row it pushed the
            // title down into the row's rounded corner, which notched the F of Fans and the M of Mac (CI d9c229c).
            .contentMargins(.top, 4 + PaneHeading.roomAbove(statusBarTop), for: .scrollContent)
            .scrollsUnder(side == .right ? 1 : 0)
            .keepsPlace(place, proxy)
            .task(id: startAt) {
                guard let to = startAt else { return }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                proxy.scrollTo(to, anchor: .top)
            }
        }
    }
    var body: some View {
        Group {
            if panes { FoldSplit { list(.left) } right: { list(.right) } } else { list(.all) }
        }
        .holdsWhileMoving(place)
        .modifier(TabBarFade())
        .background(groupedBackground.ignoresSafeArea())
        .topEdge()
        .pushedTitle()
        .animation(Motion.quick, value: away)
    }
}

// A row's outcome under it: green with what happened, red with why not.
struct OutcomeLine: View {
    let result: MacActionResult
    var body: some View {
        if result.done {
            Label(result.say ?? "Done", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            FailText(result.error ?? "That didn’t work.")
        }
    }
}

// MARK: - Connections

struct LinkRow: View {
    let link: MacLink
    let busy: Bool
    let outcome: MacActionResult?
    // Not the first in its card: drawn with its own separator above (see body).
    var first = true
    let act: (String) -> Void
    // The action the page is asking about for this link: the question hangs off the button that asked it.
    var asked: String? = nil
    var confirm: (String) -> Void = { _ in }
    var dismiss: () -> Void = {}
    var question: (String) -> String = { _ in "" }
    var color: Color { link.up ? .green : link.down ? .red : ["starting", "look"].contains(link.state) ? .orange : .secondary }
    var stateWord: String {
        switch link.state { case "up": return "Up"; case "down": return "Down"; case "off": return "Off"; case "starting": return "Starting"; case "look": return "Needs a look"; default: return "Not known" }
    }
    static func actionName(_ a: String, _ link: MacLink) -> String {
        switch a { case "restart": return "Restart"; case "repoint": return "Reconnect"; case "bringup": return link.down ? "Fix" : "Start"; default: return a.capitalized }
    }
    static func symbol(_ id: String) -> String {
        switch id {
        case "tailscale": return "network"; case "serve": return "link"; case "funnel": return "globe"
        case "bridge": return "point.3.connected.trianglepath.dotted"; case "public": return "cloud"
        case "novnc": return "display"; case "letterboxd": return "film"; case "tv": return "tv"
        case "chumby-remote": return "arrow.left.arrow.right"; case "chumby": return "alarm"; case "sessions": return "terminal"
        default: return "circle"
        }
    }
    var facts: [String] {
        var f: [String] = []
        if let e = link.endpoint, !e.isEmpty { f.append(e) }
        if let u = link.uptime { f.append("up \(Format.span(u))") }
        if let p = link.pid { f.append("process \(p)") }
        if let x = link.lastExit, !link.up { f.append("last \(MacConsole.exitText(x))") }
        return f
    }
    // Addresses, processes, the last error and the Mac's note only on a tap: he reads the state first, the parts behind it
    // when he asks (designer gate, 2026-11-13: "ports, pids and addresses go behind a tap").
    @State private var open = false
    var actions: [String] { (link.can ?? []).filter { $0 != "bringup" } }
    var more: Bool { !facts.isEmpty || link.lastError != nil || link.note != nil || link.reason != nil || !actions.isEmpty }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.symbol(link.id)).foregroundStyle(.secondary).frame(width: 26).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    // The separator starts under the name, on every row (CI d9c229c: Chumby proxy's ran full width).
                    Text(link.name)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) { Circle().fill(color).frame(width: 8, height: 8); Text(stateWord) }.font(.footnote).foregroundStyle(.secondary)
                    if more { Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Color.primary.opacity(0.3)).rotationEffect(.degrees(open ? 180 : 0)) }
                }
                if let d = link.plainDetail, d != stateWord { Text(d).font(.footnote).foregroundStyle(link.down ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true) }
                if open {
                    if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true) }
                    if let r = link.reason { Text(r).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let e = link.lastError {
                        Text("Last error\(e.t.map { " " + Format.ago(ms: $0) } ?? ""): \(e.text)").font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if let n = link.note { Text(n).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                // Only what went wrong: a success shows in the row's own state and line, so saying it again was noise
                // (designer, CI d9c229c), and a failure the row's line already says isn't repeated.
                if let outcome, !outcome.done, outcome.error != link.detail { OutcomeLine(result: outcome) }
                // A link that is up keeps its Restart behind the row's tap; one that isn't shows its action at once.
                if !actions.isEmpty, open || !link.up || busy || asked != nil {
                    let can = actions
                    HStack(spacing: 8) {
                        ForEach(can, id: \.self) { a in
                            Button(Self.actionName(a, link)) { act(a) }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                                .modifier(FilmTarget(on: MacConsole.pose == "linkrestartfilm" && link.id == "public" && a == "restart"))
                                .confirmationDialog("\(Self.actionName(a, link)) \(link.name)?", isPresented: Binding(get: { asked == a }, set: { if !$0, asked == a { dismiss() } }), titleVisibility: .visible) {
                                    Button(Self.actionName(a, link), role: .destructive) { confirm(a) }
                                    Button("Cancel", role: .cancel) {}
                                } message: { Text(question(a)) }
                        }
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onAppear { if asked != nil || (MacConsole.pose == "linkrestartfilm" && link.id == "public") { open = true } }
        .onChange(of: asked) { _, a in if a != nil { open = true } }
        // The build's film of a row opening: the bridge's, a few seconds after the page is up.
        .task { if MacConsole.pose == "linkopenfilm", link.id == "bridge" { try? await Task.sleep(nanoseconds: 3_000_000_000); withAnimation(.snappy(duration: 0.25)) { open = true } } }
        .onTapGesture { if more { withAnimation(.snappy(duration: 0.25)) { open.toggle() } } }
        .accessibilityAction(named: open ? "Fewer details" : "More details") { open.toggle() }
        .modifier(OwnSeparator(first: first))
    }
}

// The build's film taps the public link's Restart with a real touch: where the button is, as fractions of the window, in
// Caches/tap.txt for the workflow to read. Only with that pose; never on the phone.
struct FilmTarget: ViewModifier {
    let on: Bool
    // What the film saw happen, in Caches/film.txt beside tap.txt, for the build's log.
    static func note(_ line: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("film.txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (text + "\(Date().timeIntervalSince1970) \(line)\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func body(content: Content) -> some View {
        if on {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
                #if canImport(UIKit)
                guard let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first?.bounds, w.width > 0, w.height > 0 else { return }
                let line = String(format: "%.4f %.4f\n", r.midX / w.width, r.midY / w.height)
                try? line.write(to: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tap.txt"), atomically: true, encoding: .utf8)
                FilmTarget.note("restart at \(line.trimmingCharacters(in: .newlines)) in \(Int(w.width))x\(Int(w.height))")
                #endif
            }
        } else {
            content
        }
    }
}

struct LinksView: View {
    let model: AppModel
    @StateObject private var feed = FeedReader<LinksFeed>("/api/mac/links")
    @State private var busy: Set<String> = []
    @State private var outcomes: [String: MacActionResult] = [:]
    @State private var asking: (link: MacLink, action: String)?
    // The bridge said it's restarting itself: the page waits for it, and says when it's back.
    @State private var bridgeRestartAt: Date?
    @State private var fixing = false
    @State private var fixOutcome: MacActionResult?

    var groups: [(String, [String])] {
        [("Remote access", ["tailscale", "serve", "funnel"]), ("Mac dashboard", ["bridge", "public", "novnc"]), ("Relays and devices", ["letterboxd", "tv", "chumby-remote", "chumby", "sessions"])]
    }
    func links(_ ids: [String]) -> [MacLink] { (feed.value?.links ?? []).filter { ids.contains($0.id) } }
    var others: [MacLink] { let known = Set(groups.flatMap(\.1)); return (feed.value?.links ?? []).filter { !known.contains($0.id) } }

    @ViewBuilder func section(_ title: String, _ list: [MacLink]) -> some View {
        // No heading over nothing: the first read hasn't come (designer gate, 2026-11-14: empty headings, then a reflow).
        if !list.isEmpty { sectionBody(title, list) }
    }
    func sectionBody(_ title: String, _ list: [MacLink]) -> some View {
        Section(title) {
            ForEach(list) { l in
                LinkRow(link: l, busy: busy.contains(l.id), outcome: outcomes[l.id], first: l.id == list.first?.id, act: { a in
                    if film { FilmTarget.note("tapped \(l.id) \(a)") }
                    // Fix runs the Mac's own bring-up, which only starts what's down: no question. Anything that restarts asks.
                    if a == "bringup" { run(l, a) } else { asking = (l, a) }
                }, asked: asking?.link.id == l.id ? asking?.action : nil,
                   confirm: { a in asking = nil; run(l, a) },
                   dismiss: { asking = nil },
                   question: { Self.question(l, $0) })
                .place(l.id)
                .ownSeparatorRow()
            }
        }
    }
    @ViewBuilder var verdict: some View {
        // Only when something isn't up, with Fix: "Every link is working" said again what every row's green dot says.
        if let f = feed.value, !MacConsole.linkSummary(f).good || fixing || fixOutcome != nil || bridgeRestartAt != nil {
            let s = MacConsole.linkSummary(f)
            Section {
                Label(s.good ? "Every link is working" : s.text, systemImage: s.good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(s.good ? Color.green : f.links.contains(where: \.down) ? Color.red : Color.orange)
                    // A new verdict replaces the old one whole, never morphing one sentence into the next.
                    .id(s.text).transition(.opacity)
                if let b = bridgeRestartAt {
                    // Ticks every second by itself, not only when something else redraws the page.
                    TimelineView(.periodic(from: .now, by: 1)) { c in
                        HStack { ProgressView().controlSize(.small); Text("Waiting for the Mac dashboard to come back… \(Int(c.date.timeIntervalSince(b))) s").monospacedDigit() }
                    }
                }
                // The one Fix: the Mac's own bring-up, which starts only what's down and leaves what's up alone (no question).
                let fixable = f.links.filter { $0.can?.contains("bringup") == true }
                if !fixable.isEmpty || fixing || fixOutcome != nil {
                    Button { fixAll() } label: {
                        HStack {
                            Label(fixing ? "Fixing… up to two minutes" : "Fix what’s down", systemImage: "wrench.adjustable")
                            Spacer(minLength: 8)
                            if fixing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(fixing || fixable.isEmpty)
                    if let o = fixOutcome { OutcomeLine(result: o) }
                }
            }
        } else if feed.value == nil, !feed.away {
            Section { HStack { ProgressView(); Text("Reading the links…").foregroundStyle(.secondary) } }
        }
    }
    var body: some View {
        ConsolePage(title: "Connections", place: "maclinks", away: feed.away, lastRead: feed.lastRead, startAt: (film || MacConsole.pose == "linkstarting") && feed.value != nil ? "public" : nil) {
            verdict
            section(groups[0].0, links(groups[0].1))
            section(groups[1].0, links(groups[1].1))
        } right: {
            section(groups[2].0, links(groups[2].1))
            if !others.isEmpty { section("Other", others) }
        }
        .task { await start() }
        // The film: the question his tap brought up stays long enough to read, then is answered as he would.
        .onChange(of: asking?.link.id) { _, id in
            guard film, id != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let a = asking { asking = nil; run(a.link, a.action) }
            }
        }
    }
    var film: Bool { MacConsole.pose == "linkrestartfilm" }
    static func question(_ l: MacLink, _ a: String) -> String {
        switch (l.id, a) {
        case ("bridge", _): return "The app loses the Mac for a few seconds while the Mac dashboard starts again. Anything it is doing stops."
        case ("public", _): return "The public link drops and comes back with a new address."
        case ("letterboxd", _): return "A sign-in in progress on the TV is cut off."
        case ("chumby-remote", _): return "The Chumby app loses the Chumby for a few seconds."
        default: return l.note ?? "It stops and starts again."
        }
    }
    func start() async {
        if let posed = Self.posed(MacConsole.pose) {
            feed.set(posed)
            if MacConsole.pose == "linkconfirm", let l = posed.links.first(where: { $0.id == "public" }) { asking = (l, "restart") }
            if MacConsole.pose == "linkdone" { outcomes["chumby-remote"] = MacActionResult(ok: true, say: "Chumby proxy restarted (now process 51234)"); outcomes["tv"] = MacActionResult(ok: false, error: "TV link needs a reconnect from the Mac: no adb server is running") }
            return
        }
        // The build's film of a public-link restart against the stand-in Mac: the page opens at the public link, the build
        // taps its Restart (FilmTarget), the question shows and is answered, then Starting and Up are watched. Should the
        // tap miss, the question is put up 40 s in, so the film still shows the rest (and the log says it missed). The
        // build's touches land up to ~17 s after they're sent (CI 3609ee9), so it waits that long first.
        if film {
            Task {
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                if asking == nil, !busy.contains("public"), outcomes["public"] == nil, let l = feed.value?.links.first(where: { $0.id == "public" }), l.uptime ?? 0 > 60 {
                    FilmTarget.note("the tap missed; asking without it"); asking = (l, "restart")
                }
            }
            await feed.loop(model, every: 2); return
        }
        await feed.loop(model, every: 8)
    }
    // Bring-up, then what it says each part did: fixed ones by name, and any still down by name with why.
    func fixAll() {
        guard !fixing else { return }
        fixing = true; fixOutcome = nil
        Task {
            defer { fixing = false }
            do {
                let r = try await model.api.macBringUp()
                let fixed = r.parts.filter { $0.state == "fixed" }.map { MacParts.name($0.part) }, bad = r.parts.filter(\.bad)
                fixOutcome = bad.isEmpty ? MacActionResult(ok: true, say: fixed.isEmpty ? "Nothing needed fixing; everything was already running" : "Fixed: " + fixed.joined(separator: ", "))
                    : MacActionResult(ok: false, error: (fixed.isEmpty ? "" : "Fixed: " + fixed.joined(separator: ", ") + ". ") + "Still down: " + bad.map { MacParts.name($0.part) + " (" + $0.say + ")" }.joined(separator: "; "))
            } catch {
                fixOutcome = MacActionResult(ok: false, error: MacFiles.unreachable(error) ? "The Mac stopped answering while fixing, so it’s not known what came back. This page checks again by itself." : error.localizedDescription)
            }
            await feed.read(model.api, query: "?fresh")
        }
    }
    func run(_ l: MacLink, _ a: String) {
        guard !busy.contains(l.id) else { return }
        busy.insert(l.id); outcomes[l.id] = nil
        Task {
            let r: MacActionResult
            do { r = try await model.api.macDo("/api/mac/links/action", ["id": l.id, "action": a, "confirm": true], timeout: a == "bringup" ? 180 : 60) }
            catch {
                // No answer: it may or may not have happened. Said so, and the next read shows which.
                r = MacActionResult(ok: false, error: MacFiles.unreachable(error) ? "The Mac didn’t answer, so it’s not known whether that happened. This page checks again by itself." : error.localizedDescription)
            }
            busy.remove(l.id)
            var shown = r
            if l.id == "bridge", r.done {
                bridgeRestartAt = Date()
                let back = await waitForBridge()
                bridgeRestartAt = nil
                shown = back ? MacActionResult(ok: true, say: "The Mac dashboard restarted and is answering") : MacActionResult(ok: false, error: "The Mac dashboard hasn’t come back within a minute. Check Everything.")
            }
            withAnimation(Motion.quick) { outcomes[l.id] = shown }
            await feed.read(model.api, query: "?fresh")
        }
    }
    // The bridge's uptime going back to seconds is the restart having happened; up to a minute.
    func waitForBridge() async -> Bool {
        let asked = Date()
        while Date().timeIntervalSince(asked) < 60, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let f: LinksFeed = try? await model.api.macFeed("/api/mac/links?fresh", timeout: 6), let b = f.links.first(where: { $0.id == "bridge" }), let up = b.uptime, up < Date().timeIntervalSince(asked) + 5 {
                feed.set(f); return true
            }
        }
        return false
    }

    // The build's shots: all working, and one relay down with the TV link.
    static func posed(_ pose: String) -> LinksFeed? {
        // Plain "links" reads the stand-in Mac, so the shot tests the real feed too.
        guard ["linksbad", "linkconfirm", "linkdone", "linkstarting"].contains(pose) else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        var l: [MacLink] = [
            MacLink(id: "tailscale", name: "Tailscale", state: "up", detail: "Running · 4 of 6 devices online", endpoint: "100.64.0.10 · mac-pro.example.ts.net", checkedAt: now, can: [], note: "Never stopped from here: the phone reaches the Mac through it."),
            MacLink(id: "serve", name: "Tailscale Serve", state: "up", detail: "https → the bridge, tailnet only", endpoint: "https://mac-pro.example.ts.net", checkedAt: now, can: [], note: "The bridge points it again every minute by itself."),
            MacLink(id: "funnel", name: "Tailscale Funnel", state: "off", detail: "Off, as it should be", checkedAt: now, can: []),
            MacLink(id: "bridge", name: "Bridge", state: "up", detail: "Answering", endpoint: "127.0.0.1:8787", pid: 4012, uptime: 51_840, lastError: .init(text: "seed Example.ipa: device not found", t: now - 9 * 3_600_000), checkedAt: now, can: ["restart"], note: "Back in a few seconds; the app reconnects by itself."),
            MacLink(id: "public", name: "Public link", state: "up", detail: "Cloudflare tunnel up", endpoint: "https://example-words.trycloudflare.com", pid: 841, uptime: 188_400, checkedAt: now, can: ["restart"], note: "A restart gives the public link a new address."),
            MacLink(id: "novnc", name: "Screen link (noVNC)", state: "up", detail: "Screen Sharing answers; Screen relays through the bridge", endpoint: "/novnc", checkedAt: now, can: [], note: "Status only. Screen Sharing is a macOS setting."),
            MacLink(id: "letterboxd", name: "Letterboxd sign-in relay", state: "up", detail: "Running, listening on 8767", endpoint: "100.64.0.10:8767", pid: 8486, uptime: 187_900, checkedAt: now, can: ["restart"]),
            MacLink(id: "tv", name: "TV link (adb)", state: "up", detail: "Connected", checkedAt: now, can: [], note: "The bridge can only reconnect an adb that already runs; a full repair is from a Claude session on the Mac."),
            MacLink(id: "chumby-remote", name: "Chumby proxy", state: "up", detail: "Running", endpoint: "local.chumby-remote", pid: 40432, uptime: 75_500, lastExit: -15, checkedAt: now, can: ["restart"]),
            MacLink(id: "chumby", name: "Chumby", state: "up", detail: "Answering", checkedAt: now, can: []),
            MacLink(id: "sessions", name: "Claude sessions", state: "up", detail: "6 of 6 kept running · 2 others", checkedAt: now, can: []),
        ]
        if pose == "linksbad" || pose == "linkdone" {
            if let i = l.firstIndex(where: { $0.id == "tv" }) { l[i].state = "down"; l[i].detail = "TV link needs a reconnect from the Mac: no adb server is running"; l[i].can = ["bringup"] }
            if let i = l.firstIndex(where: { $0.id == "letterboxd" }) { l[i].state = "down"; l[i].detail = "Not running"; l[i].pid = nil; l[i].uptime = nil; l[i].can = ["bringup"]; l[i].lastError = .init(text: "OSError: [Errno 49] Can't assign requested address", t: now - 600_000) }
        }
        // Just after a restart of the public link: the tunnel is up, its new address not yet known.
        if pose == "linkstarting", let i = l.firstIndex(where: { $0.id == "public" }) { l[i].state = "starting"; l[i].detail = "Tunnel running, no address yet"; l[i].endpoint = ""; l[i].uptime = 4; l[i].pid = 51234 }
        return LinksFeed(t: now, healthAt: now, links: l)
    }
}

// MARK: - Fans & temperatures

struct FanDial: View {
    let fan: MacFan
    // The floor helper's word on how the speed is set: a raised slowest speed isn't "Automatic" (designer, 2a9957e).
    var control: FansFeed.Control? = nil
    var tag: String {
        if control?.ready == true, control?.mode == "floor", let f = control?.floor { return "Never under \(f.formatted()) rpm" }
        return fan.mode == "manual" ? "Set by hand" : "Automatic"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(fan.name).font(.headline)
                Spacer()
                Text(tag).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(fan.rpm.rounded()))").font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                Text("rpm").font(.title3).foregroundStyle(.secondary)
            }
            // Its range, slowest to fastest, with the speed on it.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule().fill(macBlue).frame(width: max(8, g.size.width * fan.level))
                }
            }
            .frame(height: 8)
            HStack {
                Text("Slowest \(MacConsole.rpm(fan.min))"); Spacer(); Text("Fastest \(MacConsole.rpm(fan.max))")
            }
            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct FanChart: View {
    let points: [TrendPoint]
    let fan: MacFan
    var body: some View {
        Chart(points, id: \.t) { p in
            LineMark(x: .value("Time", p.date), y: .value("rpm", p.v)).foregroundStyle(macBlue).interpolationMethod(.monotone)
        }
        // From the lowest of the day, not the fan's slowest now: with the slowest speed raised, the day's earlier speeds
        // under it were drawn below the plot, over the hour labels (CI 43030e3).
        .chartYScale(domain: max(0, min(fan.min, points.map(\.v).min() ?? fan.min) - 100)...max(fan.max, points.map(\.v).max() ?? fan.max))
        .chartPlotStyle { $0.clipped() }
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
        .chartYAxis { AxisMarks(position: .trailing) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))") } } } }
        .frame(height: 160)
        .padding(.vertical, 6)
        .accessibilityLabel("\(fan.name) over the last day")
    }
}

struct FansView: View {
    let model: AppModel
    @StateObject private var fans = FeedReader<FansFeed>("/api/mac/fans")
    @StateObject private var temps = FeedReader<TempsFeed>("/api/mac/temps")
    @State private var history: [Int: [TrendPoint]] = [:]
    @State private var historyRead = false
    @State private var askFloor: FansFeed.Control.Preset?
    @State private var floorOutcome: MacActionResult?
    @State private var busy = false
    // The row tapped, while the Mac changes the fan: its spinner (0 for Automatic).
    @State private var pending: Int?
    var away: Bool { fans.away || temps.away }

    @ViewBuilder var fanSections: some View {
        if let f = fans.value {
            if f.fans.isEmpty || f.stale == true {
                Section("Fan") { Label("The fan’s speed can’t be read right now", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            ForEach(f.fans) { fan in
                Section {
                    FanDial(fan: fan, control: f.control)
                    if let h = history[fan.index], h.count > 2 { FanChart(points: h, fan: fan) }
                    else if historyRead { Text("Its day fills in from now: speeds are kept each minute.").font(.footnote).foregroundStyle(.secondary) }
                } header: { Text(f.fans.count == 1 ? "Fan" : fan.name) } footer: {
                    if f.fans.count == 1 { Text("This Mac Pro has one fan, under the top vent; it draws air up through the core.") }
                }
            }
            fanControl(f.control)
        } else if fans.unsupported == false, !fans.away {
            Section { HStack { ProgressView(); Text("Reading the fan…").foregroundStyle(.secondary) } }
        }
    }
    // The slowest speed: how slow the fan may go, never how fast. Automatic is always there and needs no asking, nor does
    // a lower floor; raising it is asked first. Not installed, the page says so and shows the one command that installs it.
    // On success the check moves to the tapped row, its spinner gone; only a failure is said in words (designer, 2a9957e).
    @ViewBuilder func fanControl(_ c: FansFeed.Control?) -> some View {
        if let c, c.ready {
            Section {
                Button { setFloor(nil) } label: { floorRow("Automatic", detail: "The Mac sets the speed", on: c.mode != "floor", spinning: pending == 0) }
                    .buttonStyle(.plain).disabled(busy || away)
                ForEach(c.presets ?? []) { p in
                    Button { pick(p, c) } label: { floorRow(p.name, detail: "Never slower than \(p.rpm.formatted()) rpm", on: c.mode == "floor" && c.floor == p.rpm, spinning: pending == p.rpm) }
                        .buttonStyle(.plain).disabled(busy || away)
                        // Hung off the row he tapped, so it points at it rather than the middle of the page.
                        .confirmationDialog("Raise the slowest speed to \(p.rpm.formatted()) rpm?", isPresented: Binding(get: { askFloor?.rpm == p.rpm }, set: { if !$0, askFloor?.rpm == p.rpm { askFloor = nil } }), titleVisibility: .visible) {
                            Button("Raise") { setFloor(p.rpm); askFloor = nil }
                            Button("Cancel", role: .cancel) { askFloor = nil }
                        } message: { Text("The fan gets louder and the Mac cooler. The Mac still speeds it up when it heats; Automatic or a restart puts it back.") }
                }
                if c.mode == "floor", let fl = c.floor, !(c.presets ?? []).contains(where: { $0.rpm == fl }) {
                    floorRow("Raised", detail: "Never slower than \(fl.formatted()) rpm", on: true, spinning: false)
                }
                if let r = floorOutcome, !r.done { OutcomeLine(result: r) }
            } header: { Text("Slowest fan speed") } footer: {
                Text("Each is cooler and louder than Automatic. The Mac still speeds the fan up when it heats, and goes back to Automatic after a restart.")
            }
        } else if let c {
            Section {
                // In his words, the command behind a Copy button: "Fan floor helper not installed" over a raw sudo line was
                // plumbing (designer gate, 2026-11-13).
                Label(c.setup != nil ? "Choosing the speed needs a one-time setup" : "The Mac sets the fan speed", systemImage: "lock")
                Text("Until then the Mac sets the speed itself.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let cmd = c.setup { CopySetup(command: cmd) }
            } header: { Text("Slowest fan speed") } footer: {
                if c.setup != nil { Text("Paste it into Terminal on the Mac. It asks for the Mac’s password once.") }
            }
        }
    }
    // Faster than the floor now (the Mac's own when Automatic) is asked; slower is only ever quieter, so it isn't.
    func pick(_ p: FansFeed.Control.Preset, _ c: FansFeed.Control) {
        let now = c.mode == "floor" ? (c.floor ?? 0) : (c.factoryFloor ?? 0)
        if p.rpm > now { askFloor = p } else { setFloor(p.rpm) }
    }
    func floorRow(_ title: String, detail: String, on: Bool, spinning: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) { Text(title).foregroundStyle(Color.primary); Text(detail).font(.footnote).foregroundStyle(.secondary).monospacedDigit() }
            Spacer()
            if spinning { ProgressView().controlSize(.small) }
            else if on { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(macBlue) }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
    func setFloor(_ rpm: Int?) {
        busy = true; pending = rpm ?? 0; floorOutcome = nil
        Task {
            do { floorOutcome = try await model.api.macDo("/api/mac/fans/floor", rpm.map { ["rpm": $0, "confirm": true] } ?? ["auto": true], timeout: 20) }
            catch { floorOutcome = MacActionResult(ok: false, error: MacFiles.unreachable(error) ? "The Mac didn’t answer, so it’s not known whether the fan changed. This page reads it again by itself." : error.localizedDescription) }
            await fans.read(model.api)
            withAnimation(Motion.quick) { busy = false; pending = nil }
        }
    }
    // The floor helper installed, the slowest speed raised to Cooler, for the shots.
    static let posedReady = FansFeed(t: Date().timeIntervalSince1970 * 1000, stale: false, fans: [MacFan(index: 0, name: "Main fan", rpm: 1302, min: 1300, max: 1900, target: 1300, mode: "auto")],
                                     control: .init(state: "ready", mode: "floor", floor: 1300, factoryFloor: 790, max: 1900, presets: [.init(name: "A little cooler", rpm: 1000), .init(name: "Cooler", rpm: 1300), .init(name: "Coolest", rpm: 1600)]))
    @ViewBuilder var namedSection: some View {
        if let t = temps.value {
            Section {
                ForEach(t.named) { n in
                    LabeledContent(n.name) {
                        Text(MacConsole.degrees(n.c)).foregroundStyle(Heat.color(n.c) == .white ? Color.primary : Heat.color(n.c)).monospacedDigit()
                    }
                }
                if t.named.isEmpty { Label("The temperatures can’t be read right now", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            } header: {
                Text("Temperatures")
            } footer: { Text("The eight on Status, each with its day there.") }
        }
    }
    @ViewBuilder var allSections: some View {
        if let t = temps.value, !t.all.isEmpty {
            let groups = ["CPU", "GPU A", "GPU B", "Memory", "Chipset", "Drive", "Power supply", "Air", "Other"].filter { g in t.all.contains { $0.group == g } }
            ForEach(groups, id: \.self) { g in
                Section {
                    ForEach(t.all.filter { $0.group == g }) { s in
                        LabeledContent { Text(MacConsole.degrees(s.c)).monospacedDigit() } label: {
                            // The sensor's code (TC0P…) is hardware plumbing; the name says what it reads.
                            Text(s.label.replacingOccurrences(of: "\(g) · ", with: "Sensor "))
                        }
                    }
                } header: { Text(g == "Air" ? "Air" : g) }
            }
        }
    }
    var body: some View {
        ConsolePage(title: "Fans & heat", place: "macfans", away: away, lastRead: [fans.lastRead, temps.lastRead].compactMap { $0 }.min()) {
            fanSections
            namedSection
        } right: {
            allSections
        }
        .task {
            if MacConsole.pose == "fanready" { fans.set(Self.posedReady); return }
            await fans.loop(model, every: 3)
        }
        .task { await temps.loop(model, every: 3) }
        .task(id: fans.value?.fans.map(\.index) ?? []) {
            for f in fans.value?.fans ?? [] where history[f.index] == nil {
                if let p = try? await model.api.trend("fan:\(f.index)") { history[f.index] = p }
            }
            historyRead = fans.value != nil
        }
    }
}

// MARK: - Updates

// A setup command he pastes at the Mac, as a button: the command itself isn't for reading.
struct CopySetup: View {
    let command: String
    @State private var copied = false
    var body: some View {
        Button {
            #if canImport(UIKit)
            UIPasteboard.general.string = command
            #endif
            withAnimation(Motion.quick) { copied = true }
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); withAnimation(Motion.quick) { copied = false } }
        } label: { Label(copied ? "Copied" : "Copy the setup command", systemImage: copied ? "checkmark" : "doc.on.doc") }
        .foregroundStyle(macBlue)
    }
}
// A shell command is never printed: it sits behind a tap, "Copy command", for pasting at the Mac (designer gate,
// 2026-11-14: "sudo launchctl bootout…" under a row).
struct CommandRow: View {
    let command: String
    @State private var copied = false
    var body: some View {
        Button {
            #if canImport(UIKit)
            UIPasteboard.general.string = command
            #endif
            withAnimation(Motion.quick) { copied = true }
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); withAnimation(Motion.quick) { copied = false } }
        } label: { Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc").font(.subheadline) }
        .buttonStyle(.borderless).foregroundStyle(macBlue)
        .accessibilityLabel(copied ? "Copied" : "Copy the command")
    }
}

struct UpdatesView: View {
    let model: AppModel
    @StateObject private var feed = FeedReader<UpdatesFeed>("/api/mac/updates")
    @State private var checking = false
    @State private var askBrew = false
    @State private var brewOutcome: MacActionResult?

    // One name for it on every page (designer gate, 2026-11-14: "OCLP" here, the full name beside it).
    static func plain(_ t: String) -> String { t.replacingOccurrences(of: "OCLP", with: "OpenCore Legacy Patcher") }
    @ViewBuilder var macosSection: some View {
        if let u = feed.value {
            let m = u.macos
            Section {
                LabeledContent("Installed", value: "macOS \(m.current)")
                if let p = m.pending {
                    // A plain state word, not a green sentence.
                    if p.isEmpty { LabeledContent("Update waiting", value: "None") }
                    ForEach(p) { x in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(x.label)
                            Text([x.version.map { "Version \($0)" }, x.size, x.restart == true ? "restarts the Mac" : nil].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else if m.checking == true {
                    HStack { ProgressView().controlSize(.small); Text("Asking Apple…").foregroundStyle(.secondary) }
                }
                if let e = m.error { FailText("The last check didn’t finish: \(e)") }
                LabeledContent("Installs by itself", value: m.autoInstall == true ? "Yes" : "No")
                Button {
                    checking = true
                    Task { await feed.read(model.api, query: "?check=1"); try? await Task.sleep(nanoseconds: 1_000_000_000); checking = false }
                } label: { HStack { Text(m.checking == true || checking ? "Checking…" : "Check now"); Spacer(); if m.checking == true || checking { ProgressView().controlSize(.small) } } }
                .disabled(m.checking == true || checking)
                // Only with something to install: with nothing waiting it led nowhere (designer, CI d9c229c).
                if m.pending?.isEmpty == false {
                    Button { model.macPage = nil; model.tab = 4 } label: { HStack { Text("Install from the macOS tab"); Spacer(); RowChevron() } }
                }
            } header: { Text("macOS") } footer: {
                // The one footnote on the page, and only when an update is waiting: the risk is about installing it.
                if m.pending?.isEmpty == false { Text(Self.plain(m.risk ?? "")) }
            }
        } else if !feed.away {
            Section { HStack { ProgressView(); Text("Reading what’s installed…").foregroundStyle(.secondary) } }
        }
    }
    @ViewBuilder var oclpSection: some View {
        if let o = feed.value?.oclp {
            Section {
                if let v = o.installed { LabeledContent("Installed", value: v) }
                // The newest only when it is newer: "Newest 3.0.0-rc.5" under "Installed 3.0.0" read as a downgrade on offer.
                if let l = o.latest, o.newer == true { LabeledContent(o.latestPre == true ? "Newer (pre-release)" : "Newer", value: l) }
                // A row, "Patches · Healthy": the versions were said again in a sentence beside the ones above.
                if o.patches != nil { LabeledContent("Patches", value: o.healthy == true ? "Healthy" : "Needs a look") }
                if let c = o.command, o.newer == true || o.healthy == false {
                    Text("Needs you at the Mac:").font(.footnote).foregroundStyle(.secondary)
                    CommandRow(command: c)
                }
            } header: { Text("OpenCore Legacy Patcher") } footer: {
                // Said only when there is news; "Up to date" and the re-patching note were a second footnote on a page that
                // already had the macOS one.
                if o.latest == nil { Text("Couldn’t find out whether a newer OpenCore Legacy Patcher is out; the Mac looks again within half an hour.") }
                else if o.newer == true { Text("A newer OpenCore Legacy Patcher is out. Updating it is done at the Mac, and it patches again after.") }
            }
        }
    }
    @ViewBuilder var brewSection: some View {
        if let u = feed.value {
            if let b = u.brew {
                Section {
                    if let list = b.outdated {
                        if list.isEmpty { LabeledContent("Outdated", value: "None") }
                        ForEach(list) { p in LabeledContent(p.name, value: [p.installed, p.latest].compactMap { $0 }.joined(separator: " → ")) }
                    }
                    if let e = b.error { FailText(e) }
                    if let j = b.job, j.state == "running" { HStack { ProgressView().controlSize(.small); Text("Upgrading…").foregroundStyle(.secondary) } }
                    else if let j = b.job { OutcomeLine(result: MacActionResult(ok: j.state == "done", say: j.say, error: j.say)) }
                    if let list = b.outdated, !list.isEmpty, b.job?.state != "running" {
                        Button("Upgrade \(list.count == 1 ? list[0].name : "\(list.count) packages")…") { askBrew = true }
                            .confirmationDialog("Upgrade Homebrew’s packages?", isPresented: $askBrew, titleVisibility: .visible) {
                                Button("Upgrade") {
                                    Task {
                                        do { brewOutcome = try await model.api.macDo("/api/mac/updates/brew", ["confirm": true]) }
                                        catch { brewOutcome = MacActionResult(ok: false, error: MacFiles.unreachable(error) ? "The Mac didn’t answer; it’s not known whether the upgrade started." : error.localizedDescription) }
                                        await feed.read(model.api)
                                    }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: { Text("The Mac runs brew upgrade. It takes a few minutes; this page shows when it’s done.") }
                    }
                    if let r = brewOutcome { OutcomeLine(result: r) }
                } header: { Text("Homebrew") }
            }
            // No Homebrew on the Mac: no card saying so (a lone "Not installed" card, designer CI d9c229c).
            if let apps = u.apps, !apps.isEmpty {
                Section("Apps that update themselves") {
                    // "Updates itself" restated the heading above; only a different way of updating is said.
                    ForEach(apps) { a in LabeledContent(a.name, value: [a.installed, a.how.flatMap { $0 == "Updates itself" ? nil : $0 }].compactMap { $0 }.joined(separator: " · ")) }
                }
            }
        }
    }
    var body: some View {
        ConsolePage(title: "Updates", place: "macupdates", away: feed.away, lastRead: feed.lastRead) {
            macosSection
        } right: {
            oclpSection
            brewSection
        }
        .task {
            if MacConsole.pose == "updateswaiting" { feed.set(Self.posed); return }
            await feed.loop(model, every: 15)
        }
    }
    static let posed = UpdatesFeed(t: 0, macos: .init(current: "26.7.2 (25G332)", checkedAt: Date().timeIntervalSince1970 * 1000 - 2 * 3_600_000, checking: false, pending: [.init(label: "macOS Tahoe 26.7.3", version: "26.7.3", size: "1.9 GB", restart: true)], error: nil, autoInstall: false, command: "softwareupdate --install --all --restart", risk: "A macOS update removes the OpenCore root patches. Updates go through the macOS tab, which patches again after."),
                                   oclp: .init(installed: "3.0.0", latest: "3.0.0-rc.5", latestPre: true, newer: false, patchedFor: "26.7.2", patchedAt: nil, patches: "HEALTHY: macOS 26.7.2 (25G332), OCLP 3.0.0", healthy: true, command: "open -a OpenCore-Patcher"),
                                   brew: nil, apps: [.init(name: "Tailscale", installed: "1.104.4", latest: nil, how: "Updates itself")])
}

// MARK: - Storage

struct FolderRow: View {
    let model: AppModel
    let path: String
    let name: String
    let bytes: Double?
    let total: Double
    @State private var open = false
    @State private var folder: FolderFeed?
    @State private var failed = false
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            if let e = folder?.error {
                FailText("Couldn’t read this folder.")
            } else if let c = folder?.children {
                ForEach(c.prefix(12)) { x in
                    if x.dir == true, x.private != true {
                        FolderRow(model: model, path: (path as NSString).appendingPathComponent(x.name), name: x.name, bytes: x.bytes, total: total)
                    } else {
                        LabeledContent(x.name, value: x.private == true ? "Private" : x.bytes.map { MacSendSize.bytes($0) } ?? "–").monospacedDigit()
                    }
                }
                if folder?.measuring == true { HStack { ProgressView().controlSize(.small); Text("Measuring again…").font(.footnote).foregroundStyle(.secondary) } }
            } else if failed {
                FailText("Couldn’t measure it.")
            } else {
                HStack { ProgressView().controlSize(.small); Text("Measuring… big folders take a minute").font(.footnote).foregroundStyle(.secondary) }
            }
        } label: {
            HStack {
                Label(name, systemImage: "folder")
                Spacer()
                Text(bytes.map { MacSendSize.bytes($0) } ?? "–").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .task(id: open) {
            guard open else { return }
            while !Task.isCancelled {
                do {
                    let f: FolderFeed? = try await model.api.macFeed("/api/mac/storage/folder?path=" + MacFiles.query(path))
                    folder = f; failed = f == nil
                    if f?.measuring != true { return }
                } catch { if folder == nil { failed = true }; return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}
enum MacSendSize { static func bytes(_ b: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) } }

struct StorageView: View {
    let model: AppModel
    @StateObject private var feed = FeedReader<StorageFeed>("/api/mac/storage")
    @ViewBuilder var volumes: some View {
        if let s = feed.value {
            Section {
                ForEach(s.volumes) { v in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Label(v.name, systemImage: v.isInternal == true ? "internaldrive" : "externaldrive"); Spacer(); Text("\(Format.bytes(v.free)) free").foregroundStyle(.secondary).monospacedDigit() }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.25))
                                Capsule().fill(v.free / max(v.total, 1) < 0.1 ? Color.red : macBlue).frame(width: g.size.width * min(1, max(0, 1 - v.free / max(v.total, 1))))
                            }
                        }
                        .frame(height: 8)
                        Text("\(Format.bytes(v.total - v.free)) used of \(Format.bytes(v.total))\(v.kind.map { " · \($0)" } ?? "")").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
            } header: { Text("Volumes") }
        } else if !feed.away {
            Section { HStack { ProgressView(); Text("Reading the disks…").foregroundStyle(.secondary) } }
        }
    }
    @ViewBuilder var home: some View {
        if let s = feed.value {
            Section {
                if let h = s.home {
                    let total = s.volumes.first?.total ?? 1
                    // A file among the biggest (~/.claude.json) is a plain row: opened as a folder it measured for ever.
                    ForEach(h) { f in
                        if f.dir == false { LabeledContent(f.name, value: f.bytes.map { MacSendSize.bytes($0) } ?? "–").monospacedDigit() }
                        else { FolderRow(model: model, path: f.path, name: f.name, bytes: f.bytes, total: total) }
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Measuring the home folder; this takes a minute or two the first time").font(.footnote).foregroundStyle(.secondary) }
                }
            } header: { Text("Biggest folders at home") } footer: {
                Text("Private folders (Documents, Mail, Photos and the like) are never opened from here.")
            }
        }
    }
    var body: some View {
        ConsolePage(title: "Storage", place: "macstorage", away: feed.away, lastRead: feed.lastRead) { volumes } right: { home }
            .task {
                await feed.loop(model, every: 20)
            }
    }
}

// MARK: - Startup items

struct StartupRow: View {
    let item: StartupItem
    let busy: Bool
    let outcome: MacActionResult?
    let ask: (String) -> Void
    // The action the page is asking about for this row, and its two answers: the question hangs off the button that asked it,
    // so it never lands across the fold.
    var asked: String? = nil
    var askedAgain: String? = nil
    var confirm: (String) -> Void = { _ in }
    var confirmAgain: (String) -> Void = { _ in }
    var dismiss: () -> Void = {}
    var question: (String) -> String = { _ in "" }
    var questionAgain: String = ""
    @State private var open = false
    var stateText: String {
        if item.disabled == true { return "Disabled" }
        if item.running { return "Running" }
        if item.loaded { return item.interval.map { "Every \(Format.span($0))" } ?? "Idle" }
        return "Stopped"
    }
    var actions: [String] {
        guard item.mine else { return [] }
        var a: [String] = []
        if item.disabled == true { return ["enable"] }
        if !item.running { a.append("start") }
        if item.running { a.append("restart") }
        // The bridge and its watchdog restart from Connections, which waits for the bridge to come back; never stopped.
        if item.protected == "bridge" { return item.running || item.interval != nil ? [] : ["start"] }
        // Without keep-awake the Mac may sleep, out of the phone's reach: restart only.
        if item.label != "local.keep-awake" { if item.loaded { a.append("stop") }; a.append("disable") }
        return a
    }
    // Each in the words Connections uses (Mac dashboard, Public link, Chumby link…). One the app doesn't know is named
    // from its label's last part ("com.example.sync-photos" → "Sync photos"); the label itself is behind a tap
    // (designer gate, 2026-11-13: "local.mac-dash", "Chumby proxy" and the node command line were plumbing).
    static let names = [
        "local.mac-dash": "Mac dashboard", "local.mac-dash-watchdog": "Mac dashboard keeper", "local.mac-dash-tunnel": "Public link",
        "local.chumby-remote": "Chumby link", "local.claude-sessions": "Claude sessions", "local.claude-remote-control": "Claude remote control",
        "local.keep-awake": "Keep awake", "local.macpro-console": "Console", "local.usbmux-kick": "iPhone cable link",
        "com.mint.sync-youtube": "Mint YouTube sync", "local.oclp-tahoe.agent": "macOS patch check",
        "com.dortania.opencore-legacy-patcher.auto-patch": "Patch after macOS updates", "com.dortania.opencore-legacy-patcher.macos-update": "macOS update check",
        "com.dortania.opencore-legacy-patcher.os-caching": "macOS update caching", "com.google.keystone.agent": "Google updater",
        "com.google.keystone.xpcservice": "Google updater service", "com.google.GoogleUpdater.wake": "Google updater wake",
    ]
    static func name(_ i: StartupItem) -> String {
        if let n = names[i.label] { return n }
        let last = i.label.split(separator: ".").last.map(String.init) ?? i.label
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
    static func word(_ a: String) -> String { ["start": "Start", "stop": "Stop", "restart": "Restart", "enable": "Enable", "disable": "Disable"][a] ?? a }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.name(item)).lineLimit(2)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Circle().fill(item.disabled == true ? Color.secondary : item.running ? Color.green : item.loaded ? Color.blue : Color.secondary).frame(width: 8, height: 8)
                    Text(stateText)
                }
                .font(.footnote).foregroundStyle(.secondary).fixedSize()
            }
            // A second line only for what "Running" doesn't say: a running item's "Kept running · starts at login" repeated it
            // (designer gate, 2026-11-14), so a running one has none here and the facts come on its tap.
            let plain = item.running ? "" : [item.keepAlive == true ? "Meant to keep running" : nil, item.runAtLoad == true ? "starts at login" : nil, item.lastExit.flatMap { $0 != 0 ? "last \(MacConsole.exitText($0))" : nil }].compactMap { $0 }.joined(separator: " · ")
            if !plain.isEmpty { Text(plain.prefix(1).uppercased() + plain.dropFirst()).font(.footnote).foregroundStyle(.secondary) }
            // The Mac's own label, its command line and process number only on a tap.
            if open {
                if item.running { let w = [item.keepAlive == true ? "Kept running" : nil, item.runAtLoad == true ? "starts at login" : nil].compactMap { $0 }.joined(separator: " · "); if !w.isEmpty { Text(w.prefix(1).uppercased() + w.dropFirst()).font(.footnote).foregroundStyle(.secondary) } }
                Text(item.label).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let p = item.program, !p.isEmpty { Text(p).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3) }
                if let pid = item.pid { Text("Process \(pid)").font(.footnote).foregroundStyle(.secondary).monospacedDigit() }
            }
            if let outcome { OutcomeLine(result: outcome) }
            if open, !item.mine, let c = item.command {
                Text("Changing it needs the Mac’s password, at the Mac.").font(.footnote).foregroundStyle(.secondary)
                CommandRow(command: c)
            }
            // The actions come with the tap, not thirteen capsules at once.
            if !actions.isEmpty, open || busy || asked != nil || askedAgain != nil {
                HStack(spacing: 8) {
                    ForEach(actions, id: \.self) { a in
                        Button(Self.word(a)) { ask(a) }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                            .confirmationDialog("\(Self.word(a)) \(Self.name(item))?", isPresented: Binding(get: { asked == a }, set: { if !$0, asked == a { dismiss() } }), titleVisibility: .visible) {
                                Button(Self.word(a), role: .destructive) { confirm(a) }
                                Button("Cancel", role: .cancel) {}
                            } message: { Text(question(a)) }
                            .confirmationDialog("Are you sure?", isPresented: Binding(get: { askedAgain == a }, set: { if !$0, askedAgain == a { dismiss() } }), titleVisibility: .visible) {
                                Button(Self.word(a), role: .destructive) { confirmAgain(a) }
                                Button("Cancel", role: .cancel) {}
                            } message: { Text(questionAgain) }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                .padding(.top, 3)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { open.toggle() } }
        .onChange(of: asked) { _, a in if a != nil { open = true } }
        .onAppear { if asked != nil { open = true } }
        .accessibilityAction(named: open ? "Fewer details" : "More details") { open.toggle() }
    }
}

struct StartupView: View {
    let model: AppModel
    @StateObject private var feed = FeedReader<StartupFeed>("/api/mac/startup")
    @State private var busy: Set<String> = []
    @State private var outcomes: [String: MacActionResult] = [:]
    @State private var asking: (item: StartupItem, action: String)?
    // A protected item's second question: what will be lost.
    @State private var askingAgain: (item: StartupItem, action: String)?
    var mine: [StartupItem] { (feed.value?.items ?? []).filter(\.mine) }
    var system: [StartupItem] { (feed.value?.items ?? []).filter { !$0.mine } }
    func rows(_ list: [StartupItem]) -> some View {
        ForEach(list) { i in
            StartupRow(item: i, busy: busy.contains(i.label), outcome: outcomes[i.label], ask: { a in
                if a == "start" || a == "enable" { run(i, a, protectedOK: false) } else { asking = (i, a) }
            }, asked: asking?.item.label == i.label ? asking?.action : nil,
               askedAgain: askingAgain?.item.label == i.label ? askingAgain?.action : nil,
               confirm: { a in
                   asking = nil
                   if i.protected != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { askingAgain = (i, a) } } else { run(i, a, protectedOK: false) }
               },
               confirmAgain: { a in askingAgain = nil; run(i, a, protectedOK: true) },
               dismiss: { asking = nil; askingAgain = nil },
               question: { Self.question(i, $0) },
               questionAgain: i.protected == "claude" ? "This ends what keeps the Claude sessions running. Sessions on the Mac stop until it’s started again." : "This is part of how the app reaches the Mac.")
            .place(i.label)
        }
    }
    var body: some View {
        ConsolePage(title: "Startup items", place: "macstartup", away: feed.away, lastRead: feed.lastRead) {
            if feed.value != nil {
                Section { rows(mine) } header: { Text(Self.stopped(mine).isEmpty ? "Yours (\(mine.count))" : "Yours (\(MacConsole.named(Self.stopped(mine).map(StartupRow.name), "stopped")))") } footer: {
                    Text("Stop lasts until the next login; Disable keeps it from starting at login. What this app reaches the Mac through, and what keeps the Mac awake, can’t be stopped from here.")
                }
            } else if !feed.away {
                Section { HStack { ProgressView(); Text("Reading what starts with the Mac…").foregroundStyle(.secondary) } }
            }
        } right: {
            if feed.value != nil {
                Section { rows(system) } header: { Text("For the whole Mac (\(system.count))") } footer: {
                    Text("Changing these needs the Mac’s password, at the Mac.")
                }
            }
        }
        .task {
            if MacConsole.pose == "startupconfirm" {
                feed.set(Self.posed)
                if let i = Self.posed.items.first(where: { $0.label == "local.chumby-remote" }) { asking = (i, "restart") }
                return
            }
            await feed.loop(model, every: 10)
        }
    }
    // Agents meant to keep running that aren't (timed ones idle between runs by design).
    static func stopped(_ items: [StartupItem]) -> [StartupItem] { items.filter { $0.keepAlive == true && $0.disabled != true && !$0.running } }
    static func question(_ i: StartupItem, _ a: String) -> String {
        switch a {
        case "stop": return "It stops now and stays stopped until the next login, or until you start it here."
        case "disable": return "It stops now and won’t start at login until you enable it here."
        case "restart": return "It stops and starts again now."
        default: return ""
        }
    }
    func run(_ i: StartupItem, _ a: String, protectedOK: Bool) {
        guard !busy.contains(i.label) else { return }
        busy.insert(i.label); outcomes[i.label] = nil
        Task {
            let r: MacActionResult
            do { r = try await model.api.macDo("/api/mac/startup/action", ["label": i.label, "action": a, "confirm": true, "confirmProtected": protectedOK]) }
            catch { r = MacActionResult(ok: false, error: MacFiles.unreachable(error) ? "The Mac didn’t answer, so it’s not known whether that happened. This page checks again by itself." : error.localizedDescription) }
            busy.remove(i.label)
            withAnimation(Motion.quick) { outcomes[i.label] = r }
            await feed.read(model.api, query: "?fresh")
        }
    }
    static let posed: StartupFeed = {
        func a(_ label: String, _ prog: String, pid: Int?, loaded: Bool = true, exit: Int? = 0, keep: Bool = true, interval: Double? = nil, prot: String? = nil, disabled: Bool = false) -> StartupItem {
            StartupItem(label: label, kind: "agent", domain: "user", path: "~/Library/LaunchAgents/\(label).plist", program: prog, loaded: loaded, pid: pid, lastExit: exit, runAtLoad: true, keepAlive: keep, interval: interval, disabled: disabled, protected: prot, editable: true, command: nil)
        }
        return StartupFeed(t: 0, items: [
            a("local.mac-dash", "/usr/local/bin/node ~/code/Tools/mac-dash/server.js", pid: 4012, prot: "bridge"),
            a("local.mac-dash-watchdog", "/bin/bash ~/code/Tools/mac-dash/watchdog.sh", pid: nil, keep: false, interval: 60, prot: "bridge"),
            a("local.mac-dash-tunnel", "/bin/bash ~/code/Tools/mac-dash/keep-tunnel.sh", pid: 841),
            a("local.chumby-remote", "/usr/bin/python3 -I ~/code/chumby-remote/chumby_remote.py", pid: 40432, exit: -15),
            a("local.claude-sessions", "/bin/bash ~/code/Tools/keep-sessions.sh", pid: nil, keep: false, interval: 120, prot: "claude"),
            a("local.keep-awake", "/usr/bin/caffeinate -ims", pid: 702),
            a("com.google.keystone.agent", "", pid: nil, loaded: false, exit: nil, keep: false),
            StartupItem(label: "local.oclp-tahoe.agent", kind: "daemon", domain: "system", path: "/Library/LaunchDaemons/local.oclp-tahoe.agent.plist", program: "/bin/bash /Library/Application Support/oclp-tahoe/agent.sh", loaded: true, pid: nil, lastExit: 0, runAtLoad: true, keepAlive: false, interval: 300, disabled: false, protected: nil, editable: false, command: "sudo launchctl bootout system/local.oclp-tahoe.agent"),
            StartupItem(label: "com.dortania.opencore-legacy-patcher.auto-patch", kind: "agent", domain: "system", path: "/Library/LaunchAgents/com.dortania.opencore-legacy-patcher.auto-patch.plist", program: "/Library/Application Support/Dortania/OpenCore-Patcher.app/Contents/MacOS/OpenCore-Patcher --patch_sys_vol", loaded: true, pid: nil, lastExit: 0, runAtLoad: true, keepAlive: false, interval: nil, disabled: false, protected: nil, editable: false, command: "sudo launchctl bootout gui/501/com.dortania.opencore-legacy-patcher.auto-patch"),
        ])
    }()
}
