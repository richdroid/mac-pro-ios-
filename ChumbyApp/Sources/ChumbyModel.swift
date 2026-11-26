import Foundation
import SwiftUI
import WidgetKit
import Network
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
extension Image { init(platform i: UIImage) { self.init(uiImage: i) } }
#else
import AppKit
typealias PlatformImage = NSImage
extension Image { init(platform i: NSImage) { self.init(nsImage: i) } }
#endif

// A control's own failure, shown at that control and nowhere else.
struct Failure: Equatable { let id: String; let text: String; let at: Date }
// retrying: a failed change sent again, its note kept in place ("Trying again…") so nothing moves unless it lands.
enum AlarmMark: Equatable { case failed(head: String, why: String), retrying(head: String, why: String), landed(Date) }

// Whether the phone has Wi-Fi at all right now. The Chumby's own address (ChumbyFallback) is on home's Wi-Fi, so off Wi-Fi
// (cellular, 11-20) it can never answer, and trying it only cost the Tailscale route its turns. Its available interfaces,
// not the path's own: with Tailscale on, the path is the tunnel, which sits on whichever of the two is under it. Until
// the first answer it counts as Wi-Fi, so nothing is ruled out on a guess.
final class WiFiWatch: @unchecked Sendable {
    static let shared = WiFiWatch()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var wifi = true
    var on: Bool { lock.lock(); defer { lock.unlock() }; return wifi }
    private init() {
        monitor.pathUpdateHandler = { [weak self] p in
            let w = p.availableInterfaces.contains { $0.type == .wifi }
            self?.lock.lock(); self?.wifi = w; self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "chumby.wifi"))
    }
}


@MainActor
final class ChumbyModel: ObservableObject {
    @Published var sys = Sys()
    // The list as shown: the Chumby's own, with any change still on its way laid over it.
    @Published var state = ChumbyState()
    // Whether anything has been read yet, from the Chumby or from what was kept last time. Until then "no alarms" would be a guess.
    @Published var stateKnown = false
    @Published var channelData: ChannelList?
    @Published var shot: PlatformImage?
    @Published var offline = false
    @Published var needsAddress = false
    @Published var tab = UserDefaults.standard.integer(forKey: "tab")
    @Published var address: String { didSet { SavedAddress.save(address); api = Self.makeAPI(address); usingFallback = false; troubleSince = nil; triedRoutes = []; lastMacTry = .distantPast } }
    @Published var failure: Failure?
    @Published var marks: [String: AlarmMark] = [:]
    @Published var dead = false        // the Mac answers, but the Chumby itself has gone quiet
    @Published var lastSeen: Date?     // when the Mac last heard from it
    // When this phone last heard from it, kept across launches, for "last seen" when the Mac can't be reached either.
    // Not published: it moves on every reading, and is only shown while the Chumby can't be reached, when the change to
    // `offline` or `dead` redraws what shows it. Publishing it rebuilt every tab every few seconds for nothing.
    var lastHeard: Date? = UserDefaults.standard.object(forKey: "lastHeard") as? Date
    @Published var busy: (text: String, until: Date)?
    @Published var snoozedAt: Date?
    // Every change to the history asks for its covers at once, so "Woke up to" can show a song as soon as its art is in.
    @Published var songs: [Song] = [] { didSet { if songs != oldValue { SongArt.shared.prefetch(songs, state.alarms, rings) } } }
    // Every alarm that started ringing, newest first, from the Chumby's own log: what "Woke up to" pairs songs with.
    @Published var rings: [Ring] = [] { didSet { if rings != oldValue { SongArt.shared.prefetch(songs, state.alarms, rings) } } }
    @Published var homePoke: Date?
    // A tap on Add alarm from elsewhere.
    @Published var addAlarm: Date?
    // An alarm another page asked Alarms to open (by Alarm.key, or "Nap"): Home's card, tapped on a nap or a skipped ring.
    @Published var openAlarm: String?
    // The full-screen ringing page (ChumbyRing.swift): up when the ring's notification or its Lock Screen card is tapped,
    // and by itself when the app is in front as an alarm starts to sound. `ringHint` is what the tap itself said, shown
    // until the Chumby's own reading arrives.
    @Published var ringScreen = false { didSet { if ringScreen != oldValue { RingPresenter.sync(self) } } }
    var ringHint: ChumbyRingAttributes.ContentState?
    // Counts the Chumby's fresh readings of what's ringing, so the ringing page can tell "not heard from yet" from "heard,
    // and nothing is ringing".
    @Published private(set) var ringReadings = 0
    private var ringSwept = false
    // When the Chumby last confirmed a Stop and a Snooze, whichever door the press came through (the app's own keys,
    // the Lock Screen card, the notification, Siri): the desk's own note (RingDesk.note).
    private var ringStoppedAt: Date? { RingDesk.confirmed(RingDesk.stoppedKey) }
    private var ringSnoozedAt: Date? { RingDesk.confirmed(RingDesk.snoozedKey) }
    // A Stop or Snooze on its way and not yet confirmed by the Chumby: Home's ringing card and the ringing page say
    // "Stopping…" or "Snoozing…" with their keys dimmed, as the Lock Screen card does. Nil when nothing is pending.
    @Published private(set) var ringWorking: String?
    var ringStopping: Bool { ringWorking == "Stopping…" }
    // One sentence everywhere for a press the Chumby took and hasn't confirmed (card, notification, app).
    static let unconfirmed = "Sent. The Chumby hasn’t confirmed yet."
    private var readingAt = Date()
    // Opens the ringing page for a tap on the ring's notification or card. With a reading seconds old in hand that says
    // nothing is ringing, there is no page to show: what was tapped is cleared away instead.
    func openRing(hint: ChumbyRingAttributes.ContentState?) {
        if sys.ringing == nil, !unreachable, let seen = seenAt, Date().timeIntervalSince(seen) < 8, running {
            Task { await ChumbyRingCard.over() }
            return
        }
        ringHint = hint
        ringScreen = true
    }
    // Folded, Calendar settings pushed inside Alarms. Kept here so its Back can sit in the rail, outside the page that slides.
    // A page opening over Alarms gets anything parked at once (see parks).
    // The "just this once" sheet, open or not: on the model, not in the menu's own state, because Home lays its
    // controls out in another place of the tree when the phone opens flat, and a sheet held by the view went with it.
    @Published var justOnceSheetOpen = false
    @Published var alarmsPage = false { didSet { if alarmsPage { releaseHeld() }; if alarmsPage != oldValue { SwipeLog.note("alarmsPage \(alarmsPage)") } } }
    // The page shown in place of Alarms ("Calendar settings", or the day's name), for its bar's title.
    private(set) var api: ChumbyAPI?
    private var loops: [Task<Void, Never>] = []
    private var failureClear: Task<Void, Never>?
    var editingAlarm = false { didSet { if editingAlarm { releaseHeld() } else if let s = heldAdopt { heldAdopt = nil; adopt(s) } } }
    private var heldAdopt: ChumbyState?
    var unreachable: Bool { offline || dead }
    // One fact, said one way everywhere (2026-11-11 gate). "The Mac" only when the Mac is in the path.
    // (Not switched by route: while failing, the app alternates routes every few seconds, and the words must hold still.)
    var reachWords: String { dead ? "Not answering" : "Can’t reach the Mac" }
    var reachInline: String { dead ? "the Chumby isn’t answering" : "can’t reach the Mac" }
    // A reading failed and nothing has come through since: nothing is said yet, but kept values (the channel's name)
    // show rather than waiting on a confirmation that may be a while.
    @Published private(set) var struggling = false
    // Heard from within the last 15 minutes, so what was kept is near enough to show without waiting.
    var keptRecent: Bool { lastHeard.map { Date().timeIntervalSince($0) < 900 } ?? false }
    var seenAt: Date? { dead ? (lastSeen ?? lastHeard) : lastHeard }
    // It restarts itself within a few minutes of hanging (chwd on the device), so only then is it worth getting up.
    var deadText: String {
        guard let lastSeen else { return "It should restart itself within a few minutes." }
        return Date().timeIntervalSince(lastSeen) < 600 ? "It should restart itself within a few minutes." : "It hasn’t restarted. Try unplugging it for a moment."
    }
    private var fallback: String { Bundle.main.object(forInfoDictionaryKey: "ChumbyFallback") as? String ?? "" }
    private var usingFallback = false
    // Since when no reading has come through by any route, and which routes have been tried since. Nothing is said
    // about it until it has lasted `patience` and every route has failed: opening the app on cellular, Tailscale takes a
    // few seconds to wake, and the first request or two failing is normal. Richard, 2026-11-11: "i hate opening the app
    // and getting an its offline message JANKYYY". A blip that recovers leaves nothing on screen.
    private var troubleSince: Date?
    private var triedRoutes: Set<Bool> = []
    private var downSince: Date?
    static let patience: TimeInterval = 25
    // Retried every two seconds while in trouble, on whichever route is next, rather than at the route's usual pace.
    var retrying: Bool { troubleSince != nil || downSince != nil }
    private var sysBytes = Data(), stateBytes = Data(), channelBytes = Data(), shotBytes = Data()
    private var sysHold = Date.distantPast, stateHold = Date.distantPast
    // The Chumby's own list as last read or saved, with nothing of ours laid over it.
    private(set) var deviceState = ChumbyState()
    // Whether a recent reading has come in since opening. Streams and the schedule replace a whole list, so they wait for one.
    @Published private(set) var stateConfirmed = false
    private func canSave(_ id: String) -> Bool {
        if stateConfirmed { return true }
        fail(id, "Still reaching the Chumby. Nothing was saved.")
        stateBytes = Data(); stateHold = .distantPast
        return false
    }
    static var pose: String { UserDefaults.standard.string(forKey: "pose") ?? "" }

    private static func makeAPI(_ a: String) -> ChumbyAPI? { URL(string: a).flatMap { $0.host == nil ? nil : ChumbyAPI(base: $0) } }
    private static func cache(_ name: String) -> URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chumby-" + name) }

    init() {
        _ = WiFiWatch.shared
        let saved = SavedAddress.value
        address = saved
        // Kept in the Keychain from the first launch, so a reinstall finds it even if it was never typed.
        if !saved.isEmpty { SavedAddress.save(saved) }
        api = Self.makeAPI(saved)
        needsAddress = api == nil
        #if canImport(UIKit)
        // Off the launch path, but ready before the first tap.
        Task { try? await Task.sleep(nanoseconds: 1_000_000_000); Haptics.warm() }
        #endif
        // Open with what we last knew. The app is always faster than the device. (The first-run shot starts with nothing.)
        if Self.pose != "firstrun" {
            // Never a ring from what was kept: only a fresh reading may say his alarm is going off.
            if let d = try? Data(contentsOf: Self.cache("sys")), var v = try? JSONDecoder().decode(Sys.self, from: d) { v.ring = ""; sys = v }
            if let d = try? Data(contentsOf: Self.cache("state")), let v = try? JSONDecoder().decode(ChumbyState.self, from: d) { deviceState = v; state = v; stateBytes = d; stateKnown = true }
            if let d = try? Data(contentsOf: Self.cache("chlist")), let v = try? JSONDecoder().decode(ChannelList.self, from: d) { channelData = v; channelBytes = d }
            if let d = try? Data(contentsOf: Self.cache("shot")) { shot = PlatformImage(data: d) }
            if let d = try? Data(contentsOf: Self.cache("hist")), let v = try? JSONDecoder().decode([Song].self, from: d) { songs = v }
            if let d = try? Data(contentsOf: Self.cache("rings")), let v = try? JSONDecoder().decode([Ring].self, from: d) { rings = v }
        } else { lastHeard = nil }
        CalendarWake.shared.saved = { [weak self] s in self?.adopt(s) }
        ScrollHold.onRelease = { [weak self] in self?.releaseHeld() }
    }
    // Polled readings that came in while a page was moving under his finger, put on screen the moment it settles: a
    // row changing height under a page pulled past its end snaps it back instead of letting it spring (2026-11-08).
    // Only what's polled waits: his own saves, skips and channel choices go straight through, and so does a ring.
    private var heldSys: (data: Data, fresh: Bool, at: Date)?
    private var heldState: (data: Data, state: ChumbyState, recent: Bool)?
    private var heldChannels: (data: Data, list: ChannelList)?
    private var heldSongs: History?
    private struct History: Decodable { let songs: [Song]; let rings: [Ring]? }
    // Only a settled page with something already on it is worth protecting: never before a recent reading has
    // confirmed what's shown (a List reports a settling phase as it opens, which parked the Mac Pro app's first reading;
    // Home's channel name and Playing card wait on stateConfirmed), and never while Calendar settings, a day or an
    // editor is open over Alarms, since they're waiting on it.
    private var parks: Bool { ScrollHold.holding && stateConfirmed && !alarmsPage && !editingAlarm }
    private func releaseHeld() {
        if heldSys != nil || heldState != nil { SwipeLog.note("held readings landed") }
        if let h = heldSys { heldSys = nil; if var v = try? JSONDecoder().decode(Sys.self, from: h.data) { if !h.fresh { v.ring = sys.ring }; applySys(v, data: h.data, fresh: h.fresh, takenAt: h.at) } }
        if let h = heldState { heldState = nil; if Date() >= stateHold { applyState(h.state, data: h.data, recent: h.recent) } }
        if let h = heldChannels { heldChannels = nil; applyChannels(h.list, data: h.data) }
        if let h = heldSongs { heldSongs = nil; applySongs(h) }
    }
    // A list just saved from elsewhere in the app, as the Chumby now holds it. Kept back while an alarm is open in the editor.
    func adopt(_ s: ChumbyState) {
        if editingAlarm { heldAdopt = s; return }
        took(s)
        stateHold = Date().addingTimeInterval(3)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // A list a flow of its own just read straight from the Chumby (a "just this once"): as recent as a reading gets.
    func adoptFresh(_ s: ChumbyState) { stateConfirmed = true; adopt(s) }

    func start() {
        let left = stoppedAt
        stop()
        running = true
        ringSwept = false
        stateConfirmed = false      // it may have been hours; the list could have changed from elsewhere
        // Opening starts afresh: what was kept is shown at once, and only a failure that lasts from here is mentioned.
        // Back within five minutes of leaving with a verdict already said, it stands (a frozen Chumby must not look alive
        // for half a minute each time the app is opened, from its own notification say) until a reading clears it.
        let recentlyLeft = Date().timeIntervalSince(left) < 300
        // Always from the Mac's route: one left on the Wi-Fi route at home was kept into the next opening on cellular,
        // where every reading went to an address that can't answer there (11-20).
        if usingFallback, let mac = Self.makeAPI(address) { usingFallback = false; api = mac }
        lastMacTry = .distantPast
        triedRoutes = []
        troubleSince = recentlyLeft && offline ? .distantPast : nil
        downSince = recentlyLeft && dead ? .distantPast : nil
        if !recentlyLeft { staleReadings = 0; set(\.offline, false); set(\.dead, false) }
        set(\.struggling, recentlyLeft && unreachable)
        loops = [
            // Through the Mac's cache these are cheap. Straight to the 64 MB Chumby they are not, so go far slower there.
            Task { [weak self] in while !Task.isCancelled { await self?.loadSys(); try? await Task.sleep(nanoseconds: self?.retrying == true ? 2_000_000_000 : self?.direct == true ? 30_000_000_000 : 4_000_000_000) } },
            // On opening, the Mac's copy of the list is as old as the last visit; asking is what makes it read a new one,
            // which is there about two seconds later (measured 2026-11-10: 2.1 s). So an old answer is asked for again
            // in 0.7 s, a few times, and not at the next six-second turn: the list is confirmed in about 2.5 s after
            // opening where it took 6 to 7, and saves that wait for it ("Still reaching the Chumby") wait that much less.
            Task { [weak self] in
                var quick = 0
                while !Task.isCancelled {
                    let old = await self?.loadState() == false
                    quick = old && self?.direct != true ? quick + 1 : 0
                    try? await Task.sleep(nanoseconds: self?.direct == true ? 60_000_000_000 : quick > 0 && quick <= 8 ? 700_000_000 : 6_000_000_000)
                }
            },
            Task { [weak self] in await self?.loadChannels() },
        ]
    }
    func stop() { running = false; loops.forEach { $0.cancel() }; loops = []; stoppedAt = Date() }
    private var stoppedAt = Date.distantPast
    private var lastChannelTry = Date.distantPast
    private(set) var running = false
    var direct: Bool { usingFallback }
    private let gate = OneAtATime()
    // Direct requests go one at a time, as the Mac's cache would send them.
    private func fetch(_ action: String, from api: ChumbyAPI) async throws -> (data: Data, age: Double) {
        guard direct else { return try await api.raw(action) }
        await gate.enter()
        defer { Task { await gate.leave() } }
        return try await api.raw(action)
    }
    // Back to the Mac's cache as soon as it answers again, even while the direct route still works.
    private func tryMacRoute() async {
        guard usingFallback, Date().timeIntervalSince(lastMacTry) > 60, let mac = Self.makeAPI(address) else { return }
        lastMacTry = Date()
        if (try? await mac.raw("sys")) != nil, usingFallback { usingFallback = false; api = mac }
    }
    private var lastMacTry = Date.distantPast
    private var staleReadings = 0

    func loadSys() async {
        guard self.api != nil else { needsAddress = true; return }
        await tryMacRoute()
        // The route as it is now: tryMacRoute may just have gone back to the Mac's. Taken before, the reading still went
        // the old way and its failure was put down to the Mac's route, which then switched away from the one that worked.
        guard let api else { return }
        let onFallback = usingFallback
        // Trouble is timed from when the first failing request was sent, not from its timeout 8 s later.
        let began = Date()
        do {
            let r = try await fetch("sys", from: api)
            // The cache stops refreshing when nobody is looking, so an old answer on opening means nothing; six in a row
            // (about 25 s) does.
            staleReadings = r.age > 60 ? staleReadings + 1 : 0
            // Each set only when it changes: an unchanged value still republishes and redraws every tab.
            // The channel list is asked once per opening; one lost to the failure, or never kept, is asked for again now.
            if struggling || (channelData == nil && Date().timeIntervalSince(lastChannelTry) > 30) { lastChannelTry = Date(); Task { await loadChannels() } }
            troubleSince = nil; triedRoutes = []; downSince = nil
            set(\.struggling, false); set(\.offline, false); set(\.dead, staleReadings >= 6)
            if r.age <= 60 { heard() }
            // A frozen Chumby mostly shows up here, as an old copy from the Mac, rather than as an error.
            set(\.lastSeen, dead ? (await api.lastSeen() ?? lastSeen) : nil)
            guard Date() >= sysHold, r.data != sysBytes else { return }
            // An old copy from the Mac never starts, snoozes or ends a ring; it's read again until a fresh one says so.
            let fresh = r.age <= 10
            var s = try JSONDecoder().decode(Sys.self, from: r.data)
            if !fresh { s.ring = sys.ring }
            // A copy taken before a Stop or a Snooze the Chumby has since confirmed still says "ringing": it isn't
            // believed (RingReading; the Mac's copy can be ten seconds old).
            s.ring = RingReading.believed(s.ring, shown: sys.ring, takenAt: Date().addingTimeInterval(-r.age), stoppedAt: ringStoppedAt, snoozedAt: ringSnoozedAt)
            readingAt = Date().addingTimeInterval(-r.age)
            // Not while a page is moving: a row changing height mid-bounce snaps the page back. A ring starting,
            // snoozing or ending never waits.
            if parks, s.ringing == sys.ringing { SwipeLog.note("sys held"); heldSys = (r.data, fresh, readingAt); return }
            SwipeLog.note("sys landed")
            applySys(s, data: r.data, fresh: fresh, takenAt: readingAt)
        } catch is CancellationError {
        } catch ChumbyError.deviceDown {
            // The Mac answered and says the Chumby doesn't. Said only once that has lasted too: the Mac's own try can
            // fail once while the Chumby is fine (a busy moment on the Mac, a dropped Wi-Fi packet).
            troubleSince = nil; triedRoutes = []
            let now = Date()
            if downSince == nil { downSince = began }
            set(\.struggling, true); set(\.offline, false)
            if now.timeIntervalSince(downSince ?? now) >= Self.patience { set(\.dead, true); staleReadings = 6; set(\.lastSeen, await api.lastSeen()) }
        } catch {
            if Task.isCancelled { return }
            // Something other than the Chumby's cache answered at the saved address: the address is wrong, not the
            // network. The build's own one goes back in, and is asked at once.
            if case ChumbyError.wrongPlace = error, !onFallback, healAddress() { return }
            // No answer on this route: the other one at once, quietly. Only after `patience`, with both tried, is it said.
            let now = Date()
            if troubleSince == nil { troubleSince = began }
            set(\.struggling, true)
            triedRoutes.insert(onFallback)
            // Another reading may already have moved on from the route that failed.
            if onFallback == usingFallback { switchRoute() }
            if now.timeIntervalSince(troubleSince ?? now) >= Self.patience, fallback.isEmpty || triedRoutes.count == 2 { set(\.offline, true) }
        }
    }
    private func applySys(_ s: Sys, data: Data, fresh: Bool, takenAt: Date) {
        sysBytes = fresh ? data : Data()
        // A level he just set shows until a reading taken after it could have landed says otherwise (VolumeHold), the
        // same rule for every reading, parked or not. While it shows over the reading, the same bytes are read again
        // rather than skipped, so the Chumby's own level comes back if the hold lets go.
        var s = s
        if s.vol >= 0 { reportedVol = s.vol }
        let v = VolumeHold.shown(reported: s.vol, takenAt: takenAt, hold: volumeHold, now: Date())
        volumeHold = v.hold
        if v.vol != s.vol { s.vol = v.vol; sysBytes = Data() }
        do {
            if s.ringing?.snoozed == true, sys.ringing?.snoozed != true { snoozedAt = sys.ringing == nil ? nil : Date() }
            if s.ringing == nil, snoozedAt != nil { snoozedAt = nil }
            if sys.up > s.up, busy != nil { busy = nil }     // back from its restart
            // An alarm just ended: what it woke him to goes into Pandora's history song by song, so "Woke up to" (and its
            // widget) reads it again soon after and a few times more, rather than waiting out the usual five minutes.
            if sys.ringing != nil, s.ringing == nil { songsAfterRing() }
            // Snoozed on the Chumby, seen fresh: the phone's backup for that ring moves with it. A ring that's gone keeps
            // its backup: it may have died rather than been stopped (11-19), and only a Stop here cancels it.
            if fresh {
                if let r = s.ringing, r.snoozed, sys.ringing?.snoozed != true {
                    let mins = Double(state.alarms.first { $0.name == r.name }?.snooze ?? "") ?? 9
                    let until = state.ringingNow?.until.flatMap { $0 > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: $0) : nil } ?? Date().addingTimeInterval(mins * 60)
                    ChumbyBackupAlarm.shared.snoozed(name: r.name, until: until)
                }
            }
            // What this phone saw of the ring, for "Woke up to": only fresh readings, never an old copy from the Mac.
            if fresh {
                if let r = s.ringing { RingSeen.saw(snoozed: r.snoozed, until: r.snoozed ? state.ringingNow?.until.flatMap { $0 > 0 ? $0 : nil } : nil) }
                else if sys.ringing != nil || !sys.ring.isEmpty { RingSeen.quiet() }
            }
            if fresh {
                // An alarm starting to sound (or sounding again after a snooze), read from the Chumby with the app in
                // front: its page comes up by itself, over whatever is showing, since stopping it is what the phone is
                // for just then. Only from a reading, never from a Stop or Snooze taken back; closed, it stays closed
                // until the alarm next sounds. The build's posed shots keep their pages.
                let sounding = s.ringing.map { !$0.snoozed } ?? false, before = sys.ringing.map { !$0.snoozed } ?? false
                if sounding && !before && running && !ChumbyNotify.shared.staged { ringScreen = true }
                // Nothing ringing: a card or notification left from a ring that ended where the phone wasn't told (stopped
                // on the Chumby, the Mac's push not delivered) goes now. Once per opening and at each ring's end.
                if s.ringing == nil, sys.ringing != nil || !ringSwept {
                    ringSwept = true; ringHint = nil
                    let asOf = readingAt
                    Task { await ChumbyRingCard.sweep(asOf: asOf) }
                }
                ringReadings += 1
            }
            // A ring starting, snoozing or ending on the Chumby moves the page as one, never in a single frame.
            // Day or night changed on the Chumby itself (its own button, its schedule), seen here: the widget is told.
            let nightChanged = s.night != sys.night && seenAt != nil
            if s.ringing != sys.ringing { withAnimation(Self.ringChange(to: s.ringing)) { sys = s } } else if s != sys { sys = s }
            if nightChanged { nightChangedAt = Date(); WidgetCenter.shared.reloadAllTimelines() }
            try? data.write(to: Self.cache("sys"), options: .atomic)
        }
    }
    // Assigns only a different value, so a poll that finds nothing new publishes nothing.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<ChumbyModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }
    private func heard() {
        let now = Date()
        if (lastHeard.map { now.timeIntervalSince($0) > 20 }) ?? true { UserDefaults.standard.set(now, forKey: "lastHeard") }
        lastHeard = now
    }
    // Tailscale off at home: go straight to the Chumby. Back the other way when that stops working.
    private func switchRoute() {
        // Off Wi-Fi the Chumby's own address can't answer: it counts as tried, and the Mac's route keeps every turn.
        if !usingFallback, !WiFiWatch.shared.on { triedRoutes.insert(true); return }
        guard !fallback.isEmpty, let next = Self.makeAPI(usingFallback ? address : fallback) else { return }
        usingFallback.toggle(); api = next
    }
    // The saved address answered 404 for the Chumby's path (the Mac's bridge, say): the build's own address instead.
    // False when there's nothing better to go to.
    private func healAddress() -> Bool {
        let built = SavedAddress.builtIn
        guard SavedAddress.usable(built), built != address, Self.makeAPI(built) != nil else { return false }
        address = built
        return true
    }
    // False when the answer was an old copy (the Mac is reading a new one), so the caller may ask again soon.
    @discardableResult
    func loadState() async -> Bool {
        guard let api, Date() >= stateHold, let r = try? await fetch("state", from: api) else { return true }
        // Only a recent reading counts: the cache can hand back a list from hours ago, and once a recent one has come in,
        // an older copy (the Mac's, just after a save) is never shown over it.
        let recent = r.age < 30
        // Any recent answer is the Chumby reached: what was said about not reaching it goes at once, not at the next sys.
        if recent, offline || troubleSince != nil, !dead { troubleSince = nil; triedRoutes = []; set(\.offline, false); set(\.struggling, false); heard() }
        if !recent && stateConfirmed { return false }
        if r.data == stateBytes { if recent, !stateConfirmed { stateConfirmed = true }; return recent }
        guard Date() >= stateHold, let s = try? JSONDecoder().decode(ChumbyState.self, from: r.data) else { return true }
        // Not while a page is moving (see releaseHeld). The ring is sys's, which never waits.
        if parks { SwipeLog.note("state held"); heldState = (r.data, s, recent); return recent }
        SwipeLog.note("state landed")
        applyState(s, data: r.data, recent: recent)
        return recent
    }
    private func applyState(_ s: ChumbyState, data: Data, recent: Bool) {
        if recent, !stateConfirmed { stateConfirmed = true }
        stateBytes = data
        took(s)
        try? data.write(to: Self.cache("state"), options: .atomic)
    }
    // The Chumby's list, with whatever is still on its way laid over it.
    private func took(_ s: ChumbyState) {
        // A song newer than the newest one known goes straight to "Woke up to", and into the kept copy, so the next cold
        // open shows it at once rather than the old list with the new song popping in. (No widget shows songs.)
        // A ring just begun joins the list at once, so its song pairs as soon as it plays, without waiting for the history.
        if let rang = s.rang, !rings.contains(rang), rang.t > (rings.first?.t ?? 0) {
            rings.insert(rang, at: 0)
            let keep = rings, file = Self.cache("rings")
            Task.detached(priority: .utility) { try? JSONEncoder().encode(keep).write(to: file, options: .atomic) }
        }
        if let new = s.song, new.t > (songs.first?.t ?? 0) {
            songs.insert(new, at: 0)
            SongArt.shared.prefetch(songs, s.alarms, rings)
            let keep = songs, file = Self.cache("hist")
            Task.detached(priority: .utility) { try? JSONEncoder().encode(keep).write(to: file, options: .atomic) }
        }
        deviceState = s
        if !stateKnown { stateKnown = true }
        // The phone's own backup alarm for each ring coming up (ChumbyBackupAlarm).
        ChumbyBackupAlarm.shared.sync(state: s)
        if let d = doubted, Self.skipAgrees(s.skipped, d) { doubted = nil; letGo("skip") }
        // A change that didn't get through, which the Chumby now matches anyway (put right on the Chumby, say), is done.
        pending.removeAll { p in
            guard p.failed != nil else { return false }
            var x = s; p.change.apply(&x)
            let done = ChumbyAPI.form(x.alarmForm()) == ChumbyAPI.form(s.alarmForm())
            if done { clearNote(p.change.mark) }
            return done
        }
        relay()
    }
    private func relay() {
        var shown = deviceState
        // Only what's still on its way. A change that didn't get through is never shown as if it had: the control shows
        // what the Chumby holds, with the mark saying it couldn't be changed.
        for p in pending where p.failed == nil { p.change.apply(&shown) }
        shown.reindex()
        // A skip or undo just sent stays shown until a read agrees, or 10 s pass, so the card never flips back and forth
        // while the panel catches up.
        if let w = skipWanted {
            if shown.skipped == w.skipped || Date() > w.until { skipWanted = nil } else { shown.skipped = w.skipped }
        }
        // A channel just chosen stays shown until the Chumby reports it, or 20 s pass: a switch takes the panel longer than
        // the 5 s hold, and the old channel came back in between, so the switcher looked like it hadn't worked (Richard,
        // 2026-11-07: "channel switcher in home screen is buggy or doesnt work").
        if let c = chosenChannel, Date().timeIntervalSince(c.at) < 20, shown.channel != c.name { shown.channel = c.name }
        state = shown
    }
    private var skipWanted: (skipped: SkippedAlarm?, until: Date)?
    func loadChannels() async {
        guard let api, let r = try? await fetch("chlist", from: api), r.data != channelBytes, let c = try? JSONDecoder().decode(ChannelList.self, from: r.data) else { return }
        if parks { heldChannels = (r.data, c); return }
        applyChannels(c, data: r.data)
    }
    private func applyChannels(_ c: ChannelList, data: Data) {
        channelBytes = data; channelData = c
        try? data.write(to: Self.cache("chlist"), options: .atomic)
    }
    func refreshShot() async -> Bool {
        guard let api, let d = try? await api.shot() else { return false }
        // The cache renews the picture every few seconds; most answers are the same one.
        if d == shotBytes { return true }
        shotBytes = d
        let file = Self.cache("shot")
        let decoded: PlatformImage? = await Task.detached(priority: .utility) {
            try? d.write(to: file, options: .atomic)
            return PlatformImage(data: d)
        }.value
        guard let decoded else { return false }
        shot = decoded
        return true
    }
    // What Pandora played, newest first, for "Woke up to". Kept, so it's there at once next time.
    private var histAt = Date.distantPast
    // `force`: Sounds, while something plays, reads it every 20 s so the song it names is the one playing.
    private var afterRing: Task<Void, Never>?
    func songsAfterRing() {
        afterRing?.cancel()
        afterRing = Task { [weak self] in
            for wait in [20, 60, 180, 480] as [UInt64] {
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.loadSongs(force: true)
                SongArt.shared.prefetch(self.songs, self.state.alarms, self.rings)
            }
        }
    }
    func loadSongs(force: Bool = false) async {
        guard let api, Date().timeIntervalSince(histAt) > (force ? 15 : 300) else { return }
        histAt = Date()
        // "rings" is optional: an older Chumby's history has none, and Woke up to then falls back to the alarm list.
        guard let r = try? await fetch("hist", from: api), let h = try? JSONDecoder().decode(History.self, from: r.data) else { return }
        if parks { heldSongs = h; return }
        applySongs(h)
    }
    private func applySongs(_ h: History) {
        if let rr = h.rings, rr != rings {
            rings = rr
            try? JSONEncoder().encode(rr).write(to: Self.cache("rings"), options: .atomic)
        }
        if h.songs != songs {
            songs = h.songs
        }
        try? JSONEncoder().encode(h.songs).write(to: Self.cache("hist"), options: .atomic)
    }

    // A failure, at the control it came from. Nothing is said when things work: the control itself shows that.
    // Notes about whether tonight's alarm is as he left it (a skip or an undo the Chumby didn't confirm), and one that
    // arrives up to a minute after the tap (a station looked up), stay until he puts them away or the Chumby agrees:
    // one that cleared itself after six seconds was gone before a locked phone was looked at again.
    static let keptNotes: Set<String> = ["skip", "pandora", "macmusic", "calsound", "pplay"]
    @Published private(set) var kept: [String: String] = [:]
    func letGo(_ id: String) {
        if kept[id] != nil { withAnimation(.snappy) { kept[id] = nil } }
        if id == "skip" { ChumbyNotify.shared.skipSettled() }
    }
    // The ✕ for a note that stays; nil for one that clears itself.
    func dismissal(_ id: String) -> (() -> Void)? { kept[id] == nil ? nil : { [weak self] in self?.tick(); self?.letGo(id) } }
    func fail(_ id: String, _ text: String) {
        Haptic.fire(.warn)
        if Self.keptNotes.contains(id) { withAnimation(.snappy) { kept[id] = text }; return }
        // The note's row comes and goes in one spring, never in one frame.
        withAnimation(.snappy) { failure = Failure(id: id, text: text, at: Date()) }
        failureClear?.cancel()
        failureClear = Task { [weak self] in try? await Task.sleep(nanoseconds: 6_000_000_000); if !Task.isCancelled { withAnimation(.snappy) { self?.failure = nil } } }
    }
    func failed(_ id: String) -> String? { kept[id] ?? (failure?.id == id ? failure?.text : nil) }
    func clearFail(_ id: String) { if failure?.id == id { withAnimation(.snappy) { failure = nil } } }
    // A calm note, not a failure: no warning haptic, and it stays (with its ✕) until letGo, as the kept notes do.
    func note(_ id: String, _ text: String) { withAnimation(.snappy) { kept[id] = text } }
    // Nothing that reloads the Chumby's channel goes while an alarm rings, snoozes or is a minute or two from ringing (a
    // channel's reload under a ring can cut it off; Richard, 2026-11-18). Nil when it's clear, else what's in the way, for
    // the note: "Not while an alarm is ringing."
    var alarmBusy: String? {
        if let r = sys.ringing { return r.snoozed ? "an alarm is snoozing" : "an alarm is ringing" }
        if let n = state.nextRing(), n.at.timeIntervalSinceNow < 150, n.at.timeIntervalSinceNow > -60 { return "the \(n.at.formatted(date: .omitted, time: .shortened)) alarm is about to ring" }
        return nil
    }
    func hold(_ seconds: Double = 8) { let until = Date().addingTimeInterval(seconds); sysHold = until; stateHold = until; sysBytes = Data(); stateBytes = Data() }
    func tick() {
        #if canImport(UIKit)
        Haptics.light.impactOccurred(); Haptics.light.prepare()
        #endif
    }
    // Respond at once and let the Chumby catch up; only a failure interrupts.
    // Night mode, as the Chumby reports it, changed at once here so the button answers straight away.
    func setNight(_ v: String) {
        sys.night = v == "off" ? 0 : 1
        hold(5)
        Task {
            do {
                try await api?.cmd("night", v)
                // Ending night mode also brings the screen back up, one after the other so neither gets lost.
                if v == "off" { try await api?.cmd("screen", "bright") }
                widgetsFollowNight()
            } catch {
                fail("remote", "The Chumby didn’t get that. \(AlarmWriter.explain(error))")
                sys.night = v == "off" ? 1 : 0
            }
        }
    }
    // Day or night changed from the app: the Home Screen widget is told, which it never was (Richard, 11-20: the widget
    // "sometimes doesn't update" after night is switched to day in the app; it only caught up when iOS next refreshed
    // it by itself). It reads the Mac's copy of the Chumby, which can be from before the change for some seconds, so
    // it is told now and again once that copy is new, with the app kept awake for it if he has already left for the
    // Home Screen; leaving the app within two minutes of a change tells it once more.
    private var nightChangedAt: Date?
    func widgetsFollowNight() {
        nightChangedAt = Date()
        WidgetCenter.shared.reloadAllTimelines()
        #if canImport(UIKit)
        var hold = UIBackgroundTaskIdentifier.invalid
        hold = UIApplication.shared.beginBackgroundTask(withName: "Chumby widget follows night") { UIApplication.shared.endBackgroundTask(hold); hold = .invalid }
        #endif
        Task {
            for wait in [4.0, 8.0] {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                WidgetCenter.shared.reloadAllTimelines()
            }
            #if canImport(UIKit)
            if hold != .invalid { UIApplication.shared.endBackgroundTask(hold); hold = .invalid }
            #endif
        }
    }
    func widgetsOnLeaving() {
        if let t = nightChangedAt, Date().timeIntervalSince(t) < 120 { WidgetCenter.shared.reloadAllTimelines() }
    }
    // The Chumby's volume, set from the phone (Sounds and Home's Playing card, the mute key): shown at once, held until the
    // Chumby reports it, never sent under an alarm (the ring sets its own volume and puts his back after).
    // Every place that shows or sets it (Home's Playing card, Sounds' Now, the mute key) goes through here and reads
    // sys.vol, so they can't disagree. Shortcuts and Control Center use the same ChumbyAPI.setVolume.
    private var volumeHold: VolumeHold?
    // The level the Chumby itself last reported, for a send that didn't get through.
    private var reportedVol = -1
    // False when it wasn't sent (an alarm is ringing): the caller's slider goes back to the Chumby's level.
    @discardableResult func setVolume(_ v: Int, id: String) -> Bool {
        let level = min(max(v, 0), 100)
        if let why = alarmBusy, sys.ringing != nil { fail(id, "Not while \(why)."); return false }
        if reportedVol < 0 { reportedVol = sys.vol }
        let sent = VolumeHold(level: level, sentAt: Date())
        volumeHold = sent
        if sys.vol != level { sys.vol = level }
        tick()
        hold(2)
        // One send at a time, in order, and only the newest level: levels sent side by side could land out of order.
        volumeWanted = (level, sent.sentAt, id)
        if volumeSender == nil { volumeSender = Task { [weak self] in await self?.sendVolumes(); self?.volumeSender = nil } }
        return true
    }
    private var volumeWanted: (level: Int, at: Date, id: String)?
    private var volumeSender: Task<Void, Never>?
    private func sendVolumes() async {
        while let w = volumeWanted {
            volumeWanted = nil
            do { try await api?.setVolume(w.level, checkRing: false) } catch {
                // Superseded by a newer level: that one goes, and says how it went.
                guard volumeWanted == nil else { continue }
                if case ChumbyError.refused(let why) = error { fail(w.id, why) }
                else { fail(w.id, "The Chumby didn’t get that. \(AlarmWriter.explain(error))") }
                // Not taken: back to what the Chumby has.
                if volumeHold?.sentAt == w.at { volumeHold = nil; if reportedVol >= 0 { sys.vol = reportedVol } }
            }
        }
    }
    // True once the Chumby took it, for a caller that says so.
    @discardableResult func cmd(_ c: String, _ v: String? = nil, id: String, holdFor: Double = 5) -> Task<Bool, Never> {
        // The ones that reload or switch the channel wait out an alarm (alarmBusy).
        if ["channel", "shuffle", "widget", "reload"].contains(c), let why = alarmBusy { fail(id, "Not while \(why)."); return Task { false } }
        tick()
        hold(holdFor)
        return Task {
            do { try await api?.cmd(c, v); return true } catch { fail(id, "The Chumby didn’t get that. \(AlarmWriter.explain(error))"); return false }
        }
    }
    // A channel chosen to play, from Home or Channels. Kept here, so the channel editor moves to it whichever screen it came
    // from, even one opened later.
    struct ChannelChoice: Equatable { let name: String; let at: Date }
    @Published var chosenChannel: ChannelChoice?
    func playChannel(_ name: String, id: String) {
        if let why = alarmBusy { fail(id, "Not while \(why)."); return }
        state.channel = name
        let choice = ChannelChoice(name: name, at: Date())
        chosenChannel = choice
        // Readings wait only a second, not five: the name shown is his choice until the Chumby says so (channelName), so
        // an early reading can't flip it back, and the quick reads below need to get through.
        cmd("channel", name, id: id, holdFor: 1)
        // Read the Chumby's status every half second until it says it's on the channel (or 8 s pass), rather than at the
        // next 4 s poll, so the switcher settles as soon as the Chumby has switched.
        Task { [weak self] in
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.chosenChannel == choice else { return }
                await self.loadSys()
                if self.sys.chan == name { return }
            }
        }
    }
    // Restarting and rebooting take minutes, so the device itself says so until it's back.
    func restart(_ reboot: Bool) {
        busy = (reboot ? "Rebooting… back in a few minutes" : "Restarting… back in about 2 minutes", Date().addingTimeInterval(reboot ? 300 : 180))
        cmd(reboot ? "reboot" : "restart", id: reboot ? "reboot" : "restart")
    }

    // MARK: Ringing
    // The one spring every ring change uses, so Snooze and Stop never cut, the most-used moment of the morning.
    static let ringSpring = Animation.spring(duration: 0.35, bounce: 0.15)
    // Stopped: the card is gone by opacity in its first 0.12 s, and only then does what was under it move up (a frame later,
    // for a slow one), so no control ever passes under its fading words.
    static let stopFade = 0.12
    // Home's ringing card and the next alarm's gel change hands over this long, both at once.
    static let slotFade = 0.2
    static let stopSpring = ringSpring.delay(stopFade + 1.0 / 60)
    static func ringChange(to r: Sys.Ringing?) -> Animation { r == nil ? stopSpring : ringSpring }
    // A Stop or Snooze the Chumby has just confirmed, pressed somewhere other than this app's own keys (the Lock
    // Screen's card, the notification, Siri) while the app is open: shown at once, in the same springs as its own. Its
    // own presses (ringWorking set) show themselves.
    func ringConfirmedElsewhere(stop: Bool, until: Double?) {
        guard ringWorking == nil, let r = sys.ringing else { return }
        if stop { withAnimation(Self.stopSpring) { sys.ring = ""; snoozedAt = nil }; ringHint = nil }
        else if !r.snoozed { withAnimation(Self.ringSpring) { sys.ring = "s\t\(r.name)\t\(r.sound)" + (until.map { "\t\(Int($0))" } ?? ""); snoozedAt = Date() } }
    }
    func ringOff() { ringOffTask() }
    // The same, for a page that waits on the answer (the ringing screen): true once the Chumby says it has stopped. It goes
    // through the one desk the card, the notification and Siri use (RingDesk), so a press here and one on the Lock Screen
    // are one press; the page holds "Stopping…" until the Chumby's own reading shows nothing ringing.
    @discardableResult func ringOffTask() -> Task<Bool, Never> {
        #if canImport(UIKit)
        Haptics.medium.impactOccurred(); Haptics.medium.prepare()
        #endif
        let was = sys.ring
        hold(RingDesk.longest + 2)
        let tapped = Date().timeIntervalSince1970
        withAnimation(.easeOut(duration: 0.2)) { ringWorking = "Stopping…" }
        guard let api else { ringWorking = nil; fail("ring", "Didn’t stop. \(ChumbyWords.notAnswering)."); return Task { false } }
        return Task {
            let out = await RingDesk.shared.press(.stop, send: { c in try await api.ring(c) }, read: { try await RingDesk.ringLine(api) })
            // To the Mac's log with the Chumby's own word for how it went, as every other door's press is.
            Task.detached { await ChumbyRingActions.report("app", "stop", out, since: Date(timeIntervalSince1970: tapped), backup: "the app’s own") }
            hold(0)
            withAnimation(.easeOut(duration: 0.2)) { ringWorking = nil }
            switch out {
            case .confirmed, .nothingRinging:
                withAnimation(Self.stopSpring) { sys.ring = ""; snoozedAt = nil }
                RingSeen.stopped(at: tapped)
                // the phone's backup alarm for this ring goes with it (ChumbyBackupAlarm)
                ChumbyBackupAlarm.shared.handled(name: was.components(separatedBy: "\t").dropFirst().first)
                // The Lock Screen's card and the ring's notification go with it, not when the Mac next looks.
                await ChumbyRingCard.over()
                Task { await ChumbyRingCard.handled() }
                return true
            case .unconfirmed:
                // if the Mac reports the ring over within 3 minutes, this was his Stop and the backup goes then
                ChumbyBackupAlarm.shared.stopUnconfirmed(name: was.components(separatedBy: "\t").dropFirst().first)
                withAnimation(Self.ringSpring) { sys.ring = was }
                fail("ring", Self.unconfirmed)
                Task { await self.loadSys() }
                return false
            case .failed(let why):
                withAnimation(Self.ringSpring) { sys.ring = was }
                fail("ring", "Didn’t stop. \(why)")
                return false
            }
        }
    }
    func ringSnooze() { ringSnoozeTask() }
    // Snooze: shown snoozed at once (the page's key answers the thumb), then by the Chumby's own time once it confirms.
    @discardableResult func ringSnoozeTask() -> Task<Bool, Never> {
        tick()
        let was = sys.ring
        // "Snoozing…" until the Chumby says so, then its own time: never a guessed "Snoozed until" (gate, 11-18).
        withAnimation(.easeOut(duration: 0.2)) { ringWorking = "Snoozing…" }
        let began = Date()
        hold(RingDesk.longest + 2)
        guard let api else { ringWorking = nil; withAnimation(Self.ringSpring) { sys.ring = was; snoozedAt = nil }; fail("ring", "Didn’t snooze. \(ChumbyWords.notAnswering)."); return Task { false } }
        return Task {
            let out = await RingDesk.shared.press(.snooze, send: { c in try await api.ring(c) }, read: { try await RingDesk.ringLine(api) })
            Task.detached { await ChumbyRingActions.report("app", "snooze", out, since: began, backup: "the app’s own") }
            // A Stop pressed while this Snooze was on its way has the card now ("Stopping…", its own hold on readings):
            // whatever the Snooze came to, the Stop's answer is the one shown.
            if ringStopping {
                if case .confirmed(let until) = out {
                    let end = until ?? snoozeEnds?.timeIntervalSince1970
                    ChumbyBackupAlarm.shared.snoozed(name: was.components(separatedBy: "\t").dropFirst().first,
                                                     until: end.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(9 * 60))
                    return true
                }
                return out == .nothingRinging
            }
            hold(0)
            // "Snoozing…" giving way and the card turning snoozed are one change in the card's one spring, so Stop widens
            // into Snooze's room with it rather than in a frame (gate, 11-18).
            if case .confirmed = out {} else { withAnimation(.easeOut(duration: 0.2)) { ringWorking = nil } }
            switch out {
            case .confirmed(let until):
                withAnimation(Self.ringSpring) {
                    ringWorking = nil
                    if let r = sys.ringing { sys.ring = "s\t\(r.name)\t\(r.sound)" + (until.map { "\t\(Int($0))" } ?? ""); snoozedAt = Date() }
                }
                Task { await ChumbyRingCard.handled() }
                let end = until ?? snoozeEnds?.timeIntervalSince1970
                // the phone's backup alarm moves to the snooze's end plus its delay (ChumbyBackupAlarm)
                ChumbyBackupAlarm.shared.snoozed(name: was.components(separatedBy: "\t").dropFirst().first,
                                                 until: end.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(9 * 60))
                await ChumbyRingCard.change { $0.working = nil; $0.snoozed = true; $0.until = end; $0.problem = nil }
                await ChumbyRingCard.clearNotice()
                return true
            case .nothingRinging:
                // a Snooze that found nothing ringing keeps the backup, as the Lock Screen's does (ChumbyRingActions.backupAfter)
                withAnimation(Self.stopSpring) { sys.ring = ""; snoozedAt = nil }
                await ChumbyRingCard.over()
                return true
            case .unconfirmed:
                withAnimation(Self.ringSpring) { sys.ring = was; snoozedAt = nil }
                fail("ring", Self.unconfirmed)
                Task { await self.loadSys() }
                return false
            case .failed(let why):
                withAnimation(Self.ringSpring) { sys.ring = was; snoozedAt = nil }
                fail("ring", "Didn’t snooze. \(why)")
                return false
            }
        }
    }
    // When a snooze ends: the panel's own time when it reports one, else from when it began and that alarm's snooze length.
    var snoozeEnds: Date? {
        guard let r = sys.ringing, r.snoozed else { return nil }
        // The hook's own line carries the time: "s<TAB>name<TAB>sound<TAB>rings again at EPOCH".
        let f = sys.ring.components(separatedBy: "\t")
        if f.count > 3, let u = Double(f[3]), u > Date().timeIntervalSince1970 { return Date(timeIntervalSince1970: u) }
        if let p = state.ringingNow, p.state == "snoozing", p.name == r.name, let u = p.until, u > Date().timeIntervalSince1970 { return Date(timeIntervalSince1970: u) }
        guard let snoozedAt else { return nil }
        let minutes = Double(state.alarms.first { $0.name == r.name }?.snooze ?? "") ?? 9
        return snoozedAt.addingTimeInterval(minutes * 60)
    }

    // MARK: Alarms
    // Toggles and the alarm volume: shown at once, sent through the one careful save, marked if they don't get through.
    struct Pending { let id = UUID(); let change: AlarmChange; var failed: String? }
    // When each note's retry began: "Trying again…" is held at least a second, so a fast failure never flashes it.
    private var retryAt: [String: Date] = [:]
    // Notes fading before their row closes: the words go first, then the rows below move up (no text over text).
    @Published private(set) var fading: Set<String> = []
    // Notes arriving: their row opens with the words held back, which come in once the rows below have stopped.
    @Published private(set) var arriving: Set<String> = []
    // A note leaving: fade its words (0.15 s), then close its row in one spring.
    func clearNote(_ mark: String, then: AlarmMark? = nil) {
        guard marks[mark] != nil, !fading.contains(mark) else { return }
        if case .landed = marks[mark] { marks[mark] = nil; return }
        let was = marks[mark]
        withAnimation(.easeOut(duration: 0.15)) { _ = fading.insert(mark) }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self, self.fading.contains(mark) else { return }
            // Something newer arrived meanwhile (a fresh failure, a landing): it stays, its words faded back in.
            guard self.marks[mark] == was else { withAnimation(.easeIn(duration: 0.15)) { _ = self.fading.remove(mark) }; return }
            withAnimation(.snappy) { self.marks[mark] = then }
            self.fading.remove(mark)
        }
    }
    private var pending: [Pending] = []
    func change(_ c: AlarmChange) {
        tick()
        // A newer change to the same thing replaces one that hasn't gone yet or didn't get through.
        pending.removeAll { $0.change.mark == c.mark }
        let p = Pending(change: c, failed: nil)
        pending.append(p)
        clearNote(c.mark)
        relay()
        Task { await send(p.id) }
    }
    func retry(_ mark: String) {
        guard let i = pending.firstIndex(where: { $0.change.mark == mark }) else { return }
        tick()
        pending[i].failed = nil
        // The note stays where it is while the change goes again: a note that left and came back was two jump cuts.
        if case .failed(let head, let why) = marks[mark] { marks[mark] = .retrying(head: head, why: why); retryAt[mark] = Date() } else { marks[mark] = nil }
        relay()
        let id = pending[i].id
        Task { await send(id) }
    }
    // Let a change that didn't get through go (Richard, 2026-11-10: the alarm update note "should be dismissable"). The
    // control already shows what the Chumby really holds, so dropping the change leaves nothing out of step.
    func dismiss(_ mark: String) {
        tick()
        pending.removeAll { $0.change.mark == mark }
        clearNote(mark)
        relay()
    }
    private func send(_ id: UUID) async {
        guard let p = pending.first(where: { $0.id == id }) else { return }
        do {
            guard let api else { throw ChumbyError.message("No Chumby address set.") }
            let change = p.change
            let r = try await AlarmWriter.shared.edit(api, planned: { s in
                if let why = change.refusal(in: s) { throw ChumbyError.refused(why) }
                let permit = change.permit(in: s); change.apply(&s); return permit
            })
            pending.removeAll { $0.id == id }
            landed(r, mark: p.change.mark)
        } catch {
            guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
            let why = p.change.explain(error)
            pending[i].failed = why
            let mark = p.change.mark
            if case .retrying = marks[mark], let at = retryAt[mark] {
                let left = 1.0 - Date().timeIntervalSince(at)
                if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1e9)) }
            }
            retryAt[mark] = nil
            // A new note: its row springs open with the words held back, and they fade in once the rows have stopped.
            // After a retry its words change in place.
            let new: Bool = { switch marks[mark] { case .failed, .retrying: return false; default: return true } }()
            if new {
                arriving.insert(mark)
                withAnimation(.snappy) { marks[mark] = .failed(head: p.change.failHead, why: why) }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 520_000_000)
                    withAnimation(.easeIn(duration: 0.18)) { _ = self?.arriving.remove(mark) }
                }
            } else {
                marks[mark] = .failed(head: p.change.failHead, why: why)
            }
            relay()
            Haptic.fire(.warn)
        }
    }
    private func landed(_ r: AlarmWriter.Result, mark: String?) {
        // The save read the list fresh from the Chumby first, so this is as recent as a reading gets.
        stateConfirmed = true
        took(r.state)
        stateHold = Date().addingTimeInterval(3)
        if let mark, r.saved {
            let at = Date()
            // A retried change landing takes its note away: words first, then the row (clearNote), the bubble after.
            // then the landing bubble, as for any change that lands.
            if case .retrying = marks[mark] { retryAt[mark] = nil; clearNote(mark, then: .landed(at)) } else { marks[mark] = .landed(at) }
            Haptic.fire(.done)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if self?.marks[mark] == .landed(at) { self?.marks[mark] = nil }
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
    // From the editor, which waits for it: nil once the Chumby has it, else why not. `alsoOff`: the alarms the editor said
    // saving turns off (keys), which the user saw before tapping Save.
    func save(_ c: AlarmChange, alsoOff: Set<String> = []) async -> String? {
        guard let api else { return "No Chumby address set." }
        do {
            let r = try await AlarmWriter.shared.edit(api, planned: { s in
                if let why = c.refusal(in: s) { throw ChumbyError.refused(why) }
                let permit = c.permit(in: s, alsoOff: alsoOff); c.apply(&s); return permit
            })
            pending.removeAll { $0.change.mark == c.mark }
            landed(r, mark: c.mark)
            return nil
        } catch { return AlarmWriter.explain(error) }
    }
    // A real alarm on the Chumby, so its backup birdsong and catch-up cover it.
    func nap(_ minutes: Int) async {
        tick()
        let at = Int((Date().timeIntervalSince1970 / 60).rounded(.up)) + minutes
        Self.napSet()
        if let why = await save(.nap(at: at)) { fail("nap", why) }
    }
    // When the nap was set from this phone, so its row can show how much of it is left (a nap set elsewhere has no start).
    static func napSet() { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "napSetAt") }
    // The nap as the editor set it: its ring time, sound, length and snooze, in place of any nap still to come.
    func setNap(_ a: Alarm) async -> String? {
        tick()
        Self.napSet()
        let why = await save(.setNap(a))
        if let why { fail("nap", why) }
        return why
    }
    func cancelNap() async {
        tick()
        if sys.nap > 0 { try? await api?.cmd("nap", "0"); sys.nap = 0 }
        if state.alarms.contains(where: { $0.name == "Nap" && $0.when == "once" }), let why = await save(.cancelNap) { fail("nap", why) }
    }
    // The Nap alarm still to come, if the nap was set as one (from the app, the widget or Control Center); a nap set on the
    // Chumby itself (cmd nap) has no alarm and nothing to edit.
    var napAlarm: Alarm? {
        let now = Date()
        return state.alarms.filter { $0.name == "Nap" && $0.isOn && $0.when == "once" && $0.nextFire(after: now) != nil }
            .min { ($0.nextFire(after: now) ?? now) < ($1.nextFire(after: now) ?? now) }
    }
    // The nap on its way, from the Chumby's own nap or the Nap alarm.
    var napDue: Date? {
        let now = Date()
        if sys.nap > 0 { let d = Date(timeIntervalSince1970: Double(sys.nap)); if d > now { return d } }
        return state.alarms.filter { $0.name == "Nap" && $0.isOn && $0.when == "once" }.compactMap { $0.nextFire(after: now) }.min()
    }

    // The calendar alarms' shared settings: copied onto each of them, leaving its name, time, day and on or off alone, and
    // sent with the first one's place, so the Chumby keeps them as the set for every calendar alarm it's given later.
    // Kept on the phone too, so calendar alarms made before the Chumby has a set of its own ring this way.
    // Nil once it's saved or waiting for a ringing alarm to pass; otherwise why it couldn't be.
    func saveCalendarTemplate(_ t: Alarm) async -> String? {
        // A newer pick takes over from one still waiting for a ringing alarm to pass: the older one must never go out
        // after it, and what the screen shows if this one fails is what the Chumby held before the first of them.
        calendarRetry?.cancel()
        if heldCalendar == nil { calendarBefore = CalendarWake.shared.storedSettings }
        CalendarWake.shared.storedSettings = t
        heldCalendar = t
        return await sendCalendarTemplate(silent: false)
    }
    private var heldCalendar: Alarm?
    private var calendarBefore: Alarm?
    // The pick the Chumby turned down, so the note's Retry can send it again (nil once it lands or is put away).
    @Published private(set) var failedCalendarPick: Alarm?
    func clearFailedCalendarPick() { failedCalendarPick = nil }
    private var calendarRetry: Task<Void, Never>?
    @Published var calendarWaiting = false
    @discardableResult
    private func sendCalendarTemplate(silent: Bool) async -> String? {
        guard let t = heldCalendar, let api else { return nil }
        do {
            let r = try await AlarmWriter.shared.edit(api, quiet: true, force: true, template: { $0.alarms.contains { $0.isCalendar } }, permit: SavePermit()) { (s: inout ChumbyState) -> Void in
                // A day with its own sound keeps it; the Chumby leaves those alone too.
                for i in s.alarms.indices where s.alarms[i].isCalendar && !s.alarms[i].isOwn { s.alarms[i].takeSettings(from: t) }
            }
            heldCalendar = nil; calendarBefore = nil; calendarWaiting = false
            failedCalendarPick = nil
            landed(r, mark: nil)
            return nil
        } catch ChumbyError.waiting {
            // Never under a ringing alarm or one about to ring, since a save restarts the Chumby's alarm panel.
            calendarWaiting = true
            calendarRetry?.cancel()
            calendarRetry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !Task.isCancelled { await self?.sendCalendarTemplate(silent: true) }
            }
            return nil
        } catch {
            // Turned down: the pick is given up here, so no later retry can send what the screen takes back. What the
            // Chumby held goes back as the stored set, and Retry (on the note) asks for the pick again.
            let why = AlarmWriter.explain(error)
            calendarWaiting = false
            calendarRetry?.cancel()
            CalendarWake.shared.storedSettings = calendarBefore
            heldCalendar = nil; calendarBefore = nil
            failedCalendarPick = t
            // A silent retry has no caller waiting on the answer, so the note is raised here.
            if silent { fail("calsound", why) }
            return why
        }
    }

    // MARK: Streams, schedule and the calendar override: their own lists, sent one after another.
    private var saveTail: Task<Void, Never>?
    private var newestSave: [String: Int] = [:]
    private func send(_ action: String, _ form: [(String, String)], id: String) async {
        let number = (newestSave[action] ?? 0) + 1
        newestSave[action] = number
        let before = saveTail, body = ChumbyAPI.form(form)
        let task = Task { [weak self] in
            await before?.value
            guard let self, self.newestSave[action] == number else { return }
            do { try await self.api?.post(action, body: body); WidgetCenter.shared.reloadAllTimelines() }
            catch { self.fail(id, "Couldn’t save. \(AlarmWriter.explain(error))"); self.stateHold = .distantPast }
        }
        saveTail = task
        await task.value
    }
    // The same queue as the saves, for a command whose value goes in the address. Returns why it failed, if it did.
    private func sendInOrder(_ action: String, extra: String) async -> String? {
        let number = (newestSave[action] ?? 0) + 1
        newestSave[action] = number
        let before = saveTail
        var failure: String?
        let task = Task { [weak self] in
            await before?.value
            guard let self, self.newestSave[action] == number else { return }
            do { try await self.api?.post(action, extra: extra) } catch { failure = AlarmWriter.explain(error) }
        }
        saveTail = task
        await task.value
        return failure
    }
    // Skipping the next alarm uses the panel's own SKIP: no list rewrite, no restart. Shown at once here; the Chumby's own
    // answer replaces it on the next read (it can take a couple of seconds while the panel catches up).
    // Named, so the Chumby pins the skip to the ring shown here, not to whichever it thinks comes first (chumby 2c90cc9).
    func skipNext() async {
        guard let n = state.nextRing() else { return }
        if let why = await skip(n.alarm, at: n.at) { fail("skip", why) }
    }
    // The Chumby's skip, pinned to this alarm's ring at `at` (a=skip name=&at=, epoch minutes). There's only ever one pin:
    // this replaces any other. Nil once it's asked for; otherwise why not. The Chumby's own answer replaces the guess.
    func skip(_ a: Alarm, at: Date, settle: Bool = true) async -> String? {
        let before = state.skipped
        letGo("skip")
        state.skipped = SkippedAlarm(name: a.name, at: at.timeIntervalSince1970, when: a.when); deviceState.skipped = state.skipped
        skipWanted = (state.skipped, Date().addingTimeInterval(10))
        tick()
        hold(4)
        let minute = Int((at.timeIntervalSince1970 / 60).rounded())
        guard let why = await sendInOrder("skip", extra: "&name=" + ChumbyAPI.enc(a.name) + "&at=\(minute)") else {
            // Checked in the background: the card already shows it, and whoever needs the answer first (a "just this
            // once") reads it for itself.
            let wanted = state.skipped
            skipSettle?.cancel()
            if settle { holdForSkipCheck(); skipSettle = Task { await settleSkip(wanted: wanted, alarmAt: wanted?.date); if !Task.isCancelled { endSkipHold() } } }
            return nil
        }
        skipWanted = nil
        state.skipped = before; deviceState.skipped = before
        return "Couldn’t skip it. \(why)"
    }
    func unskip(settle: Bool = true) async {
        let before = state.skipped
        letGo("skip")
        state.skipped = nil; deviceState.skipped = nil
        skipWanted = (nil, Date().addingTimeInterval(10))
        tick()
        hold(4)
        guard let why = await sendInOrder("unskip", extra: "") else {
            skipSettle?.cancel()
            // The alarm that stays skipped if this undo doesn't land: the one the skip was on.
            if settle { holdForSkipCheck(); skipSettle = Task { await settleSkip(wanted: nil, alarmAt: before?.date); if !Task.isCancelled { endSkipHold() } } }
            return
        }
        skipWanted = nil
        state.skipped = before; deviceState.skipped = before
        fail("skip", "Couldn’t undo the skip. \(why)")
    }
    // The panel takes a moment to confirm, so read again once it has, and check its answer against what was asked: a
    // skip or an undo the Chumby didn't take used to flip back without a word ten seconds later, after he'd locked the
    // phone believing it. Read at 2.5, 7.5 and 22.5 s (the last one late enough that the Mac has renewed its copy of the
    // list whatever happened, so "not confirmed" is never said of a skip that landed a little late); still not as
    // asked, it's said at the card, with the error tap.
    private var skipSettle: Task<Void, Never>?
    // What was asked for when the Chumby didn't confirm it: a later reading that agrees takes the note away by itself.
    private var doubted: SkippedAlarm??
    static func skipAgrees(_ now: SkippedAlarm?, _ wanted: SkippedAlarm?) -> Bool {
        let now = now.flatMap { $0.date > Date() ? $0 : nil }
        guard let wanted else { return now == nil }
        return now.map { $0.name == wanted.name && abs($0.at - wanted.at) < 60 } ?? false
    }
    // The check outlives the app being left: he skips or undoes and locks the phone, and iOS would otherwise stop the
    // app before the last reading, 22 s on. Held as the Mac Pro app holds a send (one hold; a newer check takes it over).
    #if canImport(UIKit)
    private var skipHold = UIBackgroundTaskIdentifier.invalid
    #endif
    private func holdForSkipCheck() {
        #if canImport(UIKit)
        endSkipHold()
        skipHold = UIApplication.shared.beginBackgroundTask(withName: "Chumby skip check") { [weak self] in self?.endSkipHold() }
        #endif
    }
    private func endSkipHold() {
        #if canImport(UIKit)
        if skipHold != .invalid { UIApplication.shared.endBackgroundTask(skipHold); skipHold = .invalid }
        #endif
    }
    private func settleSkip(wanted: SkippedAlarm?, alarmAt: Date? = nil) async {
        func agrees() -> Bool { Self.skipAgrees(deviceState.skipped, wanted) }
        doubted = nil
        var ok = false
        for wait in [2.5, 5.0, 15.0] {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { return }       // a newer skip or undo has its own check
            // Straight from the Chumby's own answer, never laid over with what was asked for.
            if let api, let d = try? await api.fresh("state"), let s = try? AlarmWriter.strict(d) {
                stateConfirmed = true
                took(s)
                if agrees() { ok = true; break }
            }
        }
        if Task.isCancelled { return }
        if !ok {
            skipWanted = nil
            relay()
            doubted = .some(wanted)
            // Left the app by now: said as a notification too, since the note at the card is only seen on coming back.
            if !running { await ChumbyNotify.shared.skipUnconfirmed(undo: wanted == nil, at: alarmAt) }
            fail("skip", wanted == nil ? "The Chumby didn’t confirm the undo. Check the alarm before you sleep." : "The Chumby didn’t confirm the skip. Check the alarm before you sleep.")
        }
        // The widgets show the skip too, so they mustn't wait for their next refresh to catch up.
        WidgetCenter.shared.reloadAllTimelines()
    }
    // Calendar days keep the repeating alarms quiet. Changes at once here; goes back if the Chumby says no.
    func setCalendarOverride(_ on: Bool) async {
        let before = state.calOverride
        state.calOverride = on ? 1 : 0; deviceState.calOverride = on ? 1 : 0
        tick()
        hold(10)
        guard let why = await sendInOrder("calover", extra: "&v=\(on ? 1 : 0)") else { return }
        state.calOverride = before; deviceState.calOverride = before
        fail("calover", "Couldn’t change that. \(why)")
    }
    // A time wheel changes on every notch, so wait for it to settle.
    private var scheduleSoon: Task<Void, Never>?
    func saveScheduleSoon() {
        scheduleSoon?.cancel()
        hold(10)
        scheduleSoon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { await self?.saveSchedule() }
        }
    }
    func saveStreams() async {
        guard canSave("streams") else { return }
        var o: [(String, String)] = [("n", "\(state.streams.count)")]
        for (i, s) in state.streams.enumerated() { o += [("\(i)_name", s.name), ("\(i)_url", s.url), ("\(i)_id", s.id), ("\(i)_mimetype", s.mimetype)] }
        hold(10)
        deviceState.streams = state.streams
        await send("streams", o, id: "streams")
    }
    func saveSchedule() async {
        guard canSave("schedule") else { return }
        var o: [(String, String)] = [("n", "\(state.schedule.count)")]
        for (i, e) in state.schedule.enumerated() { o += [("\(i)_time", e.time), ("\(i)_cmd", e.cmd), ("\(i)_val", e.val)] }
        hold(10)
        state.reindex()
        deviceState.schedule = state.schedule
        await send("sched", o, id: "schedule")
    }
    // A Pandora station added from its share link (a=pstation, chumby 9d3c1a1): the Chumby reads the station's number
    // from the link and its name from Pandora's own page, and adds it to the stations an alarm can play. Nothing of his
    // account is used. The Chumby answers at once and the result arrives in its state a few seconds later.
    // A song the Mac's Music is playing on the Chumby (ChumbyMusic.swift), for the Now card.
    @Published var macPlaying: MacPlaying?
    // A song just chosen, until the Mac says the Chumby has it (about a quarter of a minute): the Now card shows it as
    // starting, with no Stop yet.
    @Published var macStarting: MacPlaying?
    // A Pandora station asked for from Sounds (a=play), until the Chumby's player says it has it: about 7 s, or about
    // 25 s on the first play after the Chumby's panel restarts (Pandora only logs in then, and the Chumby asks again).
    @Published var pandoraStarting: NamedID?
    @Published var addingStation = false
    @Published var stationAdded: String?
    func addPandora(_ link: String) async {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, !addingStation else { return }
        guard ["https://www.pandora.com/", "https://pandora.com/", "https://pandora.app.link/"].contains(where: { l.hasPrefix($0) }) else {
            fail("pandora", "That isn’t a Pandora link. In Pandora, open the station, then Share and Copy Link."); return
        }
        tick()
        letGo("pandora")
        withAnimation(.snappy) { addingStation = true; stationAdded = nil }
        defer { withAnimation(.snappy) { addingStation = false } }
        let key = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        do { try await api.post("pstation", body: ChumbyAPI.form([("u", l), ("k", key)])) }
        catch ChumbyError.message(let m) where m == "unknown action" { fail("pandora", "This Chumby can’t add a station from a link yet."); return }
        catch ChumbyError.message(let m) where m == "not a Pandora link" || m == "bad link" { fail("pandora", "That isn’t a Pandora link. In Pandora, open the station, then Share and Copy Link."); return }
        catch { fail("pandora", "Couldn’t add it. \(AlarmWriter.explain(error))"); return }
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let d = try? await api.fresh("state"), let s = try? AlarmWriter.strict(d) else { continue }
            let p = s.pandoraAdd.components(separatedBy: "\t")
            guard p.count >= 2, p[0] == key, p[1] != "wait" else { continue }
            if p[1] == "ok" {
                stateConfirmed = true
                took(s)
                withAnimation(.snappy) { stationAdded = p.count > 3 ? p[3] : "The station" }
                return
            }
            let why: String
            switch p.count > 2 ? p[2] : "" {
            case "that link isn't a Pandora station": why = "That link isn’t to a Pandora station."
            case "couldn't open that link": why = "The Chumby couldn’t open that link. Try again."
            case "Pandora doesn't know that station": why = "Pandora doesn’t know that station."
            case "couldn't reach Pandora": why = "The Chumby couldn’t reach Pandora. Try again."
            default: why = "The Chumby couldn’t save it. Its storage may be full."
            }
            fail("pandora", why)
            return
        }
        fail("pandora", "Pandora didn’t answer in time. Try again.")
    }
    // What will really ring: always from the Chumby's own list, never from a change that hasn't landed.
    func nextRing() -> (alarm: Alarm, at: Date)? { deviceState.nextRing() }
}

actor OneAtATime {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

#if canImport(UIKit)
// One of each, made and warmed once. A new generator per tap could stall the first frames of the animation it starts
// (the Snooze swap jumped in one frame after a freeze).
@MainActor enum Haptics {
    static let light: UIImpactFeedbackGenerator = { let g = UIImpactFeedbackGenerator(style: .light); g.prepare(); return g }()
    static let medium: UIImpactFeedbackGenerator = { let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); return g }()
    static let note: UINotificationFeedbackGenerator = { let g = UINotificationFeedbackGenerator(); g.prepare(); return g }()
    // The firm thunk a held button lands with, like the Lock Screen's flashlight.
    static let heavy: UIImpactFeedbackGenerator = { let g = UIImpactFeedbackGenerator(style: .heavy); g.prepare(); return g }()
    static func warm() { light.prepare(); medium.prepare(); heavy.prepare(); note.prepare() }
}
#endif
