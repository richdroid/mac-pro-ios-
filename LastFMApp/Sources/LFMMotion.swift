import Foundation
#if canImport(UIKit)
import UIKit
import QuartzCore
#if canImport(MetricKit)
import MetricKit
#endif

// Motion telemetry on his own phone (2026-11-26, after build 80: "smoothness is still very off esp the scroll"). The CI
// simulator's frame numbers never matched what he felt on the device, so the device measures itself: every touch
// opens an episode (a tap, a sideways swipe, a vertical scroll), timed by a display link from touch-down until the
// motion it started has had time to finish (a landing, a push's turnstile, a list's deceleration). Each episode is
// one line: its kind, the screen, the posture, the display's rate, how many frames were due and how many came, the
// longest gap and the hitch time per second, the finger's phase and the motion after it apart. Lines go to the Mac's
// bridge in small batches (POST /api/lastfm/motion, the address the app already uses for Claude's pieces); while the
// bridge can't take them they wait on disk. Nothing runs between touches: the link exists only inside an episode.
// MetricKit's daily animation and hang figures go the same way when the system hands them over.
@MainActor final class MotionProbe: NSObject {
    static let shared = MotionProbe()

    // The screen in front (RootView names it from the navigation path).
    static var screen = "home"

    private var link: CADisplayLink?
    private var watcher: TouchWatcher?
    private var ep: Episode?
    private var pending: [[String: Any]] = []
    private var sendTask: Task<Void, Never>?
    private var lastSend: Date = .distantPast
    private var started = false

    private let bridge: URL? = {
        var a = (UserDefaults.standard.string(forKey: "address") ?? "").trimmingCharacters(in: .whitespaces)
        if a.isEmpty { a = (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "").trimmingCharacters(in: .whitespaces) }
        guard !a.isEmpty else { return nil }
        if !a.contains("://") { a = "https://" + a }
        while a.hasSuffix("/") { a.removeLast() }
        return URL(string: a + "/api/lastfm/motion")
    }()
    private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    private static var file: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("motion-pending.jsonl") }

    // On only with a bridge to send to, never on the mock or in the build's films (-motion NO switches it off).
    var on: Bool { bridge != nil && !LastFM.shared.mock && UserDefaults.standard.object(forKey: "motion") as? String != "NO" }

    // Once the window exists: the touch watcher on it, MetricKit's subscriber, the batch left from last time.
    func start() {
        guard !started, on else { return }
        guard let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
            return
        }
        started = true
        let w = TouchWatcher(target: nil, action: nil)
        w.probe = self
        win.addGestureRecognizer(w)
        watcher = w
        if let d = try? Data(contentsOf: Self.file), let s = String(data: d, encoding: .utf8) {
            pending = s.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        #if canImport(MetricKit)
        MXMetricManager.shared.add(MetricSink.shared)
        #endif
        StallSampler.shared.start()
        flushSoon(after: 5)
    }

    // MARK: Episodes

    struct Phase {
        var frames = 0, missed = 0, late = 0
        var worst: Double = 0, hitch: Double = 0, span: Double = 0
        mutating func add(gap: Double, interval: Double) {
            frames += 1; span += gap
            worst = max(worst, gap)
            if gap > interval * 1.5 {
                late += 1
                missed += max(1, Int((gap / interval).rounded()) - 1)
                hitch += gap - interval
            }
        }
        var json: [String: Any] {
            ["frames": frames, "missed": missed, "late": late, "worst_ms": round1(worst * 1000), "hitch_ms": round1(hitch * 1000),
             "dur_ms": round1(span * 1000)]
        }
    }
    final class Episode {
        let began: CFTimeInterval
        let screen: String
        var screenEnd: String
        var lifted: CFTimeInterval?
        var until: CFTimeInterval
        var start = CGPoint.zero, travel = CGPoint.zero, maxTravel: CGFloat = 0
        var drag = Phase(), after = Phase()
        var last: CFTimeInterval = 0
        var interval: Double = 1.0 / 60
        var intervals: [Double: Int] = [:]
        var notes: [String] = []
        var stalls: [[String: Any]] = []
        var touches = 1
        init(at t: CFTimeInterval, screen: String) { began = t; until = t + 30; self.screen = screen; screenEnd = screen }
        var kind: String {
            if maxTravel < 10 { return "tap" }
            return abs(travel.x) >= abs(travel.y) ? "hswipe" : "vscroll"
        }
    }

    fileprivate func touchBegan(at p: CGPoint) {
        let now = CACurrentMediaTime()
        if let e = ep {
            // A second touch inside an episode's tail (a flick then a flick): the old one ends, a new one begins.
            if e.lifted != nil { close(now) } else { e.touches += 1; return }
        }
        let e = Episode(at: now, screen: Self.screen)
        e.start = p
        ep = e
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            let maxFPS = Float(UIScreen.main.maximumFramesPerSecond)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maxFPS), maximum: maxFPS, preferred: maxFPS)
            l.add(to: .main, forMode: .common)
            link = l
        }
        StallSampler.beat = CACurrentMediaTime()
        StallSampler.armed = true
    }
    fileprivate func touchMoved(to p: CGPoint) {
        guard let e = ep, e.lifted == nil else { return }
        e.travel = CGPoint(x: p.x - e.start.x, y: p.y - e.start.y)
        e.maxTravel = max(e.maxTravel, hypot(e.travel.x, e.travel.y))
    }
    fileprivate func touchEnded(at p: CGPoint?) {
        guard let e = ep, e.lifted == nil else { return }
        if e.touches > 1 { e.touches -= 1; return }
        if let p { touchMoved(to: p) }
        let now = CACurrentMediaTime()
        e.lifted = now
        // How long the motion a touch starts can run: a tap's push (turn-out, push, turn-in ≈ 0.7 s, plus a stall), a
        // swipe's landing (0.35 s), a list's deceleration (up to ~2 s).
        switch e.kind {
        case "tap": e.until = now + 1.4
        case "hswipe": e.until = now + 0.9
        default: e.until = now + 2.2
        }
    }

    // A pivot's or the panorama's landing, a push, a back: named in the episode it falls in.
    func note(_ s: String) {
        guard let e = ep else { return }
        e.notes.append(String(format: "%.0f ", (CACurrentMediaTime() - e.began) * 1000) + s)
    }
    nonisolated static func stall(_ ms: Double, at t: CFTimeInterval, frames: [String]) {
        Task { @MainActor in shared.ep?.stalls.append(["at_ms": round1((t - (shared.ep?.began ?? t)) * 1000), "ms": round1(ms), "stack": Array(frames.prefix(18))]) }
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let e = ep else { stopLink(); return }
        let now = l.timestamp
        let interval = max(l.targetTimestamp - l.timestamp, 1.0 / 240)
        StallSampler.beat = now
        if e.last > 0 {
            let gap = now - e.last
            if let lifted = e.lifted, now > lifted { e.after.add(gap: gap, interval: e.interval) } else { e.drag.add(gap: gap, interval: e.interval) }
        }
        e.interval = interval
        let key = (1 / interval).rounded()
        e.intervals[key, default: 0] += 1
        e.last = now
        if now >= e.until { close(now) }
    }

    private func close(_ now: CFTimeInterval) {
        guard let e = ep else { return }
        ep = nil
        e.screenEnd = Self.screen
        stopLink()
        let all = e.drag.frames + e.after.frames
        guard all > 2 else { return }
        let span = e.drag.span + e.after.span
        let hitch = e.drag.hitch + e.after.hitch
        let rate = e.intervals.max { $0.value < $1.value }?.key ?? 60
        let size = Win.bounds.size
        var line: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "build": Self.build,
            "kind": e.kind,
            "screen": e.screen,
            "posture": Self.posture(size),
            "size": "\(Int(size.width))x\(Int(size.height))",
            "fps": Int(rate),
            "max_fps": UIScreen.main.maximumFramesPerSecond,
            "dur_ms": round1(span * 1000),
            "expected": Int((span * rate).rounded()),
            "delivered": all,
            "missed": e.drag.missed + e.after.missed,
            "worst_ms": round1(max(e.drag.worst, e.after.worst) * 1000),
            "hitch_ms_per_s": span > 0 ? round1(hitch * 1000 / span) : 0,
            "drag": e.drag.json, "after": e.after.json,
            "dx": Int(e.travel.x), "dy": Int(e.travel.y),
            "rates": Dictionary(uniqueKeysWithValues: e.intervals.map { ("\(Int($0.key))", $0.value) }),
            "lpm": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        ]
        if e.screenEnd != e.screen { line["screen_end"] = e.screenEnd }
        if !e.notes.isEmpty { line["notes"] = e.notes }
        if !e.stalls.isEmpty { line["stalls"] = e.stalls }
        add(line)
    }
    private func stopLink() {
        link?.invalidate(); link = nil
        StallSampler.armed = StallSampler.always
    }

    static func posture(_ s: CGSize) -> String {
        if s.width < 500 { return s.width < s.height ? "folded" : "folded-land" }
        return s.height >= s.width ? "upright" : "flat"
    }

    // MARK: Sending

    func add(_ line: [String: Any]) {
        pending.append(line)
        if pending.count > 3000 { pending.removeFirst(pending.count - 3000) }
        save()
        flushSoon(after: pending.count >= 12 ? 1 : 20)
    }
    private func save() {
        let s = pending.compactMap { (try? JSONSerialization.data(withJSONObject: $0)).flatMap { String(data: $0, encoding: .utf8) } }.joined(separator: "\n")
        try? Data(s.utf8).write(to: Self.file, options: .atomic)
    }
    func flushSoon(after s: Double) {
        guard sendTask == nil else { return }
        sendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
            // Never while a finger is on the glass or a motion is running.
            while self?.ep != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            await self?.flush()
            self?.sendTask = nil
        }
    }
    func flush() async {
        guard let bridge, !pending.isEmpty else { return }
        let batch = Array(pending.prefix(200))
        let device: [String: Any] = ["model": Self.model, "os": UIDevice.current.systemVersion, "build": Self.build]
        guard let body = try? JSONSerialization.data(withJSONObject: ["device": device, "episodes": batch]) else { return }
        var r = URLRequest(url: bridge); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        guard let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else {
            lastSend = Date()
            return
        }
        pending.removeFirst(min(batch.count, pending.count))
        save()
        if !pending.isEmpty { flushSoon(after: 2) }
    }
    private static let model: String = {
        var s = utsname(); uname(&s)
        return withUnsafeBytes(of: &s.machine) { b in String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) }
    }()
}

private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

// Watches every touch on the window without ever taking part: it never recognises, cancels or delays anything, and is
// allowed alongside every other recogniser.
private final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var probe: MotionProbe?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { let p = t.location(in: view); MainActor.assumeIsolated { probe?.touchBegan(at: p) } }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { let p = t.location(in: view); MainActor.assumeIsolated { probe?.touchMoved(to: p) } }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let p = touches.first?.location(in: view)
        MainActor.assumeIsolated { for _ in touches { probe?.touchEnded(at: p) } }
        if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        MainActor.assumeIsolated { for _ in touches { probe?.touchEnded(at: nil) } }
        if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { state = .failed }
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy o: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf o: UIGestureRecognizer) -> Bool { false }
}

#if canImport(MetricKit)
// MetricKit's figures (scroll hitch ratio, hangs), as the system delivers them (about once a day), sent with the episodes.
final class MetricSink: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricSink()
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { send("metrickit", p.jsonRepresentation()) }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { send("metrickit-diagnostic", p.jsonRepresentation()) }
    }
    private func send(_ kind: String, _ d: Data) {
        let line: [String: Any] = ["kind": kind, "at": ISO8601DateFormatter().string(from: Date()), "payload": String(String(decoding: d, as: UTF8.self).prefix(80_000))]
        Task { @MainActor in MotionProbe.shared.add(line) }
    }
}
#endif
#endif
