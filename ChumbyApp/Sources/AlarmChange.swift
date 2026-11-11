import Foundation

// One change to the alarms, said in a way that can be applied to any copy of the list, fresh from the Chumby or not, and
// that does nothing the second time. That's what lets a save re-read the list and change only this.
enum AlarmChange {
    case toggle(Alarm, Bool)
    case replace(Alarm, Alarm)
    case add(Alarm)
    case delete(Alarm)
    case volume(Int)
    case fade(Int)
    case nap(at: Int)          // minutes since 1970
    // A nap with its own sound, length, snooze and ring time (the nap editor); still the one Nap alarm, so the Chumby's
    // helper rule (never counted by newest_wins, never pinned) and one-nap-at-a-time both hold.
    case setNap(Alarm)
    case cancelNap
    static func find(_ a: Alarm, in s: ChumbyState) -> Int? { s.alarms.firstIndex { $0.same(a) } ?? s.alarms.firstIndex { $0.key == a.key } }
    func apply(_ s: inout ChumbyState) {
        switch self {
        case .toggle(let a, let on):
            if let i = Self.find(a, in: s) { s.alarms[i].enabled = on ? "1" : "0" }
        case .replace(let old, let new):
            if s.alarms.contains(where: { $0.same(new) }) { return }
            if let i = Self.find(old, in: s) { s.alarms[i] = new } else { Self.add(new, to: &s) }
        case .add(let a):
            if !s.alarms.contains(where: { $0.same(a) }) { Self.add(a, to: &s) }
        case .delete(let a):
            if let i = Self.find(a, in: s) { s.alarms.remove(at: i) }
        case .volume(let v): s.volume = v
        case .fade(let f): s.fade = f
        case .nap(let at):
            // A new nap replaces one still to come. One that has already gone off is left to finish ringing.
            let now = Int(Date().timeIntervalSince1970 / 60)
            s.alarms.removeAll { $0.name == "Nap" && $0.when == "once" && (Int($0.time) ?? 0) > now && $0.time != String(at) }
            if !s.alarms.contains(where: { $0.name == "Nap" && $0.when == "once" && $0.time == String(at) }) { s.addNap(at: at) }
        case .setNap(let a):
            // The one nap: any other still to come goes, and this one takes its place (or the first free one).
            let now = Int(Date().timeIntervalSince1970 / 60)
            s.alarms.removeAll { $0.name == "Nap" && $0.when == "once" && (Int($0.time) ?? 0) > now && !$0.same(a) }
            if !s.alarms.contains(where: { $0.same(a) }) { Self.add(a, to: &s) }
        case .cancelNap:
            let now = Int(Date().timeIntervalSince1970 / 60)
            s.alarms.removeAll { $0.name == "Nap" && $0.when == "once" && (Int($0.time) ?? 0) > now }
        }
        s.reindex()
    }
    // Why this change can't be made to the list as read fresh, or nil. Switching on an alarm that's no longer there used
    // to change nothing and count as done; whatever relied on it being on (a "just this once" behind a skip) then left
    // the night silent. Switching off or deleting what's already gone is done already, and says nothing.
    func refusal(in s: ChumbyState) -> String? {
        if case .toggle(let a, true) = self, Self.find(a, in: s) == nil { return "That alarm is no longer on the Chumby. Nothing was changed." }
        return nil
    }
    private static func add(_ a: Alarm, to s: inout ChumbyState) {
        if let free = s.alarms.firstIndex(where: { $0.isPlaceholder }) { s.alarms[free] = a } else { s.alarms.append(a) }
    }
    // The alarms this change deletes, turns off or edits by the user's own hand, for AlarmWriter's safety net. Anything
    // else lost in the same save (the Chumby's newest_wins, say) is only allowed when the editor showed it first (`alsoOff`).
    func permit(in s: ChumbyState, alsoOff: Set<String> = []) -> SavePermit {
        var p = SavePermit(userOff: alsoOff)
        switch self {
        case .toggle(let a, let on): if !on { p.userOff.insert(a.key) }
        case .replace(let old, _), .delete(let old): p.userOff.insert(old.key)
        case .nap, .setNap, .cancelNap: p.userOff.formUnion(s.napPermit().userOff)
        case .add, .volume, .fade: break
        }
        return p
    }
    // What a failure says at the control, in the words of what was tried.
    var failHead: String {
        switch self {
        case .toggle(_, let on): return on ? "Couldn’t turn this on" : "Couldn’t turn this off"
        case .volume: return "Couldn’t change the volume"
        case .fade: return "Couldn’t change the fade"
        default: return "Not on the Chumby yet"
        }
    }
    // Where its mark shows: the alarm's row, or the control it came from.
    var mark: String {
        switch self {
        case .toggle(let a, _): return a.key
        case .replace(_, let a), .add(let a): return a.key
        case .delete(let a): return a.key
        case .volume: return "alarmVolume"
        case .fade: return "fade"
        case .nap, .setNap, .cancelNap: return "nap"
        }
    }
}
