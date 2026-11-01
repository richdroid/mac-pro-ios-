import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias TVImage = UIImage
extension Image { init(tv i: UIImage) { self.init(uiImage: i) } }
#else
import AppKit
typealias TVImage = NSImage
extension Image { init(tv i: NSImage) { self.init(nsImage: i) } }
#endif

struct TVStatus: Decodable, Equatable {
    struct Music: Decodable, Equatable { let title: String; let artist: String; let album: String; let art: String; let playing: Bool; let position: Double; let duration: Double; let sampledAt: Double }
    struct Session: Decodable, Equatable { let pkg: String; let playing: Bool; let description: [String] }
    struct App: Decodable, Identifiable, Equatable { let pkg: String; let name: String; let hasIcon: Bool; var id: String { pkg } }
    let online: Bool
    var screen: String?
    var app: String?
    var volume: Int?
    var volumeMax: Int?
    var music: Music?
    var session: Session?
    var apps: [App]?
}
struct Film: Identifiable, Hashable { let slug: String, title: String, year: String, poster: String, note: String; var id: String { slug + note } }

@MainActor
final class TVModel: ObservableObject {
    @Published var status: TVStatus?
    @Published var mirror: TVImage?
    @Published var reachable = true
    @Published var watchlist: [Film] = []
    @Published var friends: [Film] = []
    @Published var toast: String?
    @Published var tab = UserDefaults.standard.integer(forKey: "tab")
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "address") } }
    var mirrorOn = false
    private var loops: [Task<Void, Never>] = []
    private var toastTask: Task<Void, Never>?
    private static var cacheFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tv.json") }

    init() {
        let stored = UserDefaults.standard.string(forKey: "address") ?? ""
        address = stored.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "") : stored
        // Open with what was last known; the live state replaces it moments later.
        if let d = try? Data(contentsOf: Self.cacheFile) { status = try? JSONDecoder().decode(TVStatus.self, from: d) }
    }
    func url(_ path: String) -> URL? { URL(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) }
    func start() {
        stop()
        loops = [
            Task { [weak self] in while !Task.isCancelled { await self?.load(); try? await Task.sleep(nanoseconds: 2_500_000_000) } },
            Task { [weak self] in while !Task.isCancelled { if self?.mirrorOn == true { await self?.loadMirror() }; try? await Task.sleep(nanoseconds: 1_500_000_000) } },
            Task { [weak self] in await self?.loadFilms() },
        ]
    }
    func stop() { loops.forEach { $0.cancel() }; loops = [] }
    func load() async {
        guard let u = url("/api/tv/status") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 8; r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(TVStatus.self, from: d) else { if !Task.isCancelled { reachable = false }; return }
        reachable = true
        if s != status { status = s; if s.online { try? d.write(to: Self.cacheFile, options: .atomic) } }
    }
    func loadMirror() async {
        guard let u = url("/api/tv/shot") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 10; r.cachePolicy = .reloadIgnoringLocalCacheData
        if let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, let i = TVImage(data: d) { mirror = i }
    }
    func loadFilms() async {
        guard let u = url("/api/tv/letterboxd"), let (d, _) = try? await URLSession.shared.data(from: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        func list(_ key: String, _ note: ([String: String]) -> String) -> [Film] {
            ((j[key] as? [[String: String]]) ?? []).compactMap { r in
                guard let slug = r["film_slug"], !slug.isEmpty else { return nil }
                return Film(slug: slug, title: r["film_title"] ?? slug, year: r["film_year"] ?? "", poster: r["poster_url"] ?? "", note: note(r))
            }
        }
        watchlist = list("watchlist") { r in
            let n = Int(r["friends_count"] ?? "") ?? 0, a = Double(r["friends_rating_avg"] ?? "") ?? 0
            return n > 0 && a > 0 ? String(format: "★ %.1f · %d", a, n) : ""
        }
        friends = list("friends") { r in
            let who = r["friend_name"] ?? "", rating = Double(r["rating"] ?? "") ?? 0
            return who + (rating > 0 ? String(format: " ★ %.1f", rating) : " \(r["action"] ?? "")")
        }
    }
    func say(_ t: String) {
        toast = t
        toastTask?.cancel()
        toastTask = Task { [weak self] in try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { self?.toast = nil } }
    }
    func tick() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    // Answer at once and send behind the scenes; only a failure interrupts.
    func post(_ path: String, _ body: [String: Any] = [:], say msg: String? = nil) {
        guard let u = url("/api/tv/" + path), let base = URL(string: address) else { return }
        if let msg { say(msg) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task {
            let result = try? await URLSession.shared.data(for: r)
            if (result?.1 as? HTTPURLResponse)?.statusCode != 200 { say("The TV didn’t get that") }
            else { try? await Task.sleep(nanoseconds: 400_000_000); await load() }
        }
    }
    func key(_ name: String, long: Bool = false) { tick(); post("key", ["key": name, "long": long]) }
}
