#if os(iOS)
import BackgroundTasks
import Foundation
import UIKit

// What iOS allows the Now Playing card while the app is closed, with the app signed by a free Apple ID (no push
// entitlement, so no ActivityKit push updates and nothing from the Mac can wake the phone):
// - about 30 s of work right after leaving the app (BackgroundGrace, run by TVModel.background);
// - an app refresh now and then, when iOS decides the app has earned one (minutes to hours; never on a schedule);
// - the island's own button, which runs the app's intent and re-reads the TV.
// The refresh reads the TV once and puts the card right: the title, the art, play or pause, where it's got to, or takes it
// down when the TV has stopped. It asks for the next one only while a card is still up.
enum TVBackground {
    static let refresh = "local.macpro.TV.nowplaying"
    // Before launch finishes, or iOS never calls it.
    static func register() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: refresh, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task)
        }
    }
    static func handle(_ task: BGAppRefreshTask) {
        let work = Task {
            let s = await TVBridge.status(timeout: 8)
            if let s, !Task.isCancelled { await TVIsland.sync(s, art: TVIsland.art(s)) }
            schedule()
            task.setTaskCompleted(success: s != nil)
        }
        task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
    }
    // Asked for only while a card is up: with nothing on the Lock Screen there is nothing to keep true. A request replaces
    // any earlier one. iOS treats the date as the earliest it may run, not when it will.
    static func schedule() {
        guard TVIsland.live != nil else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refresh); return }
        let r = BGAppRefreshTaskRequest(identifier: refresh)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 120)
        try? BGTaskScheduler.shared.submit(r)
    }
}

// The half minute iOS gives an app after it leaves the screen, held as one task: begun once, ended once, whether the work
// finishes or iOS calls time on it.
final class BackgroundGrace {
    private var id = UIBackgroundTaskIdentifier.invalid
    func begin(expired: @escaping () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: "now-playing") { [weak self] in expired(); self?.end() }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
