import Foundation
import Security

// Shared by the app and its widgets (and the CI gallery): the links a widget opens, and the few figures only his whole
// history can give (the streak, his usual week), which the app hands the widgets.

enum LinkScheme {
    static let scheme = "rotation"
    static func url(_ host: String, _ q: [String: String?] = [:]) -> URL {
        var c = URLComponents()
        c.scheme = scheme; c.host = host
        let items = q.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { c.queryItems = items }
        return c.url ?? URL(string: "\(scheme)://you")!
    }
    static var you: URL { url("you") }
    static var now: URL { url("now") }
    static func charts(_ period: String) -> URL { url("charts", ["period": period]) }
    static func artist(_ name: String) -> URL { url("artist", ["name": name]) }
    static func album(_ artist: String, _ album: String) -> URL { url("album", ["artist": artist, "album": album]) }
    static func track(_ artist: String, _ title: String, album: String, image: String?) -> URL {
        url("track", ["artist": artist, "title": title, "album": album, "image": image])
    }
}

// What the app knows from his history that Last.fm can't say in one cheap call: worked out in the app with everything
// else, handed over through the Keychain group the TestFlight signing gives the app and each of its extensions
// (store-sign.sh: "<team>.local.macpro.LastFM.shared"). No App Group needed. Never on a build without a team (CI, the
// simulator): the widgets then go without the streak and the usual band.
struct WidgetFacts: Codable, Equatable {
    var at: Double                    // when the app worked these out
    var day: Int                      // the day they were worked out on (days since 1970, local)
    var playedThatDay: Bool           // whether the streak already counted that day
    var streak: Int?
    var best: Int?
    var weekStart: Double             // the week the figures below belong to
    var weekPlays: Int?
    var usual: Int?                   // the usual by that moment of the week
    var weeks: Int?
    var thisWeek: [Int] = []          // cumulative by day through that day
    var usualMid: [Int] = []          // the usual weeks, cumulative by day
    var usualLo: [Int] = []
    var usualHi: [Int] = []

    // Days since 1970 on his own calendar, as the app counts them (LocalDay.key).
    static func localDay(_ d: Date) -> Int {
        let off = TimeZone.current.secondsFromGMT(for: d)
        return Int(((d.timeIntervalSince1970 + Double(off)) / 86400).rounded(.down))
    }

    // The streak as it stands now: the app's last word, carried forward over the days since by the days he played
    // (local days with a play, read back as far as `covered`). Counting today once it has a play, else from yesterday,
    // as the app does. Nil when the days between can't be known.
    func streakNow(played: Set<Int>, covered: Int, now: Date = Date()) -> Int? {
        guard let s = streak else { return nil }
        let today = Self.localDay(now)
        guard today > day else { return s }
        var count = 0
        var d = today
        if played.contains(today) { count = 1 }
        d -= 1
        while d > day {
            guard d >= covered else { return nil }
            if !played.contains(d) { return count }
            count += 1; d -= 1
        }
        // That day itself: counted already if he'd played by then; if he played later that day, it counts now.
        if playedThatDay { return count + s }
        if played.contains(day) { return count + s + 1 }
        return day >= covered ? count : nil
    }

    private static var group: String? {
        let prefix = (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let team = prefix.flatMap({ $0.isEmpty ? nil : Substring($0) }) ?? Bundle.main.bundleIdentifier?.split(separator: ".").first(where: { $0.count == 10 && $0.allSatisfy { $0.isUppercase || $0.isNumber } }) else { return nil }
        return "\(team).local.macpro.LastFM.shared"
    }
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.macpro.LastFM.widgets", kSecAttrAccount as String: "facts"]
    }
    static func read() -> WidgetFacts? {
        guard let g = group else { return nil }
        var q = base
        q[kSecAttrAccessGroup as String] = g
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetFacts.self, from: d)
    }
    // Written only when something a widget shows has changed; true when it was.
    @discardableResult func write() -> Bool {
        guard let g = Self.group, let d = try? JSONEncoder().encode(self) else { return false }
        if var old = Self.read() { old.at = at; if old == self { return false } }
        var q = Self.base
        q[kSecAttrAccessGroup as String] = g
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
