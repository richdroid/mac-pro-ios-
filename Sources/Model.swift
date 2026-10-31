import Foundation
import SwiftUI

@MainActor
final class LiveStore: ObservableObject { @Published var live: LiveStatus? }

@MainActor
final class AppModel: ObservableObject {
    let liveStore = LiveStore()
    @Published var status: Status?
    @Published var problem: String?
    @Published var needsSignIn = false
    @Published var note: String?
    @Published var tab = UserDefaults.standard.integer(forKey: "tab")
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "address") } }

    var api: API { API(base: URL(string: address) ?? URL(string: "https://invalid.invalid")!) }
    private var loops: [Task<Void, Never>] = []

    // The Mac bakes its address into the build when it collects it, so it never has to live in the source.
    init() {
        let saved = UserDefaults.standard.string(forKey: "address") ?? ""
        address = saved.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : saved
        needsSignIn = address.isEmpty
        // Show the last known state at once; fresh numbers replace it moments later.
        if let d = try? Data(contentsOf: Self.cacheFile) { status = try? JSONDecoder().decode(Status.self, from: d) }
    }

    private static var cacheFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("status.json") }

    func start() {
        stop()
        loops = [
            // Everything, every 10 seconds; the live numbers every second in between.
            Task { [weak self] in while !Task.isCancelled { await self?.refresh(); try? await Task.sleep(nanoseconds: 10_000_000_000) } },
            Task { [weak self] in while !Task.isCancelled { await self?.refreshLive(); try? await Task.sleep(nanoseconds: 1_000_000_000) } },
        ]
    }
    func stop() { loops.forEach { $0.cancel() }; loops = [] }

    func refreshLive() async {
        // Only the live views watch this, so the other tabs and lists stay still.
        guard tab == 0, problem == nil, !address.isEmpty, let l = try? await api.live() else { return }
        liveStore.live = l
    }

    func refresh() async {
        if address.isEmpty { needsSignIn = true; return }
        do {
            let data = try await api.statusData()
            status = try JSONDecoder().decode(Status.self, from: data)
            problem = nil; needsSignIn = false
            try? data.write(to: Self.cacheFile, options: .atomic)
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
