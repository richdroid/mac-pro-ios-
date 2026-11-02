import AppIntents
import EventKit
import SwiftUI
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

// Turns what's on this iPhone's calendar into real alarms on the Chumby, which then ring with or without the phone.
@MainActor
final class CalendarWake: ObservableObject {
    static let shared = CalendarWake()
    static let refreshID = "local.macpro.Chumby.calendar"
    static let prefix = "Calendar: "
    let store = EKEventStore()
    @Published var rules: WakeRules { didSet { save() } }
    @Published var plan: [PlannedWake] = []
    @Published var allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var note: String?
    @Published var lastSync: Date?
    private var running = false
    private var watching = false

    init() {
        if let d = UserDefaults.standard.data(forKey: "wakeRules"), let r = try? JSONDecoder().decode(WakeRules.self, from: d) { rules = r } else { rules = WakeRules() }
        lastSync = UserDefaults.standard.object(forKey: "wakeSynced") as? Date
        if UserDefaults.standard.string(forKey: "pose") == "calendar" { showSample() }
    }
    private func save() { if let d = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(d, forKey: "wakeRules") } }
    // For the build's simulator shots, which have no calendar.
    private func showSample() {
        rules.enabled = true; allowed = true
        let cal = Calendar.current, base = cal.startOfDay(for: Date())
        func shift(_ day: Int, _ hour: Int, _ title: String, work: Bool, lead: Int, short: String? = nil) -> PlannedWake {
            let start = cal.date(byAdding: .hour, value: day * 24 + hour, to: base) ?? base
            return PlannedWake(key: title + "\(day)", title: title, start: start, wake: start.addingTimeInterval(TimeInterval(-lead * 60)), lead: lead, isWork: work, shortNight: short)
        }
        plan = [shift(1, 18, "Shift", work: true, lead: 160), shift(2, 13, "Dentist", work: false, lead: 120), shift(3, 18, "Shift", work: true, lead: 160)]
    }
    func enable() async {
        do {
            let ok = try await store.requestFullAccessToEvents()
            allowed = ok
            if ok { rules.enabled = true; await sync() } else { note = "Allow Calendars for Chumby in Settings." }
        } catch { allowed = false; note = "Allow Calendars for Chumby in Settings." }
    }
    var calendars: [EKCalendar] { allowed ? store.calendars(for: .event).sorted { $0.title < $1.title } : [] }
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
    func refreshPlan() { if allowed { plan = WakePlanner.plan(events(), rules: rules) } }
    func startWatching() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in await CalendarWake.shared.sync() }
        }
    }
    func toggleSkip(_ item: PlannedWake) {
        if rules.skipped.contains(item.key) { rules.skipped.remove(item.key) } else { rules.skipped.insert(item.key) }
        Task { await sync() }
    }
    func offTheCalendar(_ s: ChumbyState) -> [Alarm] { s.alarms.filter { !$0.name.hasPrefix(Self.prefix) && !$0.isPlaceholder } }
    // Other alarms that will ring before this one that day, since nothing here switches off an alarm of yours.
    func alsoRinging(_ item: PlannedWake, in s: ChumbyState) -> String? {
        let cal = Calendar.current
        let names = offTheCalendar(s).compactMap { a -> String? in
            guard a.name != "Catch-up", let d = a.nextFire(after: item.wake.addingTimeInterval(-8 * 3600)), d < item.wake, cal.isDate(d, inSameDayAs: item.wake) else { return nil }
            return (a.name.isEmpty ? "Another alarm" : a.name) + " at " + d.formatted(date: .omitted, time: .shortened)
        }
        return names.first
    }
    // Reads the list fresh, changes only its own alarms, and saves only if something's different, because a save restarts
    // the Chumby's panel. Returns what happened, for Shortcuts.
    @discardableResult
    func sync() async -> String {
        guard !running else { return "Already updating." }
        running = true
        defer { running = false }
        allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard allowed else { return "Chumby can't see your calendar." }
        refreshPlan()
        let wanted = rules.enabled ? plan.filter { !$0.skipped } : []
        do {
            let result: String = try await chumbyTry { api in
                let sys = try JSONSerialization.jsonObject(with: await api.fresh("sys")) as? [String: Any]
                var state = try JSONDecoder().decode(ChumbyState.self, from: await api.fresh("state"))
                guard state.applyCalendar(wanted) else { return "Already up to date." }
                // Not while something is ringing or about to: the save would restart the panel under it.
                if let ring = sys?["ring"] as? String, !ring.isEmpty { return "Waiting: an alarm is ringing." }
                let soon = Date().addingTimeInterval(180)
                if state.alarms.compactMap({ $0.nextFire() }).contains(where: { $0 < soon }) { return "Waiting: an alarm is due." }
                try await api.post("save", body: ChumbyAPI.form(state.alarmForm()))
                return wanted.isEmpty ? "No calendar alarms needed." : "Updated \(wanted.count) calendar alarm\(wanted.count == 1 ? "" : "s")."
            }
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "wakeSynced")
            note = nil
            return result
        } catch {
            note = "Couldn’t reach the Chumby. It’ll try again."
            return "Couldn't reach the Chumby."
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
    mutating func applyCalendar(_ wakes: [PlannedWake]) -> Bool {
        func minutes(_ d: Date) -> String { String(Int(d.timeIntervalSince1970 / 60)) }
        func named(_ w: PlannedWake) -> String { CalendarWake.prefix + String(w.title.prefix(30)) }
        let mine = alarms.filter { $0.name.hasPrefix(CalendarWake.prefix) }
        let have = Set(mine.filter { $0.isOn }.map { $0.time + $0.name })
        let want = Set(wakes.map { minutes($0.wake) + named($0) })
        if have == want && mine.filter({ !$0.isOn }).isEmpty { return false }
        let others = alarms.filter { !$0.name.hasPrefix(CalendarWake.prefix) }
        // The sound of your repeating alarm, or failing that any alarm with a real sound.
        let real = others.filter { !$0.isPlaceholder && $0.name != "Catch-up" && $0.name != "Nap" }
        let sound = real.first { $0.isOn && $0.when != "once" } ?? real.first { $0.type == "audio" } ?? real.first
        alarms = others
        for w in wakes {
            var a = sound ?? Alarm()
            if sound == nil, let tone = tones.first { a.type = "beep"; a.arg = tone; a.param_description = tone }
            a.name = named(w); a.enabled = "1"; a.when = "once"; a.time = minutes(w.wake); a.action = ""; a.action_param = ""; a.backup = "1"
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

// MARK: - In the Alarms tab
struct CalendarWakeSection: View {
    @EnvironmentObject var model: ChumbyModel
    @ObservedObject private var wake = CalendarWake.shared
    func leadText(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60) h" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min" }
    var body: some View {
        Section {
            if wake.rules.enabled && wake.allowed {
                if wake.plan.isEmpty {
                    Text("Nothing coming up that needs waking for.").foregroundStyle(.secondary)
                }
                ForEach(wake.plan) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.wake.formatted(date: .omitted, time: .shortened)).font(.custom("Trebuchet MS", size: 26)).monospacedDigit()
                                Text(item.wake.formatted(.dateTime.weekday(.abbreviated))).font(.footnote).foregroundStyle(.secondary)
                            }
                            Text("\(item.title) at \(item.start.formatted(date: .omitted, time: .shortened)), \(leadText(item.lead)) before").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            if let short = item.shortNight { Label("Short night: \(short)", systemImage: "moon.zzz").font(.caption).foregroundStyle(.orange) }
                            if let other = wake.alsoRinging(item, in: model.state) { Label("Also rings earlier: \(other)", systemImage: "alarm").font(.caption).foregroundStyle(.orange) }
                        }
                        .opacity(item.skipped ? 0.45 : 1)
                        Spacer(minLength: 0)
                        Toggle("Ring", isOn: Binding(get: { !item.skipped }, set: { _ in wake.toggleSkip(item) })).labelsHidden()
                    }
                }
                NavigationLink("Calendar settings") { CalendarWakeSettings() }
            } else {
                Button { Task { await wake.enable() } } label: { Label("Wake me from my calendar", systemImage: "calendar.badge.clock") }
            }
        } header: {
            Text("From your calendar")
        } footer: {
            if let n = wake.note { Text(n) }
            else if wake.rules.enabled, let s = wake.lastSync { Text("Set on the Chumby, so they ring with your phone off. Updated \(s.formatted(.relative(presentation: .named))).") }
            else if !wake.rules.enabled { Text("Sets an alarm before the first thing each day, and moves it if your calendar changes.") }
        }
        .onAppear { wake.startWatching(); wake.refreshPlan(); if wake.rules.enabled { Task { await wake.sync(); await model.loadState() } } }
    }
}
struct CalendarWakeSettings: View {
    @ObservedObject private var wake = CalendarWake.shared
    func words(_ list: Binding<[String]>) -> Binding<String> {
        Binding(get: { list.wrappedValue.joined(separator: ", ") }, set: { list.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }
    func leadRow(_ label: String, _ value: Binding<Int>) -> some View {
        Stepper(value: value, in: 15...360, step: 5) {
            HStack { Text(label); Spacer(); Text(value.wrappedValue % 60 == 0 ? "\(value.wrappedValue / 60) h" : "\(value.wrappedValue / 60) h \(value.wrappedValue % 60) min").foregroundStyle(.secondary).monospacedDigit() }
        }
    }
    var body: some View {
        Form {
            Section {
                Toggle("Wake me from my calendar", isOn: $wake.rules.enabled)
            }
            Section {
                leadRow("Before work", $wake.rules.workLead)
                leadRow("Before anything else", $wake.rules.otherLead)
                leadRow("Extra if it has a location", $wake.rules.travelExtra)
                Stepper("Look ahead \(wake.rules.daysAhead) day\(wake.rules.daysAhead == 1 ? "" : "s")", value: $wake.rules.daysAhead, in: 1...7)
            } header: { Text("How long you need") } footer: { Text("It wakes you for the first thing each day. A day runs from \(wake.rules.dayStartHour) AM, so a shift ending at 2 AM still counts as the day it started.") }
            Section {
                TextField("Words", text: words($wake.rules.workWords)).autocorrectionDisabled()
            } header: { Text("Counts as work") } footer: { Text("Whole words in the title, so “work” doesn’t match “workout”.") }
            Section {
                TextField("Words", text: words($wake.rules.ignoreWords)).autocorrectionDisabled()
            } header: { Text("Never wake for") }
            Section {
                TextField("Words", text: words($wake.rules.offWords)).autocorrectionDisabled()
            } header: { Text("All-day events that mean no work") }
            Section("Calendars") {
                ForEach(wake.calendars, id: \.calendarIdentifier) { c in
                    VStack(alignment: .leading) {
                        Toggle(c.title, isOn: Binding(get: { !wake.rules.excludedCalendars.contains(c.title) }, set: { on in
                            if on { wake.rules.excludedCalendars.remove(c.title) } else { wake.rules.excludedCalendars.insert(c.title) }
                        }))
                        if !wake.rules.excludedCalendars.contains(c.title) {
                            Toggle("Everything here is work", isOn: Binding(get: { wake.rules.workCalendars.contains(c.title) }, set: { on in
                                if on { wake.rules.workCalendars.insert(c.title) } else { wake.rules.workCalendars.remove(c.title) }
                            })).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Calendar")
        .onDisappear { Task { await wake.sync() } }
    }
}
