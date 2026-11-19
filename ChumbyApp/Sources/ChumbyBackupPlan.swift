import Foundation

// The phone's backup alarm, as rules (Foundation only, so ci/chumby-tests.sh runs them with plain swiftc). The Chumby
// rings; if nothing has stopped or snoozed that ring a few minutes later, the iPhone's own alarm goes off. ChumbyBackupAlarm
// does the AlarmKit calls; every decision about which rings get a backup, when, and what to cancel or move is made here.
enum BackupPlan {
    static let horizon: TimeInterval = 7 * 24 * 3600   // a week, so a phone left unopened is still covered
    // Richard, 11-19: music first, then the Chumby's loud beep, then the phone. The delay is counted from the Chumby's
    // loud beep (its escalation), not from the ring: minutes after it.
    static let delays = [1, 3, 6]
    static let defaultDelay = 1
    // A delay saved before 11-19 counted from the ring (3, 5 or 10 min). With the beep 4 min in, 5 and 10 keep the
    // phone ringing when it did; 3 (before the beep) becomes 1, just after it.
    static func migrated(fromRing old: Int) -> Int { old >= 10 ? 6 : 1 }

    // The Chumby's escalation (panel hook, /psp/alarm_escalate "FIRST AGAIN" in seconds, 0 off): a music ring nobody
    // stops goes to its full-volume beep `first` seconds in, `again` seconds into the ring after a snooze. A beep alarm
    // beeps from the start, so its backup counts from the ring itself.
    struct Escalation: Equatable {
        var first = 240, again = 60
        static let standard = Escalation()
        // a=state "escalate": [FIRST, AGAIN] when the Chumby says; else the hook's defaults
        init(first: Int = 240, again: Int = 60) { self.first = max(0, first); self.again = max(0, again) }
        init(_ v: [Int]?) {
            guard let v, let f = v.first else { self.init(); return }
            self.init(first: f, again: v.count > 1 ? v[1] : (f == 0 ? 0 : 60))
        }
    }
    // Seconds from a ring's start to the Chumby's loud beep, and from a snooze's end to it.
    static func beepLead(_ a: Alarm, _ e: Escalation) -> (first: TimeInterval, again: TimeInterval) {
        guard a.type == "audio", a.duration != "0" else { return (0, 0) }
        return (TimeInterval(e.first), TimeInterval(e.again))
    }

    struct Ring: Equatable {
        var at: Date; var name: String
        // to the Chumby's loud beep: on this ring, and on a ring after a snooze
        var lead: TimeInterval = 0, leadAgain: TimeInterval = 0
    }
    // One backup kept for one ring: `fireAt` is when the phone rings (the Chumby's loud beep plus the delay, or a snooze's
    // end, its beep and the delay). `again`: seconds from a snooze's end to the beep (nil in one saved before 11-19: 60).
    struct Entry: Codable, Equatable { var id: UUID; var ringAt: Date; var name: String; var fireAt: Date; var again: Double? = nil }

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
        let esc = Escalation(s.escalate)
        for a in s.alarms where a.isOn && a.name != "Catch-up" && !a.isPlaceholder {
            let lead = beepLead(a, esc)
            var from = now
            for _ in 0..<16 {
                guard let d = s.ring(of: a, after: from), d <= now.addingTimeInterval(horizon) else { break }
                out.append(Ring(at: d, name: a.name, lead: lead.first, leadAgain: lead.again))
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
            let fire = r.at.addingTimeInterval(r.lead + Double(delay) * 60)
            if let e = kept.first(where: { !used.contains($0.id) && $0.ringAt == r.at && same($0.name, r.name) }) {
                used.insert(e.id)
                if e.fireAt == fire && fire > now && e.again == r.leadAgain { entries.append(e); continue }
                // begun and moved by a snooze: it stays where the snooze put it
                if e.ringAt <= now && e.fireAt > now && e.fireAt != fire { entries.append(e); continue }
                cancel.append(e)
            }
            guard fire > now else { continue }
            let n = Entry(id: makeID(), ringAt: r.at, name: r.name, fireAt: fire, again: r.leadAgain)
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

    // Stopped on the Chumby, as the Mac reports it: only the backup of the ring that began at `at` (within 2 minutes, which
    // a snooze doesn't change) and still ahead goes. No time, or no such backup: nothing is cancelled.
    static func stoppedRing(_ entries: [Entry], now: Date, at: Date?) -> Result {
        guard let at, let e = entries.filter({ abs($0.ringAt.timeIntervalSince(at)) <= 120 && $0.fireAt > now })
            .min(by: { abs($0.ringAt.timeIntervalSince(at)) < abs($1.ringAt.timeIntervalSince(at)) })
        else { return Result(entries: entries, cancel: [], add: []) }
        return Result(entries: entries.filter { $0.id != e.id }, cancel: [e], add: [])
    }

    // He snoozed it until `until`: its backup moves to then plus the delay.
    static func snoozed(_ entries: [Entry], now: Date, name: String?, until: Date, delay: Int, makeID: () -> UUID = UUID.init) -> Result {
        guard let e = current(entries, now: now, name: name) else { return Result(entries: entries, cancel: [], add: []) }
        // already there (the card, the app's page, the Mac's push and the next reading can all report one snooze)
        let fire = until.addingTimeInterval((e.again ?? 60) + Double(delay) * 60)
        if e.fireAt == fire { return Result(entries: entries, cancel: [], add: []) }
        var n = e; n.id = makeID(); n.fireAt = fire
        return Result(entries: entries.map { $0.id == e.id ? n : $0 }, cancel: [e], add: [n])
    }

    // What the bridge's quiet ring push says (payload key `ring`): null or `over` is the end of the ring, `snoozed` with
    // `until` (Unix seconds; else the alarm's snooze minutes, `snooze`, else 9) is a snooze, anything else is still ringing.
    // `stopped`: the ring is over and the Chumby logged a Stop for it (its own Stop key or the phone's), so the backup goes;
    // a plain `over` (a ring that died, played out, or a restart) keeps it.
    // `at`: when that ring began, so only its own backup goes, however late iOS hands the push over (gate, 11-19).
    enum Signal: Equatable { case over, stopped(name: String?, at: Date?), snoozed(name: String?, until: Date) }
    static func signal(_ userInfo: [AnyHashable: Any], now: Date) -> Signal? {
        guard let raw = userInfo["ring"] else { return nil }
        guard let r = raw as? [String: Any] else { return raw is NSNull ? .over : nil }
        if (r["over"] as? Bool) == true || (r["over"] as? NSNumber)?.boolValue == true {
            let stopped = (r["stopped"] as? Bool) == true || (r["stopped"] as? NSNumber)?.boolValue == true
            let at = ((r["at"] as? NSNumber)?.doubleValue).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return stopped ? .stopped(name: r["name"] as? String, at: at) : .over
        }
        guard (r["snoozed"] as? NSNumber)?.boolValue == true else { return nil }
        let name = r["name"] as? String
        if let u = (r["until"] as? NSNumber)?.doubleValue, u > 0 { return .snoozed(name: name, until: Date(timeIntervalSince1970: u)) }
        let minutes = (r["snooze"] as? NSNumber)?.doubleValue ?? Double(r["snooze"] as? String ?? "") ?? 9
        return .snoozed(name: name, until: now.addingTimeInterval(minutes * 60))
    }
}
