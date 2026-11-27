import Foundation
#if DEBUG && canImport(UIKit)
import UIKit

// A frame meter for the build's films, never on the phone: only a Debug build launched with -frameLog YES. A display
// link counts the main thread's frames and writes, every 2 s, how many came, how many came late (an interval over 1.5×
// the display's refresh period, a dropped frame or worse) and the worst interval, to Caches/frame-log.txt; the build
// copies it out beside each film, so a page's smoothness is a number, not a reading of the recorder.
@MainActor
final class FrameLog: NSObject {
    static let shared = FrameLog()
    static var wanted: Bool { UserDefaults.standard.bool(forKey: "frameLog") }
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0, since: CFTimeInterval = 0, started: CFTimeInterval = 0
    private var frames = 0, late = 0, worst: CFTimeInterval = 0
    private var allFrames = 0, allLate = 0, allWorst: CFTimeInterval = 0, period: CFTimeInterval = 1 / 60
    private var lines: [String] = []
    private let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("frame-log.txt")

    func start() {
        guard Self.wanted, link == nil else { return }
        try? FileManager.default.removeItem(at: file)
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let p = l.targetTimestamp - l.timestamp
        if p > 0 { period = p }
        if last > 0 {
            let dt = now - last
            frames += 1
            if dt > 1.5 * period { late += 1 }
            if dt > worst { worst = dt }
        } else { since = now; started = now }
        last = now
        if now - since >= 2 { flush(now) }
    }

    private func flush(_ now: CFTimeInterval) {
        allFrames += frames; allLate += late; allWorst = max(allWorst, worst)
        lines.append(String(format: "%6.1f s  frames %4d  late %3d  worst %6.1f ms", now - started, frames, late, worst * 1000))
        frames = 0; late = 0; worst = 0; since = now
        let share = allFrames > 0 ? 100 * Double(allLate) / Double(allFrames) : 0
        let text = lines.joined(separator: "\n") + String(format: "\ntotal   frames %5d  late %4d  (%.1f%%)  worst %6.1f ms  period %.2f ms\n", allFrames, allLate, share, allWorst * 1000, period * 1000)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}
#endif
