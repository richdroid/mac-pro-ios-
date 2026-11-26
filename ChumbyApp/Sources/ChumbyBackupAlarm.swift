import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
import AlarmKit
#endif

// The last line (Richard, 2026-11-19: "I need to be woken up by any means necessary"): for each ring the Chumby will
// make, this iPhone keeps an alarm of its own, set to ring a little after the Chumby's loud beep (music, then the beep,
// then the phone), which sounds through Silent and Focus. A Stop pressed on this phone (the app's page, the Lock Screen
// card, the notification, Siri or Control Center) takes it away, and so does a Stop on the Chumby itself once the Mac
// reads the Chumby's own record of it (a=hist "stop"; Richard, 11-19). A Snooze anywhere moves it. A ring that dies, plays
// out unheard or is cut off by a restart keeps it: that is exactly the one it is for. The rules are in ChumbyBackupPlan;
// this is the AlarmKit end.
#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
struct ChumbyBackupMeta: AlarmMetadata {}
#endif

// The only place AlarmKit is touched. (The Mac-side typecheck has no AlarmKit, so there it is empty and does nothing.)
private enum Kit {
    enum Auth { case notDetermined, denied, authorized }
    #if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
    private static func auth(_ s: AlarmManager.AuthorizationState) -> Auth {
        switch s { case .authorized: return .authorized; case .denied: return .denied; default: return .notDetermined }
    }
    static var state: Auth { auth(AlarmManager.shared.authorizationState) }
    static func request() async -> Auth { auth((try? await AlarmManager.shared.requestAuthorization()) ?? .denied) }
    static func cancel(_ id: UUID) { try? AlarmManager.shared.cancel(id: id) }
    static var ids: [UUID] { ((try? AlarmManager.shared.alarms) ?? []).map(\.id) }
    static func schedule(_ e: BackupPlan.Entry) async throws {
        let name = BackupPlan.shown(e.name)
        let title = name.isEmpty ? "Backup alarm" : "Backup alarm · \(name)"
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
        } else {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title),
                                            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
        }
        let attributes = AlarmAttributes<ChumbyBackupMeta>(presentation: AlarmPresentation(alert: alert), metadata: nil, tintColor: .orange)
        _ = try await AlarmManager.shared.schedule(id: e.id, configuration: .alarm(schedule: .fixed(e.fireAt), attributes: attributes))
    }
    #else
    static var state: Auth { .denied }
    static func request() async -> Auth { .denied }
    static func cancel(_ id: UUID) {}
    static var ids: [UUID] { [] }
    static func schedule(_ e: BackupPlan.Entry) async throws {}
    #endif
}

@MainActor
final class ChumbyBackupAlarm: ObservableObject {
    static let shared = ChumbyBackupAlarm()
    // delayKey: minutes after the Chumby's loud beep (11-19 on); oldDelayKey: minutes after the ring, as saved before
    static let onKey = "backupAlarmOn", delayKey = "backupAlarmAfterBeep", oldDelayKey = "backupAlarmDelay"
    // Once: a delay saved from the ring becomes one from the beep that rings the phone when it did (or just after the beep).
    static func migrateDelay() {
        let d = UserDefaults.standard
        guard d.object(forKey: delayKey) == nil, let old = d.object(forKey: oldDelayKey) as? Int else { return }
        d.set(BackupPlan.migrated(fromRing: old), forKey: delayKey)
    }
    private static let keptKey = "backupAlarms"

    enum Status { case off, notAsked, denied, on }
    @Published private(set) var status: Status = .off
    // the next backup armed, for the setting's line
    @Published private(set) var next: Date?
    // the Chumby's escalation as last read, for the setting's words
    @Published private(set) var escalation = BackupPlan.Escalation.standard

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.onKey) as? Bool ?? true }
    var delay: Int {
        Self.migrateDelay()
        let d = UserDefaults.standard.object(forKey: Self.delayKey) as? Int ?? BackupPlan.defaultDelay
        return BackupPlan.delays.contains(d) ? d : BackupPlan.defaultDelay
    }
    private var entries: [BackupPlan.Entry] {
        get { UserDefaults.standard.data(forKey: Self.keptKey).flatMap { try? JSONDecoder().decode([BackupPlan.Entry].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.keptKey) }
    }
    private var wanted: [BackupPlan.Ring]?
    private var tail: Task<Void, Never>?

    // One thing at a time, in the order asked, so two quick calls never schedule the same ring twice.
    private func queue(_ work: @escaping @MainActor () async -> Void) {
        let before = tail
        tail = Task { await before?.value; await work() }
    }

    // After every successful read of the Chumby's list: the rings coming up (BackupPlan.rings), and how the newest rings
    // ended there (a Stop or Snooze on the Chumby reaches the backup with any read, not only by the Mac's quiet push).
    func sync(rings: [BackupPlan.Ring], escalation: BackupPlan.Escalation = .standard, ends: [RingEnd] = [], length: @escaping (String) -> Int = { _ in 30 }) {
        wanted = rings
        if self.escalation != escalation { self.escalation = escalation }
        queue { [self] in
            await apply()
            guard !ends.isEmpty, enabled, Kit.state == .authorized else { return }
            let r = BackupPlan.fromEnds(entries, ends: ends, now: Date(), delay: delay, length: length)
            if !r.cancel.isEmpty || !r.add.isEmpty { await commit(r, keepOldOnFail: true) }
        }
    }
    // From the state just read: everything sync needs.
    func sync(state s: ChumbyState) {
        let lengths = Dictionary(s.alarms.map { ($0.name, Int($0.duration) ?? 30) }, uniquingKeysWith: { a, _ in a })
        sync(rings: BackupPlan.rings(in: s, now: Date()), escalation: BackupPlan.Escalation(s.escalate), ends: s.ends,
             length: { n in lengths[n].map { $0 > 0 ? $0 : 30 } ?? 30 })
    }
    // The setting changed: start or stop at once, from the rings last read.
    func settingsChanged() { queue { [self] in await apply() } }

    // The ring in progress was stopped, or ended (name: the alarm's, when known).
    func handled(name: String? = nil) {
        queue { [self] in
            let r = BackupPlan.handled(entries, now: Date(), name: name)
            await commit(r)
        }
    }
    // The ring in progress was snoozed until `until`. The new time is set before the old one goes, and should iOS refuse it
    // the old one stays: a backup at the first ring's time beats none during a snooze.
    func snoozed(name: String? = nil, until: Date) {
        queue { [self] in
            let r = BackupPlan.snoozed(entries, now: Date(), name: name, until: until, delay: delay)
            await commit(r, keepOldOnFail: true)
        }
    }

    // For a press made outside the app's page: the same, waited for, and said in words for the Mac's log ("ring: phone").
    private var said = ""
    func stopNow(name: String?) async -> String {
        queue { [self] in
            let r = BackupPlan.handled(entries, now: Date(), name: name)
            await commit(r)
            said = r.cancel.first.map { "backup " + Self.clock($0.fireAt) + " cancelled" } ?? "no backup live"
        }
        await settle()
        return said
    }
    func snoozeNow(name: String?, until: Date) async -> String {
        queue { [self] in
            let r = BackupPlan.snoozed(entries, now: Date(), name: name, until: until, delay: delay)
            await commit(r, keepOldOnFail: true)
            if let n = r.add.first { said = entries.contains(where: { $0.ringAt == n.ringAt && $0.fireAt == n.fireAt }) ? "backup moved to " + Self.clock(n.fireAt) : "backup move refused, kept" }
            else { said = BackupPlan.current(entries, now: Date(), name: name).map { "backup at " + Self.clock($0.fireAt) } ?? "no backup live" }
        }
        await settle()
        return said
    }
    // A Stop the Chumby hadn't confirmed when the press gave up waiting: should the Mac report the ring over within
    // 3 minutes, that was his Stop, and the backup goes then.
    private static let stopSentKey = "backupStopSent"
    func stopUnconfirmed(name: String?) {
        UserDefaults.standard.set(["at": Date().timeIntervalSince1970, "name": name ?? ""], forKey: Self.stopSentKey)
    }
    // the name pressed on ("" when unknown), or nil with no unconfirmed Stop in the last 3 minutes
    private func takeStopSent() -> String? {
        guard let d = UserDefaults.standard.dictionary(forKey: Self.stopSentKey), let at = d["at"] as? Double else { return nil }
        UserDefaults.standard.removeObject(forKey: Self.stopSentKey)
        guard Date().timeIntervalSince1970 - at < 180 else { return nil }
        return d["name"] as? String ?? ""
    }
    private static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    // What the bridge's quiet push said (see BackupPlan.signal).
    func push(_ userInfo: [AnyHashable: Any]) {
        switch BackupPlan.signal(userInfo, now: Date()) {
        // A ring that's gone is not a ring he dealt with: 11-19 it died after a few beeps. A plain "over" keeps the backup,
        // unless a Stop pressed here in the last 3 minutes, which the Chumby hadn't confirmed in time, was his.
        case .over?: if let n = takeStopSent() { handled(name: n.isEmpty ? nil : n) }
        // stopped on the Chumby itself: the Mac read the hook's "stop" row for this ring (Richard, 11-19: yes, cancel it)
        case .stopped(_, let at)?: queue { [self] in await commit(BackupPlan.stoppedRing(entries, now: Date(), at: at)) }
        case .snoozed(let name, let until)?: snoozed(name: name, until: until)
        case nil: break
        }
    }

    func refreshStatus() {
        next = entries.map(\.fireAt).filter { $0 > Date() }.min()
        guard enabled else { status = .off; return }
        switch Kit.state {
        case .authorized: status = .on
        case .denied: status = .denied
        case .notDetermined: status = .notAsked
        }
    }

    private func apply() async {
        guard !ChumbyNotify.shared.staged else { return }
        guard enabled else {
            await commit(BackupPlan.Result(entries: [], cancel: entries, add: []))
            refreshStatus()
            return
        }
        guard let wanted else { refreshStatus(); return }
        var auth = Kit.state
        // Asked the first time there is something to back up; a "no" is left alone (the setting says so).
        // only with him in the app: a prompt asked from a background refresh could hang the queue
        if auth == .notDetermined, !wanted.isEmpty, Self.inFront { auth = await Kit.request() }
        refreshStatus()
        guard auth == .authorized else { return }
        await commit(BackupPlan.reconcile(kept: entries, wanted: wanted, delay: delay, now: Date()))
        // Anything of ours the list no longer knows (a reinstall, a lost save) goes too.
        let known = Set(entries.map(\.id))
        for id in Kit.ids where !known.contains(id) { Kit.cancel(id) }
    }

    // New alarms first; an old one is cancelled only once whatever replaces it (same ring) is set, so a refusal from iOS
    // leaves the old one standing rather than no backup at all.
    private func commit(_ r0: BackupPlan.Result, keepOldOnFail: Bool = false) async {
        // stable ids (the ring's minute and a number), so the notification extension can cancel one with the app closed
        let r = BackupPlan.rekeyed(r0, inUse: Set(entries.map(\.id)).union(Kit.ids))
        var kept = r.entries
        var failed: [BackupPlan.Entry] = []
        for e in r.add {
            do { try await Kit.schedule(e) } catch { kept.removeAll { $0.id == e.id }; failed.append(e) }
        }
        var cancel = r.cancel
        for f in failed {
            let old = cancel.filter { $0.ringAt == f.ringAt && $0.name == f.name }
            cancel.removeAll { o in old.contains { $0.id == o.id } }
            kept.append(contentsOf: old)
        }
        for e in cancel { Kit.cancel(e.id) }
        entries = kept
        next = kept.map(\.fireAt).filter { $0 > Date() }.min()
    }
    private static var inFront: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return false
        #endif
    }
    // Waits for what's queued (a background refresh must finish before iOS suspends the app).
    func settle() async { await tail?.value }
}

// Tinker's "iPhone backup alarm": a switch and how long to wait, in Notifications' style.
struct BackupAlarmSettings: View {
    @ObservedObject private var backup = ChumbyBackupAlarm.shared
    @AppStorage(ChumbyBackupAlarm.onKey) private var enabled = true
    @AppStorage(ChumbyBackupAlarm.delayKey) private var delay = BackupPlan.defaultDelay
    init() { ChumbyBackupAlarm.migrateDelay() }
    var denied: Bool { enabled && backup.status == .denied }
    // Plainly, in the order it happens (Richard, 11-19: music, then the Chumby's loud beep, then the phone).
    var order: String {
        let e = backup.escalation
        guard e.first > 0 else { return "The Chumby’s loud beep is off, so this counts from when the alarm starts." }
        func m(_ s: Int) -> String { s % 60 == 0 ? "\(s / 60) min" : "\(s) s" }
        return "The alarm plays, the Chumby beeps loudly after \(m(e.first)), then the iPhone rings."
    }
    // "7:05 AM" today, "Sat 7:05 AM" on another day
    static func when(_ d: Date) -> String {
        let t = d.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(d) ? t : d.formatted(.dateTime.weekday(.abbreviated)) + " " + t
    }
    var body: some View {
        Section {
            Toggle(isOn: $enabled) { TwoLine("iPhone backup alarm", (backup.status == .on ? backup.next : nil).map { "Next: " + Self.when($0) } ?? "Rings through Silent if the Chumby alarm isn’t stopped.") }
                .padding(.trailing, 2)
                .onChange(of: enabled) { _, _ in ChumbyBackupAlarm.shared.settingsChanged() }
                .soloCard(on: !enabled && !denied)
            if enabled {
                MenuRow(title: "After the beep", note: order, selection: $delay) {
                    ForEach(BackupPlan.delays, id: \.self) { Text("\($0) min").tag($0) }
                }
                .onChange(of: delay) { _, _ in ChumbyBackupAlarm.shared.settingsChanged() }
            }
            #if canImport(UIKit)
            if denied, let u = URL(string: UIApplication.openSettingsURLString) {
                Link("Allow alarms in Settings", destination: u)
            }
            #endif
        } header: { SectionHead(icon: "alarm.fill", text: "Backup") }
        .task { ChumbyBackupAlarm.shared.refreshStatus() }
        #if canImport(UIKit)
        // back from Settings having allowed it: the link goes at once
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in ChumbyBackupAlarm.shared.refreshStatus() }
        #endif
    }
}
