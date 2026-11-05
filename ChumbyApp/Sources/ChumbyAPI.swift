import Foundation

// The Chumby's own CGI API. Reads are open on the network; writes need the device's token.
struct Sys: Decodable {
    var up = 0, memFree = 0, memTotal = 0, pspFree = 0, wifi = -1, vol = -1, shuffle = 0, wall = 0, night = 0
    var load = 0.0
    var airplayOn = false
    var chan = "", cp = "", lock = ""
    // What the alarm panel is doing: "r\tname\tsound" while one rings, "s\tname\tsound" while one snoozes, else empty.
    var ring = ""
    // A nap the Chumby keeps itself (cmd nap): when it's due, in seconds since 1970, or 0.
    var nap = 0
    // How often the watchdog has had to unfreeze it, and when it last did.
    var resets = 0, resetAt = 0
    var tw: [String] = []
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
        night = try c.decodeIfPresent(Int.self, forKey: .night) ?? 0
        load = try c.decodeIfPresent(Double.self, forKey: .load) ?? 0
        airplayOn = try c.decodeIfPresent(Bool.self, forKey: .airplayOn) ?? false
        chan = try c.decodeIfPresent(String.self, forKey: .chan) ?? ""
        cp = try c.decodeIfPresent(String.self, forKey: .cp) ?? ""
        lock = try c.decodeIfPresent(String.self, forKey: .lock) ?? ""
        ring = (try? c.decodeIfPresent(String.self, forKey: .ring)) ?? ""
        nap = (try? c.decodeIfPresent(Int.self, forKey: .nap)) ?? 0
        resets = (try? c.decodeIfPresent(Int.self, forKey: .resets)) ?? 0
        resetAt = (try? c.decodeIfPresent(Int.self, forKey: .resetAt)) ?? 0
        tw = try c.decodeIfPresent([String].self, forKey: .tw) ?? []
    }
    enum Key: String, CodingKey { case up, memFree, memTotal, pspFree, wifi, vol, shuffle, wall, night, load, airplayOn, chan, cp, lock, tw, ring, nap, resets, resetAt }
    // The alarm ringing or snoozing right now, from the panel's own report.
    struct Ringing: Equatable { var snoozed: Bool; var name: String; var sound: String }
    var ringing: Ringing? {
        let parts = ring.components(separatedBy: "\t")
        guard let k = parts.first, k == "r" || k == "s" else { return nil }
        return Ringing(snoozed: k == "s", name: parts.count > 1 ? parts[1] : "", sound: parts.count > 2 ? parts[2] : "")
    }
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
    static let calendarPrefix = "Calendar: "
    var isCalendar: Bool { name.hasPrefix(Alarm.calendarPrefix) }
    // Made and cleared by the Chumby or the nap button; never switched off by a new alarm (chalarm.c is_helper).
    var isHelper: Bool { name == "Catch-up" || name == "Nap" }
    // How the Chumby tells one alarm from another when it decides what's new (chalarm.c newest_wins).
    var key: String { name + "|" + when + "|" + time }
    // The same alarm, wherever it sits in the list.
    func same(_ o: Alarm) -> Bool { var x = o; x.id = id; return x == self }
    // How another alarm sounds and what it does after, leaving this one's name, time, day and on or off alone.
    mutating func takeSettings(from t: Alarm) {
        type = t.type; arg = t.arg; param = t.param; param_description = t.param_description
        duration = t.duration; snooze = t.snooze; auto_dismiss = t.auto_dismiss
        action = t.action; action_param = t.action_param; backup = t.backup; backupDelay = t.backupDelay
    }
    var isOn: Bool { enabled == "1" }
    // How a message names it: the calendar's by their event, your own by name or time.
    var spoken: String {
        if isCalendar { return "“" + name.dropFirst(Alarm.calendarPrefix.count) + "”" }
        return name.isEmpty ? "your \(clock) \(meridiem) alarm" : "“\(name)”"
    }
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
    struct Missed: Decodable, Identifiable, Hashable { let at: Double; let rang: Bool; let name: String; var id: String { "\(at) \(name)" } }
    var missed: [Missed] = []
    // The one set of settings every calendar alarm rings with, once one has been saved as it. Null until then.
    var calTpl: Alarm?
    // Whether a day the calendar wakes you keeps your repeating alarms quiet: 1 or 0. Missing on a Chumby too old for it.
    var calOverride: Int?
    // The one alarm time skipped by hand (the panel's own SKIP), until it passes. `skipKnown` is false on a Chumby too old to skip.
    var skipped: SkippedAlarm?
    var skipKnown = false
    // The Chumby's own clock as it answered, in seconds since 1970. Alarms ring by this clock, not the phone's.
    var now: Double?
    var chumbyNow: Date? { now.map { Date(timeIntervalSince1970: $0) } }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Key.self)
        now = (try? c.decodeIfPresent(Double.self, forKey: .now)) ?? nil
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
        calTpl = (try? c.decodeIfPresent(Alarm.self, forKey: .calTpl)) ?? nil
        calOverride = (try? c.decodeIfPresent(Int.self, forKey: .calOverride)) ?? nil
        skipKnown = c.contains(.skipped)
        skipped = (try? c.decodeIfPresent(SkippedAlarm.self, forKey: .skipped)) ?? nil
        reindex()
    }
    mutating func reindex() {
        for i in alarms.indices { alarms[i].id = i }
        for i in schedule.indices { schedule[i].id = i }
    }
    enum Key: String, CodingKey { case missed, volume, fade, shuffle, pending, alarms, streams, tones, channels, pandora, pandoraScan, channel, schedule, channelNames, widgetNames, mine, calTpl, calOverride, skipped, now }
}

// The panel's own SKIP, pinned to one alarm and one minute ({"name","at","when"}).
struct SkippedAlarm: Decodable, Equatable {
    var name: String
    var at: Double
    var when: String
    var date: Date { Date(timeIntervalSince1970: at) }
}

// ?a=chlist: per channel, [id, name, secs] rows (a "#" row names the channel) and saved [id, on, secs] edits.
struct ChannelList: Decodable {
    struct Channel: Decodable { let id: String; let list: [[String]]; let conf: [[String]] }
    let cur: String?; let channels: [Channel]; let names: [[String]]?
}

enum ChumbyError: LocalizedError {
    case message(String), deviceDown, waiting(String)
    // A save AlarmWriter turned down because it would have cost an alarm that's about to ring. Never retried on its own.
    case refused(String)
    var errorDescription: String? {
        switch self {
        case .message(let m), .refused(let m): return m
        case .waiting(let why): return "Waiting: \(why)."
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
    // The Mac keeps answering with its last copy while the Chumby is frozen, and that copy can be hours old.
    // It fetches a new one on being asked, so give it a moment; a Chumby that can't supply one is down.
    func fresh(_ action: String) async throws -> Data {
        var r = try await raw(action)
        for _ in 0..<4 where r.age >= 30 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            r = try await raw(action)
        }
        guard r.age < 30 else { throw ChumbyError.deviceDown }
        return r.data
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

// MARK: - Alarm rules the Chumby applies, worked out the same way here so the phone never shows a list that flips later.
extension ChumbyState {
    // The Chumby's rule (chalarm.c newest_wins, as of 284c01f): saving an alarm that's on and new (its name, repeat and
    // time weren't in the saved list) switches every other alarm off, Rick's rule of 11-02. Calendar alarms take no part
    // either way, as he decided on 11-03: one is never the new alarm and never gets switched off, since the calendar only
    // skips that day. Catch-up and Nap don't take part either.
    // Returns the places in `sending` the Chumby will switch off, given `saved`, the list it holds now.
    static func switchedOff(saved: [Alarm], sending: [Alarm]) -> [Int] {
        let old = Set(saved.map(\.key))
        func counts(_ a: Alarm) -> Bool { a.isOn && !a.isHelper && !a.isCalendar }
        let added = sending.indices.filter { counts(sending[$0]) && !old.contains(sending[$0].key) }
        guard !added.isEmpty else { return [] }
        return sending.indices.filter { counts(sending[$0]) && !added.contains($0) }
    }
    // The next alarm that will really ring. On a day a calendar alarm is on, the Chumby keeps repeating alarms quiet unless
    // that's switched off (calOverride 0), so they're passed over for that day (the panel hook's chCalSkip).
    func nextRing(after now: Date = Date()) -> (alarm: Alarm, at: Date)? {
        let cal = Calendar.current
        let skipping = (calOverride ?? 0) != 0
        let calendarDays = Set(alarms.filter { $0.isOn && $0.when == "once" && $0.isCalendar }.compactMap { a in
            Double(a.time).map { cal.startOfDay(for: Date(timeIntervalSince1970: $0 * 60)) }
        })
        var best: (alarm: Alarm, at: Date)?
        for a in alarms where a.isOn {
            var from = now
            for _ in 0..<12 {
                guard let d = a.nextFire(after: from) else { break }
                if skipping && a.when != "once" && !a.isCalendar && calendarDays.contains(cal.startOfDay(for: d)) { from = d; continue }
                // The one time skipped by hand doesn't ring either.
                if let s = skipped, s.name == a.name, abs(d.timeIntervalSince1970 - s.at) < 60 { from = d; continue }
                if best == nil || d < best!.at { best = (a, d) }
                break
            }
        }
        return best
    }
    // A one-off or nap whose time is truly behind it by the Chumby's own clock (`chumby`, from its state), with two hours to
    // spare for any snooze. Without the Chumby's clock nothing counts as expired. The Chumby clears its own Catch-up.
    static func isExpired(_ a: Alarm, chumby: Date?) -> Bool {
        guard let chumby, a.when == "once", a.name != "Catch-up", !a.isPlaceholder, let t = Double(a.time) else { return false }
        return t * 60 < chumby.timeIntervalSince1970 - 2 * 3600
    }
    // So the 16 places don't fill up with alarms that can never ring again.
    mutating func dropExpired(chumby: Date?) {
        alarms.removeAll { Self.isExpired($0, chumby: chumby) }
    }
    static let maxAlarms = 16
}

// What a save may cost, beyond the alarms it adds or changes. AlarmWriter checks every save against this.
struct SavePermit {
    // Alarms (by key) the user deleted, turned off or edited, that very alarm, by hand. Only these may go when due soon.
    var userOff: Set<String> = []
    // Calendar alarms (by key) the calendar sync found really gone: the event deleted, declined or canceled.
    var deliberate: Set<String> = []
    // A calendar sync: it may touch calendar alarms only, never another alarm, nor whether one is on.
    var calendarOnly = false
}

// MARK: - The one way alarms are saved
// Every alarm save, from the app, the calendar or Shortcuts, goes through here, one after another. Each reads the list fresh
// from the Chumby, changes only what it means to, and sends that, so two writers can never undo each other and nothing is
// ever saved from an old copy.
actor AlarmWriter {
    static let shared = AlarmWriter()
    private var last: Task<Void, Never>?
    struct Result { var state: ChumbyState; var saved: Bool }

    // `template` says, from the list as read, whether to send the first calendar alarm as the set every calendar alarm
    // shares. `quiet` holds the save while an alarm rings or is due within 3 minutes, since a save restarts the alarm panel.
    // `force` saves even when nothing else changed, as long as there's a set to send (the calendar settings themselves).
    // `permit` says what the save may cost besides what it changes (see SavePermit and `check`).
    func edit(_ api: ChumbyAPI, quiet: Bool = false, force: Bool = false, template: @escaping (ChumbyState) -> Bool = { _ in false },
              permit: SavePermit = SavePermit(), _ change: @escaping (inout ChumbyState) -> Void) async throws -> Result {
        try await edit(api, quiet: quiet, force: force, template: template, planned: { change(&$0); return permit })
    }
    // The same, for a change that works out its own permit from the list as read fresh.
    func edit(_ api: ChumbyAPI, quiet: Bool = false, force: Bool = false, template: @escaping (ChumbyState) -> Bool = { _ in false },
              planned change: @escaping (inout ChumbyState) -> SavePermit) async throws -> Result {
        let before = last
        let task = Task<Result, Error> {
            await before?.value
            return try await Self.run(api, quiet: quiet, force: force, template: template, change)
        }
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    private static func run(_ api: ChumbyAPI, quiet: Bool, force: Bool, template: (ChumbyState) -> Bool, _ change: (inout ChumbyState) -> SavePermit) async throws -> Result {
        var s = try JSONDecoder().decode(ChumbyState.self, from: await api.fresh("state"))
        let saved = s.alarms
        let was = s.alarmForm()
        let permit = change(&s)
        let asTemplate = template(s)
        guard (force && asTemplate) || ChumbyAPI.form(s.alarmForm()) != ChumbyAPI.form(was) else { s.reindex(); return Result(state: s, saved: false) }
        if quiet {
            if let sys = try? JSONDecoder().decode(Sys.self, from: await api.fresh("sys")), sys.ringing != nil { throw ChumbyError.waiting("an alarm is ringing") }
            let soon = Date().addingTimeInterval(180)
            if s.alarms.contains(where: { ($0.nextFire() ?? .distantFuture) < soon }) { throw ChumbyError.waiting("an alarm is due") }
        }
        s.dropExpired(chumby: s.chumbyNow)
        guard s.alarms.count <= ChumbyState.maxAlarms else { throw ChumbyError.message(AlarmWriter.fullText) }
        let forceKeep = try check(saved: saved, sending: s.alarms, permit: permit, clock: s.chumbyNow ?? Date())
        var form = s.alarmForm()
        if asTemplate, let first = s.alarms.firstIndex(where: { $0.isCalendar }) { form.append(("tpl", "\(first)")) }
        // The Chumby keeps any calendar wake due within 24 h that a save drops (chalarm.c, 11-04), unless told this one is meant.
        if forceKeep { form.append(("force", "1")) }
        do { try await api.post("save", body: ChumbyAPI.form(form)) }
        catch ChumbyError.message(let m) where m.contains("token") { try await api.post("save", body: ChumbyAPI.form(form)) }
        // What the Chumby now holds, as it will read back: anything it switched off, off here too.
        for i in ChumbyState.switchedOff(saved: saved, sending: s.alarms) { s.alarms[i].enabled = "0" }
        if asTemplate, let first = s.alarms.first(where: { $0.isCalendar }) { s.calTpl = first }
        s.reindex()
        return Result(state: s, saved: true)
    }

    // The safety net, run on every save just before it's sent. `saved` is the list as read from the Chumby, `sending` what's
    // about to go, and `clock` the Chumby's time. What the Chumby will hold afterwards includes the alarms its newest_wins
    // rule switches off, so those count as lost too. It refuses (throws) when:
    // - an alarm that's on and due within 3 hours would be removed or switched off, and the user didn't delete, turn off or
    //   edit that very alarm by hand;
    // - a calendar alarm that's on and due within 24 hours would go without the user or a really-gone event saying so;
    // - a calendar sync would add, remove or switch on or off any alarm that isn't the calendar's.
    // Returns whether the save drops a calendar wake due within 24 h on purpose, so the Chumby's own guard lets it go.
    static func check(saved: [Alarm], sending: [Alarm], permit: SavePermit, clock: Date) throws -> Bool {
        var after = sending
        for i in ChumbyState.switchedOff(saved: saved, sending: sending) { after[i].enabled = "0" }
        let stillOn = Set(after.filter(\.isOn).map(\.key))
        var forceKeep = false
        for a in saved where a.isOn && !stillOn.contains(a.key) {
            guard let due = a.nextFire(after: clock) else { continue }
            let byHand = permit.userOff.contains(a.key)
            let when = due.formatted(date: .omitted, time: .shortened)
            if due.timeIntervalSince(clock) <= 3 * 3600 && !byHand {
                throw ChumbyError.refused("Not saved: that would have taken away \(a.spoken), due at \(when).")
            }
            if a.isCalendar && a.when == "once" && due.timeIntervalSince(clock) <= 86400 {
                guard byHand || permit.deliberate.contains(a.key) else {
                    throw ChumbyError.refused("Not saved: that would have taken away the calendar alarm \(a.spoken), due at \(when).")
                }
                forceKeep = true
            }
        }
        if permit.calendarOnly {
            // Every other alarm goes back exactly as it was read, on or off, apart from one-offs long past. And since none is
            // new, the Chumby's newest_wins rule can't switch anything off either.
            func own(_ l: [Alarm]) -> [String] { l.filter { !$0.isCalendar && !$0.isPlaceholder }.map { $0.key + "|" + $0.enabled }.sorted() }
            let expected = own(saved.filter { !ChumbyState.isExpired($0, chumby: clock) })
            guard own(sending) == expected, ChumbyState.switchedOff(saved: saved, sending: sending).isEmpty else {
                throw ChumbyError.refused("Not saved: the calendar update would have changed your other alarms.")
            }
        }
        return forceKeep
    }

    static let fullText = "The Chumby holds 16 alarms. Delete one, then try again."
    // The Chumby's own reasons, in words.
    static func explain(_ e: Error) -> String {
        switch e {
        case ChumbyError.waiting(let why): return "Waiting: \(why)."
        case ChumbyError.deviceDown: return "The Chumby isn’t answering."
        case ChumbyError.refused(let why): return why
        case ChumbyError.message(let m):
            switch m {
            case "bad count": return fullText
            case "bad text": return "The Chumby can’t keep that label. Try a shorter one."
            case "can't write": return "The Chumby couldn’t write it. Its storage may be full."
            case "No answer", "No answer from the Chumby.": return "Couldn’t reach the Chumby."
            default: return m.hasPrefix("bad ") ? "The Chumby turned that down (\(m))." : m
            }
        case is URLError: return "Couldn’t reach the Chumby."
        default: return e.localizedDescription
        }
    }
}
