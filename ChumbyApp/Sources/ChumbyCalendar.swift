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
    nonisolated static func alarmName(_ w: PlannedWake) -> String { prefix + String(w.title.prefix(30)) }
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
        refreshPlan()
        let wanted = rules.enabled ? plan.filter { !$0.skipped } : []
        let stored = storedSettings
        do {
            // The same careful save as everything else: read fresh, change only the calendar's alarms, never under a
            // ringing alarm. The first time, the settings chosen here become the Chumby's set for every calendar alarm after.
            let r = try await chumbyTry { api in
                try await AlarmWriter.shared.edit(api, quiet: true, template: { s in s.calTpl == nil && stored != nil && s.alarms.contains { $0.isCalendar } }) { s in
                    _ = s.applyCalendar(wanted, settings: s.calTpl ?? stored)
                }
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

extension ChumbyState {
    // Puts the calendar's alarms in the list, sounding like your own. True if anything changed.
    mutating func applyCalendar(_ wakes: [PlannedWake], settings: Alarm? = nil) -> Bool {
        let mine = alarms.filter { $0.isCalendar }
        let have = Set(mine.filter { $0.isOn }.map { $0.time + $0.name })
        let want = Set(wakes.map { CalendarWake.minutes($0.wake) + CalendarWake.alarmName($0) })
        if have == want && mine.filter({ !$0.isOn }).isEmpty { return false }
        let others = alarms.filter { !$0.isCalendar }
        // The sound of your repeating alarm, or failing that any alarm with a real sound.
        let real = others.filter { !$0.isPlaceholder && !$0.isHelper }
        let sound = real.first { $0.isOn && $0.when != "once" } ?? real.first { $0.type == "audio" } ?? real.first
        alarms = others
        for w in wakes {
            var a = sound ?? Alarm()
            if sound == nil, let tone = tones.first { a.type = "beep"; a.arg = tone; a.param_description = tone }
            if let settings { a.takeSettings(from: settings) }
            a.name = CalendarWake.alarmName(w); a.enabled = "1"; a.when = "once"; a.time = CalendarWake.minutes(w.wake)
            // Guessed from your own alarm, it only borrows the sound; chosen settings keep their own after-action and backup.
            if settings == nil { a.action = ""; a.action_param = ""; a.backup = "1" }
            if let free = alarms.firstIndex(where: { $0.isPlaceholder }) { alarms[free] = a } else { alarms.append(a) }
        }
        return true
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

func leadText(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60) h" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min" }

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
    @State private var editingSound = false
    @State private var showCalendars = false
    @State private var posed = false
    // How the calendar alarms ring: the Chumby's own set, else the one chosen here, else the first one's own.
    var calendarSound: Alarm? { model.state.calTpl ?? wake.storedSettings ?? model.state.alarms.first { $0.isCalendar } }
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
            } header: { Text("Awake before it starts") } footer: { Text("A day runs from \(wake.rules.dayStartHour) AM, so a late shift counts as the day it began.") }
            Section {
                // A sheet, so no chevron: the row says what it holds and opens the settings over the page.
                Button { editingSound = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calendarSound?.soundText ?? "Choose a sound").foregroundStyle(.primary).lineLimit(1)
                            // Held back while an alarm rings or is about to, since a save restarts the alarm panel.
                            if model.calendarWaiting { Text("Saves after the alarm").font(.subheadline).foregroundStyle(.secondary) }
                            else if let a = calendarSound { Text("Snooze \(a.snooze) min").font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Attached to this one row, not the whole group, so there's only ever one of it.
                .sheet(isPresented: $editingSound) { AlarmEditor(calendarTemplate: true).environmentObject(model) }
                .onAppear { if ChumbyModel.pose == "template" && !posed { posed = true; editingSound = true } }
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
            } header: { Text("Words in titles") } footer: { Text("Whole words, so “work” won’t match “workout”.") }
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
            ForEach(words, id: \.self) { Text($0) }
                .onDelete { words.remove(atOffsets: $0) }
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
// Folded, its own page, pushed so Back is where the system puts it, the same as the Mac Pro app's pages.
struct CalendarWakeSettings: View {
    var body: some View {
        List { CalendarSettingsSections().listRowBackground(GlassRow()) }
            .seaList()
            .overSea()
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("Calendar settings")
    }
}

// MARK: - One calendar day
// A calendar alarm opened: its event, that day's own wake-up time, whether it rings, and how calendar alarms sound.
struct CalendarDaySheet: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wake = CalendarWake.shared
    let key: String
    @State private var editingSound = false
    var item: PlannedWake? { wake.plan.first { $0.key == key } }
    var body: some View {
        NavigationStack {
            List { Group {
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
                    } footer: { Text("For this day only. The usual times are in Calendar settings.") }
                    Section {
                        Button { editingSound = true } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((model.state.calTpl ?? wake.storedSettings ?? model.state.alarms.first { $0.isCalendar })?.soundText ?? "Choose a sound").foregroundStyle(.primary)
                                Text("For every calendar alarm").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } header: { Text("How they ring") }
                } else {
                    Text("That day is no longer on your calendar.").foregroundStyle(.secondary)
                }
            }.listRowBackground(GlassRow()) }
            .seaList().background { SeaBackground().ignoresSafeArea() }
            .navigationTitle(item.map { $0.wake.formatted(.dateTime.weekday(.wide)) } ?? "Calendar").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $editingSound) { AlarmEditor(calendarTemplate: true).environmentObject(model) }
        }
    }
}
