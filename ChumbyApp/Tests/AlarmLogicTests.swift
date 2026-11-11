import Foundation

// Tests for the alarm rules the phone works out for itself: what the Chumby's newest-wins rule will switch off, the safety
// net every save passes, the changes a save applies, the calendar planner and what it may drop, and when an alarm really
// rings. Nothing here touches a Chumby or a calendar. Run with ci/chumby-tests.sh (plain swiftc on the Mac; the files under
// test import only Foundation).

var failures = 0, checks = 0
func expect(_ ok: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !ok() { failures += 1; print("FAIL line \(line): \(what)") }
}
func refused(_ work: () throws -> Void) -> Bool {
    do { try work(); return false } catch ChumbyError.refused { return true } catch { return false }
}
func section(_ name: String) { print("· \(name)") }

// A fixed "now": Wednesday 2026-11-11 09:00 in New York (the script sets TZ), well clear of a clock change.
var ny = Calendar(identifier: .gregorian)
ny.timeZone = TimeZone(identifier: "America/New_York")!
func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date { ny.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
let now = at(2026, 11, 11, 9)
func mins(_ d: Date) -> String { String(Int(d.timeIntervalSince1970 / 60)) }

func alarm(_ name: String, _ when: String, _ time: String, on: Bool = true) -> Alarm {
    var a = Alarm(); a.name = name; a.when = when; a.time = time; a.enabled = on ? "1" : "0"; a.type = "beep"; a.arg = "Beep"
    return a
}
func once(_ name: String, _ d: Date, on: Bool = true) -> Alarm { alarm(name, "once", mins(d), on: on) }
func state(_ alarms: [Alarm], clock: Date = now) -> ChumbyState {
    var s = ChumbyState(); s.alarms = alarms; s.now = clock.timeIntervalSince1970; s.calOverride = 1; s.skipKnown = true; s.reindex()
    return s
}

// MARK: Newest wins
section("newest wins")
do {
    let daily = alarm("omg", "daily", "660"), week = alarm("hell nah", "weekday", "885")
    let cal = once("Calendar: Shift", at(2026, 11, 11, 14, 40)), nap = once("Nap", at(2026, 11, 11, 10))
    let saved = [daily, week, cal, nap]
    let new = alarm("New", "daily", "420")
    expect(ChumbyState.switchedOff(saved: saved, sending: saved + [new]) == [0, 1], "a new alarm switches his other alarms off, never the calendar's or a nap")
    expect(ChumbyState.switchedOff(saved: saved, sending: saved).isEmpty, "nothing new, nothing switched off")
    var off = new; off.enabled = "0"
    expect(ChumbyState.switchedOff(saved: saved, sending: saved + [off]).isEmpty, "an alarm added switched off isn't new")
    expect(ChumbyState.switchedOff(saved: saved + [off], sending: saved + [new]).isEmpty, "switching on an alarm already in the list isn't new (how a just-this-once goes in)")
    let newCal = once("Calendar: Dentist", at(2026, 11, 12, 11))
    expect(ChumbyState.switchedOff(saved: saved, sending: saved + [newCal]).isEmpty, "a calendar alarm never switches the others off")
    var moved = daily; moved.time = "700"
    expect(ChumbyState.switchedOff(saved: saved, sending: [moved, week, cal, nap]) == [1], "an alarm given a new time counts as new")
}

// MARK: The safety net
section("the safety net")
do {
    let soon = once("", at(2026, 11, 11, 10)), later = alarm("omg", "daily", "1320")     // 10:00 today, 22:00 daily
    let cal = once("Calendar: Shift", at(2026, 11, 12, 5))                               // 20 h off
    let saved = [soon, later, cal]
    expect(refused { _ = try AlarmWriter.check(saved: saved, sending: [later, cal], permit: SavePermit(), clock: now) }, "an alarm due within 3 h can't vanish without the user's say")
    expect(!refused { _ = try AlarmWriter.check(saved: saved, sending: [later, cal], permit: SavePermit(userOff: [soon.key]), clock: now) }, "deleted by hand, it may")
    var offSoon = soon; offSoon.enabled = "0"
    expect(refused { _ = try AlarmWriter.check(saved: saved, sending: [offSoon, later, cal], permit: SavePermit(), clock: now) }, "nor be switched off")
    let new = alarm("New", "daily", "420")
    expect(refused { _ = try AlarmWriter.check(saved: saved, sending: saved + [new], permit: SavePermit(), clock: now) }, "a new alarm whose newest-wins would silence one due within 3 h is refused")
    expect(!refused { _ = try AlarmWriter.check(saved: saved, sending: saved + [new], permit: SavePermit(userOff: [soon.key]), clock: now) }, "unless the editor showed it first")
    expect(!refused { _ = try AlarmWriter.check(saved: [later, cal], sending: [later, cal, new], permit: SavePermit(), clock: now) }, "newest-wins on an alarm 13 h off needs no say")
    expect(refused { _ = try AlarmWriter.check(saved: saved, sending: [soon, later], permit: SavePermit(), clock: now) }, "a calendar wake due within 24 h can't be dropped unexplained")
    let force = try? AlarmWriter.check(saved: saved, sending: [soon, later], permit: SavePermit(deliberate: [cal.key]), clock: now)
    expect(force == true, "a calendar wake whose event is gone is dropped on purpose, and says so to the Chumby")
    let far = once("Calendar: Shift", at(2026, 11, 14, 5))
    let noForce = try? AlarmWriter.check(saved: [far], sending: [], permit: SavePermit(), clock: now)
    expect(noForce == false, "one three days off is the plan's to drop")
    // A calendar update may touch nothing else.
    let only = SavePermit(calendarOnly: true)
    expect(refused { _ = try AlarmWriter.check(saved: [later, cal], sending: [cal], permit: only, clock: now) }, "a calendar update can't remove another alarm")
    var laterOff = later; laterOff.enabled = "0"
    expect(refused { _ = try AlarmWriter.check(saved: [later, cal], sending: [laterOff, cal], permit: only, clock: now) }, "nor switch one off")
    let stale = once("Old", at(2026, 11, 10, 9))
    expect(!refused { _ = try AlarmWriter.check(saved: [stale, later, cal], sending: [later, cal], permit: only, clock: now) }, "a one-off long past may be cleared along the way")
    expect(ChumbyState.isExpired(stale, chumby: now) && !ChumbyState.isExpired(once("x", at(2026, 11, 11, 8)), chumby: now), "expired means two hours past, by the Chumby's clock")
    expect(!ChumbyState.isExpired(stale, chumby: nil), "with no Chumby clock nothing counts as expired")
}

// MARK: Reading the list
section("reading the list")
do {
    let a = alarm("omg", "daily", "660"), b = once("x (just this once)", at(2026, 11, 11, 10, 10), on: false)
    var bOn = b; bOn.enabled = "1"
    let expected = AlarmWriter.listed([a, b])
    expect(!AlarmWriter.trusts(read: [a], expected: expected, since: 0.1), "a copy from before the last save isn't trusted straight after it")
    expect(AlarmWriter.trusts(read: [a, b], expected: expected, since: 0.1), "the list that save left is")
    expect(!AlarmWriter.trusts(read: [a, bOn], expected: expected, since: 1), "on and off are told apart")
    expect(AlarmWriter.trusts(read: [a], expected: expected, since: 7), "after a few seconds the Chumby's own word stands")
    expect((try? AlarmWriter.strict(Data(#"{"ok":true}"#.utf8))) == nil, "an answer with no alarm list isn't a list of no alarms")
    expect((try? AlarmWriter.strict(Data(#"{"ok":true,"alarms":[]}"#.utf8))) == nil, "nor one without the Chumby's clock")
    expect((try? AlarmWriter.strict(Data(#"{"ok":true,"now":1794361993,"alarms":[{"name":"omg","enabled":"1","time":"660","when":"daily"}]}"#.utf8)))?.alarms.count == 1, "a whole answer is read")
    expect((try? AlarmWriter.strict(Data("<html>502</html>".utf8))) == nil, "an error page isn't a state")
    var s = state([]); s.now = 100
    expect(!ChumbyState.answered(s, since: Date(timeIntervalSince1970: 100)) && ChumbyState.answered(s, since: Date(timeIntervalSince1970: 99)), "an answer counts only if made after the request")
}

// MARK: Changes
section("changes")
do {
    let a = alarm("omg", "daily", "660", on: false), b = alarm("hell nah", "weekday", "885")
    var s = state([a, b])
    AlarmChange.toggle(a, true).apply(&s)
    expect(s.alarms[0].isOn, "toggle on")
    AlarmChange.toggle(a, true).apply(&s)
    expect(s.alarms.count == 2 && s.alarms[0].isOn, "the same change twice does nothing more")
    let ghost = alarm("gone", "daily", "100", on: false)
    expect(AlarmChange.toggle(ghost, true).refusal(in: s) != nil, "switching on an alarm that isn't there is refused, not counted as done")
    expect(AlarmChange.toggle(ghost, false).refusal(in: s) == nil && AlarmChange.delete(ghost).refusal(in: s) == nil, "switching off or deleting what's gone is already done")
    expect(AlarmChange.toggle(a, true).refusal(in: s) == nil, "one that's there is fine")
    var moved = b; moved.time = "900"
    AlarmChange.replace(b, moved).apply(&s)
    expect(s.alarms.count == 2 && s.alarms[1].time == "900", "replace edits in place")
    AlarmChange.delete(moved).apply(&s)
    expect(s.alarms.count == 1, "delete")
    AlarmChange.add(b).apply(&s); AlarmChange.add(b).apply(&s)
    expect(s.alarms.count == 2, "add once")
    // A placeholder is reused before the list grows.
    var p = Alarm(); p.enabled = "0"; p.time = "0"; p.name = ""; p.type = "beep"
    var t = state([p, b])
    AlarmChange.add(alarm("n", "daily", "1")).apply(&t)
    expect(t.alarms.count == 2 && t.alarms[0].name == "n", "an empty place is used first")
    expect(AlarmChange.toggle(a, false).permit(in: s).userOff == [a.key] && AlarmChange.toggle(a, true).permit(in: s).userOff.isEmpty, "only switching off is a loss by hand")
}

section("naps")
do {
    let real = Int(Date().timeIntervalSince1970 / 60)
    var s = state([alarm("omg", "daily", "660")], clock: Date())
    s.addNap(at: real + 20)
    expect(s.alarms.filter { $0.name == "Nap" }.count == 1, "a nap is one alarm")
    let first = s.alarms.first { $0.name == "Nap" }!
    expect(first.backup == "0" && first.backupDelay == "5" && first.when == "once", "never the stock backup beeper, and a delay the Chumby accepts")
    s.addNap(at: real + 20)
    expect(s.alarms.filter { $0.name == "Nap" }.count == 1, "the same minute twice is one nap (the 11-05 double ring)")
    let saved = s.alarms
    let permit = s.napPermit()
    s.addNap(at: real + 40)
    expect(s.alarms.filter { $0.name == "Nap" }.count == 1 && s.alarms.contains { $0.name == "Nap" && $0.time == String(real + 40) }, "a new nap replaces the one still to come")
    expect(!refused { _ = try AlarmWriter.check(saved: saved, sending: s.alarms, permit: permit, clock: Date()) }, "a second nap from the control passes the safety net")
    expect(refused { _ = try AlarmWriter.check(saved: saved, sending: s.alarms, permit: SavePermit(), clock: Date()) }, "which, unsaid, would refuse it (the bug)")
    expect(ChumbyState.switchedOff(saved: saved, sending: s.alarms).isEmpty, "a nap never switches his alarms off")
    AlarmChange.cancelNap.apply(&s)
    expect(!s.alarms.contains { $0.name == "Nap" }, "cancel removes it")
    // A nap already ringing (its minute has passed) is left to finish.
    var r = state([once("Nap", Date().addingTimeInterval(-120))], clock: Date())
    r.addNap(at: real + 30)
    expect(r.alarms.filter { $0.name == "Nap" }.count == 2, "a nap that's already gone off is left alone")
}

// MARK: When it rings
section("when it rings")
do {
    // Wed 11 Nov 2026, 09:00.
    expect(alarm("", "daily", "660").nextFire(after: now, calendar: ny) == at(2026, 11, 11, 11), "daily, later today")
    expect(alarm("", "daily", "480").nextFire(after: now, calendar: ny) == at(2026, 11, 12, 8), "daily, already past today")
    expect(alarm("", "weekend", "480").nextFire(after: now, calendar: ny) == at(2026, 11, 14, 8), "weekend is Saturday")
    expect(alarm("", "weekday", "480").nextFire(after: at(2026, 11, 13, 9), calendar: ny) == at(2026, 11, 16, 8), "weekday skips the weekend")
    expect(alarm("", "sunday", "480").nextFire(after: now, calendar: ny) == at(2026, 11, 15, 8), "a named day")
    expect(alarm("", "wednesday", "480").nextFire(after: now, calendar: ny) == at(2026, 11, 18, 8), "today's, already past, is next week")
    expect(alarm("", "daily", "660", on: false).nextFire(after: now, calendar: ny) == nil, "off never rings")
    expect(once("", at(2026, 11, 11, 8)).nextFire(after: now, calendar: ny) == nil, "a one-off in the past never rings")
    // Clocks forward, Sunday 8 March 2026: 2:30 doesn't exist, and the alarm rings at the next time that does.
    let spring = alarm("", "daily", "150").nextFire(after: at(2026, 3, 7, 12), calendar: ny)
    expect(spring != nil && spring! >= at(2026, 3, 8, 3) && spring! <= at(2026, 3, 8, 3, 30), "an alarm in the missing hour rings just after it, not a day late")
    expect(alarm("", "daily", "420").nextFire(after: at(2026, 3, 7, 12), calendar: ny) == at(2026, 3, 8, 7), "7:00 stays 7:00 by the clock across the change")
    expect(at(2026, 3, 8, 7).timeIntervalSince(at(2026, 3, 7, 7)) == 23 * 3600, "(that night really is an hour short)")
    // Clocks back, Sunday 1 November 2026: 1:30 happens twice, and it rings once, the first time.
    let fall = alarm("", "daily", "90").nextFire(after: at(2026, 10, 31, 12), calendar: ny)!
    expect(alarm("", "daily", "90").nextFire(after: fall, calendar: ny)! .timeIntervalSince(fall) > 23 * 3600, "an alarm in the repeated hour rings once that night")
}

section("away from home")
do {
    // The phone (the script's TZ) is in New York; the Chumby says it's five hours ahead (London in winter).
    let day = alarm("", "daily", "420")                                      // 7:00 by the Chumby's clock
    let t = at(2026, 11, 11, 9).timeIntervalSince1970                        // 09:00 New York = 14:00 London
    ChumbyClock.note(local: "2026-11-11T14:00", now: t)
    expect(day.nextFire(after: now) == at(2026, 11, 12, 2), "a 7:00 alarm rings at 7:00 where the Chumby is (2 AM for the phone), not 7:00 where the phone is")
    ChumbyClock.note(local: "2026-11-11T09:00", now: t)
    expect(day.nextFire(after: now) == at(2026, 11, 12, 7), "at home the phone's own calendar is used")
    ChumbyClock.note(local: "2026-11-11T09:07", now: t + 400)
    expect(day.nextFire(after: now) == at(2026, 11, 12, 7), "a few seconds between the two clocks is not another time zone")
    ChumbyClock.note(local: "garbage", now: t)
    expect(day.nextFire(after: now) == at(2026, 11, 12, 7), "an unreadable clock changes nothing")
    ChumbyClock.reset()
    var tone = alarm("x", "daily", "420"); tone.auto_dismiss = "1"
    var music = tone; music.type = "audio"; music.arg = "pandora"
    let form = state([tone, music]).alarmForm()
    expect(form.contains { $0.0 == "0_auto_dismiss" && $0.1 == "0" } && form.contains { $0.0 == "1_auto_dismiss" && $0.1 == "1" }, "a tone is never saved as ending by itself (it wouldn't ring); music may be")
}

section("calendar days and the skip")
do {
    let daily = alarm("omg", "daily", "660")                                   // 11:00
    let cal = once("Calendar: Shift", at(2026, 11, 11, 14, 40))
    var s = state([daily, cal])
    expect(s.ring(of: daily, after: now) == at(2026, 11, 12, 11), "on a calendar day the repeating alarm is passed over")
    expect(s.nextRing(after: now)?.alarm.name == "Calendar: Shift", "so the calendar's is what rings next")
    s.calOverride = 0
    expect(s.ring(of: daily, after: now) == at(2026, 11, 11, 11), "unless he switched that off")
    s.calOverride = 1
    var offCal = cal; offCal.enabled = "0"
    expect(state([daily, offCal]).ring(of: daily, after: now) == at(2026, 11, 11, 11), "a calendar alarm that's off keeps nothing quiet")
    let oneOff = once("Dentist", at(2026, 11, 11, 10))
    expect(state([oneOff, cal]).ring(of: oneOff, after: now) == at(2026, 11, 11, 10), "a one-off of his own still rings on a calendar day")
    // The one skip, pinned to one ring.
    var k = state([daily])
    k.skipped = SkippedAlarm(name: "omg", at: at(2026, 11, 11, 11).timeIntervalSince1970, when: "daily")
    expect(k.ring(of: daily, after: now) == at(2026, 11, 12, 11), "the skipped ring is passed over, once")
    expect(k.ring(of: daily, after: now, skip: false) == at(2026, 11, 11, 11), "and can be asked for all the same")
    let other = alarm("other", "daily", "660")
    k.alarms.append(other)
    expect(k.ring(of: other, after: now) == at(2026, 11, 11, 11), "another alarm at the same minute isn't skipped with it")
}

section("just this once")
do {
    let usual = alarm("omg", "daily", "660")
    var one = once(JustOnce.name(for: usual), at(2026, 11, 11, 11, 20))
    var s = state([usual, one])
    s.skipped = SkippedAlarm(name: "omg", at: at(2026, 11, 11, 11).timeIntervalSince1970, when: "daily")
    var j = s.justOnce(now: now)
    expect(j?.pinned == true && j?.original?.name == "omg" && j?.usual == at(2026, 11, 11, 11), "a one-off behind its skip is found with the alarm it stands in for")
    expect(s.nextRing(after: now)?.at == at(2026, 11, 11, 11, 20), "and it's what rings next")
    s.skipped = nil
    j = s.justOnce(now: now)
    expect(j?.pinned == false && j?.usual != nil, "without the skip, both would ring, and it's known")
    one.enabled = "0"
    expect(state([usual, one]).justOnce(now: now) == nil, "a one-off that's switched off stands in for nothing")
    let unnamed = alarm("", "daily", "600")
    expect(JustOnce.name(for: unnamed) == "10:00 AM alarm (just this once)", "an unnamed alarm's one-off is named by its time")
    expect(JustOnce.isOne(once("x (just this once)", now)) && !JustOnce.isOne(alarm("x (just this once)", "daily", "1")), "only a one-off is one")
}

// MARK: The calendar planner
section("the calendar planner")
func event(_ id: String, _ title: String, _ start: Date, hours: Double = 8, cal: String = "Home", allDay: Bool = false) -> CalEvent {
    CalEvent(id: id, title: title, calendar: cal, start: start, end: start.addingTimeInterval(hours * 3600), allDay: allDay)
}
do {
    var r = WakeRules(); r.enabled = true            // work 160 min, other 90, travel +30, 3 days ahead
    let shift = event("s1", "CR Shift: Screener", at(2026, 11, 11, 18))
    var p = WakePlanner.plan([shift], rules: r, now: now, calendar: ny)
    expect(p.count == 1 && p[0].wake == at(2026, 11, 11, 15, 20) && p[0].isWork, "work wakes 2 h 40 min before")
    var dentist = event("d1", "Dentist", at(2026, 11, 12, 13), hours: 1)
    p = WakePlanner.plan([dentist], rules: r, now: now, calendar: ny)
    expect(p[0].wake == at(2026, 11, 12, 11, 30) && !p[0].isWork, "anything else 1 h 30 min before")
    dentist.hasLocation = true
    expect(WakePlanner.plan([dentist], rules: r, now: now, calendar: ny)[0].wake == at(2026, 11, 12, 11), "plus travel when it has a place")
    expect(WakePlanner.mentions("Workout", ["work"]) == false && WakePlanner.mentions("Work: late", ["work"]) && WakePlanner.mentions("My Day Off!", ["day off"]), "words match whole words only")
    // One wake a day: the first thing.
    p = WakePlanner.plan([event("a", "Dentist", at(2026, 11, 12, 10), hours: 1), event("s2", "Shift", at(2026, 11, 12, 18))], rules: r, now: now, calendar: ny)
    expect(p.count == 1 && p[0].title == "Dentist", "one wake a day, for the first thing")
    // The first thing's wake already past: nothing planned for that day (the Chumby keeps the shift's wake; see keep).
    p = WakePlanner.plan([event("a", "Dentist", at(2026, 11, 11, 9, 30), hours: 1), shift], rules: r, now: now, calendar: ny)
    expect(p.isEmpty, "a day whose first wake has passed plans nothing")
    // Days off.
    let off = event("o", "Day off", at(2026, 11, 12, 0), hours: 24, allDay: true)
    p = WakePlanner.plan([off, event("s3", "Shift", at(2026, 11, 12, 18)), event("d2", "Dentist", at(2026, 11, 12, 19), hours: 1)], rules: r, now: now, calendar: ny)
    expect(p.count == 1 && p[0].title == "Dentist", "a day off cancels work, and the dentist still happens")
    // Things that never wake.
    var free = event("f", "Shift", at(2026, 11, 12, 18)); free.free = true
    var declined = event("g", "Shift", at(2026, 11, 13, 18)); declined.declined = true
    var canceled = event("h", "Shift", at(2026, 11, 14, 18)); canceled.canceled = true
    expect(WakePlanner.plan([free, declined, canceled, event("b", "Mum's birthday", at(2026, 11, 12, 12))], rules: r, now: now, calendar: ny).isEmpty, "free, declined, canceled and ignored words never wake")
    var ex = r; ex.excludedCalendars = ["Home"]
    expect(WakePlanner.plan([shift], rules: ex, now: now, calendar: ny).isEmpty, "nor a calendar switched off")
    var wc = r; wc.workCalendars = ["Rota"]
    expect(WakePlanner.plan([event("x", "Screener", at(2026, 11, 12, 18), cal: "Rota")], rules: wc, now: now, calendar: ny)[0].isWork, "a work calendar makes everything in it work")
    // The small hours: a 4 AM shift is its own day unless he's up for it anyway.
    let dinner = event("e", "Dinner", at(2026, 11, 11, 19), hours: 2), early = event("z", "Shift", at(2026, 11, 12, 4))
    p = WakePlanner.plan([dinner, early], rules: r, now: now, calendar: ny)
    expect(p.count == 2 && p[1].wake == at(2026, 11, 12, 1, 20), "a 4 AM shift after an evening out gets its own alarm")
    expect(p[1].shortNight != nil, "and the short night is said")
    let party = event("e2", "Party", at(2026, 11, 11, 22), hours: 5)
    p = WakePlanner.plan([party, event("z2", "Afters", at(2026, 11, 12, 3, 30), hours: 1)], rules: r, now: now, calendar: ny)
    expect(p.count == 1 && p[0].title == "Party", "something at 3:30 AM that the night runs into belongs to the night before")
    // How far ahead.
    let many = (0..<6).map { event("m\($0)", "Shift", at(2026, 11, 12 + $0, 18)) }
    expect(WakePlanner.plan(many, rules: r, now: now, calendar: ny).count == 3, "three wake-ups ahead by default")
    // A day's own choices.
    var e = r; let key = WakePlanner.key(shift)
    e.leadOverrides[key] = 200
    expect(WakePlanner.plan([shift], rules: e, now: now, calendar: ny)[0].wake == at(2026, 11, 11, 14, 40), "a day's own lead")
    e.dayEdits[key] = DayEdit(wakeAt: at(2026, 11, 11, 15).timeIntervalSince1970, label: "Early")
    p = WakePlanner.plan([shift], rules: e, now: now, calendar: ny)
    expect(p[0].wake == at(2026, 11, 11, 15) && p[0].exact && p[0].custom && WakePlanner.alarmName(p[0]) == "Calendar: Early", "a day's own time and label")
    e.dayEdits[key] = DayEdit(wakeAt: at(2026, 11, 11, 19).timeIntervalSince1970)
    expect(WakePlanner.plan([shift], rules: e, now: now, calendar: ny)[0].wake == at(2026, 11, 11, 14, 40), "a set time after the event starts is ignored")
    e = r; e.skipped = [key]
    expect(WakePlanner.plan([shift], rules: e, now: now, calendar: ny)[0].skipped, "a day switched off stays in the plan, marked")
    expect(WakePlanner.alarmName(title: "CR Shift: Screener / Backup Expediter") == "Calendar: CR Shift: Screener / Backup Ex", "long titles are cut the way the Chumby holds them")
    var changed = r; changed.workLead = 200
    var skippedOnly = r; skippedOnly.skipped = ["x"]
    expect(WakePlanner.signature(changed) != WakePlanner.signature(r) && WakePlanner.signature(skippedOnly) == WakePlanner.signature(r), "a rule change is told from a day's own choice")
}

section("what a calendar update may drop")
do {
    var r = WakeRules(); r.enabled = true
    let shift = event("s1", "Shift", at(2026, 11, 11, 18))
    let held = once("Calendar: Shift", at(2026, 11, 11, 15, 20))
    let due = at(2026, 11, 11, 15, 20)
    // The 11-04 case: an earlier event that day, its wake already past, so the plan has nothing for the day.
    let dentist = event("a", "Dentist", at(2026, 11, 11, 9, 30), hours: 1)
    var plan = WakePlanner.plan([dentist, shift], rules: r, now: now, calendar: ny)
    expect(CalendarKeep(plan: plan, events: [dentist, shift]).verdict(held, due: due) == .keep, "the plan stopped choosing it, the shift is still on: the wake stays")
    expect(CalendarKeep(plan: [], events: [dentist]).verdict(held, due: due) == .gone, "its event deleted: it goes")
    var declined = shift; declined.declined = true
    expect(CalendarKeep(plan: [], events: [declined]).verdict(held, due: due) == .gone, "declined: it goes")
    expect(CalendarKeep(plan: [], events: []).verdict(held, due: due) == .keep, "a calendar that read as empty proves nothing")
    var s = r; s.skipped = [WakePlanner.key(shift)]
    plan = WakePlanner.plan([shift], rules: s, now: now, calendar: ny)
    expect(CalendarKeep(plan: plan, events: [shift]).verdict(held, due: due) == .userChose, "switched off for that day by hand: the user's call")
    // The rule changed by hand: 2 h 40 becomes 3 h 20, and the old time must not ring beside the new.
    var longer = r; longer.workLead = 200
    plan = WakePlanner.plan([shift], rules: longer, now: now, calendar: ny)
    expect(CalendarKeep(plan: plan, events: [shift]).verdict(held, due: due) == .keep, "a wake that moved for no known reason still rings at its old time too")
    expect(CalendarKeep(plan: plan, events: [shift], rulesChanged: true).verdict(held, due: due) == .userChose, "moved because he changed the rule: replaced")
    expect(CalendarKeep(plan: plan, events: [shift], off: true).verdict(held, due: due) == .userChose, "the calendar switched off by hand: it goes")

    // The whole update, on a list.
    let mine = alarm("omg", "daily", "660", on: false)
    var tpl = Alarm(); tpl.type = "audio"; tpl.arg = "pandora"; tpl.param = "1##Station"; tpl.param_description = "Station"; tpl.snooze = "9"
    plan = WakePlanner.plan([shift], rules: r, now: now, calendar: ny)
    var st = state([mine])
    var permit = st.applyCalendar(plan, settings: tpl, keep: CalendarKeep(plan: plan, events: [shift]))
    expect(st.alarms.count == 2 && st.alarms[1].name == "Calendar: Shift" && st.alarms[1].time == mins(due) && st.alarms[1].arg == "pandora" && st.alarms[1].backup == "0", "a wake is added, ringing with the calendar's own set")
    expect(permit.calendarOnly && !refused { _ = try AlarmWriter.check(saved: [mine], sending: st.alarms, permit: permit, clock: now) }, "and passes the safety net")
    let before = ChumbyAPI.form(st.alarmForm())
    _ = st.applyCalendar(plan, settings: tpl, keep: CalendarKeep(plan: plan, events: [shift]))
    expect(ChumbyAPI.form(st.alarmForm()) == before, "the same plan again changes nothing, so nothing is saved")
    // The plan drops the day (the 11-04 case): the Chumby keeps the wake.
    let saved = st.alarms
    plan = WakePlanner.plan([dentist, shift], rules: r, now: now, calendar: ny)
    permit = st.applyCalendar(plan, settings: tpl, keep: CalendarKeep(plan: plan, events: [dentist, shift]))
    expect(st.alarms.contains { $0.name == "Calendar: Shift" && $0.isOn }, "a wake due today survives the plan dropping its day")
    expect(!refused { _ = try AlarmWriter.check(saved: saved, sending: st.alarms, permit: permit, clock: now) }, "(and that save is allowed)")
    // An empty read never clears a wake, near or far.
    let thursday = once("Calendar: Shift", at(2026, 11, 13, 15, 20))
    var far = state([mine, held, thursday])
    _ = far.applyCalendar([], settings: tpl, keep: CalendarKeep(plan: [], events: []))
    expect(far.alarms.filter { $0.isCalendar && $0.isOn }.count == 2, "a calendar read as empty leaves every wake, the one days off too")
    // Switched off by hand: all go, with his say.
    var offState = state([mine, held, thursday])
    permit = offState.applyCalendar([], settings: tpl, keep: CalendarKeep(plan: plan, events: [shift], off: true))
    expect(!offState.alarms.contains { $0.isCalendar } && permit.userOff.contains(held.key), "the calendar switched off takes its alarms with it")
    expect(!refused { _ = try AlarmWriter.check(saved: [mine, held, thursday], sending: offState.alarms, permit: permit, clock: now) }, "(allowed, as his own doing)")
    expect(offState.alarms.contains { $0.same(mine) }, "his own alarm is untouched throughout")
    // With the calendar's alarms gone, the day is no longer a calendar day: a repeating alarm of his that's on rings
    // again that very day. One he switched off stays off (nothing switches an alarm on for him), and then nothing is
    // set, which the Alarms card says ("No alarm set. Sleep in.").
    let daily = alarm("daily", "daily", "900")                                  // 15:00, on
    expect(state([daily, held]).ring(of: daily, after: now) == at(2026, 11, 12, 15), "(with the calendar's wake there, his repeating alarm waits a day)")
    var gone = state([daily, mine, held])
    _ = gone.applyCalendar([], settings: tpl, keep: CalendarKeep(plan: plan, events: [shift], off: true))
    expect(gone.ring(of: daily, after: now) == at(2026, 11, 11, 15), "the calendar switched off gives his repeating alarm its day back")
    expect(offState.nextRing(after: now) == nil, "with only alarms he'd switched off left, nothing is set, and that's what is shown")
    // A day's own sound is marked as its own.
    var own = Alarm(); own.type = "beep"; own.arg = "Chime"; own.param_description = "Chime"; own.snooze = "15"
    var e = r; e.dayEdits[WakePlanner.key(shift)] = DayEdit(own: own)
    plan = WakePlanner.plan([shift], rules: e, now: now, calendar: ny)
    var o = state([mine])
    _ = o.applyCalendar(plan, settings: tpl, keep: CalendarKeep(plan: plan, events: [shift]))
    expect(o.alarms[1].isOwn && o.alarms[1].arg == "Chime" && o.alarms[1].snooze == "15", "a day's own sound is kept and marked")
    expect(o.alarmForm().contains { $0.0 == "1_own" && $0.1 == "1" }, "and every save says so, or the Chumby puts the shared set back")
}

print(failures == 0 ? "ok: \(checks) checks" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
