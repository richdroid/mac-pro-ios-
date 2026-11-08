import SwiftUI

// MARK: - Just this once
// The next alarm, later or with another sound, for that one ring only (Richard, 2026-11-07: "like one instance of an alarm
// like say im tired and want more time before it goes off or a diff sound"). Built from what the Chumby already does:
// - a one-off at the new time with the chosen sound, named "<alarm> (just this once)". It's saved switched off first and
//   then switched on, so the Chumby's newest_wins never counts it as a new alarm and never turns the others off (chalarm.c
//   only counts an alarm that's on and wasn't in the saved list; switching one on that's already there is a plain toggle);
// - then the Chumby's own skip of the next alarm (a=skip), checked against the alarm meant, and taken back if it caught
//   another.
// The order means a failure never leaves silence: until the skip lands, both ring. The one-off is always later than the
// alarm it stands in for, at least a minute, since a skip also covers anything due the same minute (the panel hook's
// chSkipDone). A calendar alarm works the same way: it stays on, so its day still keeps repeating alarms quiet, and the
// one-off, not being a "Calendar: " alarm, keeps its own sound (the Chumby gives those the calendar's shared set).
enum JustOnce {
    static let suffix = " (just this once)"
    // How far after the usual time it may go: never past the next morning's.
    static let longest = 12 * 60
    static func isOne(_ a: Alarm) -> Bool { a.when == "once" && a.name.hasSuffix(suffix) }
    static func name(for a: Alarm) -> String {
        let base = a.isCalendar ? String(a.name.dropFirst(Alarm.calendarPrefix.count)) : a.name.isEmpty ? "\(a.clock) \(a.meridiem) alarm" : a.name
        return String(base.prefix(40)).trimmingCharacters(in: .whitespaces) + suffix
    }
    // What it stands in for, as a one-off's row says it.
    static func base(_ a: Alarm) -> String { String(a.name.dropLast(suffix.count)) }
}

extension ChumbyState {
    // A "just this once" still to ring, and the usual time it replaces (the skip just before it), if that's still pending.
    func justOnce(now: Date = Date()) -> (alarm: Alarm, at: Date, replaces: SkippedAlarm?)? {
        guard let a = alarms.filter({ JustOnce.isOne($0) && $0.isOn }).compactMap({ a in a.nextFire(after: now).map { (a, $0) } }).min(by: { $0.1 < $1.1 }) else { return nil }
        let s = skipped.flatMap { s in s.date > now && s.date < a.1 && a.1.timeIntervalSince(s.date) <= Double(JustOnce.longest * 60) ? s : nil }
        return (a.0, a.1, s)
    }
}

extension ChumbyModel {
    // Why "just this once" can't be offered for the next ring, or nil when it can. Hidden altogether (`hidden`) where it
    // makes no sense: nothing next, a Chumby that can't skip, an alarm ringing, a skip already set, or a nap.
    enum JustOnceBlock: Equatable { case hidden, note(String) }
    func justOnceBlock(for a: Alarm? = nil) -> JustOnceBlock? {
        guard stateKnown, state.skipKnown, !unreachable, sys.ringing == nil, let n = nextRing() else { return .hidden }
        if let a, n.alarm.key != a.key {
            return .note("Just this once changes the next alarm to ring, and this isn’t it. Next is \(alarmLabel(n.alarm)), \(dayWord(n.at).lowercased()) at \(n.at.formatted(date: .omitted, time: .shortened)).")
        }
        if state.skipped.map({ $0.date > Date() }) == true || n.alarm.isHelper || JustOnce.isOne(n.alarm) { return .hidden }
        if n.at.timeIntervalSinceNow < 180 { return .note("It’s about to ring, so it can’t be changed now. Snooze it when it does.") }
        return nil
    }

    // Puts the next alarm, `original` due at `due`, at `at` with `settings` (its sound, length and snooze) for that ring
    // only. Nil once it's all on the Chumby; otherwise why not, with nothing left changed that could keep an alarm quiet.
    func justOnce(_ original: Alarm, due: Date, at: Date, settings: Alarm) async -> String? {
        guard let api else { return "No Chumby address set." }
        tick()
        let late = at.timeIntervalSince(due)
        guard late >= 60, late <= Double(JustOnce.longest * 60) else { return "Pick a time after \(due.formatted(date: .omitted, time: .shortened)), on the same night." }
        // Fresh from the Chumby: it must still be the next to ring, with nothing skipped, and not about to ring.
        do {
            let s = try JSONDecoder().decode(ChumbyState.self, from: await api.fresh("state"))
            guard s.skipped.map({ $0.date > Date() }) != true else { return "An alarm is already skipped. Undo that first." }
            guard let n = s.nextRing(), n.alarm.key == original.key, abs(n.at.timeIntervalSince(due)) < 60 else { return "That’s no longer the next alarm. Nothing was changed." }
            guard due.timeIntervalSinceNow >= 180 else { return "It’s about to ring, so nothing was changed. Snooze it when it does." }
            guard !s.alarms.contains(where: { JustOnce.isOne($0) && $0.isOn && $0.nextFire() != nil }) else { return "There’s already one set just this once. Undo it first." }
        } catch { return AlarmWriter.explain(error) }
        var one = settings
        one.name = JustOnce.name(for: original)
        one.enabled = "1"; one.when = "once"; one.time = String(Int((at.timeIntervalSince1970 / 60).rounded())); one.backup = "0"
        if one.backupDelay.isEmpty || one.backupDelay == "0" { one.backupDelay = "5" }
        // 1. Kept switched off, so it's not a new alarm when it's switched on.
        var off = one; off.enabled = "0"
        if let why = await save(.add(off)) { return why }
        // 2. Switched on: now both ring.
        if let why = await save(.toggle(off, true)) {
            _ = await save(.delete(off))
            return why
        }
        // 3. The usual one skipped, checked against the Chumby's own answer.
        let skipNote = await skipFor(original, due: due)
        if let skipNote {
            // Couldn't skip it: take the one-off away again, so the night is as it was rather than ringing twice.
            if let why = await save(.delete(one)) { return "\(skipNote) Both will ring: \(why)" }
            return "\(skipNote) Nothing was changed."
        }
        return nil
    }
    // The Chumby's skip, landed on the alarm meant, or why not. A skip that caught another alarm is taken back at once.
    private func skipFor(_ original: Alarm, due: Date) async -> String? {
        // Only this skip's own failure counts, not one still showing from before.
        if failure?.id == "skip" { failure = nil }
        await skipNext()
        if let f = failed("skip") { return f }
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
    // Back to the usual: the skip taken back first (so the usual one rings again), then the one-off removed. Stopping at
    // a failure leaves both ringing, never neither.
    func undoJustOnce() async -> String? {
        tick()
        guard let j = state.justOnce() else { return nil }
        // Once the usual time has gone by, there's nothing to go back to: removing this one would leave the night silent.
        guard j.replaces != nil else { return "The usual time has already gone, so this one stays." }
        if failure?.id == "skip" { failure = nil }
        await unskip()
        if let f = failed("skip") { return f }
        return await save(.delete(j.alarm))
    }
}

// The quick way, from the next alarm on Home and in Alarms: later by a few minutes, the same sound, in one tap; or the
// sheet for another time or sound.
struct JustOnceMenu: View {
    @EnvironmentObject var model: ChumbyModel
    // On the Skip card's slab (white) or on glass (tinted).
    var onSlab = false
    @State private var busy = false
    @State private var sheet = false
    @State private var problem: String?
    @State private var posed = false
    var body: some View {
        if model.justOnceBlock() == nil, let n = model.nextRing() {
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    Section("Later, just this once") {
                        ForEach([10, 20, 30], id: \.self) { m in
                            let at = n.at.addingTimeInterval(Double(m * 60))
                            Button("+\(m) min · \(at.formatted(date: .omitted, time: .shortened))") { quick(n.alarm, n.at, at) }
                        }
                    }
                    Button { sheet = true } label: { Label("Another time or sound…", systemImage: "slider.horizontal.3") }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) } else { Image(systemName: "clock.arrow.circlepath") }
                        Text("Later or different, just this once")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(onSlab ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .disabled(busy)
                .accessibilityHint("Moves the \(n.at.formatted(date: .omitted, time: .shortened)) alarm later, or changes its sound, for this time only")
                if let problem { FailNote(text: problem) }
            }
            .sheet(isPresented: $sheet) { JustOnceSheet(original: n.alarm, due: n.at).environmentObject(model) }
            .onAppear { if ChumbyModel.pose == "justonce" && model.tab == 0 && !posed { posed = true; sheet = true } }
        }
    }
    func quick(_ a: Alarm, _ due: Date, _ at: Date) {
        busy = true; problem = nil
        Task {
            problem = await model.justOnce(a, due: due, at: at, settings: a)
            busy = false
        }
    }
}

// Another time or sound for the next ring: how much later (a few presets or a time), and the editor's own sound rows.
struct JustOnceSheet: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let original: Alarm
    let due: Date
    // Minutes later it starts at: 10 from Home, 1 from a calendar day, where it's mostly the sound that changes.
    var later = 10
    @State private var minutes = 10
    @State private var alarm = Alarm()
    @State private var sound = SoundChoice()
    @State private var saving = false
    @State private var problem: String?
    @State private var loaded = false
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
                        if saving { ProgressView() } else { Button("Set") { save() }.fontWeight(.semibold) }
                    }
                }
                .interactiveDismissDisabled(saving)
                .onAppear { if !loaded { load(); loaded = true } }
        }
        .tint(ChumbyPalette.acc(scheme == .dark))
    }
    @ViewBuilder var sections: some View {
        if saving || problem != nil {
            Section {
                if saving { HStack(spacing: 10) { ProgressView(); Text("Reaching the Chumby…").foregroundStyle(.secondary) } }
                if let problem { FailNote(text: problem) }
            }
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.custom("Trebuchet MS", size: 24).weight(.bold)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(due.formatted(date: .omitted, time: .shortened)).strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Text(at.formatted(date: .omitted, time: .shortened)).font(.body.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                    Text(dayWord(due)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .animation(.snappy, value: minutes)
        }
        Section {
            HStack(spacing: 8) {
                ForEach([10, 20, 30], id: \.self) { m in
                    Button { withAnimation(.snappy) { minutes = m } } label: {
                        Text("+\(m) min").font(.subheadline.weight(.semibold)).monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(minutes == m ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                            .background { Capsule().fill(minutes == m ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)) }
                            .overlay { Capsule().stroke(.tint, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
            DatePicker("Rings at", selection: Binding(get: { at }, set: { d in
                // A time on the clock, the next one after the usual time.
                var t = d
                while t <= due { t = t.addingTimeInterval(86400) }
                while t.timeIntervalSince(due) > 86400 { t = t.addingTimeInterval(-86400) }
                minutes = min(max(Int((t.timeIntervalSince(due) / 60).rounded()), 1), JustOnce.longest)
            }), displayedComponents: .hourAndMinute)
        } header: { Text("Later") }
        Section("Sound") { SoundRows(choice: $sound, alarm: $alarm) }
        Section {} footer: {
            Text("The \(due.formatted(date: .omitted, time: .shortened)) is skipped and this rings in its place. Your other alarms stay as they are.")
        }
    }
    func load() {
        minutes = later
        // How it rings now: a calendar alarm as the Chumby holds it, with the calendar's shared set.
        alarm = model.deviceState.alarms.first { $0.key == original.key } ?? original
        sound = SoundChoice(alarm, state: model.state, stations: model.pandoraStations)
    }
    func save() {
        var a = alarm
        if let why = sound.apply(to: &a, state: model.state, stations: model.pandoraStations) { problem = why.errorDescription; return }
        saving = true; problem = nil
        Task {
            let why = await model.justOnce(original, due: due, at: at, settings: a)
            saving = false
            if let why { problem = why } else { dismiss() }
        }
    }
}
