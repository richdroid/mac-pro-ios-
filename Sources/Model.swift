import Foundation
import SwiftUI

@MainActor
final class LiveStore: ObservableObject { @Published var live: LiveStatus? }

// What the pushed pages show from the status, kept apart from it: Version History its app's entry, a session's page its
// session. Each is set only when it changed, so a page watching these never redraws for a reading (the status itself is
// republished with every one; Version History redrew once a second under live readings, 2.4 % late frames vs 0.2 %).
@MainActor
final class SeedStore: ObservableObject {
    @Published private(set) var seed: Status.SeedStatus?
    func set(_ s: Status.SeedStatus?) { if s != seed { seed = s } }
}
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Status.Session] = []
    func set(_ s: [Status.Session]) { if s != sessions { sessions = s } }
}

// When the Mac last answered. Kept apart from the model so the beat on each refresh redraws only the chip that shows it.
@MainActor
final class Pulse: ObservableObject {
    @Published var lastFresh: Date?
    @Published var beats = 0
}

@MainActor
final class AppModel: ObservableObject {
    let liveStore = LiveStore()
    let seedStore = SeedStore()
    let sessionStore = SessionStore()
    let pulse = Pulse()
    let screen = RemoteScreen()
    @Published var screenOpen = false { didSet { screen.paused = !screenOpen } }
    @Published var signingIn = false
    @Published var status: Status? { didSet { seedStore.set(status?.iosApps); sessionStore.set(status?.claude.sessions ?? []) } }
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
    @Published var appHistory: String?  // the package (TV.ipa) whose Version History is open on the Apps tab's stack
    private var posedHistory = false
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
    // Kept in the Keychain too, so a reinstall finds it (SavedAddress).
    @Published var address: String { didSet { SavedAddress.save(address); liveStore.live = nil; lastData = nil; IconCache.api = api } }

    var api: API { API(base: URL(string: address) ?? URL(string: "https://invalid.invalid")!) }
    private var loops: [Task<Void, Never>] = []

    // The Mac bakes its address into the build when it collects it, so it never has to live in the source.
    init() {
        address = SavedAddress.value
        // On first launch too, so a baked-in address (or one the Keychain kept) is in both stores from then on. Not for the
        // build's shots, launched with their own address.
        if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["address"] == nil { SavedAddress.save(address) }
        needsSignIn = address.isEmpty
        signInSheet = address.isEmpty
        // Usage was a tab of its own until 2026-11-07; a start tab set to it opens on Claude, where it now lives.
        if UserDefaults.standard.integer(forKey: "startTab") == 3 { UserDefaults.standard.set(2, forKey: "startTab") }
        history = UserDefaults.standard.string(forKey: "openHistory").flatMap(HistoryMetric.named)
        processes = UserDefaults.standard.string(forKey: "openProcesses").flatMap(ProcessSort.init(rawValue:))
        if Self.reopen { reopenForShots() }
        // Show the last known state at once; fresh numbers replace it moments later.
        if let d = try? Data(contentsOf: Self.cacheFile) { status = try? JSONDecoder().decode(Status.self, from: d) }
        seedStore.set(status?.iosApps); sessionStore.set(status?.claude.sessions ?? [])
        IconCache.api = api
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

    // A session's page, from its row: its text read ahead for a moment at most, so the page arrives drawn.
    // For the build's shots of a page's first open beside its second (-reopen YES, never on the phone): the page the
    // launch asked for is pushed as a tap would push it 12 s in (its first open since launch, once a cold launch has
    // drawn the tab), closed at 18 s and pushed again at 19.5 s, so the two can be compared pixel for pixel (Richard, 2026-11-10: "certain elements open with the
    // text too close to edge but correct themselves on subsequent presses").
    static let reopen = UserDefaults.standard.bool(forKey: "reopen")
    private func reopenForShots() {
        let h = history, p = processes
        history = nil; processes = nil
        Task { @MainActor in
            @MainActor func push() {
                if let h { tab = 0; history = h }
                else if let p { tab = 0; processes = p }
                else if pose == "session" { tab = 2; openSession(key: "chumby") }
                else if pose.hasPrefix("versions") { tab = 1; appHistory = "TV.ipa" }
            }
            try? await Task.sleep(nanoseconds: 12_000_000_000); push()
            try? await Task.sleep(nanoseconds: 6_000_000_000); history = nil; processes = nil; sessionScreen = nil; appHistory = nil
            try? await Task.sleep(nanoseconds: 1_500_000_000); push()
        }
    }
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

    // What came in while a page was moving, put on screen the moment it settles.
    private var heldStatus: Status?
    private var heldLive: LiveStatus?
    // Only a settled page with something already on it is worth protecting: never the first reading, nor while a page is
    // open over a tab (a history waits on its chart; designer HOLD, 2026-11-08: the first status parked at launch left
    // the history in portrait on an empty chart).
    private var parks: Bool { ScrollHold.holding && status != nil && history == nil && processes == nil && sessionScreen == nil && pendingSession == nil }
    private func apply(_ fresh: Status) {
        // An app opening or quitting on the Mac, or one of his apps coming or going, slides its row in or out with the list's
        // own animation; put in at once, the rows under it jumped a row's height in one frame (designer, CI 836207d: the
        // foot of Apps went 90→76 between two frames as TextEdit came and went, the page at rest at its end).
        func rows(_ s: Status?) -> [String] { (s?.apps.filter { $0.mem != nil }.map { "\($0.pid)" } ?? []) + (s?.iosApps?.apps.map(\.id) ?? []) }
        if status != nil, rows(status) != rows(fresh) { withAnimation(Motion.quick) { status = fresh } }
        else { status = fresh }
        IconCache.prefetch(fresh, api: api)
        openPending()
        // Status's histories read ahead, so a tile opens onto a drawn chart.
        if tab == 0 { let api = api; Task { await TrendCache.prefetch(api, fresh) } }
        AlertWatch.shared.sawInForeground(fresh.alerts ?? [])
    }
    private func releaseHeld() {
        if let s = heldStatus { heldStatus = nil; apply(s) }
        if let l = heldLive { heldLive = nil; if liveStore.live != l { liveStore.live = l } }
    }

    func start() {
        stop()
        ScrollHold.onRelease = { [weak self] in self?.releaseHeld() }
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
        // Not while a page is moving under his finger: a row changing height mid-bounce snaps the page back.
        if parks { heldLive = l; return }
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
            if pose == "session", sessionScreen == nil, !Self.reopen { pendingSession = "chumby"; tab = 2 }
            // The build's shot of an app's Version History, opened as from the Apps tab.
            if ["versions", "versionsfilm", "versionsupdate"].contains(pose), !posedHistory, !Self.reopen {
                posedHistory = true; tab = 1
                // "versionsupdate": an app with a newer build ready over the air, so the page's Update shows.
                appHistory = pose == "versionsupdate" ? "Chumby.ipa" : "TV.ipa"
            }
            if parks { heldStatus = fresh; return }
            apply(fresh)
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
        // Away from home with two of his apps rebuilt and signed for this iPhone: both install over the air, with the card
        // to install them together ("otaoffer" also has the offer sheet up, as the app opens).
        // Every one of his apps already at the Mac's build: the Updates section says so.
        case "uptodate":
            if let seed = s.iosApps {
                let apps = seed.apps.map { a in
                    a.own ? Status.SeedApp(file: a.file, name: a.name, version: a.version, build: a.build, phoneBuild: a.build, installedAt: a.installedAt, expires: a.expires, state: "current", message: "", own: true, ota: a.ota, icon: a.icon) : a
                }
                s.iosApps = Status.SeedStatus(reachable: seed.reachable, via: seed.via, checkedAt: seed.checkedAt, seeding: "", fetch: seed.fetch, apps: apps)
            }
        // His three apps from TestFlight, as the Mac reports them since 2026-11-10: quiet rows, Mac Pro with a newer
        // build waiting in TestFlight, and one app he added himself with an update the Mac signed for this iPhone.
        case "testflight", "testflighttip":
            let mine = Int(OTAInstaller.thisBuild) ?? 12
            func tf(_ file: String, _ name: String, _ phone: String, _ tf: String, _ id: String) -> Status.SeedApp {
                Status.SeedApp(file: file, name: name, version: "1.0", build: tf, phoneBuild: phone, installedAt: 1, expires: 0, state: "testflight", message: "", own: true,
                               ota: "itms-beta://beta.itunes.apple.com/v1/app/\(id)", notes: tf != phone ? ["Pages you swipe away slide off whole"] : nil,
                               builtAt: Date().timeIntervalSince1970 * 1000 - 3_600_000, icon: "/ios/icon/\(file)", tfBuild: tf)
            }
            let added = Status.SeedApp(file: "Delta.ipa", name: "Delta", version: "1.6", build: "107", phoneBuild: "106", installedAt: 1, expires: Date().timeIntervalSince1970 * 1000 + 20 * 86_400_000, state: "waiting", message: "", own: true,
                                       ota: "itms-services://?action=download-manifest&url=https%3A%2F%2Fmac-pro.example.ts.net%2Fota%2FDelta.plist", notes: ["Smoother scrolling in the library"], builtAt: Date().timeIntervalSince1970 * 1000 - 7_200_000, icon: nil)
            s.iosApps = Status.SeedStatus(reachable: false, via: "", checkedAt: 1, seeding: "", fetch: nil,
                                          apps: [tf("MacPro.ipa", "Mac Pro", "\(mine)", "\(mine + 1)", "6740000001"), tf("TV.ipa", "TV Remote", "204", "204", "6740000002"), tf("Chumby.ipa", "Chumby", "12", "12", "6740000003"), added])
            if pose == "testflighttip" { UserDefaults.standard.removeObject(forKey: "tfAutoTipDone") } else { UserDefaults.standard.set(true, forKey: "tfAutoTipDone") }
        case "otaready", "otaoffer", "otasent", "otahome", "versionsupdate":
            let mine = Int(OTAInstaller.thisBuild) ?? 12
            func link(_ n: String) -> String { "itms-services://?action=download-manifest&url=https%3A%2F%2Fmac-pro.example.ts.net%2Fota%2F\(n).plist" }
            let apps = [
                Status.SeedApp(file: "MacPro.ipa", name: "Mac Pro", version: "1.0", build: "\(mine + 1)", phoneBuild: "\(mine)", installedAt: 1, expires: 4102444800000, state: "waiting", message: "", own: true, ota: link("MacPro"),
                               notes: ["Screen: the posture follows the Duo's own hinge, partly open as a laptop, fully open flat", "Screen: symbols on the keys and @ reaches the Mac, held keys repeat, a MacBook-shaped trackpad", "Updates have their own place at the top of Apps, with a count on the tab", "Status: the Display key follows the Mac's display every second"],
                               builtAt: Date().timeIntervalSince1970 * 1000 - 3_600_000, icon: "/ios/icon/MacPro.ipa"),
                Status.SeedApp(file: "Chumby.ipa", name: "Chumby", version: "1.0", build: "12", phoneBuild: "11", installedAt: 1, expires: 4102444800000, state: "waiting", message: "", own: true, ota: link("Chumby"),
                               notes: ["A calendar day can have its own sound and snooze", "The next alarm can ring later or with another sound just this once"],
                               builtAt: Date().timeIntervalSince1970 * 1000 - 90_000_000, icon: "/ios/icon/Chumby.ipa"),
            ]
            s.iosApps = Status.SeedStatus(reachable: false, via: "", checkedAt: 1, seeding: "", fetch: nil, apps: apps + (s.iosApps?.apps ?? []).filter { !$0.own })
            // "otasent": Chumby's update already sent to this iPhone over the air, as after he tapped it at work.
            // "otahome": away, with Chumby's new build not yet signed for this iPhone: its capsule dimmed, "on home Wi-Fi".
            if pose == "otahome", let seed = s.iosApps {
                s.iosApps = Status.SeedStatus(reachable: false, via: "", checkedAt: 1, seeding: "", fetch: nil, apps: seed.apps.map { a in
                    a.file == "Chumby.ipa" ? Status.SeedApp(file: a.file, name: a.name, version: a.version, build: a.build, phoneBuild: "", installedAt: a.installedAt, expires: a.expires, state: "waiting", message: "", own: true, ota: nil, notes: a.notes, builtAt: a.builtAt, icon: a.icon) : a
                })
            }
            if pose == "otasent" { UserDefaults.standard.set(["Chumby.ipa": "12"], forKey: "otaOpened") }
            else { UserDefaults.standard.removeObject(forKey: "otaOpened") }
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
