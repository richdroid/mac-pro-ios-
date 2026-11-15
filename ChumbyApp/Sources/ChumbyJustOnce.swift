import SwiftUI

// MARK: - Just this once
// An alarm's next ring, later or with another sound, for that one ring only (Richard, 2026-11-07: "like one instance of an
// alarm like say im tired and want more time before it goes off or a diff sound"). Built from what the Chumby does:
// - a one-off at the new time with the chosen sound, named "<alarm> (just this once)". It's saved switched off first and
//   then switched on, with the same name, repeat and time both times, so the Chumby's newest_wins never counts it as a new
//   alarm and never turns the others off (do_save only counts an alarm that's on and whose name|when|time wasn't in the
//   saved list; confirmed by the device session 11-07);
// - then the Chumby's skip, pinned by name to that alarm's ring (a=skip name=&at=, chumby 2c90cc9), and checked against
//   the Chumby's own answer.
// The order means a failure never leaves silence: until the skip lands, both ring. Since 2c90cc9 a one-off at the same
// minute rings (the hook's same-minute rule only skips a copy with the same name), so it may keep the usual time and only
// change the sound.
// The Chumby holds only one skip at a time: a new one replaces it, earlier or later. So starting one while another skip
// is set says so first, and then takes the old one back properly (its one-off removed, so its alarm rings as usual).
// JustOnce, JustOnceNow and ChumbyState.justOnce() live in ChumbyAPI.swift, which the widgets compile too.

extension ChumbyModel {
    // What the Chumby's one skip is on now, said for the warning before something replaces it, or nil with none set.
    var pinWarning: String? {
        guard let s = state.skipped, s.date > Date() else { return nil }
        let t = s.date.formatted(date: .omitted, time: .shortened)
        let name = s.name.hasPrefix(Alarm.calendarPrefix) ? String(s.name.dropFirst(Alarm.calendarPrefix.count)) : (s.name.isEmpty ? "your \(t) alarm" : s.name)
        if let j = state.justOnce(), j.pinned {
            return "This replaces your “just this once” for \(name): \(name) rings at \(t) again and its \(j.at.formatted(date: .omitted, time: .shortened)) ring is removed."
        }
        return "This replaces your skip of \(name) at \(t); that alarm will ring again."
    }
    // Whether "just this once" can be offered for alarm `a`'s next ring (or, with none given, the next alarm to ring), and
    // the ring it would change. From Home and the Alarms hero it's hidden while a skip is set, since the card shows that
    // skip; from an alarm's editor it's offered with `warning`, since it would replace that skip.
    enum JustOnceOffer { case hidden, note(String), ok(alarm: Alarm, due: Date, warning: String?) }
    func justOnceOffer(for a: Alarm? = nil) -> JustOnceOffer {
        guard stateKnown, state.skipKnown, !unreachable else { return .hidden }
        if let j = state.justOnce(), j.orphan { return .hidden }   // fixed first, where it's shown
        let target: (alarm: Alarm, at: Date)
        if let a {
            guard a.isOn, !a.isHelper, !JustOnce.isOne(a), let d = state.ring(of: a) else { return .hidden }
            target = (a, d)
        } else {
            guard sys.ringing == nil, state.skipped.map({ $0.date > Date() }) != true, let n = nextRing(), !n.alarm.isHelper, !JustOnce.isOne(n.alarm) else { return .hidden }
            target = n
        }
        if let r = sys.ringing, r.name == target.alarm.name { return .note("It’s ringing now. Snooze or stop it on the card above.") }
        if target.at.timeIntervalSinceNow < 180 { return .note("It’s about to ring, so it can’t be changed now. Snooze it when it does.") }
        // A calendar day moves its own alarm (moveDay): no skip is involved, so nothing is replaced.
        return .ok(alarm: target.alarm, due: target.at, warning: target.alarm.isCalendar ? nil : pinWarning)
    }

    // Puts `original`'s ring at `due` at `at` with `settings` (its sound, length and snooze), for that ring only. With
    // `replacing`, the user has seen pinWarning and the skip already set is replaced: its "just this once", if any, is
    // removed once the new skip has landed. Nil once it's all on the Chumby; otherwise why not, never leaving an alarm quiet
    // that the user didn't change.
    func justOnce(_ original: Alarm, due: Date, at: Date, settings: Alarm, replacing: Bool = false) async -> String? {
        guard let api else { return "No Chumby address set." }
        tick()
        let late = at.timeIntervalSince(due)
        // One of his own alarms only ever later (its usual ring is skipped and a one-off stands in for it); a calendar
        // day's alarm is moved by the calendar's own update, which has its own limits (before the event, not too soon).
        guard original.isCalendar || late >= 0, late <= Double(JustOnce.longest * 60) else { return "Pick a time from \(due.formatted(date: .omitted, time: .shortened)), on the same night." }
        // A calendar day is one alarm of its own already: that day's time (and sound) simply change, through the
        // calendar's own update, in one save. No skip, no second alarm, nothing for the panel's reload to lose (11-08:
        // his "just this once" on the shift's alarm went through the skip path and came back with an error).
        if original.isCalendar {
            let wake = CalendarWake.shared
            func day() -> PlannedWake? { wake.plan.first { CalendarWake.alarmName($0) == original.name && abs($0.wake.timeIntervalSince(due)) < 60 } }
            if day() == nil { wake.refreshPlan() }     // from Home before Alarms has been opened, the plan may not be worked out yet
            if let item = day() { return await wake.moveDay(item, to: at, settings: settings, current: deviceState.alarms.first { $0.key == original.key }) }
        }
        guard late >= 0 else { return "It can ring later than usual, not earlier. Nothing was changed." }
        // Fresh from the Chumby: that ring is still ahead and not about to ring, and what the one skip is on now.
        var old: JustOnceNow?
        do {
            let s = try JSONDecoder().decode(ChumbyState.self, from: await api.fresh("state"))
            let pending = s.skipped.map { $0.date > Date() } == true
            guard !pending || replacing else { return "Another alarm is already skipped. Nothing was changed." }
            guard let d = s.ring(of: original), abs(d.timeIntervalSince(due)) < 60 else { return "That alarm’s next ring has changed. Nothing was changed." }
            guard due.timeIntervalSinceNow >= 180 else { return "It’s about to ring, so nothing was changed. Snooze it when it does." }
            if let j = s.justOnce() {
                guard j.pinned else { return "Sort out the one set just this once first. Nothing was changed." }
                old = j
            }
        } catch { return AlarmWriter.explain(error) }
        var one = settings
        one.name = JustOnce.name(for: original)
        one.own = ""
        one.enabled = "1"; one.when = "once"; one.time = String(Int((at.timeIntervalSince1970 / 60).rounded())); one.backup = "0"
        if one.backupDelay.isEmpty || one.backupDelay == "0" { one.backupDelay = "5" }
        if old?.alarm.key == one.key { return "That’s already set just this once." }
        // In one request where the Chumby can (a=once): the one-off added and the usual ring skipped in a few seconds,
        // rather than three saves and a skip over 20 to 70. An older Chumby goes the long way below.
        switch await onceInOne(original, due: due, one: one) {
        case .done:
            if let old, old.alarm.key != one.key, old.alarm.name != one.name {
                if let why = await save(.delete(old.alarm)) { return "Set. But the earlier \(old.at.formatted(date: .omitted, time: .shortened)) ring couldn’t be removed, so it rings too: \(why)" }
            }
            return nil
        case .failed(let why): return why
        case .older: break
        }
        // 1. Kept switched off, so it's not a new alarm when it's switched on.
        var off = one; off.enabled = "0"
        if let why = await save(.add(off)) { return why }
        // 2. Switched on: now both ring.
        if let why = await save(.toggle(off, true)) {
            _ = await save(.delete(off))
            return why
        }
        // The two saves just sent the panel back to its list; it answers no skip until that's in. Wait for it.
        await waitForPanel()
        // The usual ring is only skipped once the Chumby itself shows the one-off there and switched on. Anything else
        // (on 11-10 a 10:10 one-off was found left switched off on the Chumby, the mark of a save built on an old copy)
        // stops here, with the usual alarm untouched.
        guard let now = try? AlarmWriter.strict(await api.fresh("state")), now.alarms.contains(where: { $0.key == one.key && $0.isOn }) else {
            _ = await save(.delete(one))
            return "The Chumby didn’t take the new time, so nothing was changed. Your usual alarm rings."
        }
        // 3. The usual ring skipped, checked against the Chumby's own answer.
        if let why = await skipFor(original, due: due) {
            // Couldn't: take the one-off away again, so it's as it was rather than ringing twice.
            let lost = replacing ? " The earlier skip may be gone too, so that alarm may ring." : ""
            if let w = await save(.delete(one)) { return "\(why) Both will ring: \(w)\(lost)" }
            return "\(why) Nothing else was changed.\(lost)"
        }
        // 4. The skip it replaced no longer stands, so its one-off goes and its alarm rings as usual.
        if let old {
            if let why = await save(.delete(old.alarm)) { return "Set. But the earlier \(old.at.formatted(date: .omitted, time: .shortened)) ring couldn’t be removed, so it rings too: \(why)" }
        }
        return nil
    }
    enum OnceOutcome { case done, older, failed(String) }
    // The Chumby's own "just this once" (a=once, chumby 9d3c1a1): it writes the one-off into its list switched on, with
    // no other alarm touched, and asks its panel to skip the usual ring, in that order, so a failure part-way leaves
    // both ringing. Whatever it answers (or if the answer is lost on the way), the Chumby's state is then read until it
    // shows both the one-off switched on and the skip on that ring; only that counts as done. The one-off there
    // without its skip is taken away again, so it's as it was; the skip never stands without the one-off.
    private func onceInOne(_ original: Alarm, due: Date, one: Alarm) async -> OnceOutcome {
        guard let api else { return .failed("No Chumby address set.") }
        let minute = Int((due.timeIntervalSince1970 / 60).rounded())
        let body = ChumbyAPI.form([("name", original.name), ("at", "\(minute)"), ("to", one.time), ("oname", one.name),
                                   ("type", one.type), ("arg", one.arg), ("param", one.param), ("param_description", one.param_description),
                                   ("duration", one.duration), ("snooze", one.snooze), ("auto_dismiss", one.auto_dismiss)])
        hold(12)
        var lost = false
        do {
            // A token the Chumby no longer takes is asked for again, once (post forgets it on that answer).
            do { try await api.post("once", body: body) }
            catch ChumbyError.message(let m) where m.contains("token") { try await api.post("once", body: body) }
        }
        catch ChumbyError.message(let m) where m == "unknown action" { return .older }
        // Turned down by the Chumby in its own words: nothing was changed.
        catch ChumbyError.message(let m) where m != "No answer from the Chumby." { return .failed(AlarmWriter.explain(ChumbyError.message(m))) }
        catch { lost = true }      // no answer: it may still have been done, so the state decides
        func there(_ s: ChumbyState) -> Bool { s.alarms.contains { $0.key == one.key && $0.isOn } }
        func skipped(_ s: ChumbyState) -> Bool { s.skipped.map { $0.name == original.name && abs($0.date.timeIntervalSince(due)) < 60 } ?? false }
        var last: ChumbyState?
        // Up to 24 s: the Mac renews its copy of the list every 20 s when nothing told it to sooner (an answer lost on the
        // way told it nothing), and the panel may take that long to pin the skip while it's loading the list.
        for _ in 0..<16 {
            if let s = try? AlarmWriter.strict(await api.fresh("state")) {
                last = s
                if there(s) && skipped(s) {
                    adoptFresh(s)
                    return .done
                }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        guard let s = last else { return .failed(ChumbyWords.notAnswering + ". Check the alarm before you sleep.") }
        // Not as asked. Whatever is put back, the skip goes first: a skip request still waiting on the panel would
        // otherwise land after the one-off had been removed, and nothing would ring. (An undo with nothing to undo
        // is harmless.) Then the one-off, if it's there, so it's as it was.
        await unskip(settle: false)
        if !there(s) {
            if skipped(s) { return .failed("The Chumby didn’t take the new time, so the skip was taken back. Your usual alarm rings.") }
            return .failed(lost ? ChumbyWords.notAnswering + ". Check the alarm before you sleep." : "The Chumby didn’t take the new time. Nothing was changed.")
        }
        if let why = await save(.delete(one)) { return .failed("The Chumby didn’t confirm the skip, so both will ring: \(why)") }
        return .failed("The Chumby didn’t confirm the skip. Nothing was changed.")
    }
    // After a save the panel re-reads its list (a=state says "pending" until the hook has it in, apply.sh), and its
    // hook answers no skip request until then. A skip asked for straight after the one-off's two saves went
    // unconfirmed within the few seconds allowed, was taken back, and the one-off with it (11-08).
    private func waitForPanel() async {
        guard let api else { return }
        for _ in 0..<20 {
            if let s = try? JSONDecoder().decode(ChumbyState.self, from: await api.fresh("state")), !s.pending { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
    // The Chumby's skip, pinned to that ring, or why not. One that landed elsewhere is taken back at once.
    private func skipFor(_ original: Alarm, due: Date) async -> String? {
        guard let api else { return "No Chumby address set." }
        // The Chumby's clock before asking, so a copy from before the request (the relay keeps one for a while) is
        // never read as its answer.
        let asked = (try? JSONDecoder().decode(ChumbyState.self, from: await api.fresh("state")))?.chumbyNow
        if let why = await skip(original, at: due, settle: false) { return why }
        // Read again until the panel has answered: its poll runs every 2 s once its list is in, and the relay's copy
        // follows a little behind. Up to half a minute, not a few seconds.
        for _ in 0..<15 {
            if let s = try? JSONDecoder().decode(ChumbyState.self, from: await api.fresh("state")), asked.map({ a in s.chumbyNow.map { $0 > a } ?? true }) ?? true, let k = s.skipped {
                if k.name == original.name && abs(k.date.timeIntervalSince(due)) < 60 { return nil }
                await unskip(settle: false)
                return "The Chumby skipped another alarm, so that skip was taken back."
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        await unskip(settle: false)
        return "The Chumby didn’t confirm the skip."
    }
    // Back to the usual: the skip taken back first when it's this one's (so the usual alarm rings again), then the one-off
    // removed. Stopping at a failure leaves both ringing, never neither.
    func undoJustOnce() async -> String? {
        tick()
        guard let j = state.justOnce() else { return nil }
        // Once the usual time has gone by, there's nothing to go back to: removing this one would leave the night silent.
        guard j.canUndo else { return "The usual time has already gone, so this one stays." }
        if j.pinned {
            letGo("skip")
            let asked = deviceState.chumbyNow
            await unskip(settle: false)
            if let f = failed("skip") { return f }
            // Only once the Chumby itself says the skip is off does the one-off go: with the skip still on and the one-off
            // removed, nothing would ring. Unconfirmed, the one-off stays, so both ring.
            guard let api, await chumbyUnskipConfirmed(api, since: asked) else { return chumbyUnskipDoubt }
        }
        return await save(.delete(j.alarm))
    }
    // A one-off whose usual alarm isn't skipped any more (the skip moved): skip the usual ring again, replacing the skip
    // that's set now (`replacing`, after its warning).
    func reskipJustOnce() async -> String? {
        tick()
        guard let j = state.justOnce(), j.orphan, let o = j.original, let u = j.usual else { return nil }
        guard u.timeIntervalSinceNow >= 180 else { return "It’s about to ring. Snooze it when it does." }
        return await skipFor(o, due: u)
    }
}

// Under Home's card: a "just this once" that no longer stands behind its skip, with the fix. (Until 2026-11-14 this was
// also a link, "Later or another sound, just tomorrow", with a menu of +10/+20/+30; Richard: "later or another sound is
// stupid and redundant -- i should be able to tap and set the time pressely". The time on the card opens the sheet now.)
struct JustOnceMenu: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var busy = false
    @State private var spinning = false
    @State private var problem: String?
    @State private var confirmReskip = false
    var body: some View {
        Group {
            if let j = model.state.justOnce(), j.orphan { orphan(j) }
            if let problem { FailNote(text: problem) }
        }
    }
    // Both would ring (or the one-off rings alone): said plainly, with the two ways back.
    @ViewBuilder func orphan(_ j: JustOnceNow) -> some View {
        let t = j.at.formatted(date: .omitted, time: .shortened)
        VStack(alignment: .leading, spacing: 6) {
            if let o = j.original, let u = j.usual {
                RowNote(icon: "exclamationmark.circle.fill", text: "Both will ring: \(alarmLabel(o).capitalizedFirst) at \(u.formatted(date: .omitted, time: .shortened)) and its ring at \(t). The skip moved to another alarm.")
            } else {
                RowNote(icon: "exclamationmark.circle.fill", text: "\(j.alarm.name) still rings at \(t), though the alarm it stood in for is gone.")
            }
            HStack(spacing: 18) {
                if let u = j.usual {
                    Button("Skip the \(u.formatted(date: .omitted, time: .shortened))") { if model.pinWarning != nil { confirmReskip = true } else { run { await model.reskipJustOnce() } } }
                        .confirmationDialog(model.pinWarning ?? "", isPresented: $confirmReskip, titleVisibility: .visible) {
                            Button("Replace the skip") { run { await model.reskipJustOnce() } }
                        }
                }
                Button("Remove the \(j.at.formatted(date: .omitted, time: .shortened)) ring") { run { await model.save(.delete(j.alarm)) } }
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(.tint).buttonStyle(.borderless).disabled(busy)
        }
    }
    func run(_ work: @escaping () async -> String?) {
        guard !busy else { return }
        busy = true
        Task { let why = await work(); withAnimation(.snappy) { problem = why; busy = false; spinning = false } }
        // An older note goes, and the spinner comes, after the close; nothing at all if the Chumby has answered by then.
        MenuClose.then { if busy { problem = nil; spinning = true } }
    }
    // "just today", "just tomorrow", "just Friday": the day in the sentence, a weekday keeping its capital.
    func justDay(_ d: Date) -> String { chumbyJustDay(d) }
}

// One ring's own time and sound: a time wheel, +5 and +10 from wherever it stands, and the editor's own sound rows
// (Richard, 2026-11-14: "i should be able to tap and set the time pressely however maybe have + 5 or +10 shortcuts").
// One of his own alarms can only ring later than usual (the usual ring is skipped and a one-off rings in its place); a
// calendar day's alarm is simply moved, so it can ring earlier too. `adjusting`: this ring was already moved just this
// once, and Set puts the usual one back first and then sets the new time, so there is never a moment with neither.
// When the Chumby's one skip is already on another alarm, it says what Set will replace before it does.
struct JustOnceSheet: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let original: Alarm
    let due: Date
    var later = 0
    var adjusting = false
    @State private var minutes = 0
    @State private var loadedSound = ""
    @State private var alarm = Alarm()
    @State private var sound = SoundChoice()
    @State private var saving = false
    @State private var problem: String?
    @State private var loaded = false
    @State private var confirm = false
    var at: Date { due.addingTimeInterval(Double(minutes * 60)) }
    // How far it may go: his own alarms from the usual time to twelve hours on; a calendar day's from a few minutes from
    // now (never more than six hours early) to twelve hours on, and the calendar's own check keeps it before the event.
    var earliest: Int { original.isCalendar ? max(-360, Int((Date().addingTimeInterval(240).timeIntervalSince(due) / 60).rounded(.up))) : 0 }
    func step(_ by: Int) { Haptic.fire(.tick); withAnimation(.snappy) { minutes = min(max(minutes + by, min(earliest, 0)), JustOnce.longest) } }
    // "25 min later than usual", "At its usual time"
    var offsetText: String {
        if minutes == 0 { return "At its usual time" }
        let m = abs(minutes), words = m >= 60 ? "\(m / 60) h\(m % 60 > 0 ? " \(m % 60) min" : "")" : "\(m) min"
        return "\(words) \(minutes > 0 ? "later" : "earlier") than usual"
    }
    func soundKey(_ a: Alarm) -> String { [a.type, a.arg, a.param, a.param_description, a.duration, a.snooze, a.auto_dismiss].joined(separator: "\u{1}") }
    // The same pill as the nap's lengths: outlined in the accent.
    func stepChip(_ title: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize()
                .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(.tint).overlay { Capsule().stroke(.tint, lineWidth: 1) }.contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
    var name: String { original.isCalendar ? String(original.name.dropFirst(Alarm.calendarPrefix.count)) : alarmLabel(original).capitalizedFirst }
    var body: some View {
        NavigationStack {
            Form { sections.listRowBackground(GlassRow()) }
                .seaList().background { SeaBackground().ignoresSafeArea() }
                .navigationTitle("Just this once").navigationBarTitleDisplayMode(.inline)
                // Edge to edge (fillCover, from Home and the editor), Cancel and Set in the Duo's side bar as the alarm
                // editor's Cancel and Save are: the system's items, each with a glyph (2026-11-10).
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else {
                            Button { if !original.isCalendar, !adjusting, model.pinWarning != nil { confirm = true } else { save(replacing: false) } } label: { Label("Set", systemImage: "checkmark") }.fontWeight(.semibold)
                                // What it replaces is said once, in the note at the top of the sheet; this only asks
                                // (Richard, 2026-11-10: the same sentence twice).
                                .confirmationDialog("Replace that skip?", isPresented: $confirm, titleVisibility: .visible) {
                                    Button("Replace and set") { save(replacing: true) }
                                }
                        }
                    }
                }
                .interactiveDismissDisabled(saving)
                .onAppear {
                    if !loaded { load(); loaded = true }
                    // For the shot: Set pressed with the Chumby's one skip already on another alarm.
                    if ChumbyModel.pose == "reskip" { Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if model.pinWarning != nil { confirm = true } } }
                }
        }
        .tint(ChumbyPalette.acc(scheme == .dark))
    }
    @ViewBuilder var sections: some View {
        let warning = original.isCalendar || adjusting ? nil : model.pinWarning
        if saving || problem != nil || warning != nil {
            Section {
                if saving { HStack(spacing: 10) { ProgressView(); Text("Reaching the Chumby…").foregroundStyle(.secondary) } }
                if let problem { FailNote(text: problem) }
                if let w = warning, !saving { RowNote(icon: "exclamationmark.circle.fill", text: w) }
            }
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.custom("Trebuchet MS", size: 24).weight(.bold)).lineLimit(2)
                // The alarm and its day, and the usual time once. The new time lives only in "Rings at", the picker
                // under When: the hero said it too, so the sheet showed it twice (designer, 11-11).
                Text("\(dayWord(due)) · usually \(due.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        Section {
            // The time itself. A time on the clock is taken as the one nearest the usual time; one this ring can't have
            // (earlier than usual for his own alarms, already gone for a calendar day) settles on the nearest it can.
            DatePicker("Rings at", selection: Binding(get: { at }, set: { d in
                var m = Int((d.timeIntervalSince(due) / 60).rounded()) % 1440
                if m > 720 { m -= 1440 } else if m < -720 { m += 1440 }
                minutes = min(max(m, min(earliest, 0)), JustOnce.longest)
            }), displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
            // Five or ten more from wherever it stands, and the way back to the usual time once it has left it.
            HStack(spacing: 8) {
                stepChip("+5 min", label: "Five minutes later") { step(5) }
                stepChip("+10 min", label: "Ten minutes later") { step(10) }
                if minutes != 0 {
                    stepChip("Usual", label: "Back to the usual time") { Haptic.fire(.tick); withAnimation(.snappy) { minutes = 0 } }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 11, leading: 20, bottom: 0, trailing: 20))
            Text(offsetText).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText())
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 11, trailing: 20))
        } header: { SectionHead(icon: "clock", text: "When") }
        Section { SoundRows(choice: $sound, alarm: $alarm) } header: { SectionHead(icon: "music.note", text: "Sound") }
        Section {} footer: {
            SectionFoot(original.isCalendar ? "Only that day’s alarm changes. The other days are as they were."
                 : "For this ring only, and never earlier than usual. It repeats as usual after.")
        }
    }
    func load() {
        minutes = later
        // How it rings now, as the Chumby holds it (a calendar alarm with the calendar's set, or its own); a ring already
        // moved just this once opens with the sound it was given then.
        alarm = model.deviceState.alarms.first { $0.key == original.key } ?? original
        if adjusting, let j = model.state.justOnce() { alarm.takeSettings(from: j.alarm) }
        sound = SoundChoice(alarm, state: model.state, stations: model.pandoraStations)
        var a = alarm
        if sound.apply(to: &a, state: model.state, stations: model.pandoraStations) == nil { loadedSound = soundKey(a) }
    }
    func save(replacing: Bool) {
        var a = alarm
        if let why = sound.apply(to: &a, state: model.state, stations: model.pandoraStations) { problem = why.errorDescription; return }
        // Nothing changed: nothing to send.
        if minutes == later && soundKey(a) == loadedSound { dismiss(); return }
        saving = true; problem = nil
        Task {
            // A ring already moved goes back to its usual time first (the skip taken back, the one-off removed), so the
            // new time is set from the same footing as the first; a failure in between leaves the usual alarm ringing.
            if adjusting, let why = await model.undoJustOnce() { saving = false; problem = why; return }
            // Back at its usual time with its usual sound is all he asked for.
            if adjusting && minutes == 0 && soundKey(a) == soundKey(model.deviceState.alarms.first { $0.key == original.key } ?? original) { saving = false; dismiss(); return }
            let why = await model.justOnce(original, due: due, at: at, settings: a, replacing: replacing)
            saving = false
            if let why { problem = adjusting ? "It’s back at its usual time. \(why)" : why } else { dismiss() }
        }
    }
}

// "today", "tomorrow", "Friday": the day in a sentence, a weekday keeping its capital (never "monday").
func chumbyJustDay(_ d: Date) -> String { let w = dayWord(d); return w == "Today" || w == "Tomorrow" ? w.lowercased() : w }
