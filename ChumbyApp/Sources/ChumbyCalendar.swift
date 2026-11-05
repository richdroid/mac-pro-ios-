import AppIntents
import EventKit
import SwiftUI
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif

// Turns what's on this iPhone's calendar into real alarms on the Chumby, which then ring with or without the phone.
@MainActor
final class CalendarWake: ObservableObject {
    static let shared = CalendarWake()
    static let refreshID = "local.macpro.Chumby.calendar"
    nonisolated static let prefix = Alarm.calendarPrefix
    // The build's simulator shots, which have no calendar, show a sample plan in these.
    static let samplePoses: Set<String> = ["calendar", "calsettings", "calday", "template"]
    static var sample: Bool { samplePoses.contains(ChumbyModel.pose) }
    let store = EKEventStore()
    // A change here updates the Chumby a moment later, wherever it was made, so nothing waits for a page to close.
    @Published var rules: WakeRules { didSet { save(); if rules != oldValue { refreshPlan(); soon() } } }
    @Published var plan: [PlannedWake] = []
    @Published var allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var note: String?
    @Published var lastSync: Date?
    @Published private(set) var running = false
    // An update is on its way (gathering for a moment, or going), so the list isn't checked against the Chumby yet.
    @Published private(set) var queued = false
    private var again = false
    private var watching = false
    private var lastTry = Date.distantPast
    private var debounce: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    // The app's own copy of the list, which a save here replaces, so the Alarms tab shows it at once.
    var saved: ((ChumbyState) -> Void)?

    init() {
        if let d = UserDefaults.standard.data(forKey: "wakeRules"), let r = try? JSONDecoder().decode(WakeRules.self, from: d) { rules = r } else { rules = WakeRules() }
        lastSync = UserDefaults.standard.object(forKey: "wakeSynced") as? Date
        if Self.sample { showSample() }
    }
    private func save() { if !Self.sample, let d = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(d, forKey: "wakeRules") } }
    // The calendar alarms' settings as last chosen here, for alarms made before the Chumby keeps a set of its own.
    var storedSettings: Alarm? {
        get { UserDefaults.standard.data(forKey: "calendarAlarmSettings").flatMap { try? JSONDecoder().decode(Alarm.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "calendarAlarmSettings") }
    }
    func showSample() {
        rules.enabled = true; allowed = true
        let cal = Calendar.current, base = cal.startOfDay(for: Date())
        func shift(_ day: Int, _ hour: Int, _ title: String, work: Bool, lead: Int, short: String? = nil) -> PlannedWake {
            let start = cal.date(byAdding: .hour, value: day * 24 + hour, to: base) ?? base
            return PlannedWake(key: title + "\(day)", title: title, start: start, wake: start.addingTimeInterval(TimeInterval(-lead * 60)), lead: lead, isWork: work, shortNight: short)
        }
        plan = [shift(1, 18, "Shift", work: true, lead: 160), shift(2, 13, "Dentist", work: false, lead: 120), shift(3, 18, "Shift", work: true, lead: 160)]
        lastSync = Date().addingTimeInterval(-240)
    }
    func enable() async {
        do {
            let ok = try await store.requestFullAccessToEvents()
            allowed = ok
            if ok { note = nil; startWatching(); rules.enabled = true } else { note = "Chumby can’t see your calendar. Allow it in Settings." }
        } catch { allowed = false; note = "Chumby can’t see your calendar. Allow it in Settings." }
    }
    var denied: Bool { !Self.sample && EKEventStore.authorizationStatus(for: .event) == .denied }
    var calendars: [EKCalendar] { allowed && !Self.sample ? store.calendars(for: .event).sorted { $0.title < $1.title } : [] }
    func events() -> [CalEvent] {
        let now = Date()
        guard allowed, let end = Calendar.current.date(byAdding: .day, value: max(rules.daysAhead, 1) + 8, to: now) else { return [] }
        // From a day back, so the night before can be seen.
        let from = now.addingTimeInterval(-86400)
        return store.events(matching: store.predicateForEvents(withStart: from, end: end, calendars: nil)).map { e in
            CalEvent(id: e.eventIdentifier ?? e.title ?? "", title: e.title ?? "Untitled", calendar: e.calendar?.title ?? "",
                     start: e.startDate, end: e.endDate, allDay: e.isAllDay, free: e.availability == .free,
                     declined: e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
                     canceled: e.status == .canceled, hasLocation: !(e.location ?? "").isEmpty)
        }
    }
    func refreshPlan() {
        if Self.sample {
            for i in plan.indices { plan[i].skipped = rules.skipped.contains(plan[i].key); if let l = rules.leadOverrides[plan[i].key] { plan[i].lead = l; plan[i].wake = plan[i].start.addingTimeInterval(TimeInterval(-l * 60)); plan[i].custom = true } }
            return
        }
        if allowed { plan = WakePlanner.plan(events(), rules: rules) }
    }
    // Calendar changes come in bursts, so they're gathered for a moment first.
    func startWatching() {
        guard !watching, !Self.sample else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in CalendarWake.shared.refreshPlan(); CalendarWake.shared.soon(3) }
        }
    }
    func soon(_ seconds: Double = 1.5) {
        guard !Self.sample else { return }
        queued = true
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { await self?.sync() }
        }
    }
    // Coming back to the app: an update if the last try was a while ago, never on every visit to a tab.
    func syncIfDue() {
        guard rules.enabled, Date().timeIntervalSince(lastTry) > 300 else { return }
        Task { await sync() }
    }
    func toggleSkip(_ item: PlannedWake) {
        if rules.skipped.contains(item.key) { rules.skipped.remove(item.key) } else { rules.skipped.insert(item.key) }
    }
    func offTheCalendar(_ s: ChumbyState) -> [Alarm] { s.alarms.filter { !$0.isCalendar && !$0.isPlaceholder } }
    // Other alarms that will ring before this one that day. With calendar days skipping the repeating ones, only a
    // one-off still rings, so only those are worth a word.
    func alsoRinging(_ item: PlannedWake, in s: ChumbyState) -> String? {
        let cal = Calendar.current
        let skipping = (s.calOverride ?? 0) != 0
        let names = offTheCalendar(s).compactMap { a -> String? in
            guard a.name != "Catch-up", !(skipping && a.when != "once"), let d = a.nextFire(after: item.wake.addingTimeInterval(-8 * 3600)), d < item.wake, cal.isDate(d, inSameDayAs: item.wake) else { return nil }
            return (a.name.isEmpty ? "Another alarm" : a.name) + " at " + d.formatted(date: .omitted, time: .shortened)
        }
        return names.first
    }
    nonisolated static func minutes(_ d: Date) -> String { String(Int(d.timeIntervalSince1970 / 60)) }
    nonisolated static func alarmName(_ w: PlannedWake) -> String { alarmName(title: w.title) }
    nonisolated static func alarmName(title: String) -> String { prefix + String(title.prefix(30)) }
    // Whether the Chumby really holds what the plan says, so the list never shows the phone's plan as if it were set.
    enum OnDevice { case set, missing, stillOn }
    func onDevice(_ item: PlannedWake, in s: ChumbyState) -> OnDevice {
        let there = s.alarms.contains { $0.isOn && $0.name == Self.alarmName(item) && $0.time == Self.minutes(item.wake) }
        if item.skipped || !rules.enabled { return there ? .stillOn : .set }
        return there ? .set : .missing
    }
    // Calendar alarms on the Chumby that the plan no longer wants: still ringing, and shown so they can be removed.
    func strays(in s: ChumbyState) -> [Alarm] {
        let wanted = Set((rules.enabled && allowed ? plan.filter { !$0.skipped } : []).map { Self.minutes($0.wake) + Self.alarmName($0) })
        return s.alarms.filter { $0.isCalendar && $0.isOn && $0.nextFire() != nil && !wanted.contains($0.time + $0.name) }
    }

    // Reads the list fresh, changes only its own alarms, and saves only if something's different, because a save restarts
    // the Chumby's panel. Returns what happened, for Shortcuts.
    @discardableResult
    func sync() async -> String {
        if Self.sample { return "" }
        // A change made while one is going (two skips in a row, say) runs straight after it rather than being lost.
        guard !running else { again = true; return "Updating after the one in progress." }
        running = true
        defer { running = false; queued = false }
        var result = await syncOnce()
        while again { again = false; result = await syncOnce() }
        return result
    }
    private func syncOnce() async -> String {
        lastTry = Date()
        retry?.cancel()
        allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard allowed else { return "Chumby can't see your calendar." }
        // One reading of the calendar for both the plan and the check on what's already set, so they can't disagree.
        let evs = events()
        plan = WakePlanner.plan(evs, rules: rules)
        let wanted = rules.enabled ? plan.filter { !$0.skipped } : []
        let keep = CalendarKeep(plan: plan, events: evs)
        let stored = storedSettings
        do {
            // The same careful save as everything else: read fresh, change only the calendar's alarms, never under a
            // ringing alarm. The first time, the settings chosen here become the Chumby's set for every calendar alarm after.
            let r = try await chumbyTry { api in
                try await AlarmWriter.shared.edit(api, quiet: true, template: { s in s.calTpl == nil && stored != nil && s.alarms.contains { $0.isCalendar } }, planned: { s in
                    s.applyCalendar(wanted, settings: s.calTpl ?? stored, keep: keep)
                })
            }
            if r.saved { saved?(r.state) }
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "wakeSynced")
            note = nil
            return !r.saved ? "Already up to date." : wanted.isEmpty ? "No calendar alarms needed." : "Updated \(wanted.count) calendar alarm\(wanted.count == 1 ? "" : "s")."
        } catch ChumbyError.waiting(let why) {
            note = "Holding the update: \(why). Trying again in 30 seconds."
            tryAgain(after: 30)
            return "Waiting: \(why)."
        } catch ChumbyError.refused(let why) {
            // The safety net kept an alarm that's about to ring. Nothing was sent; the next calendar change or visit tries again.
            note = why
            return why
        } catch {
            let why = AlarmWriter.explain(error)
            note = "\(why) Trying again in a minute."
            tryAgain(after: 60)
            return why
        }
    }
    private func tryAgain(after seconds: Double) {
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { await self?.sync() }
        }
    }
    #if os(iOS)
    func scheduleRefresh() {
        guard rules.enabled else { return }
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        r.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(r)
    }
    #endif
}

// What the calendar said when a sync began, so it can tell a calendar alarm whose event is really gone from one the plan has
// merely stopped choosing. The plan picks the first thing each day and drops a day whose wake-up is already behind it, so
// an earlier event turning up that day, a longer lead or a different first event all leave the plan without a wake the
// Chumby still holds, sometimes minutes before it rings (11-04: the 14:40 shift wake, removed at 14:00).
struct CalendarKeep {
    var plan: [PlannedWake]            // every planned wake, skipped ones too
    var events: [CalEvent]             // everything read, declined and canceled ones too
    enum Verdict { case keep, userChose, gone }
    // For a calendar alarm that's on, due within 24 h, which the plan no longer wants.
    func verdict(_ a: Alarm, due: Date) -> Verdict {
        // Its event: same title, starting after the alarm and no more than 18 hours after it (any lead there is).
        func near(_ start: Date) -> Bool { start >= due && start.timeIntervalSince(due) <= 18 * 3600 }
        if let item = plan.first(where: { CalendarWake.alarmName($0) == a.name && near($0.start) }) {
            // Turned off for that day, or given that day's own lead, by hand: the user's call, and the new time replaces it.
            if item.skipped || item.custom { return .userChose }
            // Moved some other way (the event's time, a rule): the old time still rings, beside the new one.
            return .keep
        }
        let matching = events.filter { CalendarWake.alarmName(title: $0.title) == a.name && near($0.start) }
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
        let have = Set(mine.filter { $0.isOn }.map { $0.time + $0.name })
        let want = Set(wakes.map { CalendarWake.minutes($0.wake) + CalendarWake.alarmName($0) })
        if have == want && mine.filter({ !$0.isOn }).isEmpty { return permit }
        // By the Chumby's clock, since that's the one it rings by.
        let clock = chumbyNow ?? Date()
        var held: [Alarm] = []
        for a in mine where a.isOn && !want.contains(a.time + a.name) {
            // Past, or more than a day off: the plan decides.
            guard let due = a.nextFire(after: clock), due.timeIntervalSince(clock) <= 86400 else { continue }
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
            a.name = CalendarWake.alarmName(w); a.enabled = "1"; a.when = "once"; a.time = CalendarWake.minutes(w.wake)
            // Guessed from your own alarm, it only borrows the sound; chosen settings keep their own after-action and backup.
            if settings == nil { a.action = ""; a.action_param = ""; a.backup = "1" }
            if let free = alarms.firstIndex(where: { $0.isPlaceholder }) { alarms[free] = a } else { alarms.append(a) }
        }
        return permit
    }
}

struct ChumbyCalendarIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Chumby Alarms from Calendar"
    static var description = IntentDescription("Sets the Chumby's alarms from your calendar. Run this from an automation to keep them current.")
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await CalendarWake.shared.sync()))
    }
}

// Non-breaking spaces, so "2 h 40 min" never splits across lines.
func leadText(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60)\u{00A0}h" : m < 60 ? "\(m)\u{00A0}min" : "\(m / 60)\u{00A0}h\u{00A0}\(m % 60)\u{00A0}min" }

// For Calendars access turned off in Settings: the one place it can be turned back on.
struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        #if canImport(UIKit)
        Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }.foregroundStyle(.tint)
        #else
        EmptyView()
        #endif
    }
}

// MARK: - Calendar settings
// The sections themselves, so they can be a page of their own folded or fill the right pane open.
struct CalendarSettingsSections: View {
    @EnvironmentObject var model: ChumbyModel
    @ObservedObject private var wake = CalendarWake.shared
    @State private var showCalendars = false
    // The value on the left under its name, well clear of the − and +.
    func leadRow(_ label: String, _ value: Binding<Int>) -> some View {
        Stepper(value: value, in: 15...360, step: 5) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(leadText(value.wrappedValue)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
    var included: Int { wake.calendars.filter { !wake.rules.excludedCalendars.contains($0.title) }.count }
    var body: some View {
        Group {
            Section {
                Toggle("Wake me from my calendar", isOn: $wake.rules.enabled)
            }
            Section {
                leadRow("Work", $wake.rules.workLead)
                leadRow("Anything else", $wake.rules.otherLead)
                leadRow("Extra for a location", $wake.rules.travelExtra)
                Stepper(value: $wake.rules.daysAhead, in: 1...7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plan ahead")
                        Text("\(wake.rules.daysAhead) wake-up\(wake.rules.daysAhead == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Awake before it starts") }
            Section {
                CalendarSoundRow(autoOpen: ChumbyModel.pose == "template")
            } header: { Text("How they ring") }
            // Only on a Chumby that knows how.
            if let on = model.state.calOverride {
                Section {
                    Toggle("Calendar days skip my other alarms", isOn: Binding(get: { on == 1 }, set: { v in Task { await model.setCalendarOverride(v) } }))
                    if let f = model.failed("calover") { FailNote(text: f) }
                } header: { Text("Skipping other alarms") } footer: {
                    Text(on == 1 ? "On a day your calendar wakes you, your repeating alarms stay quiet. They ring as usual the day after."
                         : "Your repeating alarms ring as usual, even on days your calendar wakes you.")
                }
            }
            Section {
                WordsGroup(title: "Counts as work", words: $wake.rules.workWords)
                WordsGroup(title: "Never wake for", words: $wake.rules.ignoreWords)
                WordsGroup(title: "Days off", words: $wake.rules.offWords)
            } header: { Text("Words in titles") }
            if !wake.calendars.isEmpty {
                Section {
                    // Closed to begin with: it's set once and rarely looked at again.
                    DisclosureGroup("Calendars · \(included) of \(wake.calendars.count)", isExpanded: $showCalendars) {
                        ForEach(wake.calendars, id: \.calendarIdentifier) { c in
                            let on = !wake.rules.excludedCalendars.contains(c.title)
                            HStack(spacing: 10) {
                                Text(c.title).lineLimit(1).opacity(on ? 1 : 0.5)
                                if on { WorkBadge(on: wake.rules.workCalendars.contains(c.title)) {
                                    if wake.rules.workCalendars.contains(c.title) { wake.rules.workCalendars.remove(c.title) } else { wake.rules.workCalendars.insert(c.title) }
                                } }
                                Spacer(minLength: 12)
                                Toggle(c.title, isOn: Binding(get: { on }, set: { v in
                                    if v { wake.rules.excludedCalendars.remove(c.title) } else { wake.rules.excludedCalendars.insert(c.title) }
                                })).labelsHidden()
                            }
                        }
                    }
                } footer: { if showCalendars { Text("Tap Work on a calendar to count everything in it as work.") } }
            }
        }
    }
}
// A small tag that says a calendar's events are all work, and switches it.
struct WorkBadge: View {
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("Work").font(.footnote.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .background { Capsule().fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)) }
                .overlay { Capsule().stroke(.tint, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Everything here is work").accessibilityValue(on ? "On" : "Off")
    }
}
// One list of words, folded away: each its own row, swiped away to remove, and a box at the foot to add one.
struct WordsGroup: View {
    let title: String
    @Binding var words: [String]
    @State private var adding = ""
    @State private var open = false
    func add() {
        let w = adding.trimmingCharacters(in: .whitespaces)
        if !w.isEmpty && !words.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) { words.append(w) }
        adding = ""
    }
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            // Taken out with the mark beside it, never a swipe that slides the word off its card.
            ForEach(words, id: \.self) { w in
                HStack {
                    Text(w)
                    Spacer(minLength: 8)
                    RowRemove(label: "Remove \(w)", icon: "xmark.circle.fill") { words.removeAll { $0 == w } }
                }
            }
            TextField("Add a word", text: $adding).autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.done).onSubmit(add)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(words.isEmpty ? "None" : words.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .onChange(of: open) { _, o in if !o { add() } }
    }
}
// Folded, its own page. With the Duo's side column it slides in inside the Alarms tab (AlarmsTab), with no bar of its own:
// Back sits in the rail where + was (RootView), so the rail never moves. With the bars across it's pushed, with the system's Back.
struct CalendarWakeSettings: View {
    @EnvironmentObject var model: ChumbyModel
    // Pushed, it brings its own sea. Slid in inside Alarms it brings none, so the tab's sea never moves or changes.
    var ownSea = true
    var rail: Bool { model.railWidth >= 44 }
    var body: some View {
        List {
            if rail { PageTitle("Calendar settings") }
            CalendarSettingsSections().listRowBackground(GlassRow())
        }
        .seaList()
        .overSea(shown: ownSea)
        .toolbar(rail ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle("Calendar settings")
        .toolbar { ToolbarItem(placement: .principal) { Text("Calendar settings").font(.custom("Trebuchet MS", size: 18).weight(.bold)) } }
    }
}

// MARK: - One calendar day
// A calendar alarm opened: its event, that day's own wake-up time, whether it rings, and how calendar alarms sound.
struct CalendarDaySheet: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wake = CalendarWake.shared
    @Environment(\.colorScheme) private var scheme
    // Folded: measured on first layout, a first guess until then.
    @State private var fit: CGFloat = 520
    @State private var detent: PresentationDetent = .height(520)
    @State private var openedAt = Date()
    let key: String
    // Set when it fills the open Duo's right pane, or the folded content column, instead of being a sheet.
    var close: (() -> Void)?
    // Folded with the side column, Back in the rail closes it, so it has no Done of its own.
    var done = true
    var item: PlannedWake? { wake.plan.first { $0.key == key } }
    var title: String { item.map { $0.wake.formatted(.dateTime.weekday(.wide)) } ?? "Calendar" }
    @ViewBuilder var sections: some View {
        if let item {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.custom("Trebuchet MS", size: 24).weight(.bold))
                    Text("Starts \(item.start.formatted(.dateTime.weekday(.wide).hour().minute()))").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                Stepper(value: Binding(get: { item.lead }, set: { wake.rules.leadOverrides[key] = $0 }), in: 15...360, step: 5) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake \(leadText(item.lead)) before")
                        Text("Rings at \(item.wake.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if item.custom { Button("Use the usual time") { wake.rules.leadOverrides[key] = nil }.foregroundStyle(.tint) }
                Toggle("Ring that day", isOn: Binding(get: { !item.skipped }, set: { _ in wake.toggleSkip(item) }))
            }
            Section { CalendarSoundRow().background { foot } } header: { Text("How they ring") }
        } else {
            Text("That day is no longer on your calendar.").foregroundStyle(.secondary).background { foot }
        }
    }
    // Folded, where the last row ends, so the sheet can stop just under it. onGeometryChange reports the first layout too,
    // which onScrollGeometryChange never did, so the sheet used to stay at its first guess.
    @ViewBuilder var foot: some View {
        if close == nil {
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("daySheet")).maxY } action: { fitTo($0) }
        }
    }
    func fitTo(_ rowBottom: CGFloat) {
        // Only as it opens: later the row moves because the list is being scrolled, not because the sheet is the wrong size.
        guard Date().timeIntervalSince(openedAt) < 1.5 else { return }
        // The row's own bottom padding and a little air under the last card.
        let h = (rowBottom + 11 + 24).rounded()
        guard h > 200, abs(h - fit) > 1 else { return }
        let onFit = detent == .height(fit)
        fit = h
        // The new height is in the detents before it's chosen.
        if onFit { Task { @MainActor in detent = .height(h) } }
    }
    var body: some View {
        if let close {
            Group {
                PageTitle(title) { if done { Button("Done") { close() }.fontWeight(.semibold).foregroundStyle(.tint) } }
                sections
            }
        } else {
            NavigationStack {
                // The folded sheet is as tall as what's in it (see foot), so no row is cut by its bottom edge, no empty sheet
                // hangs under the last one, and its top stays clear of the rail's clock.
                List { sections.listRowBackground(GlassRow()) }
                .coordinateSpace(.named("daySheet"))
                .seaList().background { SeaBackground().ignoresSafeArea() }
                .onAppear { openedAt = Date() }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { Text(title).font(.custom("Trebuchet MS", size: 18).weight(.bold)) }
                    // Tinted, the same as Done in the open pane.
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold).foregroundStyle(.tint) }
                }
            }
            .tint(ChumbyPalette.acc(scheme == .dark))
            .presentationDetents([.height(fit), .large], selection: $detent)
        }
    }
}

// Opens the calendar alarms' settings in the open Duo's right pane; unset, they open as a sheet.
private struct OpenTemplateKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues { var openTemplate: (() -> Void)? { get { self[OpenTemplateKey.self] } set { self[OpenTemplateKey.self] = newValue } } }

extension CalendarWake {
    // The sound calendar alarms really ring with: their own set, else what one on the Chumby has, else the sound the next
    // update will borrow from your own alarm, and saying whose.
    func ringsWith(_ s: ChumbyState) -> (sound: String, snooze: String?) {
        if let t = s.calTpl ?? storedSettings { return (t.soundText, t.snooze) }
        if let c = s.alarms.first(where: { $0.isCalendar }) { return (c.soundText, c.snooze) }
        let real = s.alarms.filter { !$0.isCalendar && !$0.isPlaceholder && !$0.isHelper }
        if let a = real.first(where: { $0.isOn && $0.when != "once" }) ?? real.first(where: { $0.type == "audio" }) ?? real.first {
            return ("\(a.soundText) · same as \(alarmLabel(a))", a.snooze)
        }
        return (s.tones.first ?? "Beep", nil)
    }
}
// How every calendar alarm rings: the real sound, tinted, with a chevron, since it opens their settings.
struct CalendarSoundRow: View {
    @EnvironmentObject var model: ChumbyModel
    @ObservedObject private var wake = CalendarWake.shared
    @Environment(\.openTemplate) private var openTemplate
    var autoOpen = false
    @State private var editing = false
    @State private var opened = false
    var body: some View {
        let r = wake.ringsWith(model.state)
        Button { if let openTemplate { openTemplate() } else { editing = true } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.sound).foregroundStyle(.tint).lineLimit(1)
                    // Held back while an alarm rings or is about to, since a save restarts the alarm panel.
                    if model.calendarWaiting { Text("Saves after the alarm").font(.subheadline).foregroundStyle(.secondary) }
                    else if let z = r.snooze { Text("Snooze \(z) min").font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editing) { AlarmEditor(calendarTemplate: true).environmentObject(model) }
        .onAppear { if autoOpen && !opened && openTemplate == nil { opened = true; editing = true } }
    }
}
