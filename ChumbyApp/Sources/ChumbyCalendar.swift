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
    // What the calendar switch does, in one sentence wherever the switch is (Alarms and Calendar settings: designer, 11-11).
    static let what = "Rings before your first event."
    static let shared = CalendarWake()
    static let refreshID = "local.macpro.Chumby.calendar"
    nonisolated static let prefix = Alarm.calendarPrefix
    // The build's simulator shots, which have no calendar, show a sample plan in these.
    static let samplePoses: Set<String> = ["calendar", "calsettings", "calday", "caldayedit", "caldayown", "template", "alarmsdemo", "calonce"]
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
    private var samplePlan: [PlannedWake] = []
    func showSample() {
        rules.enabled = true; allowed = true
        let cal = Calendar.current, base = cal.startOfDay(for: Date())
        func shift(_ day: Int, _ hour: Int, _ title: String, work: Bool, lead: Int, short: String? = nil) -> PlannedWake {
            let start = cal.date(byAdding: .hour, value: day * 24 + hour, to: base) ?? base
            return PlannedWake(key: title + "\(day)", title: title, start: start, wake: start.addingTimeInterval(TimeInterval(-lead * 60)), lead: lead, isWork: work, shortNight: short)
        }
        samplePlan = [shift(1, 18, "Shift", work: true, lead: 160), shift(2, 13, "Dentist", work: false, lead: 120), shift(3, 18, "Shift", work: true, lead: 160)]
        plan = samplePlan
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
            plan = samplePlan
            for i in plan.indices {
                let k = plan[i].key, w = plan[i]
                plan[i].skipped = rules.skipped.contains(k)
                let lead = rules.leadOverrides[k] ?? w.lead
                plan[i].lead = lead; plan[i].wake = w.start.addingTimeInterval(TimeInterval(-lead * 60)); plan[i].exact = false
                if let at = rules.dayEdits[k]?.wakeAt, at < w.start.timeIntervalSince1970 {
                    plan[i].wake = Date(timeIntervalSince1970: at); plan[i].lead = Int((w.start.timeIntervalSince(plan[i].wake) / 60).rounded()); plan[i].exact = true
                }
                plan[i].label = rules.dayEdits[k]?.label.flatMap { $0.isEmpty ? nil : $0 }
                plan[i].own = rules.dayEdits[k]?.own
                plan[i].custom = rules.edited(k)
            }
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
    nonisolated static func minutes(_ d: Date) -> String { WakePlanner.minutes(d) }
    // A day's own label, when it has one, names its alarm on the Chumby in place of the event's title.
    nonisolated static func alarmName(_ w: PlannedWake) -> String { alarmName(title: w.shown) }
    nonisolated static func alarmName(title: String) -> String { WakePlanner.alarmName(title: title) }
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
        guard allowed else { return "Chumby can’t see your calendar." }
        // One reading of the calendar for both the plan and the check on what's already set, so they can't disagree.
        let evs = events()
        plan = WakePlanner.plan(evs, rules: rules)
        let wanted = rules.enabled ? plan.filter { !$0.skipped } : []
        // Whether a rule was changed by hand since the last update that went through (see CalendarKeep).
        let signature = WakePlanner.signature(rules)
        let synced = UserDefaults.standard.string(forKey: "wakeRulesSynced")
        let on = rules.enabled
        let keep = CalendarKeep(plan: plan, events: evs, labels: rules.dayEdits.compactMapValues { $0.label },
                                off: !on, rulesChanged: synced != nil && synced != signature)
        let stored = storedSettings
        do {
            // The same careful save as everything else: read fresh, change only the calendar's alarms, never under a
            // ringing alarm. The first time, the settings chosen here become the Chumby's set for every calendar alarm after.
            let r = try await chumbyTry { api in
                try await AlarmWriter.shared.edit(api, quiet: true, template: { s in s.calTpl == nil && stored != nil && s.alarms.contains { $0.isCalendar } }, planned: { s in
                    // A calendar that came back with nothing at all, while the Chumby holds wakes from it: far likelier a
                    // phone that couldn't read it (locked, access lapsed) than a calendar truly emptied. Nothing is sent.
                    if on, evs.isEmpty, s.alarms.contains(where: { $0.isCalendar && $0.isOn && $0.nextFire(after: s.chumbyNow ?? Date()) != nil }) {
                        throw ChumbyError.refused("Couldn’t read the calendar, so its alarms were left as they are. Pull down to try again.")
                    }
                    return s.applyCalendar(wanted, settings: s.calTpl ?? stored, keep: keep)
                })
            }
            if r.saved { saved?(r.state) }
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "wakeSynced")
            UserDefaults.standard.set(signature, forKey: "wakeRulesSynced")
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

extension CalendarWake {
    // "Just this once" for a calendar day: the day's own time, and its own sound when it differs from what the Chumby
    // holds for it, saved by the calendar's own update, so the day's one alarm moves in one save. CalendarKeep counts an
    // edited day as the user's call, and the save carries force=1 for the old time it drops, which the Chumby accepts
    // for a calendar alarm due today. Nil once it's on the Chumby; otherwise why not (the update's own note).
    func moveDay(_ item: PlannedWake, to at: Date, settings: Alarm, current: Alarm?) async -> String? {
        guard at < item.start else { return "Pick a time before it starts." }
        guard at.timeIntervalSinceNow >= 120 else { return "That’s too soon to set. Pick a later time." }
        func sound(_ a: Alarm) -> String { [a.type, a.arg, a.param, a.param_description, a.duration, a.snooze, a.auto_dismiss, a.action, a.action_param].joined(separator: "\u{1}") }
        var e = rules.dayEdits[item.key] ?? DayEdit()
        e.wakeAt = at.timeIntervalSince1970
        if let current, sound(settings) != sound(current) { var own = e.own ?? Alarm(); own.takeSettings(from: settings); e.own = own }
        rules.dayEdits[item.key] = e
        note = nil
        _ = await sync()
        return note
    }
}

struct ChumbyCalendarIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Chumby Alarms from Calendar"
    static var description = IntentDescription("Sets the Chumby’s alarms from your calendar. Run this from an automation to keep them current.")
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
                Toggle(isOn: $wake.rules.enabled) { TwoLine("Wake me from my calendar", CalendarWake.what) }
                    .soloCard()
                    .placeMark("cs-wake")
            }
            Section {
                leadRow("Work", $wake.rules.workLead).placeMark("cs-lead")
                leadRow("Anything else", $wake.rules.otherLead)
                leadRow("Extra for a location", $wake.rules.travelExtra)
                Stepper(value: $wake.rules.daysAhead, in: 1...7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plan ahead")
                        Text("\(wake.rules.daysAhead) wake-up\(wake.rules.daysAhead == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } header: { SectionHead(icon: "clock", text: "Awake before it starts") }
            Section {
                CalendarSoundRow(autoOpen: ChumbyModel.pose == "template").placeMark("cs-ring")
            } header: { SectionHead(icon: "music.note", text: "How they ring") }
            // Only on a Chumby that knows how.
            if let on = model.state.calOverride {
                Section {
                    Toggle(isOn: Binding(get: { on == 1 }, set: { v in Task { await model.setCalendarOverride(v) } })) {
                        TwoLine("Calendar days skip my other alarms", on == 1 ? "On a day your calendar wakes you, your repeating alarms stay quiet. They ring as usual the day after."
                                : "Your repeating alarms ring as usual, even on days your calendar wakes you.")
                    }
                    .soloCard(on: model.failed("calover") == nil)
                    .placeMark("cs-skip")
                    if let f = model.failed("calover") { FailNote(text: f) }
                } header: { SectionHead(icon: "bell.slash.fill", text: "Skipping other alarms") }
            }
            Section {
                WordsGroup(title: "Counts as work", words: $wake.rules.workWords).placeMark("cs-words")
                WordsGroup(title: "Never wake for", words: $wake.rules.ignoreWords)
                WordsGroup(title: "Days off", words: $wake.rules.offWords)
            } header: { SectionHead(icon: "text.quote", text: "Words in titles") }
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
                } footer: { if showCalendars { SectionFoot("Tap Work on a calendar to count everything in it as work.") } }
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
// Folded, and open in portrait, its own page pushed over Alarms, with the system's Back (laid out by iOS the Duo's
// way); open in landscape its sections fill the right pane (AlarmsTab).
struct CalendarWakeSettings: View {
    @EnvironmentObject var model: ChumbyModel
    var body: some View {
        List { PageTitle("Calendar settings"); CalendarSettingsSections().listRowBackground(GlassRow()) }
            .keepsPlace("page:Calendar settings")
            .pushedPage("settings")
    }
}
// A calendar day pushed over Alarms (folded, and open in portrait): the day's own settings, with the system's Back.
struct CalendarDayPage: View {
    @EnvironmentObject var model: ChumbyModel
    let key: String
    var body: some View {
        CalendarDaySheet(key: key, close: { model.alarmsPage = false }, done: false)
            .pushedPage("day")
    }
}
extension View {
    // A page pushed over a tab. Its name is its own first row (PageTitle), in the tabs' face and at their height, and
    // the system's bar holds only Back, which iOS lays out the Duo's way (the top of the side strip folded, the bar
    // along the top open in portrait). The system's large title is not used: a tab's own bar is hidden, so on Back the
    // bar went with it, and the title was cut out of the page before the slide began and its band closed up under the
    // rows as they went (CI bx, alarmsdemo 11.80 s and 15.58 s; Richard, 2026-11-10: "weird resizing issues at times
    // when going back on a screen from another"). The Mac Pro app's pushed pages are named the same way (pushedTitle).
    func pushedPage(_ name: String) -> some View { modifier(PushedPage(name: name)) }
}
private struct PushedPage: ViewModifier {
    let name: String
    @Environment(\.horizontalSizeClass) private var size
    func body(content: Content) -> some View {
        content
            .seaList()
            // Open in portrait the status bar and Back have the top to themselves, so the list's own top margin is left
            // off there, as on the tabs (TwoPane).
            .contentMargins(.top, size == .regular ? 0 : nil, for: .scrollContent)
            // Open in portrait the tab bar runs along the foot under this page too: its rows fade out above the bar, as a
            // tab's do, never reading through it (build 204: "Never wake for…" beside the bar).
            .modifier(TabBarFade(top: size == .regular))
            .overSea()
            .pageLog(name)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            // No title in the bar: a text item there forces a horizontal bar across the top even where the Duo puts
            // controls on the side, leaving Back alone on the strip (Richard, 2026-11-09: "the back button looks off …
            // not iphone duo").
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - One calendar day
// A calendar alarm opened: its event, and for that day alone its wake-up (how long before, or a set time), its label,
// whether it rings, and another sound or snooze; then how every calendar alarm sounds. Nothing here changes another day.
struct CalendarDaySheet: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wake = CalendarWake.shared
    @Environment(\.colorScheme) private var scheme
    // Folded: measured on first layout, a first guess until then.
    @State private var fit: CGFloat = 520
    @State private var detent: PresentationDetent = .height(520)
    @State private var openedAt = Date()
    @State private var labelText = ""
    @State private var problem: String?
    @State private var undoing = false
    @State private var ownSound = SoundChoice()
    @State private var ownAlarm = Alarm()
    @State private var ownBase: SoundChoice?
    let key: String
    // Set when it fills the open Duo's right pane, or the folded content column, instead of being a sheet.
    var close: (() -> Void)?
    // Pushed, the system's Back closes it, so it has no Done of its own.
    var done = true
    var item: PlannedWake? { wake.plan.first { $0.key == key } }
    var title: String { item.map { $0.wake.formatted(.dateTime.weekday(.wide)) } ?? "Calendar" }
    var edit: DayEdit { wake.rules.dayEdits[key] ?? DayEdit() }
    // One change to this day's own settings; an edit left with nothing in it is dropped, so the day is plainly usual again.
    func setEdit(_ change: (inout DayEdit) -> Void) {
        var e = edit
        change(&e)
        wake.rules.dayEdits[key] = e.isEmpty ? nil : e
    }
    func commitLabel() {
        let l = String(labelText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard l != (edit.label ?? "") else { return }
        setEdit { $0.label = l.isEmpty ? nil : l }
    }
    // A time on the clock, put on the last such time before the event starts, and never one already gone.
    func setExact(_ d: Date, for item: PlannedWake) {
        let cal = Calendar.current, c = cal.dateComponents([.hour, .minute], from: d)
        guard var t = cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: item.start) else { return }
        if t >= item.start { t = cal.date(byAdding: .day, value: -1, to: t) ?? t }
        guard t > Date().addingTimeInterval(60) else { problem = "That time has already gone. Pick a later one."; return }
        problem = nil
        setEdit { $0.wakeAt = t.timeIntervalSince1970 }
    }
    func useUsual(_ item: PlannedWake) {
        wake.rules.leadOverrides[key] = nil
        wake.rules.dayEdits[key] = nil
        labelText = ""; problem = nil
        loadOwn()
        if model.state.justOnce(for: item) != nil { undo() }
    }
    func undo() {
        undoing = true
        Task { problem = await model.undoJustOnce(); undoing = false }
    }
    @ViewBuilder var sections: some View {
        if let item {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.shown).font(.custom("Trebuchet MS", size: 24).weight(.bold))
                    if item.label != nil { Text("“\(item.title)” on your calendar").foregroundStyle(.secondary).lineLimit(1) }
                    Text("Starts \(item.start.formatted(.dateTime.weekday(.wide).hour().minute()))").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                Picker("Wake", selection: Binding(get: { item.exact }, set: { exact in
                    problem = nil
                    setEdit { $0.wakeAt = exact ? (item.wake.timeIntervalSince1970 / 60).rounded() * 60 : nil }
                })) {
                    Text("Before it starts").tag(false); Text("At a set time").tag(true)
                }
                .pickerStyle(.segmented)
                if item.exact {
                    DatePicker(selection: Binding(get: { item.wake }, set: { setExact($0, for: item) }), displayedComponents: .hourAndMinute) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rings at")
                            Text("\(leadText(item.lead)) before it starts").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } else {
                    Stepper(value: Binding(get: { item.lead }, set: { wake.rules.leadOverrides[key] = $0 }), in: 15...360, step: 5) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wake \(leadText(item.lead)) before")
                            Text("Rings at \(item.wake.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                if let problem { FailNote(text: problem) }
                HStack {
                    Text("Label")
                    TextField(item.title, text: $labelText).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                        .submitLabel(.done).onSubmit(commitLabel)
                }
                Toggle("Ring that day", isOn: Binding(get: { !item.skipped }, set: { _ in wake.toggleSkip(item) }))
            } header: { SectionHead(icon: "calendar", text: "Just this day") }
            soundSection(item)
            if item.custom || model.state.justOnce(for: item) != nil {
                Section {
                    Button("Use the usual settings") { useUsual(item) }.foregroundStyle(.tint).disabled(undoing)
                        .soloCard(note: "This day goes back to the usual.").background { foot }
                }
            }
            // No "How they all ring" here: a day's page changes that day alone, and the shared sound is set in Calendar
            // settings (and shown under Sounds). A control for every day on one day's page read as one more place the same
            // thing was set (Richard, 2026-11-09: "the logic of all the layouts … some of it is confusing").
        } else {
            Text("That day is no longer on your calendar.").foregroundStyle(.secondary).background { foot }
        }
    }
    // That day's own sound and snooze, or the shared set. Its own is sent marked as its own (I_own=1), which the Chumby
    // keeps for that alarm alone, on any day. A "just this once" set from Home for this day shows here too, with Undo.
    var shared: Alarm { model.state.calTpl ?? wake.storedSettings ?? model.state.alarms.first { $0.isCalendar && !$0.isOwn } ?? Alarm() }
    func loadOwn() {
        ownAlarm = edit.own ?? shared
        ownSound = SoundChoice(ownAlarm, state: model.state, stations: model.pandoraStations)
        ownBase = ownSound
    }
    func commitOwn() {
        guard edit.own != nil else { return }
        var a = Alarm()
        a.takeSettings(from: ownAlarm)
        // The sound is only rewritten once it's been changed here, so opening a day never alters what it plays.
        if ownSound != ownBase, let why = ownSound.apply(to: &a, state: model.state, stations: model.pandoraStations) { problem = why.errorDescription; return }
        if a != edit.own { setEdit { $0.own = a } }
    }
    @ViewBuilder func soundSection(_ item: PlannedWake) -> some View {
        Section {
            Picker("Sound", selection: Binding(get: { edit.own != nil }, set: { on in
                if on { var a = Alarm(); a.takeSettings(from: shared); setEdit { $0.own = a } } else { setEdit { $0.own = nil } }
                loadOwn()
            })) {
                Text("Same as the others").tag(false); Text("Different").tag(true)
            }
            .pickerStyle(.segmented)
            if edit.own != nil {
                SoundRows(choice: $ownSound, alarm: $ownAlarm, tail: AnyView(foot))
            } else {
                // The shared set, as information: dimmed, nothing to tap, and where it's changed (Richard, 2026-11-10:
                // read-only rows look read-only).
                let r = wake.ringsWith(model.state)
                LabeledContent("Plays", value: r.sound).lineLimit(1).foregroundStyle(.secondary).background { foot }
                if let z = r.snooze { LabeledContent("Snooze", value: "\(z) min").foregroundStyle(.secondary).background { foot } }
                Text("How every calendar alarm rings; change it in Calendar settings.").font(.footnote).foregroundStyle(.secondary).background { foot }
            }
            if let j = model.state.justOnce(for: item) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(j.alarm.soundText) · \(j.at.formatted(date: .omitted, time: .shortened))")
                        Text("Just this once, in place of the usual time").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if undoing { ProgressView() } else { Button("Undo") { undo() }.font(.subheadline.weight(.semibold)).foregroundStyle(.tint).buttonStyle(.borderless) }
                }
                .background { foot }
            }
        } header: { SectionHead(icon: "music.note", text: "Sound for this day") }
        .onChange(of: ownSound) { _, _ in commitOwn() }
        .onChange(of: ownAlarm) { _, _ in commitOwn() }
    }
    // Folded, where the last row ends, so the sheet can stop just under it. onGeometryChange reports the first layout too,
    // which onScrollGeometryChange never did, so the sheet used to stay at its first guess. Several rows carry it (whichever
    // of them is last depends on the day), and the lowest one wins (fitTo).
    @ViewBuilder var foot: some View {
        if close == nil {
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("daySheet")).maxY } action: { fitTo($0) }
        }
    }
    @State private var measured = false
    func fitTo(_ rowBottom: CGFloat) {
        // Only as it opens: later the row moves because the list is being scrolled, not because the sheet is the wrong size.
        guard Date().timeIntervalSince(openedAt) < 1.5 else { return }
        // The row's own bottom padding and a little air under the last card.
        let h = (rowBottom + 11 + 24).rounded()
        // The first row to report replaces the guess; after that only a lower row may move it, so the sheet fits the last.
        guard h > 200, abs(h - fit) > 1, !measured || h > fit else { return }
        measured = true
        let onFit = detent == .height(fit)
        fit = h
        // The new height is in the detents before it's chosen.
        if onFit { Task { @MainActor in detent = .height(h) } }
    }
    var body: some View {
        if let close {
            // Its own list in the pane, so the title row with Done stays pinned once scrolled (as the editor's does).
            let doneButton = Group { if done { Button("Done") { commitLabel(); close() }.fontWeight(.semibold).foregroundStyle(.tint) } }
            // Always its own list, pushed too (CalendarDayPage puts nothing around it): a list inside a list's row
            // collapsed to one empty bar, and rows handed up loose took this page's onAppear each, so a section scrolling
            // back reloaded the label and wiped what was typed (designer, 11-11).
            List {
                PageTitle(title, pins: done) { doneButton }
                sections.listRowBackground(GlassRow())
            }
            // Pinned only with its Done: a pushed page's way out is the system's Back.
            .pinsTitle(done) { PageTitle(title) { doneButton } }
            .keepsPlace("page:day:" + key)
            .onAppear { labelText = edit.label ?? ""; loadOwn() }
            .onDisappear { commitLabel() }
        } else {
            NavigationStack {
                // The folded sheet is as tall as what's in it (see foot), so no row is cut by its bottom edge, no empty sheet
                // hangs under the last one, and its top stays clear of the rail's clock.
                List { sections.listRowBackground(GlassRow()) }
                .coordinateSpace(.named("daySheet"))
                .seaList().background { SeaBackground().ignoresSafeArea() }
                .onAppear { openedAt = Date(); measured = false; labelText = edit.label ?? ""; loadOwn() }
                .onDisappear { commitLabel() }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Tinted, the same as Done in the open pane.
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { commitLabel(); dismiss() }.fontWeight(.semibold).foregroundStyle(.tint) }
                }
            }
            .tint(ChumbyPalette.acc(scheme == .dark))
            .presentationDetents([.height(fit), .large], selection: $detent)
        }
    }
}

extension ChumbyState {
    // The "just this once" standing in for this calendar day's alarm, if there is one.
    func justOnce(for item: PlannedWake) -> (alarm: Alarm, at: Date)? {
        guard let j = justOnce(), let r = j.replaces, r.name == CalendarWake.alarmName(item), abs(r.at - item.wake.timeIntervalSince1970) < 60 else { return nil }
        return (j.alarm, j.at)
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
        if let c = s.alarms.first(where: { $0.isCalendar && !$0.isOwn }) { return (c.soundText, c.snooze) }
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
    @Namespace private var editNS
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
        .zoomSource("template", in: editNS)
        .fillCover(isPresented: $editing) { AlarmEditor(calendarTemplate: true).environmentObject(model).zoomed(from: "template", in: editNS) }
        .onAppear { if autoOpen && !opened && openTemplate == nil { opened = true; editing = true } }
    }
}
