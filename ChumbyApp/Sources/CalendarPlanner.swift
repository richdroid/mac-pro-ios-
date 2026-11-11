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
    // One day's own exact wake-up time and label, set from that day's sheet, by PlannedWake key (see DayEdit).
    var dayEdits: [String: DayEdit] = [:]
    // Whether that day has anything of its own: a lead, a time or a label.
    func edited(_ key: String) -> Bool { leadOverrides[key] != nil || !(dayEdits[key]?.isEmpty ?? true) }
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
        dayEdits = try c.decodeIfPresent([String: DayEdit].self, forKey: .dayEdits) ?? f.dayEdits
    }
}
// What one calendar day changes for itself alone. The day's key holds the event's start, so if the event moves, the edit
// is left behind with the old time and the day goes back to the usual settings, as a lead set for that day does.
struct DayEdit: Codable, Equatable {
    // An exact wake-up time (seconds since 1970) in place of "how long before".
    var wakeAt: Double?
    // Shown on the Chumby in place of the event's title, after "Calendar: ".
    var label: String?
    // That day's own sound, length, snooze and stop, in place of the shared calendar set: only those settings of the
    // alarm are used (Alarm.takeSettings). Sent with I_own=1, which the Chumby keeps (chumby 2c90cc9).
    var own: Alarm?
    var isEmpty: Bool { wakeAt == nil && (label ?? "").isEmpty && own == nil }
    init(wakeAt: Double? = nil, label: String? = nil, own: Alarm? = nil) { self.wakeAt = wakeAt; self.label = label; self.own = own }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        wakeAt = try c.decodeIfPresent(Double.self, forKey: .wakeAt)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        own = try? c.decodeIfPresent(Alarm.self, forKey: .own)
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
    var custom = false          // its lead, time or label was set for this day alone
    var exact = false           // rings at a time set for this day, not "how long before"
    var label: String?          // this day's own label, in place of the title on the Chumby
    var own: Alarm?             // this day's own sound and snooze (DayEdit.own), in place of the shared set
    var shown: String { label ?? title }
    var id: String { key }
}

enum WakePlanner {
    // How a calendar alarm is named and timed on the Chumby (here, so the plan and the checks on it share them).
    static func minutes(_ d: Date) -> String { String(Int(d.timeIntervalSince1970 / 60)) }
    // A day's own label, when it has one, names its alarm on the Chumby in place of the event's title.
    static func alarmName(_ w: PlannedWake) -> String { alarmName(title: w.shown) }
    static func alarmName(title: String) -> String { Alarm.calendarPrefix + String(title.prefix(30)) }
    // The rules a wake's time comes from, as one string, without the per-day choices (skips, a day's own time): when
    // this differs from the last update's, the user changed a rule by hand.
    static func signature(_ r: WakeRules) -> String {
        [String(r.enabled), String(r.workLead), String(r.otherLead), String(r.travelExtra), String(r.dayStartHour),
         r.workWords.joined(separator: ","), r.ignoreWords.joined(separator: ","), r.offWords.joined(separator: ","),
         r.workCalendars.sorted().joined(separator: ","), r.excludedCalendars.sorted().joined(separator: ",")].joined(separator: "|")
    }
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
            let edit = r.dayEdits[key(first)]
            var lead = r.leadOverrides[key(first)] ?? (work ? r.workLead : r.otherLead + (first.hasLocation ? r.travelExtra : 0))
            var wake = first.start.addingTimeInterval(TimeInterval(-lead * 60))
            // A time set for this day alone, as long as it's still before the event.
            if let at = edit?.wakeAt, at < first.start.timeIntervalSince1970 {
                wake = Date(timeIntervalSince1970: at)
                lead = Int((first.start.timeIntervalSince(wake) / 60).rounded())
            }
            // Already past: you're either up already or it's too late for an alarm to help.
            guard wake > now else { continue }
            var item = PlannedWake(key: key(first), title: first.title, start: first.start, wake: wake, lead: lead, isWork: work)
            item.skipped = r.skipped.contains(item.key)
            item.custom = r.edited(item.key)
            item.exact = wake.timeIntervalSince1970 == edit?.wakeAt
            if let l = edit?.label?.trimmingCharacters(in: .whitespaces), !l.isEmpty { item.label = l }
            item.own = edit?.own
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

// What the calendar said when a sync began, so it can tell a calendar alarm whose event is really gone from one the plan has
// merely stopped choosing. The plan picks the first thing each day and drops a day whose wake-up is already behind it, so
// an earlier event turning up that day, a longer lead or a different first event all leave the plan without a wake the
// Chumby still holds, sometimes minutes before it rings (11-04: the 14:40 shift wake, removed at 14:00).
struct CalendarKeep {
    var plan: [PlannedWake]            // every planned wake, skipped ones too
    var events: [CalEvent]             // everything read, declined and canceled ones too
    var labels: [String: String] = [:] // a day's own label, by event key: its alarm goes by that name on the Chumby
    // "Wake me from my calendar" switched off by hand: every calendar alarm goes, the next day's too. Left on, it rang
    // the morning after he'd turned the whole thing off.
    var off = false
    // The rules themselves were changed by hand since the last update (how long before work, a word, a calendar): a wake
    // that moved because of that is replaced, not left ringing beside its new time.
    var rulesChanged = false
    enum Verdict { case keep, userChose, gone }
    // For a calendar alarm that's on, due within 24 h, which the plan no longer wants.
    func verdict(_ a: Alarm, due: Date) -> Verdict {
        // Its event: same title, starting after the alarm and no more than 18 hours after it (any lead there is).
        if off { return .userChose }
        func near(_ start: Date) -> Bool { start >= due && start.timeIntervalSince(due) <= 18 * 3600 }
        // Events whose day was given a label this alarm goes by (the event's id, from "id@start", so it's found after the
        // event moves too).
        let labelled = Set(labels.filter { WakePlanner.alarmName(title: $0.value) == a.name }.keys.map { k in k.range(of: "@", options: .backwards).map { String(k[..<$0.lowerBound]) } ?? k })
        func ofLabelled(_ key: String) -> Bool { key.range(of: "@", options: .backwards).map { labelled.contains(String(key[..<$0.lowerBound])) } ?? false }
        // By the name it has now, by its event's title for an alarm made before that day was given a label of its own,
        // or by a label that day was given.
        if let item = plan.first(where: { (WakePlanner.alarmName($0) == a.name || WakePlanner.alarmName(title: $0.title) == a.name || ofLabelled($0.key)) && near($0.start) }) {
            // Turned off for that day, or given that day's own lead, time or label, by hand: the user's call, and the new
            // alarm replaces it.
            if item.skipped || item.custom || rulesChanged { return .userChose }
            // Moved some other way (the event's time, a rule): the old time still rings, beside the new one.
            return .keep
        }
        // Its event by title, or by the label that day was given, so a labelled day's alarm is kept like any other while
        // its event is still there.
        let matching = events.filter { e in
            (WakePlanner.alarmName(title: e.title) == a.name || ofLabelled(WakePlanner.key(e))) && near(e.start)
        }
        if matching.contains(where: { !$0.declined && !$0.canceled }) { return .keep }
        if !matching.isEmpty { return .gone }               // declined or canceled
        // Nothing by that name: deleted, as long as the calendar was really read. An empty read (locked phone, no access
        // yet) proves nothing, so the alarm stays.
        return events.isEmpty ? .keep : .gone
    }
}

extension ChumbyState {
    // Puts the calendar's alarms in the list, sounding like your own, and says what that may cost (see SavePermit).
    // Only calendar alarms are touched. One that's on and due within 24 hours is never dropped just because the plan stopped
    // choosing it; it goes only when its event is deleted, declined or canceled, or the user skipped or re-timed that day.
    // Without `keep`, every such alarm stays.
    mutating func applyCalendar(_ wakes: [PlannedWake], settings: Alarm? = nil, keep: CalendarKeep? = nil) -> SavePermit {
        var permit = SavePermit(calendarOnly: true)
        let mine = alarms.filter { $0.isCalendar }
        // A day with its own sound counts as different until the Chumby holds exactly that sound, marked as its own.
        func sound(_ a: Alarm) -> String { [a.type, a.arg, a.param, a.param_description, a.duration, a.snooze, a.auto_dismiss, a.action, a.action_param].joined(separator: "\u{1}") }
        let have = Set(mine.filter { $0.isOn }.map { $0.time + $0.name + ($0.isOwn ? "\u{2}" + sound($0) : "") })
        let wanted = wakes.map { w -> String in
            var own = Alarm(); if let o = w.own { own.takeSettings(from: o) }
            return WakePlanner.minutes(w.wake) + WakePlanner.alarmName(w) + (w.own != nil ? "\u{2}" + sound(own) : "")
        }
        if have == Set(wanted) && mine.filter({ !$0.isOn }).isEmpty { return permit }
        let want = Set(wakes.map { WakePlanner.minutes($0.wake) + WakePlanner.alarmName($0) })
        // By the Chumby's clock, since that's the one it rings by.
        let clock = chumbyNow ?? Date()
        var held: [Alarm] = []
        for a in mine where a.isOn && !want.contains(a.time + a.name) {
            // Past: the plan decides.
            guard let due = a.nextFire(after: clock) else { continue }
            // More than a day off, the plan decides too, unless the calendar came back empty while it's switched on: a
            // phone that couldn't read it (locked, access lapsed) proves nothing, and Thursday's wake stays.
            guard due.timeIntervalSince(clock) <= 86400 else {
                if let keep, keep.events.isEmpty, !keep.off { held.append(a) }
                continue
            }
            switch keep?.verdict(a, due: due) ?? .keep {
            case .keep: held.append(a)
            case .userChose: permit.userOff.insert(a.key)
            case .gone: permit.deliberate.insert(a.key)
            }
        }
        let others = alarms.filter { !$0.isCalendar }
        // The sound of your repeating alarm, or failing that any alarm with a real sound.
        let real = others.filter { !$0.isPlaceholder && !$0.isHelper }
        let sound = real.first { $0.isOn && $0.when != "once" } ?? real.first { $0.type == "audio" } ?? real.first
        alarms = others
        // Kept exactly as the Chumby holds it.
        for a in held {
            if let free = alarms.firstIndex(where: { $0.isPlaceholder }) { alarms[free] = a } else { alarms.append(a) }
        }
        for w in wakes {
            var a = sound ?? Alarm()
            if sound == nil, let tone = tones.first { a.type = "beep"; a.arg = tone; a.param_description = tone }
            if let settings { a.takeSettings(from: settings) }
            a.name = WakePlanner.alarmName(w); a.enabled = "1"; a.when = "once"; a.time = WakePlanner.minutes(w.wake)
            // Guessed from your own alarm, it only borrows the sound; chosen settings keep their own after-action and backup.
            // (Never the stock backup beeper: the Chumby saves backup 0 whatever it's sent.)
            if settings == nil { a.action = ""; a.action_param = ""; a.backup = "0" }
            // That day's own sound and snooze, kept by the Chumby because it's marked as its own.
            if let o = w.own { a.takeSettings(from: o); a.backup = "0"; if a.backupDelay.isEmpty || a.backupDelay == "0" { a.backupDelay = "5" }; a.own = "1" } else { a.own = "" }
            if let free = alarms.firstIndex(where: { $0.isPlaceholder }) { alarms[free] = a } else { alarms.append(a) }
        }
        return permit
    }
}
