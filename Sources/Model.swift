import Foundation
import SwiftUI

@MainActor
final class LiveStore: ObservableObject { @Published var live: LiveStatus? }

// When the Mac last answered. Kept apart from the model so the beat on each refresh redraws only the chip that shows it.
@MainActor
final class Pulse: ObservableObject {
    @Published var lastFresh: Date?
    @Published var beats = 0
}

@MainActor
final class AppModel: ObservableObject {
    let liveStore = LiveStore()
    let pulse = Pulse()
    let screen = RemoteScreen()
    @Published var screenOpen = false { didSet { screen.paused = !screenOpen } }
    @Published var signingIn = false
    @Published var status: Status?
    @Published var problem: String?
    // The Mac wants its access code. Shown as a row at the top of each tab; the sheet only opens by itself when there's
    // no address at all, so pressing Cancel is respected.
    @Published var needsSignIn = false
    @Published var signInSheet = false
    @Published var apiSetup = false      // the Admin key row in the Usage card; here, so leaving the tab doesn't lose it
    @Published var gotFresh = false      // the Mac has answered at least once since launch, not just the cache
    private var posedSheet = false
    @Published var history: HistoryMetric?  // kept here so unfolding doesn't close it
    @Published var processes: ProcessSort?
    @Published var sessionScreen: Status.Session?  // a session's own screen, on the Claude tab's stack
    private var pendingSession: String?
    private var lastData: Data?
    // The tab chosen to open on in Settings, or else the one last used.
    @Published var tab = AppModel.firstTab == 3 ? 2 : AppModel.firstTab
    // Counts each ask for the usage, which lives on the Claude tab: the Claude tab scrolls to it.
    @Published var usageAsked = AppModel.firstTab == 3 ? 1 : 0
    var usageShown = 0
    private static let firstTab: Int = { let d = UserDefaults.standard, start = d.object(forKey: "startTab") as? Int ?? -1; return start >= 0 ? start : d.integer(forKey: "tab") }()
    // A tab by number, from a link or the widget. 3 was the Usage tab, which is now part of Claude.
    func show(tab t: Int) {
        if t == 3 { tab = 2; usageAsked += 1 } else { tab = t }
    }
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "address"); liveStore.live = nil; lastData = nil } }

    var api: API { API(base: URL(string: address) ?? URL(string: "https://invalid.invalid")!) }
    private var loops: [Task<Void, Never>] = []

    // The Mac bakes its address into the build when it collects it, so it never has to live in the source.
    init() {
        let saved = UserDefaults.standard.string(forKey: "address") ?? ""
        address = saved.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : saved
        needsSignIn = address.isEmpty
        signInSheet = address.isEmpty
        // Usage was a tab of its own until 2026-11-07; a start tab set to it opens on Claude, where it now lives.
        if UserDefaults.standard.integer(forKey: "startTab") == 3 { UserDefaults.standard.set(2, forKey: "startTab") }
        history = UserDefaults.standard.string(forKey: "openHistory").flatMap(HistoryMetric.named)
        processes = UserDefaults.standard.string(forKey: "openProcesses").flatMap(ProcessSort.init(rawValue:))
        // Show the last known state at once; fresh numbers replace it moments later.
        if let d = try? Data(contentsOf: Self.cacheFile) { status = try? JSONDecoder().decode(Status.self, from: d) }
        // How old those numbers are, so being offline never passes them off as live.
        pulse.lastFresh = (try? FileManager.default.attributesOfItem(atPath: Self.cacheFile.path)[.modificationDate]) as? Date
    }

    // What's on screen is only the last the Mac sent: it can't be reached, or won't answer without its code.
    var stale: Bool { problem != nil || needsSignIn }

    var pose: String { UserDefaults.standard.string(forKey: "pose") ?? "" }

    // How this phone is reaching the Mac, for the chip under its picture.
    var route: String {
        guard let host = URL(string: address)?.host?.lowercased() else { return "not set" }
        if host.hasSuffix(".ts.net") || host.hasPrefix("100.") { return "Tailscale" }
        if let p = status.flatMap({ URL(string: $0.publicUrl)?.host?.lowercased() }), p == host { return "public link" }
        if host.hasSuffix("trycloudflare.com") { return "public link" }
        return "local network"
    }

    // A page open over the current tab (a history, the processes, a session), so the side bar shows Back. Back is the
    // side bar's, as in the TV app (Richard, 2026-11-07: "back should be on side bar").
    var pageOpen: Bool { (tab == 0 && (history != nil || processes != nil)) || (tab == 2 && sessionScreen != nil) }
    func goBack() {
        switch tab {
        case 0: if processes != nil { processes = nil } else { history = nil }
        case 2: sessionScreen = nil
        default: break
        }
    }
    // A session's page, from its row: its text read ahead for a moment at most, so the page arrives drawn.
    func open(session s: Status.Session) {
        guard let key = s.key else { return }
        Task { await TermCache.warm(api, key, within: 0.15); sessionScreen = s }
    }
    // A session's own page lives on the Claude tab, wherever it was asked for from.
    // Its text is asked for first, for a moment at most, so the page arrives drawn.
    func openSession(key: String) {
        tab = 2
        guard let s = status?.claude.sessions.first(where: { $0.key == key }) else { pendingSession = key; return }
        pendingSession = nil
        Task { await TermCache.warm(api, key, within: 0.15); sessionScreen = s }
    }

    private func openPending() {
        if let key = pendingSession, let s = status?.claude.sessions.first(where: { $0.key == key }) {
            pendingSession = nil
            Task { await TermCache.warm(api, key, within: 0.15); sessionScreen = s }
        }
    }

    private static var cacheFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("status.json") }

    func start() {
        stop()
        // One answer per build is all the Mac needs.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if UserDefaults.standard.string(forKey: "hotProbedBuild") != build {
            Task { [weak self] in
                // Not counted as tried if the Mac wasn't ready to hand it over.
                if await self?.hotProbeOnce() == true { UserDefaults.standard.set(build, forKey: "hotProbedBuild") }
            }
        }
        loops = [
            // Everything, every 10 seconds; the live numbers every second in between.
            Task { [weak self] in while !Task.isCancelled { if self?.screenOpen != true { await self?.refresh() }; try? await Task.sleep(nanoseconds: UInt64(MacPrefs.fullEvery * 1e9)) } },
            Task { [weak self] in while !Task.isCancelled { if self?.screenOpen != true { await self?.refreshLive() }; try? await Task.sleep(nanoseconds: UInt64(MacPrefs.liveEvery * 1e9)) } },
        ]
    }
    func stop() { loops.forEach { $0.cancel() }; loops = [] }

    // Tests whether code fetched from the Mac can run here, and tells the Mac what happened.
    func hotProbeOnce() async -> Bool {
        // Whole, as it was signed: the signature was made for a framework bundle, and alone it was refused.
        let fm = FileManager.default
        let base = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Hot").appendingPathComponent("HotProbe.framework")
        try? fm.removeItem(at: base)
        var binary = 0
        for part in ["HotProbe", "Info.plist", "_CodeSignature/CodeResources"] {
            guard let (data, resp) = try? await api.hotProbe(part), (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                return false
            }
            let file = base.appendingPathComponent(part)
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: file, options: .noFileProtection)) != nil else { _ = await run("ios-probe", ["result": "could not save \(part)"]); return false }
            if part == "HotProbe" { binary = data.count }
        }
        var result: String
        if let h = dlopen(base.appendingPathComponent("HotProbe").path, RTLD_NOW) {
            typealias Probe = @convention(c) () -> UnsafePointer<CChar>?
            if let sym = dlsym(h, "hot_probe"), let out = unsafeBitCast(sym, to: Probe.self)() { result = "OK: " + String(cString: out) }
            else { result = "opened, but no function" }
        } else {
            // Paths are long and the reason comes last, so send the end of the message.
            let message = dlerror().map { String(cString: $0) } ?? "unknown"
            result = "whole framework failed: " + String(message.suffix(300))
        }
        result += " (\(binary) bytes)"
        _ = await run("ios-probe", ["result": result])
        return true
    }

    func refreshLive() async {
        // Only the live views watch this, so the other tabs and lists stay still.
        guard tab == 0, problem == nil, !address.isEmpty else { return }
        // A reading that failed to come back drops the last one, so the tiles fall back to the full status
        // rather than holding an old number over newer ones.
        guard let l = try? await api.live() else {
            if liveStore.live != nil, !Task.isCancelled { liveStore.live = nil }
            return
        }
        if liveStore.live != l { liveStore.live = l }
    }

    func refresh() async {
        if address.isEmpty { if !needsSignIn { needsSignIn = true }; return }
        do {
            let data = try await api.statusData()
            pulse.lastFresh = Date(); pulse.beats &+= 1
            if problem != nil { problem = nil }
            if needsSignIn { needsSignIn = false }
            if !gotFresh { gotFresh = true }
            // The build's shot of the Admin key row, in place well before the picture is taken.
            if pose == "api-sheet", !posedSheet {
                posedSheet = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); apiSetup = true }
            }
            // The same answer as last time changes nothing on screen, so nothing is redrawn for it.
            if data == lastData, status != nil { openPending(); return }
            lastData = data
            let file = Self.cacheFile
            let decoded = try await Task.detached(priority: .userInitiated) {
                let s = try JSONDecoder().decode(Status.self, from: data)
                try? data.write(to: file, options: .atomic)
                return s
            }.value
            var fresh = decoded
            Self.applyPose(pose, to: &fresh)
            // The build's shot of a session's own page, opened as from the Claude tab.
            if pose == "session", sessionScreen == nil { pendingSession = "chumby"; tab = 2 }
            status = fresh
            openPending()
            // Status's histories read ahead, so a tile opens onto a drawn chart.
            if tab == 0 { let api = api; Task { await TrendCache.prefetch(api, fresh) } }
            AlertWatch.shared.sawInForeground(fresh.alerts ?? [])
        } catch APIError.signInNeeded {
            if !needsSignIn { needsSignIn = true }
            lastData = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            if problem == nil { problem = "Mac Pro is unreachable. It may be restarting, or Tailscale may be off." }
            lastData = nil
            liveStore.live = nil
        }
    }

    // States the build's screenshots need that the sample Mac doesn't have. Only with a pose; never on the phone.
    static func applyPose(_ pose: String, to s: inout Status) {
        switch pose {
        case "alerts": s.alerts = Status.Alert.samples
        case "api-none": s.apiUsage = Status.APIUsage(configured: false)
        case "api-refused": s.apiUsage = Status.APIUsage(configured: true, error: "Couldn’t read API usage: the Admin key was refused")
        case "api-live", "api-sheet": s.apiUsage = .sample
        case "api-estimate": s.apiUsage = .estimateSample
        case "longlog": s.upgrade = Status.Upgrade.longSample
        default: break
        }
    }

    func run(_ name: String, _ body: [String: Any] = [:]) async -> String? {
        do { try await api.action(name, body); await refresh(); return nil }
        catch { return error.localizedDescription }
    }
    func runSealed(_ name: String, secret: String, extra: [String: Any] = [:]) async -> String? {
        do { try await api.sendSealed(name, secret: secret, extra: extra); await refresh(); return nil }
        catch { return error.localizedDescription }
    }
}

enum Format {
    static func bytes(_ b: Double) -> String { String(format: b < 17_179_869_184 ? "%.1f GB" : "%.0f GB", b / 1_073_741_824) }
    static func memory(_ b: Double) -> String { b < 1_073_741_824 ? "\(Int(b / 1_048_576)) MB" : String(format: "%.1f GB", b / 1_073_741_824) }
    static func rate(_ b: Double) -> String {
        if b < 1024 { return "\(Int(b)) B/s" }
        if b < 1_048_576 { return "\(Int(b / 1024)) KB/s" }
        return String(format: "%.1f MB/s", b / 1_048_576)
    }
    static func count(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e3 { return "\(n / 1000)K" }
        return "\(n)"
    }
    static func span(_ seconds: Double) -> String {
        let s = Int(max(0, seconds)), d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        return h > 0 ? "\(h)h \(m)m" : (m > 0 ? "\(m)m" : "under 1m")
    }
    // How old a reading is, only once that's worth saying (half an hour): a fresh one needs no "updated just now".
    static func staleAge(ms: Double) -> String? {
        let s = Date().timeIntervalSince1970 - ms / 1000
        return s < 1800 ? nil : span(s) + " ago"
    }
    static func ago(ms: Double) -> String {
        let s = Date().timeIntervalSince1970 - ms / 1000
        return s < 60 ? "just now" : span(s) + " ago"
    }
}

// What's being typed outlives the layout: unfolding rebuilds the tabs.
@MainActor
final class Drafts: ObservableObject {
    static let shared = Drafts()
    @Published var typed = ""
    @Published var macPassword = ""
}
