import Foundation

// The Chumby's own CGI API. Reads are open on the network; writes need the device's token.
struct Sys: Decodable {
    var up = 0, memFree = 0, memTotal = 0, pspFree = 0, wifi = -1, vol = -1, shuffle = 0, wall = 0
    var load = 0.0
    var airplayOn = false
    var chan = "", cp = "", lock = ""
    var tw: [String] = []
    var roms: [String] = []
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Key.self)
        up = try c.decodeIfPresent(Int.self, forKey: .up) ?? 0
        memFree = try c.decodeIfPresent(Int.self, forKey: .memFree) ?? 0
        memTotal = try c.decodeIfPresent(Int.self, forKey: .memTotal) ?? 0
        pspFree = try c.decodeIfPresent(Int.self, forKey: .pspFree) ?? 0
        wifi = try c.decodeIfPresent(Int.self, forKey: .wifi) ?? -1
        vol = try c.decodeIfPresent(Int.self, forKey: .vol) ?? -1
        shuffle = try c.decodeIfPresent(Int.self, forKey: .shuffle) ?? 0
        wall = try c.decodeIfPresent(Int.self, forKey: .wall) ?? 0
        load = try c.decodeIfPresent(Double.self, forKey: .load) ?? 0
        airplayOn = try c.decodeIfPresent(Bool.self, forKey: .airplayOn) ?? false
        chan = try c.decodeIfPresent(String.self, forKey: .chan) ?? ""
        cp = try c.decodeIfPresent(String.self, forKey: .cp) ?? ""
        lock = try c.decodeIfPresent(String.self, forKey: .lock) ?? ""
        tw = try c.decodeIfPresent([String].self, forKey: .tw) ?? []
        roms = try c.decodeIfPresent([String].self, forKey: .roms) ?? []
    }
    enum Key: String, CodingKey { case up, memFree, memTotal, pspFree, wifi, vol, shuffle, wall, load, airplayOn, chan, cp, lock, tw, roms }
}

struct Alarm: Codable, Identifiable, Equatable {
    var id = 0     // its place in the list, so rows keep their identity across refreshes
    var name = "", enabled = "1", time = "420", when = "daily", type = "beep", arg = "Beep", param = ""
    var param_description = "Beep", duration = "30", snooze = "9", auto_dismiss = "0"
    var action = "", action_param = "", backup = "1", backupDelay = "5"
    enum CodingKeys: String, CodingKey { case name, enabled, time, when, type, arg, param, param_description, duration, snooze, auto_dismiss, action, action_param, backup, backupDelay }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys, _ f: String) throws -> String { try c.decodeIfPresent(String.self, forKey: k) ?? f }
        name = try s(.name, ""); enabled = try s(.enabled, "0"); time = try s(.time, "0"); when = try s(.when, "daily")
        type = try s(.type, "beep"); arg = try s(.arg, ""); param = try s(.param, ""); param_description = try s(.param_description, "")
        duration = try s(.duration, "30"); snooze = try s(.snooze, "9"); auto_dismiss = try s(.auto_dismiss, "0")
        action = try s(.action, ""); action_param = try s(.action_param, ""); backup = try s(.backup, "1"); backupDelay = try s(.backupDelay, "5")
    }
    var isPlaceholder: Bool { enabled == "0" && time == "0" && name.isEmpty && type == "beep" }
    var isOn: Bool { enabled == "1" }
    // Minutes after local midnight. A one-off stores absolute minutes since 1970.
    var localMinutes: Int {
        guard when == "once", let t = Double(time) else { return Int(time) ?? 0 }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t * 60))
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    var clock: String {
        let h = localMinutes / 60 % 24, m = localMinutes % 60
        return String(format: "%d:%02d", h % 12 == 0 ? 12 : h % 12, m)
    }
    var meridiem: String { localMinutes / 60 % 24 < 12 ? "AM" : "PM" }
    static let dayKeys = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    var whenText: String {
        switch when {
        case "once": return Date(timeIntervalSince1970: (Double(time) ?? 0) * 60).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case "daily": return "Every day"
        case "weekday": return "Weekdays"
        case "weekend": return "Weekends"
        default: return Alarm.dayKeys.firstIndex(of: when).map { Calendar.current.weekdaySymbols[$0] + "s" } ?? when
        }
    }
    var soundText: String {
        if type == "none" { return "Silent" }
        if type == "beep" { return arg.isEmpty ? "Beep" : arg }
        if type == "widget" { return "Chumby app" }
        if arg == "directurl" { return param_description.isEmpty ? "Radio stream" : param_description }
        if arg == "pandora" { return "Pandora: " + (param_description.isEmpty ? "station" : param_description) }
        return param_description.isEmpty ? (arg.isEmpty ? "Music" : arg) : param_description
    }
    func nextFire(after now: Date = Date()) -> Date? {
        guard isOn, let t = Double(time) else { return nil }
        if when == "once" { let d = Date(timeIntervalSince1970: t * 60); return d > now ? d : nil }
        let cal = Calendar.current
        for i in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: i, to: now),
                  let d = cal.date(bySettingHour: Int(t) / 60, minute: Int(t) % 60, second: 0, of: day), d > now else { continue }
            let w = cal.component(.weekday, from: d) - 1
            if when == "daily" || (when == "weekday" && w > 0 && w < 6) || (when == "weekend" && (w == 0 || w == 6)) || when == Alarm.dayKeys[w] { return d }
        }
        return nil
    }
}

struct Stream: Codable, Identifiable, Equatable { var id = ""; var name = ""; var url = ""; var mimetype = "audio/mpeg"
    var key: String { id + url } }
struct NamedID: Decodable, Identifiable, Hashable { let id: String; let name: String }
struct MineWidget: Decodable, Identifiable { let name: String; let secs: Int; var id: String { name } }
struct ScheduleItem: Codable, Identifiable, Equatable { var id = 0; var time = "22:00"; var cmd = "night"; var val = "on"
    enum CodingKeys: String, CodingKey { case time, cmd, val } }

struct ChumbyState: Decodable {
    var volume = 100, fade = -1, shuffle = 0
    var pending = false
    var alarms: [Alarm] = []
    var streams: [Stream] = []
    var tones: [String] = []
    var channels: [NamedID] = []
    var pandora: [NamedID] = []
    var pandoraScan = "", channel = ""
    var schedule: [ScheduleItem] = []
    var channelNames: [String] = []
    var widgetNames: [String] = []
    var mine: [MineWidget] = []
    // Alarms that came due while it was frozen, off or restarting.
    struct Missed: Decodable, Identifiable, Hashable { let at: Double; let rang: Bool; let name: String; var id: Double { at } }
    var missed: [Missed] = []
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Key.self)
        volume = try c.decodeIfPresent(Int.self, forKey: .volume) ?? 100
        fade = try c.decodeIfPresent(Int.self, forKey: .fade) ?? -1
        shuffle = try c.decodeIfPresent(Int.self, forKey: .shuffle) ?? 0
        pending = try c.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        alarms = try c.decodeIfPresent([Alarm].self, forKey: .alarms) ?? []
        streams = try c.decodeIfPresent([Stream].self, forKey: .streams) ?? []
        tones = try c.decodeIfPresent([String].self, forKey: .tones) ?? []
        channels = try c.decodeIfPresent([NamedID].self, forKey: .channels) ?? []
        pandora = try c.decodeIfPresent([NamedID].self, forKey: .pandora) ?? []
        pandoraScan = try c.decodeIfPresent(String.self, forKey: .pandoraScan) ?? ""
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? ""
        schedule = try c.decodeIfPresent([ScheduleItem].self, forKey: .schedule) ?? []
        channelNames = try c.decodeIfPresent([String].self, forKey: .channelNames) ?? []
        widgetNames = try c.decodeIfPresent([String].self, forKey: .widgetNames) ?? []
        mine = try c.decodeIfPresent([MineWidget].self, forKey: .mine) ?? []
        missed = try c.decodeIfPresent([Missed].self, forKey: .missed) ?? []
        reindex()
    }
    mutating func reindex() {
        for i in alarms.indices { alarms[i].id = i }
        for i in schedule.indices { schedule[i].id = i }
    }
    enum Key: String, CodingKey { case missed, volume, fade, shuffle, pending, alarms, streams, tones, channels, pandora, pandoraScan, channel, schedule, channelNames, widgetNames, mine }
}

// ?a=chlist: per channel, [id, name, secs] rows (a "#" row names the channel) and saved [id, on, secs] edits.
struct ChannelList: Decodable {
    struct Channel: Decodable { let id: String; let list: [[String]]; let conf: [[String]] }
    let cur: String?; let channels: [Channel]; let names: [[String]]?
}

enum ChumbyError: LocalizedError {
    case message(String), deviceDown
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .deviceDown: return "The Chumby isn’t answering."
        }
    }
}

actor ChumbyAPI {
    static let appPath = "/cgi-bin/custom/app"
    let base: URL
    private var token: String?
    init(base: URL) { self.base = base }

    private func url(_ query: String) -> URL { URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + ChumbyAPI.appPath + "?" + query)! }

    // The bytes and how old the Mac's copy is, so an unchanged answer costs nothing.
    func raw(_ action: String) async throws -> (data: Data, age: Double) {
        var r = URLRequest(url: url("a=" + action)); r.cachePolicy = .reloadIgnoringLocalCacheData; r.timeoutInterval = 8
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw ChumbyError.message("No answer") }
        // The Mac answered, but says the Chumby itself isn't responding.
        if h.statusCode == 502 { throw ChumbyError.deviceDown }
        guard h.statusCode == 200 else { throw ChumbyError.message("No answer") }
        return (d, Double(h.value(forHTTPHeaderField: "X-Chumby-Age") ?? "") ?? 0)
    }
    // Only the Mac can say this: when the Chumby last answered it. Nil when going straight to the Chumby.
    func lastSeen() async -> Date? {
        struct Health: Decodable { let lastSeen: Double? }
        guard let h = try? await get("health", as: Health.self), let t = h.lastSeen else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    func get<T: Decodable>(_ action: String, as: T.Type) async throws -> T {
        var r = URLRequest(url: url("a=" + action)); r.cachePolicy = .reloadIgnoringLocalCacheData; r.timeoutInterval = 8
        let (d, resp) = try await URLSession.shared.data(for: r)
        // An error page must not read as an empty answer, or a failure looks like "no alarms".
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ChumbyError.message("No answer") }
        return try JSONDecoder().decode(T.self, from: d)
    }
    func text(_ query: String) async throws -> String {
        var r = URLRequest(url: url(query)); r.timeoutInterval = 25
        return String(decoding: try await URLSession.shared.data(for: r).0, as: UTF8.self)
    }
    func shot() async throws -> Data {
        var r = URLRequest(url: url("a=shot&n=\(Int(Date().timeIntervalSince1970))")); r.cachePolicy = .reloadIgnoringLocalCacheData; r.timeoutInterval = 6
        let (data, response) = try await URLSession.shared.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChumbyError.message("No picture") }
        return data
    }
    private func getToken() async throws -> String {
        if let token { return token }
        struct T: Decodable { let t: String }
        let t = try await get("tok", as: T.self).t
        token = t
        return t
    }
    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    static func form(_ pairs: [(String, String)]) -> String { pairs.map { enc($0.0) + "=" + enc($0.1) }.joined(separator: "&") }

    @discardableResult
    func post(_ action: String, extra: String = "", body: String = "") async throws -> [String: Any] {
        let t = try await getToken()
        var r = URLRequest(url: url("a=\(action)&t=\(t)\(extra)")); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); r.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard j["ok"] as? Bool == true else {
            if (j["error"] as? String)?.contains("token") == true { token = nil }
            throw ChumbyError.message(j["error"] as? String ?? "No answer from the Chumby.")
        }
        return j
    }
    func cmd(_ c: String, _ v: String? = nil) async throws {
        try await post("cmd", extra: "&c=\(c)" + (v.map { "&v=" + ChumbyAPI.enc($0) } ?? ""))
    }
}
