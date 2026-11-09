import Foundation
import Security

// Mirrors the dashboard's /api/status. Fields are optional where the Mac may not have an answer yet.
struct Status: Decodable {
    struct CPU: Decodable { let total: Int; let per: [Int] }
    struct Memory: Decodable { let used: Double; let total: Double }
    struct Disk: Decodable { let total: Double; let used: Double; let free: Double }
    struct Network: Decodable { let iface: String; let kind: String; let ip: String; let rxRate: Double; let txRate: Double }
    struct History: Decodable { let cpu: [Double]; let mem: [Double]; let rx: [Double]; let tx: [Double] }
    struct App: Decodable, Identifiable { let name: String; let pid: Int; let cpu: Double?; let mem: Double?; var id: Int { pid } }
    struct Process: Decodable, Identifiable { let pid: Int; let cpu: Double; let mem: Double; let name: String; var id: Int { pid } }
    struct Peer: Decodable, Identifiable { let name: String; let os: String; let online: Bool; var id: String { name } }
    struct Tailscale: Decodable { let state: String; let name: String?; let peers: [Peer] }
    struct Session: Decodable, Identifiable, Hashable {
        let name: String; let status: String; let cwd: String; let remote: Bool
        var updated: Double?; var key: String?; var restartable: Bool?; var stuck: Bool?; var waiting: Bool?
        var id: String { key ?? (name + cwd) }
    }
    struct Claude: Decodable {
        let remoteControl: Bool; let desktop: Bool; let version: String; let keepAlive: Bool; let service: String?; let sessions: [Session]
    }
    struct Tally: Decodable { let input: Int; let output: Int; let cache: Int; let messages: Int; let models: [String: ModelTally]
        var tokens: Int { input + output } }
    struct ModelTally: Decodable { let input: Int; let output: Int; let messages: Int; var tokens: Int { input + output } }
    struct Hour: Decodable, Identifiable { let t: Double; let tokens: Int; var id: Double { t } }
    struct Plan: Decodable { let source: String; let at: Double; let fiveHour: Double?; let fiveHourResets: Double?; let sevenDay: Double?; let sevenDayResets: Double? }
    struct Usage: Decodable { let plan: Plan?; let fiveHours: Tally; let day: Tally; let week: Tally; let hours: [Hour]; let scanning: Bool }
    struct Upgrade: Decodable { let installed: Bool; let status: String; let state: [String: String]; let log: String }
    struct OCLP: Decodable { let version: String; let patchedFor: String; let patchedAt: String; let kdk: String }
    struct Sharing: Decodable { let ssh: Bool; let vnc: Bool }
    struct Temp: Decodable, Identifiable { let name: String; let c: Double; var id: String { name } }
    struct SeedApp: Decodable, Identifiable {
        let file: String; let name: String; let version: String; let build: String; let phoneBuild: String
        let installedAt: Double; let expires: Double; let state: String; let message: String; let own: Bool
        // The itms-services link of a copy signed for this iPhone, which installs over the air from anywhere on Tailscale.
        // Empty or missing (an older Mac) when there's none.
        var ota: String?
        // What's new in the waiting build (the app's own changes since the one on the phone), when it was built (ms), and
        // where the Mac serves its icon. Missing from an older Mac.
        var notes: [String]?
        var builtAt: Double?
        var icon: String?
        var id: String { file.isEmpty ? name : file }
    }
    struct SeedStatus: Decodable { let reachable: Bool; let via: String; let checkedAt: Double; let seeding: String; let fetch: Fetch?; let apps: [SeedApp] }
    struct Fetch: Decodable { let state: String; let message: String }
    struct Service: Decodable, Identifiable { let label: String; let name: String; let running: Bool; var id: String { label } }
    // A temperature alert also carries its reading in °C, so it's shown in the unit chosen in Settings.
    struct Alert: Decodable, Identifiable { let id: String; let level: String; let kind: String; var metric: String?; let title: String; let detail: String; let since: Double; var c: Double? }
    // What the Anthropic API has cost, read on the Mac with its Admin key. Read leniently: a field it can't make sense of
    // is simply missing, rather than losing the whole status.
    struct APIUsage: Decodable {
        struct Spend: Decodable { let cost: Double; let tokens: Int }
        var configured = false
        var error: String?
        var at: Double?
        var today: Spend?, week: Spend?, month: Spend?
        // The billing period, in ms: his credit renews on the 19th, not the 1st.
        var periodStart: Double?, renewsAt: Double?
        // "estimate" when the Mac counted it from its own sessions, without an Admin key; nil for the Admin API's figures.
        var source: String?
        var estimated: Bool { source == "estimate" }
        // Anthropic has said the credit is spent ("Credit balance is too low"): the key stops working until it renews.
        var outOfCredit = false
        enum K: String, CodingKey { case configured, error, at, today, week, month, periodStart, renewsAt, source, outOfCredit }
        init(from d: Decoder) throws {
            guard let c = try? d.container(keyedBy: K.self) else { return }
            source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil
            configured = (try? c.decodeIfPresent(Bool.self, forKey: .configured)) ?? false
            outOfCredit = (try? c.decodeIfPresent(Bool.self, forKey: .outOfCredit)) ?? false
            error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil
            at = (try? c.decodeIfPresent(Double.self, forKey: .at)) ?? nil
            today = (try? c.decodeIfPresent(Spend.self, forKey: .today)) ?? nil
            week = (try? c.decodeIfPresent(Spend.self, forKey: .week)) ?? nil
            month = (try? c.decodeIfPresent(Spend.self, forKey: .month)) ?? nil
            periodStart = (try? c.decodeIfPresent(Double.self, forKey: .periodStart)) ?? nil
            renewsAt = (try? c.decodeIfPresent(Double.self, forKey: .renewsAt)) ?? nil
        }
        init(configured: Bool, error: String? = nil) { self.configured = configured; self.error = error }
    }
    struct IOSJob: Decodable { let state: String; let message: String }
    struct IOSStatus: Decodable {
        let hasPhone: Bool; let signedIn: Bool; let ready: Bool; let installedAt: Double; let nextDue: Double
        let lastResult: String; let resigning: Bool; let job: IOSJob
    }

    let model: String; let macos: String; let build: String; var uptime: Double; var load: [Double]; let cpuModel: String
    var cpu: CPU; var mem: Memory; let disk: Disk; var net: Network; var hist: History
    let apps: [App]; let installed: [String]; let procs: [Process]; let tailscale: Tailscale
    let claude: Claude; let usage: Usage; var upgrade: Upgrade; let oclp: OCLP; let sharing: Sharing
    let publicUrl: String; let typing: String; let iphone: Bool; let iloader: Bool
    let macLogin: Bool; let screen: String; let agentStale: Bool; let ios: IOSStatus
    var displayOn: Bool?
    var temps: [Temp]?
    let services: [Service]?
    var iosApps: SeedStatus?
    var alerts: [Alert]?
    // Null until the Mac's first read.
    var apiUsage: APIUsage?
    // Whether the tunnel behind the public link is actually running. Older Macs don't say, and then the link's address
    // existing is all there is to go on.
    var publicUp: Bool?
    var publicLinkActive: Bool { !publicUrl.isEmpty && (publicUp ?? true) }
}

// The numbers that change every second.
struct LiveStatus: Decodable, Equatable {
    let uptime: Double; let load: [Double]; let cpu: Status.CPU; let mem: Status.Memory; let net: Status.Network; let hist: Status.History; let temps: [Status.Temp]?
    // The display's real state each second, so the Display key follows the Mac by itself (Richard, 2026-11-07: "should
    // self update not requiring refresh").
    var displayOn: Bool?
}
// Compared, so a reading that's the same as the last one doesn't redraw the live tiles.
extension Status.CPU: Equatable {}
extension Status.Memory: Equatable {}
extension Status.Network: Equatable {}
extension Status.History: Equatable {}
extension Status.Temp: Equatable {}
// Compared, so a pushed page that shows one app or one session redraws only when that changes, never for a reading.
extension Status.SeedApp: Equatable {}
extension Status.SeedStatus: Equatable {}
extension Status.Fetch: Equatable {}

enum APIError: LocalizedError {
    case signInNeeded, message(String), badResponse
    var errorDescription: String? {
        switch self {
        case .signInNeeded: return "Sign in to the Mac Pro."
        case .message(let m): return m
        case .badResponse: return "The Mac Pro sent an unexpected reply."
        }
    }
}

// Talks to the dashboard. The Tailscale address needs no login; the public link uses the access code.
struct API {
    let base: URL
    var session: URLSession = .shared

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = method
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 25
        return r
    }

    func clipboard() async throws -> String {
        struct Clip: Decodable { let text: String }
        var r = request("/api/clipboard"); r.timeoutInterval = 8
        let (d, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(Clip.self, from: d).text
    }
    func setClipboard(_ text: String) async throws {
        var r = request("/api/clipboard", method: "POST")
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.httpBody = Data(text.utf8)
        let (_, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.badResponse }
    }

    func hotProbe(_ part: String = "HotProbe") async throws -> (Data, URLResponse) { try await session.data(for: request("/ios/hot/\(part)")) }

    func live() async throws -> LiveStatus {
        var r = request("/api/live"); r.timeoutInterval = 6
        let (data, response) = try await session.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(LiveStatus.self, from: data)
    }

    func trend(_ key: String) async throws -> [TrendPoint] {
        struct Answer: Decodable { let points: [TrendPoint] }
        let term = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        let (data, response) = try await session.data(for: request("/api/trend?m=\(term)"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(Answer.self, from: data).points
    }

    // One of his apps' finished builds, newest first, with what changed in each: the Apps tab's Version History.
    func history(_ file: String) async throws -> [BuildNotes] {
        struct Answer: Decodable { let builds: [BuildNotes] }
        let term = file.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file
        let (data, response) = try await session.data(for: request("/api/ios-history?file=\(term)"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(Answer.self, from: data).builds
    }

    func statusData() async throws -> Data {
        let (data, response) = try await session.data(for: request("/api/status"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw APIError.signInNeeded }
        guard code == 200 else { throw APIError.badResponse }
        return data
    }

    func status() async throws -> Status {
        let (data, response) = try await session.data(for: request("/api/status"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw APIError.signInNeeded }
        guard code == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(Status.self, from: data)
    }

    @discardableResult
    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var r = request(path, method: "POST")
        // The server rejects requests from other sites, so say which site this is, as a browser would.
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return data }
        let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        if code == 401 { throw APIError.signInNeeded }
        throw APIError.message(err ?? "That did not work.")
    }

    // Hands an app package to the Mac's library, ready to seed.
    func upload(_ file: URL) async throws {
        let name = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? file.lastPathComponent
        var r = request("/api/ios-upload?name=\(name)", method: "POST")
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.timeoutInterval = 600
        let (data, response) = try await session.upload(for: r, fromFile: file)
        if (response as? HTTPURLResponse)?.statusCode == 200 { return }
        throw APIError.message((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "The Mac refused that file.")
    }

    // A small file from the Mac, such as an app's icon.
    func data(_ path: String) async throws -> Data {
        var r = request(path); r.timeoutInterval = 15
        let (d, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.badResponse }
        return d
    }

    // Fetches an app from the Mac, so this iPhone can hand it to SideStore when it's away from home.
    func download(_ file: String) async throws -> URL {
        let name = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        var r = request("/ios/app/\(name)"); r.timeoutInterval = 600
        let (temp, response) = try await session.download(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.message("The Mac couldn’t send that app.") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    func processes() async throws -> ProcessReport {
        let (data, response) = try await session.data(for: request("/api/procs"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(ProcessReport.self, from: data)
    }
    // True once it has gone. The Mac waits a few seconds to find out.
    func quitProcess(_ p: MacProcess, force: Bool) async throws -> Bool {
        struct Answer: Decodable { let gone: Bool }
        return try JSONDecoder().decode(Answer.self, from: try await post("/api/procs/quit", body: ["pid": p.pid, "start": p.start, "force": force])).gone
    }
    // True once it's back in tmux.
    func restartSession(_ key: String) async throws -> Bool {
        struct Answer: Decodable { let running: Bool }
        return try JSONDecoder().decode(Answer.self, from: try await post("/api/claude-sessions/restart", body: ["name": key])).running
    }
    // A kept session's screen as text, and keys or a message typed into it. Only through Tailscale.
    struct Term: Decodable { var running: Bool?; var text: String? }
    func termScreen(_ key: String) async throws -> Term {
        var r = request("/api/term?name=\(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)"); r.timeoutInterval = 10
        let (data, response) = try await session.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(Term.self, from: data)
    }
    func termSend(_ key: String, _ body: [String: Any]) async throws -> Term {
        var b = body; b["name"] = key
        return try JSONDecoder().decode(Term.self, from: try await post("/api/term", body: b))
    }
    func alerts() async throws -> [Status.Alert] {
        struct Answer: Decodable { let alerts: [Status.Alert] }
        var r = request("/api/alerts"); r.timeoutInterval = 15
        let (data, response) = try await session.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(Answer.self, from: data).alerts
    }

    func login(code: String) async throws { try await post("/login", body: ["code": code]) }
    func action(_ name: String, _ body: [String: Any] = [:]) async throws { try await post("/api/action/\(name)", body: body) }

    // Secrets are encrypted here, to a one-time offer from the Mac, before they leave the phone.
    func sendSealed(_ name: String, secret: String, extra: [String: Any] = [:]) async throws {
        let (data, _) = try await session.data(for: request("/api/seal"))
        guard let offer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = offer["nonce"] as? String, let jwk = offer["jwk"] as? [String: Any],
              let n = jwk["n"] as? String, let e = jwk["e"] as? String else { throw APIError.badResponse }
        let plain = try JSONSerialization.data(withJSONObject: ["secret": secret, "nonce": nonce])
        var body = extra
        body["sealed"] = try Sealer.encrypt(plain, modulus: n, exponent: e).base64EncodedString()
        try await action(name, body)
    }
}

enum Sealer {
    static func encrypt(_ plain: Data, modulus: String, exponent: String) throws -> Data {
        guard let n = base64URL(modulus), let e = base64URL(exponent) else { throw APIError.badResponse }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der(n, e) as CFData, attributes as CFDictionary, &error),
              let sealed = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, plain as CFData, &error) else {
            throw APIError.message("Could not encrypt on this device.")
        }
        return sealed as Data
    }

    private static func base64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
    private static func der(_ n: Data, _ e: Data) -> Data {
        func length(_ c: Int) -> Data {
            if c < 128 { return Data([UInt8(c)]) }
            var bytes: [UInt8] = []; var v = c
            while v > 0 { bytes.insert(UInt8(v & 255), at: 0); v >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ d: Data) -> Data {
            let v = (d.first ?? 0) >= 0x80 ? Data([0]) + d : d
            return Data([0x02]) + length(v.count) + v
        }
        let inner = integer(n) + integer(e)
        return Data([0x30]) + length(inner.count) + inner
    }
}
