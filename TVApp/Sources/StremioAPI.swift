import Foundation
import Security

// Stremio on this phone: his own account, his own add-ons, asked from here and nowhere else. The phone signs in once (he
// types his email and password; neither is kept), and the key Stremio hands back lives only in this phone's Keychain.
// It goes to Stremio's own API and nowhere else, and is never logged, shown or sent to the Mac.

enum StremioKeychain {
    private static let service = "local.macpro.TV.stremio"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else {
            #if targetEnvironment(simulator)
            // The build's unsigned simulator app has no Keychain (errSecMissingEntitlement): its stand-in key is kept
            // in its defaults instead. Never on a phone.
            return UserDefaults.standard.string(forKey: "simKeychain." + account)
            #else
            return nil
            #endif
        }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ account: String, _ value: String?) {
        SecItemDelete(query(account) as CFDictionary)
        #if targetEnvironment(simulator)
        UserDefaults.standard.set(value, forKey: "simKeychain." + account)
        #endif
        guard let value, !value.isEmpty else { return }
        var add = query(account)
        add[kSecValueData as String] = Data(value.utf8)
        // Readable after the first unlock, so Picture in Picture and the lock screen can keep writing his progress.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

// ICU regular expressions, always: String's own .regularExpression went through Swift Regex on the phone, which read
// one of these patterns differently and stopped the app (CI 01e426f).
enum Rx {
    static func has(_ s: String, _ p: String, ci: Bool = false) -> Bool {
        guard let r = try? NSRegularExpression(pattern: p, options: ci ? [.caseInsensitive] : []) else { return false }
        return r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    static func strip(_ s: String, _ p: String, ci: Bool = false) -> String {
        guard let r = try? NSRegularExpression(pattern: p, options: ci ? [.caseInsensitive] : []) else { return s }
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}

struct StremioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// One add-on of his that answers streams.
struct StremioAddon: Hashable {
    let name: String
    let base: String          // its transport address without /manifest.json
    let types: [String]
    let prefixes: [String]?
}

// A stream as his add-on gave it, with what's worth choosing by pulled out of its free text (the Mac's describeStream,
// tv.js, so the phone's list reads and ranks as the TV's does).
struct PhoneStream: Identifiable, Hashable {
    let id: String
    let addon: String
    let name: String
    let text: String            // the add-on's description (or title): file name, size, source
    let url: URL?               // a link this phone can play
    let infoHash: String?       // a torrent: the TV's to play, not this phone's
    let fileIdx: Int?
    let external: URL?          // a page elsewhere (a service): never played here
    let headers: [String: String]
    let raw: [String: Any]
    // Pulled out of the text.
    let quality: String, hdr: String, gb: Double, instant: Bool, service: Bool, lang: String, file: String, dubbed: Bool

    static func == (a: PhoneStream, b: PhoneStream) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var playsHere: Bool { url != nil }
    var torrent: Bool { url == nil && infoHash != nil }
    // The row's heading: "1080p HDR", else the add-on's own name for it.
    var title: String {
        if service { return name.isEmpty ? addon : name }
        let q = [quality, hdr].filter { !$0.isEmpty }.joined(separator: " ")
        if !q.isEmpty { return q }
        let n = Rx.strip(name, "\\[[^\\]]*\\]").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? addon : n
    }
    var size: String? { gb > 0 ? (gb < 1 ? "\(Int(gb * 1024)) MB" : String(format: "%.1f GB", gb)) : nil }
    var details: String {
        var parts: [String] = []
        if instant { parts.append("Ready now") }
        if !lang.isEmpty { parts.append(lang) }
        parts.append(addon)
        return parts.joined(separator: " · ")
    }

    init?(_ s: [String: Any], addon: String, title: String) {
        let link = (s["url"] as? String).flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil }
        let hash = s["infoHash"] as? String
        let ext = (s["externalUrl"] as? String).flatMap(URL.init(string:))
        guard link != nil || hash != nil || ext != nil else { return nil }
        let name = s["name"] as? String ?? ""
        let text = (s["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? s["title"] as? String ?? ""
        self.raw = s
        self.addon = addon.components(separatedBy: " - ").first?.components(separatedBy: " TB").first?.trimmingCharacters(in: .whitespaces) ?? addon
        self.name = name
        self.text = text
        self.url = link
        self.infoHash = hash
        self.fileIdx = s["fileIdx"] as? Int
        self.external = link == nil && hash == nil ? ext : nil
        var headers: [String: String] = [:]
        if let hints = s["behaviorHints"] as? [String: Any], let proxy = hints["proxyHeaders"] as? [String: Any], let req = proxy["request"] as? [String: String] { headers = req }
        self.headers = headers
        let all = name + " " + text
        func has(_ p: String) -> Bool { Rx.has(all, p, ci: true) }
        quality = has("2160p|\\b4k\\b|\\buhd\\b") ? "4K" : has("1080p") ? "1080p" : has("720p") ? "720p" : has("480p") ? "480p" : ""
        hdr = has("dolby.?vision|\\bdovi\\b|\\bdv\\b") ? "Dolby Vision" : has("hdr10\\+|hdr10.?plus") ? "HDR10+" : has("\\bhdr") ? "HDR" : ""
        var gb = 0.0
        for pattern in ["💾\\s*([\\d.]+)\\s*(GB|MB)", "\\b(\\d+(?:\\.\\d+)?)\\s*(GB|MB)\\b"] {
            if let r = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let m = r.firstMatch(in: all, range: NSRange(all.startIndex..., in: all)),
               let n = Range(m.range(at: 1), in: all), let u = Range(m.range(at: 2), in: all) {
                gb = (Double(all[n]) ?? 0) / (all[u].lowercased() == "mb" ? 1024 : 1)
                break
            }
        }
        self.gb = (gb * 10).rounded() / 10
        let svc = addon.range(of: "watchhub", options: .caseInsensitive) != nil
            || (quality.isEmpty && gb == 0 && Rx.has(text, "subscription|rent|buy|\\bads\\b|free", ci: true))
            || (link == nil && hash == nil)
        service = svc
        instant = (!svc && (name.contains("⚡") || Rx.has(name, "\\+\\]"))) || text.contains("⚡")
        lang = has("\\b(multi|dual)\\b") ? "Multi-audio" : ""
        file = Self.file(text)
        // A file named as a dub, the title's own words aside (tv.js describeStream).
        let named = title.isEmpty ? file : file.replacingOccurrences(of: title, with: "", options: .caseInsensitive)
        dubbed = Rx.has(named, "(?:^|[\\s._\\-\\[(])(ita|italian|vfi|vf2|hindi|tamil|telugu|french|truefrench|vff|vfq|german|deutsch|spanish|castellano|latino|rus|russian|dublado|dubbed|dub|pt[ ._-]?br|polish|czech|turkish|ukr|kor|chinese|mandarin|cantonese)(?=$|[\\s._\\-\\])])", ci: true)
            || named.unicodeScalars.contains { c in
                [0x0400...0x04FF, 0x0590...0x06FF, 0x0900...0x0DFF, 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF].contains { $0.contains(c.value) }
            }
        id = (link?.absoluteString ?? hash.map { "\($0):\(s["fileIdx"] as? Int ?? -1)" } ?? ext?.absoluteString ?? UUID().uuidString)
    }
    // The file's name as the Mac shows it: the description's last line, up to its first emoji, without the extension,
    // cut at 110 (tv.js describeStream's `file`). The same stream on the TV's list has this as its description.
    static func file(_ text: String) -> String {
        let last = text.components(separatedBy: "\n").last ?? ""
        // Up to the first of the add-ons' emoji (scalars, so a variation selector never hides one).
        let marks: Set<UInt32> = [0x1F464, 0x1F4BE, 0x2699, 0x1F4E6, 0x1F4FA, 0x26A1]
        var cut = last
        if let i = last.unicodeScalars.firstIndex(where: { marks.contains($0.value) }) { cut = String(last.unicodeScalars[..<i]) }
        let bare = Rx.strip(cut, "\\.(mkv|mp4|avi)\\b", ci: true)
        return String(bare.trimmingCharacters(in: .whitespacesAndNewlines).prefix(110))
    }
    // Best first, for this phone: one it can play, ready now, the original sound, then 4K (Richard, 2026-11-13: "i want
    // 4k for ipad 1080p for tv"; HDR and Dolby Vision count as 4K, the phone shows both), then the best below it, at a
    // sensible size (tv.js streamRank, with the phone's own first rule: a torrent can only go to the TV).
    func rank(target: Double) -> [Double] {
        let q: Double = ["4K": 0, "1080p": 1, "720p": 2, "480p": 3][quality] ?? 4
        let off = gb > 0 ? abs(log(gb / target)) : 9
        return [service ? 2 : 0, playsHere ? 0 : 1, instant ? 0 : 1, dubbed ? 1 : 0, gb > 25 ? 1 : 0, q, off]
    }
}

enum StremioAPI {
    // Stremio's own API, or the build's stand-in when the films set one ("-stremioAPI http://127.0.0.1:9003").
    static var base: String {
        let s = UserDefaults.standard.string(forKey: "stremioAPI") ?? ""
        return s.isEmpty ? "https://api.strem.io" : s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static var metaBase: String {
        let s = UserDefaults.standard.string(forKey: "stremioMeta") ?? ""
        return s.isEmpty ? "https://v3-cinemeta.strem.io" : s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static var isStandIn: Bool { base != "https://api.strem.io" }
    static var authKey: String? { StremioKeychain.get("authKey") }

    // One call to Stremio's API: its "result", or its own words for what went wrong.
    static func call(_ method: String, _ body: [String: Any], timeout: TimeInterval = 15) async throws -> Any {
        guard let u = URL(string: "\(base)/api/\(method)") else { throw StremioError(message: "Stremio's address is wrong.") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let d: Data
        do { d = try await URLSession.shared.data(for: r).0 }
        catch {
            // Once more after a moment: the first request after launch sometimes loses its connection.
            try? await Task.sleep(nanoseconds: 700_000_000)
            do { d = try await URLSession.shared.data(for: r).0 }
            catch { throw StremioError(message: "Couldn’t reach Stremio. Check the connection and try again.") }
        }
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw StremioError(message: "Stremio gave an answer this app can’t read.") }
        let said = (j["error"] as? [String: Any])?["message"] as? String ?? j["error"] as? String
        if j["error"] != nil {
            let message = said.map(Self.plain) ?? "Stremio said no."
            // Stremio has ended this phone's session: forgotten here too, so Settings says so (gate item 4).
            if message.hasPrefix("Stremio has signed this phone out") { await MainActor.run { StremioAccount.shared.forget() } }
            throw StremioError(message: message)
        }
        guard let result = j["result"] else { throw StremioError(message: "Stremio gave an answer this app can’t read.") }
        return result
    }
    private static func plain(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("password") || l.contains("user not found") || l.contains("wrong") { return "That email and password don’t match a Stremio account." }
        if l.contains("session") || l.contains("auth") { return "Stremio has signed this phone out. Sign in again in Settings." }
        return s
    }

    static func login(email: String, password: String) async throws -> (key: String, email: String) {
        let r = try await call("login", ["type": "Login", "email": email, "password": password, "facebook": false])
        guard let o = r as? [String: Any], let key = o["authKey"] as? String, !key.isEmpty else { throw StremioError(message: "Stremio didn’t sign this phone in.") }
        return (key, ((o["user"] as? [String: Any])?["email"] as? String) ?? email)
    }
    static func logout(_ key: String) async { _ = try? await call("logout", ["type": "Logout", "authKey": key], timeout: 6) }

    // His add-ons that answer streams, kept ten minutes (the launcher's StremioStreams.kt does the same).
    @MainActor private static var collection: (key: String, at: Date, list: [StremioAddon])?
    @MainActor static func addons(force: Bool = false) async throws -> [StremioAddon] {
        guard let key = authKey else { throw StremioError(message: "Sign in to Stremio in Settings first.") }
        if !force, let c = collection, c.key == key, Date().timeIntervalSince(c.at) < 600 { return c.list }
        let r = try await call("addonCollectionGet", ["type": "AddonCollectionGet", "authKey": key, "update": true])
        let all = (r as? [String: Any])?["addons"] as? [[String: Any]] ?? []
        var out: [StremioAddon] = []
        for a in all {
            guard let m = a["manifest"] as? [String: Any], let t = a["transportUrl"] as? String, t.hasSuffix("/manifest.json") else { continue }
            let base = String(t.dropLast("/manifest.json".count))
            let resources = m["resources"] as? [Any] ?? []
            for res in resources {
                if let s = res as? String, s == "stream" {
                    out.append(StremioAddon(name: m["name"] as? String ?? "", base: base, types: m["types"] as? [String] ?? [], prefixes: m["idPrefixes"] as? [String]))
                } else if let o = res as? [String: Any], o["name"] as? String == "stream" {
                    out.append(StremioAddon(name: m["name"] as? String ?? "", base: base, types: o["types"] as? [String] ?? m["types"] as? [String] ?? [],
                                            prefixes: o["idPrefixes"] as? [String] ?? m["idPrefixes"] as? [String]))
                }
            }
        }
        collection = (key, Date(), out)
        return out
    }

    // Every add-on of his asked at once. Ten seconds at most; once three and a half have passed and there are eight to
    // choose from, the slow ones aren't waited for (StremioStreams.kt).
    @MainActor static func streams(type: String, video: String, title: String) async throws -> [PhoneStream] {
        let list = try await addons().filter { a in
            a.types.contains(type) && (a.prefixes == nil || a.prefixes!.contains { video.hasPrefix($0) })
        }
        guard !list.isEmpty else { throw StremioError(message: "None of your Stremio add-ons offer streams for this.") }
        let started = Date()
        let id = video.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? video
        var found: [PhoneStream] = []
        await withTaskGroup(of: [PhoneStream].self) { group in
            for a in list {
                group.addTask {
                    guard let u = URL(string: "\(a.base)/stream/\(type)/\(id).json") else { return [] }
                    var r = URLRequest(url: u, timeoutInterval: 10)
                    r.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    guard let d = try? await URLSession.shared.data(for: r).0,
                          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let s = j["streams"] as? [[String: Any]] else { return [] }
                    return s.compactMap { PhoneStream($0, addon: a.name, title: title) }
                }
            }
            for await batch in group {
                found += batch
                let waited = Date().timeIntervalSince(started)
                if waited >= 10 || (waited >= 3.5 && found.count >= 8) { group.cancelAll(); break }
            }
        }
        let target = type == "series" ? 1.5 : 5
        var seen = Set<String>()
        return found
            .sorted { a, b in a.rank(target: target).lexicographicallyPrecedes(b.rank(target: target)) }
            .filter { s in
                let k = s.service ? s.name : s.file.lowercased().filter { $0.isLetter || $0.isNumber }
                if k.isEmpty { return true }
                return seen.insert(k).inserted
            }
            .prefix(60).map { $0 }
    }

    // What the title is: its name, poster, backdrop, and for a show its episodes.
    struct Episode: Hashable { var id: String, season: Int, episode: Int, name: String }
    struct Meta {
        var name: String, poster: String, background: String, logo: String
        var episodes: [Episode]
    }
    static func meta(type: String, id: String) async -> Meta? {
        guard let u = URL(string: "\(metaBase)/meta/\(type)/\(id).json"),
              let d = try? await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 10)).0,
              let m = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["meta"] as? [String: Any] else { return nil }
        let eps = (m["videos"] as? [[String: Any]] ?? []).compactMap { v -> Episode? in
            guard let id = v["id"] as? String else { return nil }
            let s = v["season"] as? Int ?? 0, e = v["episode"] as? Int ?? v["number"] as? Int ?? 0
            return Episode(id: id, season: s, episode: e, name: v["name"] as? String ?? v["title"] as? String ?? "")
        }.sorted { ($0.season == 0 ? 999 : $0.season, $0.episode) < ($1.season == 0 ? 999 : $1.season, $1.episode) }
        return Meta(name: m["name"] as? String ?? "", poster: m["poster"] as? String ?? "", background: m["background"] as? String ?? "",
                    logo: m["logo"] as? String ?? "", episodes: eps)
    }

    // His library entry for a title (where he is in it, on any device), or nil.
    static func libraryItem(_ id: String) async -> [String: Any]? {
        guard let key = authKey,
              let r = try? await call("datastoreGet", ["authKey": key, "collection": "libraryItem", "ids": [id], "all": false], timeout: 8) else { return nil }
        return (r as? [[String: Any]])?.first { $0["_id"] as? String == id }
    }
    // Where to start: the spot his library holds for this very film or episode, in seconds, unless it's all but over.
    static func resumeAt(_ item: [String: Any]?, video: String) -> Double? {
        guard let st = item?["state"] as? [String: Any] else { return nil }
        let at = (st["timeOffset"] as? Double ?? 0) / 1000, length = (st["duration"] as? Double ?? 0) / 1000
        let on = st["video_id"] as? String
        guard at > 15, on == nil || on == video || (on ?? "").isEmpty else { return nil }
        if length > 0, at / length > 0.95 { return nil }
        return at
    }

    static func iso(_ d: Date = Date()) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    // Where he is, written back to his library, so the TV's Stremio (and Continue watching everywhere) carries on from
    // here. The entry he has is kept as it is but for the playing state; one he doesn't have is made as Stremio makes one
    // for a title watched without adding it (removed and temporary: in Continue watching, not in his library).
    static func putProgress(id: String, type: String, name: String, poster: String, video: String, at: Double, length: Double, watchedFor: Double, existing: [String: Any]?) async -> Bool {
        guard let key = authKey, at >= 0 else { return false }
        let now = iso()
        var item = existing ?? [
            "_id": id, "name": name, "type": type, "poster": poster, "posterShape": "poster",
            "removed": true, "temp": true, "_ctime": now,
            "state": ["lastWatched": now, "timeWatched": 0, "timeOffset": 0, "overallTimeWatched": 0, "timesWatched": 0,
                      "flaggedWatched": 0, "duration": 0, "video_id": video, "watched": NSNull(), "noNotif": false] as [String: Any],
            "behaviorHints": ["defaultVideoId": NSNull(), "featuredVideoId": NSNull(), "hasScheduledVideos": false] as [String: Any],
        ]
        var st = item["state"] as? [String: Any] ?? [:]
        let sameVideo = (st["video_id"] as? String) == video
        st["video_id"] = video
        st["timeOffset"] = Int(at * 1000)
        if length > 0 { st["duration"] = Int(length * 1000) }
        st["lastWatched"] = now
        st["timeWatched"] = (sameVideo ? (st["timeWatched"] as? Int ?? 0) : 0) + Int(watchedFor * 1000)
        st["overallTimeWatched"] = (st["overallTimeWatched"] as? Int ?? 0) + Int(watchedFor * 1000)
        item["state"] = st
        item["_mtime"] = now
        // Watched to the end: as Stremio does, the spot goes back to the start and it counts as seen once more.
        if length > 0, at / length > 0.95 { st["timeOffset"] = 0; st["timesWatched"] = (st["timesWatched"] as? Int ?? 0) + 1; item["state"] = st }
        return (try? await call("datastorePut", ["authKey": key, "collection": "libraryItem", "changes": [item]], timeout: 10)) != nil
    }

    // Continue watching from his library: the titles he's part way through, newest first.
    static func continueWatching(limit: Int = 12) async -> [[String: Any]] {
        guard let key = authKey,
              let r = try? await call("datastoreGet", ["authKey": key, "collection": "libraryItem", "ids": [], "all": true], timeout: 12),
              let all = r as? [[String: Any]] else { return [] }
        let live = all.filter { i in
            guard let st = i["state"] as? [String: Any], (st["timeOffset"] as? Double ?? 0) > 0 else { return false }
            return i["removed"] as? Bool != true || i["temp"] as? Bool == true
        }
        func when(_ i: [String: Any]) -> String { ((i["state"] as? [String: Any])?["lastWatched"] as? String) ?? (i["_mtime"] as? String ?? "") }
        return Array(live.sorted { when($0) > when($1) }.prefix(limit))
    }
}

// Signed in or not, and as whom, for Settings and every "Play on iPhone".
@MainActor @Observable
final class StremioAccount {
    static let shared = StremioAccount()
    private(set) var email: String? = StremioKeychain.get("email")
    private(set) var signedIn = StremioKeychain.get("authKey") != nil
    func signIn(email: String, password: String) async throws {
        let r = try await StremioAPI.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        StremioKeychain.set("authKey", r.key)
        StremioKeychain.set("email", r.email)
        guard StremioKeychain.get("authKey") == r.key else { throw StremioError(message: "Stremio signed in, but this iPhone couldn’t keep the sign-in. Try again.") }
        self.email = r.email
        signedIn = true
        _ = try? await StremioAPI.addons(force: true)
    }
    // Signed out by Stremio: the key dropped, nothing sent.
    func forget() {
        StremioKeychain.set("authKey", nil)
        signedIn = false
    }
    func signOut() {
        let key = StremioKeychain.get("authKey")
        StremioKeychain.set("authKey", nil)
        StremioKeychain.set("email", nil)
        email = nil
        signedIn = false
        if let key { Task { await StremioAPI.logout(key) } }
    }
}
