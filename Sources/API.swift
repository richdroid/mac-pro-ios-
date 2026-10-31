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
    struct Session: Decodable, Identifiable {
        let name: String; let status: String; let cwd: String; let remote: Bool
        var id: String { name + cwd }
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
    struct IOSJob: Decodable { let state: String; let message: String }
    struct IOSStatus: Decodable {
        let hasPhone: Bool; let signedIn: Bool; let ready: Bool; let installedAt: Double; let nextDue: Double
        let lastResult: String; let resigning: Bool; let job: IOSJob
    }

    let model: String; let macos: String; let build: String; let uptime: Double; let load: [Double]; let cpuModel: String
    let cpu: CPU; let mem: Memory; let disk: Disk; let net: Network; let hist: History
    let apps: [App]; let installed: [String]; let procs: [Process]; let tailscale: Tailscale
    let claude: Claude; let usage: Usage; let upgrade: Upgrade; let oclp: OCLP; let sharing: Sharing
    let publicUrl: String; let typing: String; let iphone: Bool; let iloader: Bool
    let macLogin: Bool; let screen: String; let agentStale: Bool; let ios: IOSStatus
    let temps: [Temp]?
}

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

    func status() async throws -> Status {
        let (data, response) = try await session.data(for: request("/api/status"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw APIError.signInNeeded }
        guard code == 200 else { throw APIError.badResponse }
        return try JSONDecoder().decode(Status.self, from: data)
    }

    private func post(_ path: String, body: [String: Any]) async throws {
        var r = request(path, method: "POST")
        // The server rejects requests from other sites, so say which site this is, as a browser would.
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return }
        let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        if code == 401 { throw APIError.signInNeeded }
        throw APIError.message(err ?? "That did not work.")
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
