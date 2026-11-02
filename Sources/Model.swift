import Foundation
import SwiftUI

@MainActor
final class LiveStore: ObservableObject { @Published var live: LiveStatus? }

@MainActor
final class AppModel: ObservableObject {
    let liveStore = LiveStore()
    let screen = RemoteScreen()
    @Published var screenOpen = false { didSet { screen.paused = !screenOpen } }
    @Published var signingIn = false
    @Published var status: Status?
    @Published var problem: String?
    @Published var needsSignIn = false
    @Published var note: String?
    @Published var history: HistoryMetric?  // kept here so unfolding doesn't close it
    @Published var processes: ProcessSort?
    @Published var tab = UserDefaults.standard.integer(forKey: "tab")
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "address") } }

    var api: API { API(base: URL(string: address) ?? URL(string: "https://invalid.invalid")!) }
    private var loops: [Task<Void, Never>] = []

    // The Mac bakes its address into the build when it collects it, so it never has to live in the source.
    init() {
        let saved = UserDefaults.standard.string(forKey: "address") ?? ""
        address = saved.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : saved
        needsSignIn = address.isEmpty
        history = UserDefaults.standard.string(forKey: "openHistory").flatMap(HistoryMetric.named)
        processes = UserDefaults.standard.string(forKey: "openProcesses").flatMap(ProcessSort.init(rawValue:))
        // Show the last known state at once; fresh numbers replace it moments later.
        if let d = try? Data(contentsOf: Self.cacheFile) { status = try? JSONDecoder().decode(Status.self, from: d) }
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
            Task { [weak self] in while !Task.isCancelled { if self?.screenOpen != true { await self?.refresh() }; try? await Task.sleep(nanoseconds: 10_000_000_000) } },
            Task { [weak self] in while !Task.isCancelled { if self?.screenOpen != true { await self?.refreshLive() }; try? await Task.sleep(nanoseconds: 1_000_000_000) } },
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
        guard tab == 0, problem == nil, !address.isEmpty, let l = try? await api.live() else { return }
        liveStore.live = l
    }

    func refresh() async {
        if address.isEmpty { needsSignIn = true; return }
        do {
            let data = try await api.statusData()
            let file = Self.cacheFile
            let decoded = try await Task.detached(priority: .userInitiated) {
                let s = try JSONDecoder().decode(Status.self, from: data)
                try? data.write(to: file, options: .atomic)
                return s
            }.value
            var fresh = decoded
            if UserDefaults.standard.string(forKey: "pose") == "alerts" { fresh.alerts = Status.Alert.samples }
            status = fresh
            AlertWatch.shared.sawInForeground(fresh.alerts ?? [])
            problem = nil; needsSignIn = false
        } catch APIError.signInNeeded {
            needsSignIn = true
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            problem = "Mac Pro is unreachable. It may be restarting, or Tailscale may be off."
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
