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
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "address"); api = Self.makeAPI(address) } }
    private(set) var api: ChumbyAPI?
    private var loops: [Task<Void, Never>] = []
    private var toastTask: Task<Void, Never>?
    var editingAlarm = false

    private static func makeAPI(_ a: String) -> ChumbyAPI? { URL(string: a).flatMap { $0.host == nil ? nil : ChumbyAPI(base: $0) } }

    init() {
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        let saved = stored.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : stored
        address = saved
        api = Self.makeAPI(saved)
        needsAddress = api == nil
    }

    func start() {
        stop()
        loops = [
            Task { [weak self] in while !Task.isCancelled { await self?.loadSys(); try? await Task.sleep(nanoseconds: 10_000_000_000) } },
            Task { [weak self] in while !Task.isCancelled { if self?.editingAlarm != true { await self?.loadState() }; try? await Task.sleep(nanoseconds: 15_000_000_000) } },
            Task { [weak self] in await self?.loadChannels() },
        ]
    }
    func stop() { loops.forEach { $0.cancel() }; loops = [] }

    func loadSys() async {
        guard let api else { needsAddress = true; return }
        do { sys = try await api.get("sys", as: Sys.self); offline = false } catch is CancellationError {} catch { if !Task.isCancelled { offline = true } }
    }
    func loadState() async {
        guard let api else { return }
        if let s = try? await api.get("state", as: ChumbyState.self) { state = s }
    }
    func loadChannels() async {
        guard let api else { return }
        if let c = try? await api.get("chlist", as: ChannelList.self) { channelData = c }
    }
    func refreshShot() async -> Bool {
        guard let api, let d = try? await api.shot(), let i = PlatformImage(data: d) else { return false }
        shot = i
        return true
    }

    func say(_ t: String) {
        toast = t
        toastTask?.cancel()
        toastTask = Task { [weak self] in try? await Task.sleep(nanoseconds: 2_600_000_000); if !Task.isCancelled { self?.toast = nil } }
    }
    func cmd(_ c: String, _ v: String? = nil, _ msg: String? = nil) {
        Task {
            do { try await api?.cmd(c, v); if let msg { say(msg) } } catch { say("Couldn’t: \(error.localizedDescription)") }
        }
    }
    func saveAlarms(_ msg: String) async {
        var o: [(String, String)] = [("n", "\(state.alarms.count)"), ("v", "\(state.volume)"), ("f", "\(state.fade)")]
        for (i, a) in state.alarms.enumerated() {
            o += [("\(i)_name", a.name), ("\(i)_enabled", a.enabled), ("\(i)_time", a.time), ("\(i)_when", a.when), ("\(i)_type", a.type), ("\(i)_arg", a.arg),
                  ("\(i)_param", a.param), ("\(i)_param_description", a.param_description), ("\(i)_duration", a.duration), ("\(i)_snooze", a.snooze),
                  ("\(i)_auto_dismiss", a.auto_dismiss), ("\(i)_action", a.action), ("\(i)_action_param", a.action_param), ("\(i)_backup", a.backup), ("\(i)_backupDelay", a.backupDelay)]
        }
        do { try await api?.post("save", body: ChumbyAPI.form(o)); say(msg + ". The Chumby picks it up in a few seconds.") } catch { say("Couldn’t save: \(error.localizedDescription)") }
        await loadState()
    }
    func saveStreams() async {
        var o: [(String, String)] = [("n", "\(state.streams.count)")]
        for (i, s) in state.streams.enumerated() { o += [("\(i)_name", s.name), ("\(i)_url", s.url), ("\(i)_id", s.id), ("\(i)_mimetype", s.mimetype)] }
        do { try await api?.post("streams", body: ChumbyAPI.form(o)); say("Streams saved") } catch { say("Couldn’t save: \(error.localizedDescription)") }
        await loadState()
    }
    func saveSchedule() async {
        var o: [(String, String)] = [("n", "\(state.schedule.count)")]
        for (i, e) in state.schedule.enumerated() { o += [("\(i)_time", e.time), ("\(i)_cmd", e.cmd), ("\(i)_val", e.val)] }
        do { try await api?.post("sched", body: ChumbyAPI.form(o)); say("Schedule saved") } catch { say("Couldn’t: \(error.localizedDescription)"); await loadState() }
    }
    func nextAlarm() -> Date? { state.alarms.compactMap { $0.nextFire() }.min() }
}
