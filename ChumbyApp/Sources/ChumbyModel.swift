import Foundation
import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
extension Image { init(platform i: UIImage) { self.init(uiImage: i) } }
#else
import AppKit
typealias PlatformImage = NSImage
extension Image { init(platform i: NSImage) { self.init(nsImage: i) } }
#endif

// One change to the alarms, said in a way that can be applied to any copy of the list, fresh from the Chumby or not, and
// that does nothing the second time. That's what lets a save re-read the list and change only this.
enum AlarmChange {
    case toggle(Alarm, Bool)
    case replace(Alarm, Alarm)
    case add(Alarm)
    case delete(Alarm)
    case volume(Int)
    case fade(Int)
    case nap(at: Int)          // minutes since 1970
    // A nap with its own sound, length, snooze and ring time (the nap editor); still the one Nap alarm, so the Chumby's
    // helper rule (never counted by newest_wins, never pinned) and one-nap-at-a-time both hold.
    case setNap(Alarm)
    case cancelNap
    static func find(_ a: Alarm, in s: ChumbyState) -> Int? { s.alarms.firstIndex { $0.same(a) } ?? s.alarms.firstIndex { $0.key == a.key } }
    func apply(_ s: inout ChumbyState) {
        switch self {
        case .toggle(let a, let on):
            if let i = Self.find(a, in: s) { s.alarms[i].enabled = on ? "1" : "0" }
        case .replace(let old, let new):
            if s.alarms.contains(where: { $0.same(new) }) { return }
            if let i = Self.find(old, in: s) { s.alarms[i] = new } else { Self.add(new, to: &s) }
        case .add(let a):
            if !s.alarms.contains(where: { $0.same(a) }) { Self.add(a, to: &s) }
        case .delete(let a):
            if let i = Self.find(a, in: s) { s.alarms.remove(at: i) }
        case .volume(let v): s.volume = v
        case .fade(let f): s.fade = f
        case .nap(let at):
            // A new nap replaces one still to come. One that has already gone off is left to finish ringing.
            let now = Int(Date().timeIntervalSince1970 / 60)
            s.alarms.removeAll { $0.name == "Nap" && $0.when == "once" && (Int($0.time) ?? 0) > now && $0.time != String(at) }
            if !s.alarms.contains(where: { $0.name == "Nap" && $0.when == "once" && $0.time == String(at) }) { s.addNap(at: at) }
        case .setNap(let a):
            // The one nap: any other still to come goes, and this one takes its place (or the first free one).
            let now = Int(Date().timeIntervalSince1970 / 60)
            s.alarms.removeAll { $0.name == "Nap" && $0.when == "once" && (Int($0.time) ?? 0) > now && !$0.same(a) }
            if !s.alarms.contains(where: { $0.same(a) }) { Self.add(a, to: &s) }
        case .cancelNap:
            let now = Int(Date().timeIntervalSince1970 / 60)
            s.alarms.removeAll { $0.name == "Nap" && $0.when == "once" && (Int($0.time) ?? 0) > now }
        }
        s.reindex()
    }
    private static func add(_ a: Alarm, to s: inout ChumbyState) {
        if let free = s.alarms.firstIndex(where: { $0.isPlaceholder }) { s.alarms[free] = a } else { s.alarms.append(a) }
    }
    // The alarms this change deletes, turns off or edits by the user's own hand, for AlarmWriter's safety net. Anything
    // else lost in the same save (the Chumby's newest_wins, say) is only allowed when the editor showed it first (`alsoOff`).
    func permit(in s: ChumbyState, alsoOff: Set<String> = []) -> SavePermit {
        var p = SavePermit(userOff: alsoOff)
        switch self {
        case .toggle(let a, let on): if !on { p.userOff.insert(a.key) }
        case .replace(let old, _), .delete(let old): p.userOff.insert(old.key)
        case .nap, .setNap, .cancelNap: for a in s.alarms where a.name == "Nap" && a.when == "once" { p.userOff.insert(a.key) }
        case .add, .volume, .fade: break
        }
        return p
    }
    // What a failure says at the control, in the words of what was tried.
    var failHead: String {
        switch self {
        case .toggle(_, let on): return on ? "Couldn’t turn this on" : "Couldn’t turn this off"
        case .volume: return "Couldn’t change the volume"
        case .fade: return "Couldn’t change the fade"
        default: return "Not on the Chumby yet"
        }
    }
    // Where its mark shows: the alarm's row, or the control it came from.
    var mark: String {
        switch self {
        case .toggle(let a, _): return a.key
        case .replace(_, let a), .add(let a): return a.key
        case .delete(let a): return a.key
        case .volume: return "alarmVolume"
        case .fade: return "fade"
        case .nap, .setNap, .cancelNap: return "nap"
        }
    }
}

// A control's own failure, shown at that control and nowhere else.
struct Failure: Equatable { let id: String; let text: String; let at: Date }
enum AlarmMark: Equatable { case failed(head: String, why: String), landed(Date) }


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
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "address"); api = Self.makeAPI(address); usingFallback = false; failures = 0 } }
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
    // The width of the side bar's column on the Duo (0 when the bars run across), and a tap on + placed in it.
    @Published var railWidth: CGFloat = 0
    @Published var addAlarm: Date?
    // Folded, Calendar settings pushed inside Alarms. Kept here so its Back can sit in the rail, outside the page that slides.
    // A page opening over Alarms gets anything parked at once (see parks).
    // The "just this once" sheet, open or not: on the model, not in the menu's own state, because Home lays its
    // controls out in another place of the tree when the phone opens flat, and a sheet held by the view went with it.
    @Published var justOnceSheetOpen = false
    @Published var alarmsPage = false { didSet { if alarmsPage { releaseHeld() } } }
    // The page shown in place of Alarms ("Calendar settings", or the day's name), for its bar's title.
    private(set) var api: ChumbyAPI?
    private var loops: [Task<Void, Never>] = []
    private var failureClear: Task<Void, Never>?
    var editingAlarm = false { didSet { if editingAlarm { releaseHeld() } else if let s = heldAdopt { heldAdopt = nil; adopt(s) } } }
    private var heldAdopt: ChumbyState?
    var unreachable: Bool { offline || dead }
    var seenAt: Date? { dead ? (lastSeen ?? lastHeard) : lastHeard }
    // It restarts itself within a few minutes of hanging (chwd on the device), so only then is it worth getting up.
    var deadText: String {
        guard let lastSeen else { return "It should restart itself within a few minutes." }
        return Date().timeIntervalSince(lastSeen) < 600 ? "It should restart itself within a few minutes." : "It hasn’t restarted. Try unplugging it for a moment."
    }
    private var fallback: String { Bundle.main.object(forInfoDictionaryKey: "ChumbyFallback") as? String ?? "" }
    private var usingFallback = false
    private var failures = 0
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
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        let saved = stored.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : stored
        address = saved
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
    private var heldSys: (data: Data, fresh: Bool)?
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
        if let h = heldSys { heldSys = nil; if var v = try? JSONDecoder().decode(Sys.self, from: h.data) { if !h.fresh { v.ring = sys.ring }; applySys(v, data: h.data, fresh: h.fresh) } }
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

    func start() {
        stop()
        running = true
        stateConfirmed = false      // it may have been hours; the list could have changed from elsewhere
        loops = [
            // Through the Mac's cache these are cheap. Straight to the 64 MB Chumby they are not, so go far slower there.
            Task { [weak self] in while !Task.isCancelled { await self?.loadSys(); try? await Task.sleep(nanoseconds: self?.direct == true ? 30_000_000_000 : 4_000_000_000) } },
            Task { [weak self] in while !Task.isCancelled { await self?.loadState(); try? await Task.sleep(nanoseconds: self?.direct == true ? 60_000_000_000 : 6_000_000_000) } },
            Task { [weak self] in await self?.loadChannels() },
        ]
    }
    func stop() { running = false; loops.forEach { $0.cancel() }; loops = [] }
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
        if (try? await mac.raw("sys")) != nil, usingFallback { usingFallback = false; api = mac; failures = 0 }
    }
    private var lastMacTry = Date.distantPast
    private var staleReadings = 0

    func loadSys() async {
        guard let api else { needsAddress = true; return }
        await tryMacRoute()
        do {
            let r = try await fetch("sys", from: api)
            // The cache stops refreshing when nobody is looking, so one old answer on opening means nothing.
            staleReadings = r.age > 60 ? staleReadings + 1 : 0
            // Each set only when it changes: an unchanged value still republishes and redraws every tab.
            failures = 0; set(\.offline, false); set(\.dead, staleReadings >= 3)
            if r.age <= 60 { heard() }
            // A frozen Chumby mostly shows up here, as an old copy from the Mac, rather than as an error.
            set(\.lastSeen, dead ? (await api.lastSeen() ?? lastSeen) : nil)
            guard Date() >= sysHold, r.data != sysBytes else { return }
            // An old copy from the Mac never starts, snoozes or ends a ring; it's read again until a fresh one says so.
            let fresh = r.age <= 10
            var s = try JSONDecoder().decode(Sys.self, from: r.data)
            if !fresh { s.ring = sys.ring }
            // Not while a page is moving: a row changing height mid-bounce snaps the page back. A ring starting,
            // snoozing or ending never waits.
            if parks, s.ringing == sys.ringing { heldSys = (r.data, fresh); return }
            applySys(s, data: r.data, fresh: fresh)
        } catch is CancellationError {
        } catch ChumbyError.deviceDown {
            failures = 0; set(\.offline, false); set(\.dead, true); staleReadings = 3
            set(\.lastSeen, await api.lastSeen())
        } catch {
            if Task.isCancelled { return }
            failures += 1
            if failures >= 2 { set(\.offline, true); switchRoute() }
        }
    }
    private func applySys(_ s: Sys, data: Data, fresh: Bool) {
        sysBytes = fresh ? data : Data()
        do {
            if s.ringing?.snoozed == true, sys.ringing?.snoozed != true { snoozedAt = sys.ringing == nil ? nil : Date() }
            if s.ringing == nil, snoozedAt != nil { snoozedAt = nil }
            if sys.up > s.up, busy != nil { busy = nil }     // back from its restart
            // An alarm just ended: what it woke him to goes into Pandora's history song by song, so "Woke up to" (and its
            // widget) reads it again soon after and a few times more, rather than waiting out the usual five minutes.
            if sys.ringing != nil, s.ringing == nil { songsAfterRing() }
            // A ring starting, snoozing or ending on the Chumby moves the page as one, never in a single frame.
            if s.ringing != sys.ringing { withAnimation(Self.ringChange(to: s.ringing)) { sys = s } } else if s != sys { sys = s }
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
        guard !fallback.isEmpty, let next = Self.makeAPI(usingFallback ? address : fallback) else { return }
        usingFallback.toggle(); api = next; failures = 0
    }
    func loadState() async {
        guard let api, Date() >= stateHold, let r = try? await fetch("state", from: api) else { return }
        // Only a recent reading counts: the cache can hand back a list from hours ago, and once a recent one has come in,
        // an older copy (the Mac's, just after a save) is never shown over it.
        let recent = r.age < 30
        if !recent && stateConfirmed { return }
        if r.data == stateBytes { if recent, !stateConfirmed { stateConfirmed = true }; return }
        guard Date() >= stateHold, let s = try? JSONDecoder().decode(ChumbyState.self, from: r.data) else { return }
        // Not while a page is moving (see releaseHeld). The ring is sys's, which never waits.
        if parks { heldState = (r.data, s, recent); return }
        applyState(s, data: r.data, recent: recent)
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
        // A change that didn't get through, which the Chumby now matches anyway (put right on the Chumby, say), is done.
        pending.removeAll { p in
            guard p.failed != nil else { return false }
            var x = s; p.change.apply(&x)
            let done = ChumbyAPI.form(x.alarmForm()) == ChumbyAPI.form(s.alarmForm())
            if done { marks[p.change.mark] = nil }
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
    func fail(_ id: String, _ text: String) {
        #if canImport(UIKit)
        Haptics.note.notificationOccurred(.error)
        #endif
        failure = Failure(id: id, text: text, at: Date())
        failureClear?.cancel()
        failureClear = Task { [weak self] in try? await Task.sleep(nanoseconds: 6_000_000_000); if !Task.isCancelled { self?.failure = nil } }
    }
    func failed(_ id: String) -> String? { failure?.id == id ? failure?.text : nil }
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
            } catch {
                fail("remote", "The Chumby didn’t get that. \(AlarmWriter.explain(error))")
                sys.night = v == "off" ? 1 : 0
            }
        }
    }
    func cmd(_ c: String, _ v: String? = nil, id: String, holdFor: Double = 5) {
        tick()
        hold(holdFor)
        Task {
            do { try await api?.cmd(c, v) } catch { fail(id, "The Chumby didn’t get that. \(AlarmWriter.explain(error))") }
        }
    }
    // A channel chosen to play, from Home or Channels. Kept here, so the channel editor moves to it whichever screen it came
    // from, even one opened later.
    struct ChannelChoice: Equatable { let name: String; let at: Date }
    @Published var chosenChannel: ChannelChoice?
    func playChannel(_ name: String, id: String) {
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
    static let stopSpring = ringSpring.delay(stopFade + 1.0 / 60)
    static func ringChange(to r: Sys.Ringing?) -> Animation { r == nil ? stopSpring : ringSpring }
    func ringOff() {
        #if canImport(UIKit)
        Haptics.medium.impactOccurred(); Haptics.medium.prepare()
        #endif
        let was = sys.ring
        withAnimation(Self.stopSpring) { sys.ring = ""; snoozedAt = nil }
        hold(5)
        Task { do { try await api?.cmd("ringoff") } catch { withAnimation(Self.ringSpring) { sys.ring = was }; fail("ring", "The Chumby didn’t stop. \(AlarmWriter.explain(error))") } }
    }
    func ringSnooze() {
        tick()
        let was = sys.ring
        if let r = sys.ringing { withAnimation(Self.ringSpring) { sys.ring = "s\t\(r.name)\t\(r.sound)"; snoozedAt = Date() } }
        hold(5)
        Task { do { try await api?.cmd("ringsnooze") } catch { withAnimation(Self.ringSpring) { sys.ring = was; snoozedAt = nil }; fail("ring", "The Chumby didn’t snooze. \(AlarmWriter.explain(error))") } }
    }
    // When a snooze ends: the panel's own time when it reports one, else from when it began and that alarm's snooze length.
    var snoozeEnds: Date? {
        guard let r = sys.ringing, r.snoozed else { return nil }
        if let p = state.ringingNow, p.state == "snoozing", p.name == r.name, let u = p.until, u > Date().timeIntervalSince1970 { return Date(timeIntervalSince1970: u) }
        guard let snoozedAt else { return nil }
        let minutes = Double(state.alarms.first { $0.name == r.name }?.snooze ?? "") ?? 9
        return snoozedAt.addingTimeInterval(minutes * 60)
    }

    // MARK: Alarms
    // Toggles and the alarm volume: shown at once, sent through the one careful save, marked if they don't get through.
    struct Pending { let id = UUID(); let change: AlarmChange; var failed: String? }
    private var pending: [Pending] = []
    func change(_ c: AlarmChange) {
        tick()
        // A newer change to the same thing replaces one that hasn't gone yet or didn't get through.
        pending.removeAll { $0.change.mark == c.mark }
        let p = Pending(change: c, failed: nil)
        pending.append(p)
        marks[c.mark] = nil
        relay()
        Task { await send(p.id) }
    }
    func retry(_ mark: String) {
        guard let i = pending.firstIndex(where: { $0.change.mark == mark }) else { return }
        tick()
        pending[i].failed = nil
        marks[mark] = nil
        relay()
        let id = pending[i].id
        Task { await send(id) }
    }
    private func send(_ id: UUID) async {
        guard let p = pending.first(where: { $0.id == id }) else { return }
        do {
            guard let api else { throw ChumbyError.message("No Chumby address set.") }
            let change = p.change
            let r = try await AlarmWriter.shared.edit(api, planned: { s in let permit = change.permit(in: s); change.apply(&s); return permit })
            pending.removeAll { $0.id == id }
            landed(r, mark: p.change.mark)
        } catch {
            guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
            pending[i].failed = AlarmWriter.explain(error)
            marks[p.change.mark] = .failed(head: p.change.failHead, why: AlarmWriter.explain(error))
            relay()
            #if canImport(UIKit)
            Haptics.note.notificationOccurred(.error)
            #endif
        }
    }
    private func landed(_ r: AlarmWriter.Result, mark: String?) {
        // The save read the list fresh from the Chumby first, so this is as recent as a reading gets.
        stateConfirmed = true
        took(r.state)
        stateHold = Date().addingTimeInterval(3)
        if let mark, r.saved {
            let at = Date()
            marks[mark] = .landed(at); tick()
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
            let r = try await AlarmWriter.shared.edit(api, planned: { s in let permit = c.permit(in: s, alsoOff: alsoOff); c.apply(&s); return permit })
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
        CalendarWake.shared.storedSettings = t
        heldCalendar = t
        return await sendCalendarTemplate()
    }
    private var heldCalendar: Alarm?
    private var calendarRetry: Task<Void, Never>?
    @Published var calendarWaiting = false
    @discardableResult
    private func sendCalendarTemplate() async -> String? {
        guard let t = heldCalendar, let api else { return nil }
        do {
            let r = try await AlarmWriter.shared.edit(api, quiet: true, force: true, template: { $0.alarms.contains { $0.isCalendar } }, permit: SavePermit()) { (s: inout ChumbyState) -> Void in
                // A day with its own sound keeps it; the Chumby leaves those alone too.
                for i in s.alarms.indices where s.alarms[i].isCalendar && !s.alarms[i].isOwn { s.alarms[i].takeSettings(from: t) }
            }
            heldCalendar = nil; calendarWaiting = false
            landed(r, mark: nil)
            return nil
        } catch ChumbyError.waiting {
            // Never under a ringing alarm or one about to ring, since a save restarts the Chumby's alarm panel.
            calendarWaiting = true
            calendarRetry?.cancel()
            calendarRetry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !Task.isCancelled { await self?.sendCalendarTemplate() }
            }
            return nil
        } catch {
            calendarWaiting = false
            return AlarmWriter.explain(error)
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
    func skip(_ a: Alarm, at: Date) async -> String? {
        let before = state.skipped
        state.skipped = SkippedAlarm(name: a.name, at: at.timeIntervalSince1970, when: a.when); deviceState.skipped = state.skipped
        skipWanted = (state.skipped, Date().addingTimeInterval(10))
        tick()
        hold(4)
        let minute = Int((at.timeIntervalSince1970 / 60).rounded())
        guard let why = await sendInOrder("skip", extra: "&name=" + ChumbyAPI.enc(a.name) + "&at=\(minute)") else { await settleSkip(); return nil }
        skipWanted = nil
        state.skipped = before; deviceState.skipped = before
        return "Couldn’t skip it. \(why)"
    }
    func unskip() async {
        let before = state.skipped
        state.skipped = nil; deviceState.skipped = nil
        skipWanted = (nil, Date().addingTimeInterval(10))
        tick()
        hold(4)
        guard let why = await sendInOrder("unskip", extra: "") else { await settleSkip(); return }
        skipWanted = nil
        state.skipped = before; deviceState.skipped = before
        fail("skip", "Couldn’t undo the skip. \(why)")
    }
    // The panel takes a moment to confirm, so read again once it has.
    private func settleSkip() async {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await loadState()
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
