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

// The Mac's status, kept apart from the model (gate 3, 2026-11-11). On the model, every landing published to the whole
// app: the root, every tab's frame and the Status page were worked out again on the main thread, a 60 to 180 ms late frame
// each time, and in the first frames of a pull's spring when held readings landed as it ended. Only each tab's frame takes
// it (Screen, and only while its tab is the one in front) and the pages that ask for it.
@MainActor
final class StatusStore: ObservableObject {
    @Published var status: Status?
    // This landing adds or takes away a row: whoever takes it on screen does so in one animated move.
    var moves = false
}

// When the Mac last answered. Kept apart from the model so the beat on each refresh redraws only the chip that shows it.
@MainActor
final class Pulse: ObservableObject {
    @Published var lastFresh: Date?
    @Published var beats = 0
}

// Which page is open over each tab. Apart from the model, and watched only by the stacks (StackPages): on the model,
// closing a page published to the whole app, so every tab was worked out and laid out again on the main thread before
// the pop could move. That was the wait between Back lighting and the page moving (Richard's recording, 2026-11-10:
// lit at 14.15, moving at 14.285; CI 1b744be: root, the tab's stack and both of Status's panes redrawn inside every pop).
@MainActor
final class NavStore: ObservableObject {
    @Published var history: HistoryMetric?  // kept here, not in a view, so unfolding doesn't close it
    @Published var processes: ProcessSort?
    @Published var sessionScreen: Status.Session?  // a session's own screen, on the Claude tab's stack
    @Published var appHistory: String?  // the package (TV.ipa) whose Version History is open on the Apps tab's stack
    @Published var macPage: MacPage?  // Everything on the Mac, or Restart the Mac, on the Control tab's stack
}

@MainActor
final class AppModel: ObservableObject {
    let nav = NavStore()
    let liveStore = LiveStore()
    let seedStore = SeedStore()
    let sessionStore = SessionStore()
    let pulse = Pulse()
    let statusStore = StatusStore()
    let screen = RemoteScreen()
    @Published var screenOpen = false { didSet { screen.paused = !screenOpen } }
    @Published var signingIn = false
    var status: Status? {
        get { statusStore.status }
        set { statusStore.status = newValue; seedStore.set(newValue?.iosApps); sessionStore.set(newValue?.claude.sessions ?? []) }
    }
    // Can't reach the Mac: said only once it has failed to answer for 8 s straight, and never in the first 6 s back in
    // front (Tailscale wakes up after the app does), so one missed reading or the bridge restarting never flips the app to
    // unreachable (Richard, 2026-11-10, of the TV app: "cant reach the mac is tailscale on keeps happening"). An answer
    // the app couldn't read isn't the Mac being away and never counts. Every view that says it reads this (or Reach).
    @Published var problem: String?
    // The Mac answered, but with a status this build can't read (the bridge changes daily; one renamed field was
    // enough). It's reachable, so not `problem`; but nothing on screen is live, and the app says so instead of freezing
    // every tab under a chip that read "Live" (audit, 2026-11-10).
    @Published var unreadable = false
    // The unreachable card put away with its ✕ (a note that stays can be dismissed). The Mac is still away, and the chips
    // and dimmed keys go on saying so; the card returns with the next run of misses, or the next launch.
    @Published var problemPutAway = false
    private var unread = 0
    // The Mac wants its access code. Shown as a row at the top of each tab; the sheet only opens by itself when there's
    // no address at all, so pressing Cancel is respected.
    @Published var needsSignIn = false
    @Published var signInSheet = false
    @Published var apiSetup = false      // the Admin key row in the Usage card; here, so leaving the tab doesn't lose it
    @Published var gotFresh = false      // the Mac has answered at least once since launch, not just the cache
    private var posedSheet = false
    // The open pages, by their old names: read and set through the model, published only by `nav`.
    var history: HistoryMetric? { get { nav.history } set { nav.history = newValue } }
    var processes: ProcessSort? { get { nav.processes } set { nav.processes = newValue } }
    var sessionScreen: Status.Session? { get { nav.sessionScreen } set { nav.sessionScreen = newValue } }
    var appHistory: String? { get { nav.appHistory } set { nav.appHistory = newValue } }
    var macPage: MacPage? { get { nav.macPage } set { nav.macPage = newValue } }
    // A page asked for before its tab has been on screen (a launch straight onto a page: a notification tapped, the
    // build's -openHistory) is pushed once the tab has drawn. Pushed at once, the tab underneath was never drawn until
    // Back first showed it, and it arrived late and in pieces, open flat a pane at a time (designer, CI 1b744be).
    private var tabSince = Date()
    private var drawnAt: Date?
    func whenDrawn(_ push: @escaping @MainActor () -> Void) {
        func wait() -> TimeInterval { drawnAt.map { max($0, tabSince).addingTimeInterval(0.6).timeIntervalSinceNow } ?? 1 }
        if wait() <= 0 { push(); return }
        Task { @MainActor in
            while wait() > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
            push()
        }
    }
    private var posedHistory = false
    private var posedSession = false
    private var pendingSession: String?
    private var lastData: Data?
    // The tab chosen to open on in Settings, or else the one last used.
    @Published var tab = AppModel.firstTab == 3 ? 2 : AppModel.firstTab { didSet { if tab != oldValue { tabSince = Date() } } }
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
        let h = UserDefaults.standard.string(forKey: "openHistory").flatMap(HistoryMetric.named)
        let p = UserDefaults.standard.string(forKey: "openProcesses").flatMap(ProcessSort.init(rawValue:))
        // The build's shots of the Control tab's pushed pages (health, a fix under way, back from a restart, the checks).
        let page: MacPage? = ["health", "healthbad", "healthfixing", "healthback", "healthstuck"].contains(pose) || pose == "didntconfirm" ? .health : ["restart", "restartred"].contains(pose) ? .restart : nil
        if Self.reopen { history = h; processes = p; reopenForShots() }
        else if h != nil || p != nil || page != nil { whenDrawn { [weak self] in self?.history = h; self?.processes = p; self?.macPage = page } }
        // The build's shot of the unreachable card, as it is said now.
        if pose == "unreachable" { problem = Phrase.macAway }
        // The build's shot of the Connection sheet.
        if pose.hasPrefix("signin") { signInSheet = true }
        // Show the last known state at once; fresh numbers replace it moments later.
        if let d = try? Data(contentsOf: Self.cacheFile) { status = try? JSONDecoder().decode(Status.self, from: d) }
        seedStore.set(status?.iosApps); sessionStore.set(status?.claude.sessions ?? [])
        IconCache.api = api
        // How old those numbers are, so being offline never passes them off as live.
        pulse.lastFresh = (try? FileManager.default.attributesOfItem(atPath: Self.cacheFile.path)[.modificationDate]) as? Date
    }

    // What's on screen is only the last the Mac sent: it can't be reached, or won't answer without its code.
    var stale: Bool { problem != nil || needsSignIn || unreadable }

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
                else if pose.hasPrefix("session") { tab = 2; openSession(key: "chumby") }
                else if pose.hasPrefix("versions") { tab = 1; appHistory = "TV.ipa" }
            }
            try? await Task.sleep(nanoseconds: 12_000_000_000); push()
            try? await Task.sleep(nanoseconds: 6_000_000_000); history = nil; processes = nil; sessionScreen = nil; appHistory = nil
            try? await Task.sleep(nanoseconds: 1_500_000_000); push()
        }
    }
    func open(session s: Status.Session) {
        guard let key = s.key else { return }
        Task { await TermCache.warm(api, key, within: 0.15); whenDrawn { self.sessionScreen = s } }
    }
    // A session's own page lives on the Claude tab, wherever it was asked for from.
    // Its text is asked for first, for a moment at most, so the page arrives drawn.
    func openSession(key: String) {
        tab = 2
        guard let s = status?.claude.sessions.first(where: { $0.key == key }) else { pendingSession = key; return }
        pendingSession = nil
        Task { await TermCache.warm(api, key, within: 0.15); whenDrawn { self.sessionScreen = s } }
    }

    private func openPending() {
        if let key = pendingSession, let s = status?.claude.sessions.first(where: { $0.key == key }) {
            pendingSession = nil
            Task { await TermCache.warm(api, key, within: 0.15); whenDrawn { self.sessionScreen = s } }
        }
    }

    private static var cacheFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("status.json") }

    // What came in while a page was moving, put on screen the moment it settles.
    private var heldStatus: Status?
    private var heldLive: LiveStatus?
    // Only a settled page with something already on it is worth protecting: never the first reading, nor while a page is
    // open over a tab (a history waits on its chart; designer HOLD, 2026-11-08: the first status parked at launch left
    // the history in portrait on an empty chart).
    // Nor while a page slides on or off: a reading landing then redrew the tab mid-slide, on the main thread the slide
    // needs, and changed the figures of a page still arriving. It lands as the move ends (NavTransit.onEnd).
    private var parks: Bool {
        if NavTransit.shared.active, status != nil, pendingSession == nil { return true }
        return ScrollHold.holding && status != nil && history == nil && processes == nil && sessionScreen == nil && pendingSession == nil
    }
    private func apply(_ fresh: Status) {
        // An app opening or quitting on the Mac, or one of his apps coming or going, slides its row in or out with the list's
        // own animation; put in at once, the rows under it jumped a row's height in one frame (designer, CI 836207d: the
        // foot of Apps went 90→76 between two frames as TextEdit came and went, the page at rest at its end).
        // The same for anything that adds or takes away a row or a card: an alert arriving or going at the top of Status (the
        // whole page under it moved down a row in one frame), a session, a sensor, a top process.
        func rows(_ s: Status?) -> [String] {
            guard let s else { return [] }
            var r: [String] = s.apps.filter { $0.mem != nil }.map { "\($0.pid)" }
            r += (s.iosApps?.apps ?? []).map { $0.id }
            r += (s.alerts ?? []).map { "alert:" + $0.id }
            r += s.claude.sessions.map { "session:" + $0.id }
            r += (s.temps ?? []).map { "temp:" + $0.name }
            r.append("procs:\(s.procs.count)")
            r.append("health:\(s.healthBad ?? -1)")
            return r
        }
        statusStore.moves = status != nil && rows(status) != rows(fresh)
        if statusStore.moves { withAnimation(Motion.quick) { status = fresh } } else { status = fresh }
        statusStore.moves = false
        IconCache.prefetch(fresh, api: api)
        openPending()
        // Status's histories read ahead, so a tile opens onto a drawn chart.
        if tab == 0 { let api = api; Task { await TrendCache.prefetch(api, fresh) } }
        // Status's health chip, from a Mac whose status doesn't count its parts yet: read from its Health now and then.
        if tab == 0, fresh.healthBad == nil, pose != "checking" { HealthSummary.shared.refresh(api) }
        AlertWatch.shared.sawInForeground(fresh.alerts ?? [])
    }
    private func releaseHeld() {
        if let s = heldStatus { heldStatus = nil; SwipeLog.note("held status landed"); apply(s) }
        if let l = heldLive { heldLive = nil; if liveStore.live != l { SwipeLog.note("held live landed"); liveStore.live = l } }
    }

    func start() {
        if drawnAt == nil { drawnAt = Date() }
        stop()
        ScrollHold.onRelease = { [weak self] in self?.releaseHeld() }
        // What waited for a slide lands as it ends, simply there: figures rolling into place on a page that has only just
        // arrived read as the page still settling (Richard's recording, 2026-11-10).
        NavTransit.shared.onEnd = { [weak self] in
            guard !ScrollHold.holding else { return }
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { self?.releaseHeld() }
        }
        loops = [
            // Everything, every 10 seconds; the live numbers every second in between. While the Mac can't be reached it's
            // asked every 3 s at most: the live numbers stop then, and only this brings the app back, which took up to a
            // minute after Tailscale came on with "Everything else" set to a minute (audit, 2026-11-10).
            Task { [weak self] in
                while !Task.isCancelled {
                    if self?.screenOpen != true { await self?.refresh() }
                    let wait = self?.problem != nil ? min(MacPrefs.fullEvery, 3) : MacPrefs.fullEvery
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                }
            },
            Task { [weak self] in while !Task.isCancelled { if self?.screenOpen != true { await self?.refreshLive() }; try? await Task.sleep(nanoseconds: UInt64(MacPrefs.liveEvery * 1e9)) } },
        ]
    }
    func stop() { loops.forEach { $0.cancel() }; loops = [] }
    // One missed answer from the Mac: unreachable once they've run 8 s with nothing between.
    private func missed() {
        guard Reach.shared.miss(), problem == nil else { return }
        // The card at the top of every tab arrives in one animated move, as it leaves: put in at once, the whole page under
        // it dropped by the card's height in one frame, and rose again when the Mac answered.
        withAnimation(Motion.quick) { problem = Phrase.macAway }
        // A new run of misses says it again, whatever was put away before.
        problemPutAway = false
        liveStore.live = nil
    }

    func refreshLive() async {
        // Only the live views watch this, so the other tabs and lists stay still.
        guard tab == 0, problem == nil, !address.isEmpty else { return }
        // A reading that failed to come back drops the last one, so the tiles fall back to the full status
        // rather than holding an old number over newer ones.
        // Missed once, the last reading stays: it's dropped only when the Mac counts as unreachable (missed).
        let l: LiveStatus
        do { l = try await api.live() }
        catch {
            // An answer this build can't read is the Mac there, as it is for the full status. It counted as a miss, once
            // a second, so a Mac whose live figures the app couldn't read was "unreachable" 8 s after every full reading
            // and back again at the next, for as long as that lasted (CI 1b744be against a stand-in Mac with no live
            // figures: the red card on and off every 10 s; the brief's "cause unproven" flash).
            if Task.isCancelled { return }
            if error is DecodingError { Reach.shared.hit(); SwipeLog.note("live unread") } else { SwipeLog.note("live missed: \(error)"); missed() }
            return
        }
        Reach.shared.hit()
        // Not while a page is moving under his finger: a row changing height mid-bounce snaps the page back.
        if parks { heldLive = l; return }
        if liveStore.live != l { SwipeLog.note("live landed"); liveStore.live = l }
    }

    func refresh() async {
        if address.isEmpty { if !needsSignIn { needsSignIn = true }; return }
        do {
            let data = try await api.statusData()
            // It answered: reachable, whatever it said. Fresh only once what it said has been read (below).
            Reach.shared.hit()
            if problem != nil, pose != "unreachable" { withAnimation(Motion.quick) { problem = nil } }
            if needsSignIn { withAnimation(Motion.quick) { needsSignIn = false } }
            func markFresh() { unread = 0; pulse.lastFresh = pose == "unreachable" ? Date().addingTimeInterval(-25) : Date(); pulse.beats &+= 1; if !gotFresh { gotFresh = true }; if unreadable != (pose == "unreadable") { withAnimation(Motion.quick) { unreadable = pose == "unreadable" } } }
            // The build's shot of the Admin key row, in place well before the picture is taken.
            if pose == "api-sheet", !posedSheet {
                posedSheet = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); apiSetup = true }
            }
            // The same answer as last time changes nothing on screen, so nothing is redrawn for it.
            if data == lastData, status != nil { markFresh(); openPending(); return }
            let file = Self.cacheFile
            let asked = CFAbsoluteTimeGetCurrent()
            let decoded = try await Task.detached(priority: .userInitiated) {
                let s = try JSONDecoder().decode(Status.self, from: data)
                try? data.write(to: file, options: .atomic)
                return s
            }.value
            if SwipeLog.on { SwipeLog.note(String(format: "status read off main %.0f ms", (CFAbsoluteTimeGetCurrent() - asked) * 1000)) }
            lastData = data
            markFresh()
            var fresh = decoded
            Self.applyPose(pose, to: &fresh)
            // The build's shot of a session's own page, opened as from the Claude tab.
            // (Also "sessionstale", its screen no longer coming, and "sessionfail", a message that didn't get through.)
            // Once: taken back with Back in the build's film, the page stays closed.
            if pose.hasPrefix("session"), sessionScreen == nil, !posedSession, !Self.reopen { posedSession = true; pendingSession = "chumby"; tab = 2 }
            // The build's shot of an app's Version History, opened as from the Apps tab.
            if ["versions", "versionsfilm", "versionsupdate"].contains(pose), !posedHistory, !Self.reopen {
                posedHistory = true; tab = 1
                // "versionsupdate": an app with a newer build ready over the air, so the page's Update shows.
                let file = pose == "versionsupdate" ? "Chumby.ipa" : "TV.ipa"
                whenDrawn { self.appHistory = file }
            }
            if parks { SwipeLog.note("status held"); heldStatus = fresh; return }
            SwipeLog.note("status landed")
            let t0 = CFAbsoluteTimeGetCurrent()
            apply(fresh)
            if SwipeLog.on { SwipeLog.note(String(format: "status applied %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)) }
        } catch APIError.signInNeeded {
            if !needsSignIn { withAnimation(Motion.quick) { needsSignIn = true } }
            lastData = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch is DecodingError {
            // The Mac answered with something this build can't read: it's there, the last status stands, and the app
            // says that's what it is showing.
            // Said only when the next reading can't be read either: the bridge sends a half-made status for a moment as it
            // restarts, and one of those is not a version the app can't read.
            lastData = nil
            unread += 1
            if unread >= 2, !unreadable { withAnimation(Motion.quick) { unreadable = true } }
        } catch {
            lastData = nil
            SwipeLog.note("status missed: \(error)")
            missed()
        }
    }

    // States the build's screenshots need that the sample Mac doesn't have. Only with a pose; never on the phone.
    static func applyPose(_ pose: String, to s: inout Status) {
        switch pose {
        case "alerts", "alertsdismiss": s.alerts = Status.Alert.samples
        // Two parts of the Mac needing a look, as its bridge will count them: Status's chip says so and opens Health.
        case "needslook": s.healthBad = 2
        // Before the Mac has said anything about itself: the chip is grey "Checking".
        case "checking": s.alerts = nil; s.healthBad = nil
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

    // Nil when it worked, or what went wrong in plain words: the Mac out of reach reads the way it does everywhere, never
    // as the system's "The request timed out."
    func run(_ name: String, _ body: [String: Any] = [:]) async -> String? {
        do { try await api.action(name, body); await refresh(); return nil }
        catch { return Self.say(error) }
    }
    func runSealed(_ name: String, secret: String, extra: [String: Any] = [:]) async -> String? {
        do { try await api.sendSealed(name, secret: secret, extra: extra); await refresh(); return nil }
        catch { return Self.say(error) }
    }
    static func say(_ error: Error) -> String { MacFiles.unreachable(error) ? Phrase.macAway : error.localizedDescription }
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

// Whether the Mac counts as unreachable yet, for the model and for each page that reads from the Mac on its own: a run
// of failures 8 s long, with nothing answered between, and not in the first 6 s after the app came back to the front.
@MainActor final class Reach {
    static let shared = Reach()
    private var since: Date?
    private var count = 0
    private(set) var foregroundAt = Date()
    func cameForward() { foregroundAt = Date(); since = nil; count = 0 }
    func hit() { since = nil; count = 0 }
    // A miss; true once they add up to unreachable: three unanswered in a row as well as 8 s. Time alone let two misses
    // ten seconds apart say it, and a phone too busy to run for a while say it with one (the build's films, 2026-11-10:
    // "can't reach" flashing against a Mac that was answering).
    func miss() -> Bool {
        let now = Date()
        if since == nil { since = now }
        count += 1
        return count >= 3 && now.timeIntervalSince(since!) >= 8 && now.timeIntervalSince(foregroundAt) >= 6
    }
}
// The same rule for a page's own reading (a history, the processes, a session's screen): its misses, counted from its
// first, with the app's grace after coming back to the front.
struct MissClock {
    private var since: Date?
    private var count = 0
    mutating func hit() { since = nil; count = 0 }
    @MainActor mutating func miss() -> Bool {
        let now = Date()
        if since == nil { since = now }
        count += 1
        return count >= 3 && now.timeIntervalSince(since!) >= 8 && now.timeIntervalSince(Reach.shared.foregroundAt) >= 6
    }
}
