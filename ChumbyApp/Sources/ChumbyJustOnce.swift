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
enum JustOnce {
    static let suffix = " (just this once)"
    // How far after the usual time it may go: never past the next morning's.
    static let longest = 12 * 60
    static func isOne(_ a: Alarm) -> Bool { a.when == "once" && a.name.hasSuffix(suffix) }
    static func name(for a: Alarm) -> String {
        let base = a.isCalendar ? String(a.name.dropFirst(Alarm.calendarPrefix.count)) : a.name.isEmpty ? "\(a.clock) \(a.meridiem) alarm" : a.name
        return String(base.prefix(40)).trimmingCharacters(in: .whitespaces) + suffix
    }
}

// A "just this once" on the Chumby, and how it stands: the alarm it replaces, that alarm's usual ring, and whether the
// Chumby's one skip is on that ring.
struct JustOnceNow {
    var alarm: Alarm
    var at: Date
    var original: Alarm?
    var usual: Date?
    var pinned: Bool
    var skip: SkippedAlarm?
    // The skip it stands behind, when that's where the Chumby's skip is.
    var replaces: SkippedAlarm? { pinned ? skip : nil }
    // Removing it leaves the usual alarm to ring (skip taken back first, when it's pinned), as long as that's still ahead.
    var canUndo: Bool { usual.map { $0 > Date() } ?? false }
    // Not standing behind its skip: the usual one rings as well (the skip moved elsewhere), or it's alone because the
    // usual one has gone (turned off, deleted, its calendar day dropped).
    var orphan: Bool { !pinned && (usual == nil || usual! > Date()) }
}

extension ChumbyState {
    // The first "just this once" still to ring.
    func justOnce(now: Date = Date()) -> JustOnceNow? {
        guard let (one, at) = alarms.filter({ JustOnce.isOne($0) && $0.isOn }).compactMap({ a in a.nextFire(after: now).map { (a, $0) } }).min(by: { $0.1 < $1.1 }) else { return nil }
        // The alarm it stands in for: same name before the suffix, with a ring in the 12 hours up to it.
        let from = at.addingTimeInterval(-Double(JustOnce.longest * 60) - 60)
        let candidates = alarms.filter { !JustOnce.isOne($0) && JustOnce.name(for: $0) == one.name }
            .compactMap { a in ring(of: a, after: from, skip: false).flatMap { $0 <= at ? (a, $0) : nil } }
        let best = candidates.max { $0.1 < $1.1 }
        let skip = skipped.flatMap { $0.date > now ? $0 : nil }
        let pinned = best.map { b in skip.map { $0.name == b.0.name && abs($0.date.timeIntervalSince(b.1)) < 60 } ?? false } ?? false
        return JustOnceNow(alarm: one, at: at, original: best?.0, usual: best?.1, pinned: pinned, skip: skip)
    }
}

extension ChumbyModel {
    // What the Chumby's one skip is on now, said for the warning before something replaces it, or nil with none set.
    var pinWarning: String? {
        guard let s = state.skipped, s.date > Date() else { return nil }
        let t = s.date.formatted(date: .omitted, time: .shortened)
        let name = s.name.hasPrefix(Alarm.calendarPrefix) ? String(s.name.dropFirst(Alarm.calendarPrefix.count)) : (s.name.isEmpty ? "your \(t) alarm" : s.name)
        if let j = state.justOnce(), j.pinned {
            return "This replaces your “just this once” for \(name): \(name) rings at \(t) again and its \(j.at.formatted(date: .omitted, time: .shortened)) one-off is removed."
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
        return .ok(alarm: target.alarm, due: target.at, warning: pinWarning)
    }

    // Puts `original`'s ring at `due` at `at` with `settings` (its sound, length and snooze), for that ring only. With
    // `replacing`, the user has seen pinWarning and the skip already set is replaced: its "just this once", if any, is
    // removed once the new skip has landed. Nil once it's all on the Chumby; otherwise why not, never leaving an alarm quiet
    // that the user didn't change.
    func justOnce(_ original: Alarm, due: Date, at: Date, settings: Alarm, replacing: Bool = false) async -> String? {
        guard let api else { return "No Chumby address set." }
        tick()
        let late = at.timeIntervalSince(due)
        guard late >= 0, late <= Double(JustOnce.longest * 60) else { return "Pick a time from \(due.formatted(date: .omitted, time: .shortened)), on the same night." }
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
        // 1. Kept switched off, so it's not a new alarm when it's switched on.
        var off = one; off.enabled = "0"
        if let why = await save(.add(off)) { return why }
        // 2. Switched on: now both ring.
        if let why = await save(.toggle(off, true)) {
            _ = await save(.delete(off))
            return why
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
            if let why = await save(.delete(old.alarm)) { return "Set. But the earlier one-off at \(old.at.formatted(date: .omitted, time: .shortened)) couldn’t be removed, so it rings too: \(why)" }
        }
        return nil
    }
    // The Chumby's skip, pinned to that ring, or why not. One that landed elsewhere is taken back at once.
    private func skipFor(_ original: Alarm, due: Date) async -> String? {
        if let why = await skip(original, at: due) { return why }
        guard let api else { return "No Chumby address set." }
        // Read straight from the Chumby, since the list shown keeps the skip it asked for for a few seconds.
        for _ in 0..<3 {
            if let s = try? JSONDecoder().decode(ChumbyState.self, from: await api.fresh("state")), let k = s.skipped {
                if k.name == original.name && abs(k.date.timeIntervalSince(due)) < 60 { return nil }
                await unskip()
                return "The Chumby skipped another alarm, so that skip was taken back."
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        await unskip()
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
            if failure?.id == "skip" { failure = nil }
            await unskip()
            if let f = failed("skip") { return f }
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

// From the next alarm on Home and in Alarms: later by a few minutes with the same sound, in one tap; or the sheet for
// another time or sound. A "just this once" that no longer stands behind its skip is shown here instead, with the fix.
struct JustOnceMenu: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var busy = false
    @State private var sheet = false
    @State private var problem: String?
    @State private var posed = false
    @State private var confirmReskip = false
    var body: some View {
        Group {
            if let j = model.state.justOnce(), j.orphan { orphan(j) }
            else if case .ok(let a, let due, _) = model.justOnceOffer() {
                Menu {
                    Section("Later, just this once") {
                        ForEach([10, 20, 30], id: \.self) { m in
                            let at = due.addingTimeInterval(Double(m * 60))
                            Button("+\(m) min · \(at.formatted(date: .omitted, time: .shortened))") { run { await model.justOnce(a, due: due, at: at, settings: a) } }
                        }
                    }
                    Button { sheet = true } label: { Label("Another time or sound…", systemImage: "slider.horizontal.3") }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) } else { Image(systemName: "clock.arrow.circlepath") }
                        Text("Later or different, just this once")
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    .frame(minHeight: 30).contentShape(Rectangle())
                }
                .disabled(busy)
                .accessibilityHint("Moves the \(due.formatted(date: .omitted, time: .shortened)) alarm later, or changes its sound, for this time only")
                .sheet(isPresented: $sheet) { JustOnceSheet(original: a, due: due).environmentObject(model) }
                .onAppear { if ChumbyModel.pose == "justonce" && model.tab == 0 && !posed { posed = true; sheet = true } }
            }
            if let problem { FailNote(text: problem) }
        }
    }
    // Both would ring (or the one-off rings alone): said plainly, with the two ways back.
    @ViewBuilder func orphan(_ j: JustOnceNow) -> some View {
        let t = j.at.formatted(date: .omitted, time: .shortened)
        VStack(alignment: .leading, spacing: 6) {
            if let o = j.original, let u = j.usual {
                RowNote(icon: "exclamationmark.circle.fill", text: "Both will ring: \(alarmLabel(o).capitalizedFirst) at \(u.formatted(date: .omitted, time: .shortened)) and its one-off at \(t). The skip moved to another alarm.")
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
                Button("Remove the one-off") { run { await model.save(.delete(j.alarm)) } }
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(.tint).buttonStyle(.borderless).disabled(busy)
        }
    }
    func run(_ work: @escaping () async -> String?) {
        busy = true; problem = nil
        Task { problem = await work(); busy = false }
    }
}

// Another time or sound for one ring: how much later (a few presets or a time), and the editor's own sound rows. When the
// Chumby's one skip is already on another alarm, it says what Set will replace before it does.
struct JustOnceSheet: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let original: Alarm
    let due: Date
    var later = 10
    @State private var minutes = 10
    @State private var alarm = Alarm()
    @State private var sound = SoundChoice()
    @State private var saving = false
    @State private var problem: String?
    @State private var loaded = false
    @State private var confirm = false
    var at: Date { due.addingTimeInterval(Double(minutes * 60)) }
    var name: String { original.isCalendar ? String(original.name.dropFirst(Alarm.calendarPrefix.count)) : alarmLabel(original).capitalizedFirst }
    var body: some View {
        NavigationStack {
            Form { sections.listRowBackground(GlassRow()) }
                .seaList().background { SeaBackground().ignoresSafeArea() }
                .navigationTitle("Just this once").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { Text("Just this once").font(.custom("Trebuchet MS", size: 18).weight(.bold)) }
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else {
                            Button("Set") { if model.pinWarning != nil { confirm = true } else { save(replacing: false) } }.fontWeight(.semibold)
                                .confirmationDialog(model.pinWarning ?? "", isPresented: $confirm, titleVisibility: .visible) {
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
        if saving || problem != nil || model.pinWarning != nil {
            Section {
                if saving { HStack(spacing: 10) { ProgressView(); Text("Reaching the Chumby…").foregroundStyle(.secondary) } }
                if let problem { FailNote(text: problem) }
                if let w = model.pinWarning, !saving { RowNote(icon: "exclamationmark.circle.fill", text: w) }
            }
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.custom("Trebuchet MS", size: 24).weight(.bold)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if minutes > 0 {
                        Text(due.formatted(date: .omitted, time: .shortened)).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(at.formatted(date: .omitted, time: .shortened)).font(.body.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                    Text(dayWord(due)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .animation(.snappy, value: minutes)
        }
        Section {
            HStack(spacing: 8) {
                ForEach([0, 10, 20, 30], id: \.self) { m in
                    Button { withAnimation(.snappy) { minutes = m } } label: {
                        Text(m == 0 ? "On time" : "+\(m) min").font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(minutes == m ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                            .background { Capsule().fill(minutes == m ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)) }
                            .overlay { Capsule().stroke(.tint, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
            DatePicker("Rings at", selection: Binding(get: { at }, set: { d in
                // A time on the clock, the next one from the usual time.
                var t = d
                while t < due { t = t.addingTimeInterval(86400) }
                while t.timeIntervalSince(due) >= 86400 { t = t.addingTimeInterval(-86400) }
                minutes = min(max(Int((t.timeIntervalSince(due) / 60).rounded()), 0), JustOnce.longest)
            }), displayedComponents: .hourAndMinute)
        } header: { Text("When") }
        Section("Sound") { SoundRows(choice: $sound, alarm: $alarm) }
        Section {} footer: {
            Text("The usual \(due.formatted(date: .omitted, time: .shortened)) is skipped and this rings in its place. It repeats as usual after.")
        }
    }
    func load() {
        minutes = later
        // How it rings now, as the Chumby holds it (a calendar alarm with the calendar's set, or its own).
        alarm = model.deviceState.alarms.first { $0.key == original.key } ?? original
        sound = SoundChoice(alarm, state: model.state, stations: model.pandoraStations)
    }
    func save(replacing: Bool) {
        var a = alarm
        if let why = sound.apply(to: &a, state: model.state, stations: model.pandoraStations) { problem = why.errorDescription; return }
        saving = true; problem = nil
        Task {
            let why = await model.justOnce(original, due: due, at: at, settings: a, replacing: replacing)
            saving = false
            if let why { problem = why } else { dismiss() }
        }
    }
}
