import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
extension Image { init(platform i: UIImage) { self.init(uiImage: i) } }
#else
import AppKit
typealias PlatformImage = NSImage
extension Image { init(platform i: NSImage) { self.init(nsImage: i) } }
#endif

@MainActor
final class ChumbyModel: ObservableObject {
    @Published var sys = Sys()
    @Published var state = ChumbyState()
    @Published var channelData: ChannelList?
    @Published var shot: PlatformImage?
    @Published var offline = false
    @Published var toast: String?
    @Published var needsAddress = false
    @Published var tab = UserDefaults.standard.integer(forKey: "tab")
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "address"); api = Self.makeAPI(address) } }
    private(set) var api: ChumbyAPI?
    private var loops: [Task<Void, Never>] = []
    private var toastTask: Task<Void, Never>?
    var editingAlarm = false
    @Published var dead = false        // the Mac answers, but the Chumby itself has gone quiet
    private var fallback: String { Bundle.main.object(forInfoDictionaryKey: "ChumbyFallback") as? String ?? "" }
    private var usingFallback = false
    private var failures = 0
    private var sysBytes = Data(), stateBytes = Data(), channelBytes = Data(), shotBytes = Data()
    private var sysHold = Date.distantPast, stateHold = Date.distantPast
    // A save replaces the whole list on the Chumby, so never send one built only from an old copy.
    private var stateConfirmed = false
    private func canSave() -> Bool {
        if stateConfirmed { return true }
        say("Still reaching the Chumby. Nothing was saved.")
        stateBytes = Data(); stateHold = .distantPast
        return false
    }

    private static func makeAPI(_ a: String) -> ChumbyAPI? { URL(string: a).flatMap { $0.host == nil ? nil : ChumbyAPI(base: $0) } }
    private static func cache(_ name: String) -> URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chumby-" + name) }

    init() {
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        let saved = stored.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : stored
        address = saved
        api = Self.makeAPI(saved)
        needsAddress = api == nil
        // Open with what we last knew. The app is always faster than the device.
        if let d = try? Data(contentsOf: Self.cache("sys")), let v = try? JSONDecoder().decode(Sys.self, from: d) { sys = v; sysBytes = d }
        if let d = try? Data(contentsOf: Self.cache("state")), let v = try? JSONDecoder().decode(ChumbyState.self, from: d) { state = v; stateBytes = d }
        if let d = try? Data(contentsOf: Self.cache("chlist")), let v = try? JSONDecoder().decode(ChannelList.self, from: d) { channelData = v; channelBytes = d }
        if let d = try? Data(contentsOf: Self.cache("shot")) { shot = PlatformImage(data: d) }
    }

    func start() {
        stop()
        running = true
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
            failures = 0; offline = false; dead = staleReadings >= 3
            guard Date() >= sysHold, r.data != sysBytes else { return }
            sysBytes = r.data
            sys = try JSONDecoder().decode(Sys.self, from: r.data)
            try? r.data.write(to: Self.cache("sys"), options: .atomic)
        } catch is CancellationError {
        } catch ChumbyError.deviceDown {
            failures = 0; offline = false; dead = true; staleReadings = 3
        } catch {
            if Task.isCancelled { return }
            failures += 1
            if failures >= 2 { offline = true; switchRoute() }
        }
    }
    // Tailscale off at home: go straight to the Chumby. Back the other way when that stops working.
    private func switchRoute() {
        guard !fallback.isEmpty, let next = Self.makeAPI(usingFallback ? address : fallback) else { return }
        usingFallback.toggle(); api = next; failures = 0
    }
    func loadState() async {
        guard let api, !editingAlarm, Date() >= stateHold, let r = try? await fetch("state", from: api) else { return }
        // Only a recent reading counts: the cache can hand back a list from hours ago.
        if r.age < 30 { stateConfirmed = true }
        if r.data == stateBytes { return }
        guard Date() >= stateHold, !editingAlarm, let s = try? JSONDecoder().decode(ChumbyState.self, from: r.data) else { return }
        stateBytes = r.data; state = s
        try? r.data.write(to: Self.cache("state"), options: .atomic)
    }
    func loadChannels() async {
        guard let api, let r = try? await fetch("chlist", from: api), r.data != channelBytes, let c = try? JSONDecoder().decode(ChannelList.self, from: r.data) else { return }
        channelBytes = r.data; channelData = c
        try? r.data.write(to: Self.cache("chlist"), options: .atomic)
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

    func say(_ t: String) {
        toast = t
        toastTask?.cancel()
        toastTask = Task { [weak self] in try? await Task.sleep(nanoseconds: 2_200_000_000); if !Task.isCancelled { self?.toast = nil } }
    }
    func hold(_ seconds: Double = 8) { let until = Date().addingTimeInterval(seconds); sysHold = until; stateHold = until; sysBytes = Data(); stateBytes = Data() }
    func tick() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    // Respond at once and let the Chumby catch up; only a failure interrupts.
    func cmd(_ c: String, _ v: String? = nil, _ msg: String? = nil) {
        tick()
        hold(5)
        if let msg { say(msg) }
        Task {
            do { try await api?.cmd(c, v) } catch { say("The Chumby didn’t get that: \(error.localizedDescription)") }
        }
    }
    // Each save carries the whole list, so they leave in order and only the newest of a burst goes.
    private var saveTail: Task<Void, Never>?
    private var newestSave: [String: Int] = [:]
    private func send(_ action: String, _ form: [(String, String)]) async {
        let number = (newestSave[action] ?? 0) + 1
        newestSave[action] = number
        let before = saveTail, body = ChumbyAPI.form(form)
        let task = Task { [weak self] in
            await before?.value
            guard let self, self.newestSave[action] == number else { return }
            do { try await self.api?.post(action, body: body) }
            catch { self.say("Couldn’t save: \(error.localizedDescription)"); self.stateHold = .distantPast }
        }
        saveTail = task
        await task.value
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
    func saveAlarms(_ msg: String) async {
        guard canSave() else { return }
        let o = state.alarmForm()
        hold(10)
        state.reindex()
        say(msg)
        await send("save", o)
    }
    func saveStreams() async {
        guard canSave() else { return }
        var o: [(String, String)] = [("n", "\(state.streams.count)")]
        for (i, s) in state.streams.enumerated() { o += [("\(i)_name", s.name), ("\(i)_url", s.url), ("\(i)_id", s.id), ("\(i)_mimetype", s.mimetype)] }
        hold(10)
        say("Streams saved")
        await send("streams", o)
    }
    func saveSchedule() async {
        guard canSave() else { return }
        var o: [(String, String)] = [("n", "\(state.schedule.count)")]
        for (i, e) in state.schedule.enumerated() { o += [("\(i)_time", e.time), ("\(i)_cmd", e.cmd), ("\(i)_val", e.val)] }
        hold(10)
        state.reindex()
        await send("sched", o)
    }
    func nextAlarm() -> Date? { state.alarms.compactMap { $0.nextFire() }.min() }
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
