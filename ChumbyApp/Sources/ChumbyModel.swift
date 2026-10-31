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
    private var sysBytes = Data(), stateBytes = Data(), channelBytes = Data()
    private var sysHold = Date.distantPast, stateHold = Date.distantPast

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
        loops = [
            Task { [weak self] in while !Task.isCancelled { await self?.loadSys(); try? await Task.sleep(nanoseconds: 4_000_000_000) } },
            Task { [weak self] in while !Task.isCancelled { await self?.loadState(); try? await Task.sleep(nanoseconds: 6_000_000_000) } },
            Task { [weak self] in await self?.loadChannels() },
        ]
    }
    func stop() { loops.forEach { $0.cancel() }; loops = [] }

    func loadSys() async {
        guard let api else { needsAddress = true; return }
        do {
            let r = try await api.raw("sys")
            failures = 0; offline = false; dead = r.age > 60
            guard Date() >= sysHold, r.data != sysBytes else { return }
            sysBytes = r.data
            sys = try JSONDecoder().decode(Sys.self, from: r.data)
            try? r.data.write(to: Self.cache("sys"), options: .atomic)
        } catch is CancellationError {
        } catch ChumbyError.deviceDown {
            failures = 0; offline = false; dead = true
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
        guard let api, !editingAlarm, Date() >= stateHold, let r = try? await api.raw("state"), Date() >= stateHold, !editingAlarm, r.data != stateBytes,
              let s = try? JSONDecoder().decode(ChumbyState.self, from: r.data) else { return }
        stateBytes = r.data; state = s
        try? r.data.write(to: Self.cache("state"), options: .atomic)
    }
    func loadChannels() async {
        guard let api, let r = try? await api.raw("chlist"), r.data != channelBytes, let c = try? JSONDecoder().decode(ChannelList.self, from: r.data) else { return }
        channelBytes = r.data; channelData = c
        try? r.data.write(to: Self.cache("chlist"), options: .atomic)
    }
    func refreshShot() async -> Bool {
        guard let api, let d = try? await api.shot(), let i = PlatformImage(data: d) else { return false }
        shot = i
        try? d.write(to: Self.cache("shot"), options: .atomic)
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
    func saveAlarms(_ msg: String) async {
        var o: [(String, String)] = [("n", "\(state.alarms.count)"), ("v", "\(state.volume)"), ("f", "\(state.fade)")]
        for (i, a) in state.alarms.enumerated() {
            o += [("\(i)_name", a.name), ("\(i)_enabled", a.enabled), ("\(i)_time", a.time), ("\(i)_when", a.when), ("\(i)_type", a.type), ("\(i)_arg", a.arg),
                  ("\(i)_param", a.param), ("\(i)_param_description", a.param_description), ("\(i)_duration", a.duration), ("\(i)_snooze", a.snooze),
                  ("\(i)_auto_dismiss", a.auto_dismiss), ("\(i)_action", a.action), ("\(i)_action_param", a.action_param), ("\(i)_backup", a.backup), ("\(i)_backupDelay", a.backupDelay)]
        }
        hold(10)
        state.reindex()
        say(msg)
        do { try await api?.post("save", body: ChumbyAPI.form(o)) } catch { say("Couldn’t save: \(error.localizedDescription)"); stateHold = .distantPast }
    }
    func saveStreams() async {
        var o: [(String, String)] = [("n", "\(state.streams.count)")]
        for (i, s) in state.streams.enumerated() { o += [("\(i)_name", s.name), ("\(i)_url", s.url), ("\(i)_id", s.id), ("\(i)_mimetype", s.mimetype)] }
        hold(10)
        say("Streams saved")
        do { try await api?.post("streams", body: ChumbyAPI.form(o)) } catch { say("Couldn’t save: \(error.localizedDescription)"); stateHold = .distantPast }
    }
    func saveSchedule() async {
        var o: [(String, String)] = [("n", "\(state.schedule.count)")]
        for (i, e) in state.schedule.enumerated() { o += [("\(i)_time", e.time), ("\(i)_cmd", e.cmd), ("\(i)_val", e.val)] }
        hold(10)
        state.reindex()
        do { try await api?.post("sched", body: ChumbyAPI.form(o)) } catch { say("Couldn’t: \(error.localizedDescription)"); stateHold = .distantPast }
    }
    func nextAlarm() -> Date? { state.alarms.compactMap { $0.nextFire() }.min() }
}
