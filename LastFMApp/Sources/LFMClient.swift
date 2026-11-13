import Foundation
import CryptoKit

// Last.fm's JSON is loose: numbers come as strings, a list of one comes as a bare object, text hides under "#text" and
// attributes under "@attr". J reads it the forgiving way, so a reply that changes shape never crashes a screen.
struct J {
    let v: Any?
    init(_ v: Any?) { self.v = v }
    subscript(_ k: String) -> J { J((v as? [String: Any])?[k]) }
    subscript(_ i: Int) -> J { let a = array; return i < a.count ? a[i] : J(nil) }
    var string: String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let d = v as? [String: Any], let t = d["#text"] { return J(t).string }
        return nil
    }
    var text: String { string ?? "" }
    var int: Int? { if let n = v as? NSNumber { return n.intValue }; return string.flatMap { Int($0) } }
    var bool: Bool { if let b = v as? Bool { return b }; return ["1", "true"].contains(string ?? "") }
    // A list of one arrives as the object itself.
    var array: [J] {
        if let a = v as? [Any] { return a.map(J.init) }
        if v is [String: Any] { return [self] }
        return []
    }
    var exists: Bool { v != nil && !(v is NSNull) }
}

// One clock for the whole app. In the build's mock it's evening, so the shots show a lived-in day whatever hour CI runs.
enum Clock {
    static let launched = Date()
    static var offset: TimeInterval = 0
    static var now: Date { Date().addingTimeInterval(offset) }
    static func pinEvening() {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: Date())
        c.hour = 21; c.minute = 40
        if let evening = cal.date(from: c) { offset = evening.timeIntervalSince(Date()) }
    }
}

// Replies kept on disk, so every screen opens on the last thing it showed, at once, and asks again behind it.
enum DiskCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("lastfm", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func key(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description }
    static func url(_ k: String) -> URL { dir.appendingPathComponent(key(k)) }
    static func read(_ k: String) -> (Data, Date)? {
        let u = url(k)
        guard let d = try? Data(contentsOf: u) else { return nil }
        let when = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast
        return (d, when)
    }
    static func write(_ k: String, _ d: Data) { try? d.write(to: url(k), options: .atomic) }
}

enum LFMError: Error { case noKey, http(Int), api(Int, String), shape }

// The Last.fm API, gently: one request at a time no closer than 0.22 s apart (its limit is about 5 a second), each reply
// kept on disk for as long as it can't have changed.
actor LastFM {
    static let shared = LastFM()
    nonisolated let key: String?
    nonisolated let user: String
    nonisolated let mock: Bool
    private var nextSlot = Date.distantPast
    private var inFlight: [String: Task<J, Error>] = [:]

    // The key and his name are baked in at signing (preset-ipa.sh); a build without them, or -mock YES, is the mock.
    private static func baked(_ k: String) -> String? { (Bundle.main.infoDictionary?[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    static var mockMode: Bool { UserDefaults.standard.bool(forKey: "mock") || baked("LastFMKey") == nil || baked("LastFMUser") == nil }

    init() {
        let k = Self.baked("LastFMKey"), u = Self.baked("LastFMUser")
        mock = Self.mockMode
        key = mock ? nil : k
        user = mock ? MockLastFM.catalogName : (u ?? "")
    }

    nonisolated func cacheKey(_ method: String, _ params: [String: String]) -> String {
        let p = params.merging(["user": user]) { a, _ in a }
        return method + "?" + p.keys.sorted().map { "\($0)=\(p[$0]!)" }.joined(separator: "&") + (mock ? "#mock" : "")
    }

    // What was last kept for this call, however old, without waiting: for a screen's first frame.
    nonisolated func kept(_ method: String, _ params: [String: String] = [:]) -> (J, Date)? {
        guard let (d, when) = DiskCache.read(cacheKey(method, params)), let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return (J(o), when)
    }

    // A fresh reply, unless the kept one is younger than `fresh` seconds. Calls already on their way are shared.
    // `keep: false` for replies that go straight into the history database (a thousand pages need no second copy).
    func call(_ method: String, _ params: [String: String] = [:], fresh: TimeInterval = 0, keep: Bool = true) async throws -> J {
        let ck = cacheKey(method, params)
        if fresh > 0, let (d, when) = DiskCache.read(ck), Date().timeIntervalSince(when) < fresh, let o = try? JSONSerialization.jsonObject(with: d) { return J(o) }
        if let t = inFlight[ck] { return try await t.value }
        let t = Task { try await self.fetch(method, params, keep ? ck : nil) }
        inFlight[ck] = t
        defer { inFlight[ck] = nil }
        return try await t.value
    }

    private func slot() -> Date {
        let s = max(Date(), nextSlot)
        nextSlot = s.addingTimeInterval(0.22)
        return s
    }

    private func fetch(_ method: String, _ params: [String: String], _ ck: String?, retry: Bool = true) async throws -> J {
        if mock {
            // About a real reply's wait, or a slow one (-mockSyncSlow YES) so the build can film the history arriving.
            try? await Task.sleep(nanoseconds: UserDefaults.standard.bool(forKey: "mockSyncSlow") ? 90_000_000 : 12_000_000)
            let o = MockLastFM.shared.respond(method, params)
            if let ck, let d = try? JSONSerialization.data(withJSONObject: o) { DiskCache.write(ck, d) }
            return J(o)
        }
        guard let key else { throw LFMError.noKey }
        let wait = slot().timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        var c = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        var q = [URLQueryItem(name: "method", value: method), URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "format", value: "json")]
        // His own numbers ride along: plays on a user.* call, his play count and love on an info call.
        if method.hasPrefix("user."), params["user"] == nil { q.append(URLQueryItem(name: "user", value: user)) }
        else if method.hasSuffix(".getinfo"), params["username"] == nil { q.append(URLQueryItem(name: "username", value: user)) }
        q += params.map { URLQueryItem(name: $0.key, value: $0.value) }
        c.queryItems = q
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let o = try? JSONSerialization.jsonObject(with: data)
        let j = J(o)
        if let e = j["error"].int {
            // 29: too many requests. Once more after a breath.
            if e == 29 && retry { try await Task.sleep(nanoseconds: 1_200_000_000); return try await fetch(method, params, ck, retry: false) }
            throw LFMError.api(e, j["message"].text)
        }
        guard code == 200, o != nil else { throw LFMError.http(code) }
        if let ck { DiskCache.write(ck, data) }
        return j
    }
}
