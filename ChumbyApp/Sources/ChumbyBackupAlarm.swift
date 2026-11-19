import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
import AlarmKit
#endif

// The last line (Richard, 2026-11-19: "I need to be woken up by any means necessary"): for each ring the Chumby will
// make, this iPhone keeps an alarm of its own a few minutes later, which sounds through Silent and Focus. Stopping or
// snoozing the ring (here, on the Chumby, or as the Mac reports it) takes it away or moves it; a ring that ends with
// nothing reaching the phone is exactly the one it is for. The rules are in ChumbyBackupPlan; this is the AlarmKit end.
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
    static let onKey = "backupAlarmOn", delayKey = "backupAlarmDelay"
    private static let keptKey = "backupAlarms"

    enum Status { case off, notAsked, denied, on }
    @Published private(set) var status: Status = .off
    // the next backup armed, for the setting's line
    @Published private(set) var next: Date?

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.onKey) as? Bool ?? true }
    var delay: Int {
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

    // After every successful read of the Chumby's list: the rings coming up (BackupPlan.rings).
    func sync(rings: [BackupPlan.Ring]) {
        wanted = rings
        queue { [self] in await apply() }
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
    // The ring in progress was snoozed until `until`.
    func snoozed(name: String? = nil, until: Date) {
        queue { [self] in
            let r = BackupPlan.snoozed(entries, now: Date(), name: name, until: until, delay: delay)
            await commit(r)
        }
    }

    // What the bridge's quiet push said (see BackupPlan.signal).
    func push(_ userInfo: [AnyHashable: Any]) {
        switch BackupPlan.signal(userInfo, now: Date()) {
        // A ring that's gone is not a ring he dealt with: 11-19 it died after a few beeps. Only his own Stop (in this
        // app) takes the backup away; the Mac can't tell a Stop on the Chumby from a ring that failed.
        case .over?: break
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

    private func commit(_ r: BackupPlan.Result) async {
        for e in r.cancel { Kit.cancel(e.id) }
        var kept = r.entries
        for e in r.add {
            do { try await Kit.schedule(e) } catch { kept.removeAll { $0.id == e.id } }
        }
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
    var denied: Bool { enabled && backup.status == .denied }
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
                MenuRow(title: "Ring the iPhone after", note: "After the Chumby rings, or a snooze ends.", selection: $delay) {
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
