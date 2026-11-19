import Foundation

// The phone's backup alarm, as rules (Foundation only, so ci/chumby-tests.sh runs them with plain swiftc). The Chumby
// rings; if nothing has stopped or snoozed that ring a few minutes later, the iPhone's own alarm goes off. ChumbyBackupAlarm
// does the AlarmKit calls; every decision about which rings get a backup, when, and what to cancel or move is made here.
enum BackupPlan {
    static let horizon: TimeInterval = 7 * 24 * 3600   // a week, so a phone left unopened is still covered
    static let delays = [3, 5, 10]
    static let defaultDelay = 5

    struct Ring: Equatable { var at: Date; var name: String }
    // One backup kept for one ring: `fireAt` is when the phone rings (the ring plus the delay, or the snooze's end plus it).
    struct Entry: Codable, Equatable { var id: UUID; var ringAt: Date; var name: String; var fireAt: Date }

    static func shown(_ name: String) -> String {
        name.hasPrefix(Alarm.calendarPrefix) ? String(name.dropFirst(Alarm.calendarPrefix.count)) : name
    }
    private static func same(_ a: String, _ b: String) -> Bool {
        shown(a).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(shown(b).trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    // The rings the Chumby will really make within the horizon (skips and calendar days already worked out by ring(of:)).
    // A Nap is a wake-up too and is backed up; Catch-up (the Chumby re-ringing one it missed) is not.
    static func rings(in s: ChumbyState, now: Date, horizon: TimeInterval = BackupPlan.horizon) -> [Ring] {
        var out: [Ring] = []
        for a in s.alarms where a.isOn && a.name != "Catch-up" && !a.isPlaceholder {
            var from = now
            for _ in 0..<16 {
                guard let d = s.ring(of: a, after: from), d <= now.addingTimeInterval(horizon) else { break }
                out.append(Ring(at: d, name: a.name))
                from = d.addingTimeInterval(60)
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    struct Result: Equatable { var entries: [Entry]; var cancel: [Entry]; var add: [Entry] }

    // Keeps exactly one backup per wanted ring. A ring that has begun and isn't wanted any more (it is past) keeps its backup
    // only while that is still ahead (a snooze moved it); anything else unwanted or already past is cancelled.
    static func reconcile(kept: [Entry], wanted: [Ring], delay: Int, now: Date, makeID: () -> UUID = UUID.init) -> Result {
        var entries: [Entry] = [], cancel: [Entry] = [], add: [Entry] = []
        var used = Set<UUID>()
        for r in wanted {
            let fire = r.at.addingTimeInterval(Double(delay) * 60)
            if let e = kept.first(where: { !used.contains($0.id) && $0.ringAt == r.at && same($0.name, r.name) }) {
                used.insert(e.id)
                if e.fireAt == fire && fire > now { entries.append(e); continue }
                cancel.append(e)
            }
            guard fire > now else { continue }
            let n = Entry(id: makeID(), ringAt: r.at, name: r.name, fireAt: fire)
            entries.append(n); add.append(n)
        }
        for e in kept where !used.contains(e.id) {
            if e.ringAt <= now && e.fireAt > now { entries.append(e) } else { cancel.append(e) }
        }
        return Result(entries: entries.sorted { $0.ringAt < $1.ringAt }, cancel: cancel, add: add)
    }

    // The backup of the ring in progress: one whose ring has begun and whose backup is still ahead, the alarm of that name if
    // several, else the latest to begin.
    // The alarm named may have begun up to a minute "early" by this phone's clock (a Chumby a little fast, a quick press).
    static func current(_ entries: [Entry], now: Date, name: String?) -> Entry? {
        let live = entries.filter { $0.ringAt <= now && $0.fireAt > now }
        if let name, !name.isEmpty, let e = entries.filter({ $0.ringAt <= now.addingTimeInterval(60) && $0.fireAt > now && same($0.name, name) }).max(by: { $0.ringAt < $1.ringAt }) { return e }
        return live.max { $0.ringAt < $1.ringAt }
    }

    // He stopped it (or the ring ended): the ring in progress needs no backup.
    static func handled(_ entries: [Entry], now: Date, name: String? = nil) -> Result {
        guard let e = current(entries, now: now, name: name) else { return Result(entries: entries, cancel: [], add: []) }
        return Result(entries: entries.filter { $0.id != e.id }, cancel: [e], add: [])
    }

    // He snoozed it until `until`: its backup moves to then plus the delay.
    static func snoozed(_ entries: [Entry], now: Date, name: String?, until: Date, delay: Int, makeID: () -> UUID = UUID.init) -> Result {
        guard let e = current(entries, now: now, name: name) else { return Result(entries: entries, cancel: [], add: []) }
        // already there (the card, the app's page, the Mac's push and the next reading can all report one snooze)
        let fire = until.addingTimeInterval(Double(delay) * 60)
        if e.fireAt == fire { return Result(entries: entries, cancel: [], add: []) }
        var n = e; n.id = makeID(); n.fireAt = fire
        return Result(entries: entries.map { $0.id == e.id ? n : $0 }, cancel: [e], add: [n])
    }

    // What the bridge's quiet ring push says (payload key `ring`): null or `over` is the end of the ring, `snoozed` with
    // `until` (Unix seconds; else the alarm's snooze minutes, `snooze`, else 9) is a snooze, anything else is still ringing.
    enum Signal: Equatable { case over, snoozed(name: String?, until: Date) }
    static func signal(_ userInfo: [AnyHashable: Any], now: Date) -> Signal? {
        guard let raw = userInfo["ring"] else { return nil }
        guard let r = raw as? [String: Any] else { return raw is NSNull ? .over : nil }
        if (r["over"] as? Bool) == true || (r["over"] as? NSNumber)?.boolValue == true { return .over }
        guard (r["snoozed"] as? NSNumber)?.boolValue == true else { return nil }
        let name = r["name"] as? String
        if let u = (r["until"] as? NSNumber)?.doubleValue, u > 0 { return .snoozed(name: name, until: Date(timeIntervalSince1970: u)) }
        let minutes = (r["snooze"] as? NSNumber)?.doubleValue ?? Double(r["snooze"] as? String ?? "") ?? 9
        return .snoozed(name: name, until: now.addingTimeInterval(minutes * 60))
    }
}
