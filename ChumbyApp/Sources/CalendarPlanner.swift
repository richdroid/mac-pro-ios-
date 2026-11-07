import Foundation

// Works out when to wake from what's on the calendar. Nothing here touches the Chumby or the calendar itself.
struct CalEvent {
    var id = "", title = "", calendar = ""
    var start = Date(), end = Date()
    var allDay = false, free = false, declined = false, canceled = false
    var hasLocation = false
}
struct WakeRules: Codable, Equatable {
    var enabled = false
    // Minutes to be awake before something starts.
    var workLead = 160, otherLead = 90, travelExtra = 30
    var workWords = ["shift", "work"]
    var ignoreWords = ["birthday", "reminder", "optional"]
    var offWords = ["day off", "off work", "vacation", "pto", "holiday"]
    var workCalendars: Set<String> = []
    var excludedCalendars: Set<String> = []
    var skipped: Set<String> = []
    var daysAhead = 3
    // A day runs from here to here, so a shift that ends at 2 AM belongs to the day it started.
    var dayStartHour = 5
    // One day's own wake-up lead, set from that day's sheet, by PlannedWake key.
    var leadOverrides: [String: Int] = [:]
    init() {}
    // Every field optional, so settings saved by an older build still load rather than resetting to the defaults.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let f = WakeRules()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? f.enabled
        workLead = try c.decodeIfPresent(Int.self, forKey: .workLead) ?? f.workLead
        otherLead = try c.decodeIfPresent(Int.self, forKey: .otherLead) ?? f.otherLead
        travelExtra = try c.decodeIfPresent(Int.self, forKey: .travelExtra) ?? f.travelExtra
        workWords = try c.decodeIfPresent([String].self, forKey: .workWords) ?? f.workWords
        ignoreWords = try c.decodeIfPresent([String].self, forKey: .ignoreWords) ?? f.ignoreWords
        offWords = try c.decodeIfPresent([String].self, forKey: .offWords) ?? f.offWords
        workCalendars = try c.decodeIfPresent(Set<String>.self, forKey: .workCalendars) ?? f.workCalendars
        excludedCalendars = try c.decodeIfPresent(Set<String>.self, forKey: .excludedCalendars) ?? f.excludedCalendars
        skipped = try c.decodeIfPresent(Set<String>.self, forKey: .skipped) ?? f.skipped
        daysAhead = try c.decodeIfPresent(Int.self, forKey: .daysAhead) ?? f.daysAhead
        dayStartHour = try c.decodeIfPresent(Int.self, forKey: .dayStartHour) ?? f.dayStartHour
        leadOverrides = try c.decodeIfPresent([String: Int].self, forKey: .leadOverrides) ?? f.leadOverrides
    }
}
struct PlannedWake: Identifiable, Equatable {
    var key: String
    var title: String
    var start: Date
    var wake: Date
    var lead: Int
    var isWork: Bool
    var skipped = false
    var shortNight: String?
    var custom = false          // its lead was set for this day alone
    var id: String { key }
}

enum WakePlanner {
    // Whole words only, so "Workout" isn't work and "Shiftless" isn't a shift.
    static func mentions(_ text: String, _ phrases: [String]) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return phrases.contains { phrase in
            let want = phrase.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            guard !want.isEmpty, words.count >= want.count else { return false }
            return (0...(words.count - want.count)).contains { Array(words[$0..<($0 + want.count)]) == want }
        }
    }
    static func isWork(_ e: CalEvent, _ r: WakeRules) -> Bool { r.workCalendars.contains(e.calendar) || mentions(e.title, r.workWords) }
    static func counts(_ e: CalEvent, _ r: WakeRules) -> Bool {
        !e.allDay && !e.free && !e.declined && !e.canceled && !r.excludedCalendars.contains(e.calendar) && !mentions(e.title, r.ignoreWords)
    }
    static func key(_ e: CalEvent) -> String { "\(e.id)@\(Int(e.start.timeIntervalSince1970))" }
    // The day an event belongs to. Something in the small hours (before dayStartHour) only counts as the night before
    // when you'd be up for it anyway, because something else runs into it or ended in the last few hours. Otherwise, as
    // with a 4 AM shift after an evening dinner, it starts a day of its own and gets its own alarm.
    static func dayOf(_ e: CalEvent, among events: [CalEvent], _ r: WakeRules, _ cal: Calendar) -> Date {
        let own = cal.startOfDay(for: e.start)
        guard cal.component(.hour, from: e.start) < r.dayStartHour else { return own }
        let up = events.contains { $0.start < e.start && $0.end > e.start.addingTimeInterval(-4 * 3600) }
        return up ? (cal.date(byAdding: .day, value: -1, to: own) ?? own) : own
    }
    static func plan(_ events: [CalEvent], rules r: WakeRules, now: Date = Date(), calendar cal: Calendar = .current) -> [PlannedWake] {
        var off = Set<Date>()
        for e in events where e.allDay && !e.canceled && !e.declined && mentions(e.title, r.offWords) {
            var d = cal.startOfDay(for: e.start)
            while d < e.end { off.insert(d); d = cal.date(byAdding: .day, value: 1, to: d) ?? e.end }
        }
        let usable = events.filter { counts($0, r) }.sorted { $0.start < $1.start }
        var byDay: [Date: [CalEvent]] = [:]
        let days = usable.map { dayOf($0, among: usable, r, cal) }
        for (e, d) in zip(usable, days) { byDay[d, default: []].append(e) }
        var out: [PlannedWake] = []
        for day in byDay.keys.sorted() {
            // A day off cancels work, but the dentist still happens.
            let list = byDay[day]!.filter { !(off.contains(day) && isWork($0, r)) }
            guard let first = list.first else { continue }
            let work = isWork(first, r)
            let lead = r.leadOverrides[key(first)] ?? (work ? r.workLead : r.otherLead + (first.hasLocation ? r.travelExtra : 0))
            let wake = first.start.addingTimeInterval(TimeInterval(-lead * 60))
            // Already past: you're either up already or it's too late for an alarm to help.
            guard wake > now else { continue }
            var item = PlannedWake(key: key(first), title: first.title, start: first.start, wake: wake, lead: lead, isWork: work)
            item.skipped = r.skipped.contains(item.key)
            item.custom = r.leadOverrides[item.key] != nil
            // Worth saying if the night before leaves little sleep.
            if let i = usable.indices.last(where: { usable[$0].end <= wake && days[$0] < day }) {
                let before = usable[i]
                let hours = wake.timeIntervalSince(before.end) / 3600
                if hours < 7 { item.shortNight = String(format: "%.1f h after %@", hours, before.title) }
            }
            out.append(item)
            if out.count >= r.daysAhead { break }
        }
        return out
    }
}
