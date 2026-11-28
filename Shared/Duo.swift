import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Two panes only when there's room side by side. Open in portrait the bars go horizontal and the fold runs across,
// so lists read better as one column, the same as on the outer display.
private struct PaneLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var paneLayout: Bool { get { self[PaneLayoutKey.self] } set { self[PaneLayoutKey.self] = newValue } } }
// How far FoldSplit has already moved its left pane in from the display's outer edge, so a page drawn by hand (not a
// List, whose cards land at the same place either way) can take it off its own inset and line up with the lists.
private struct PaneOuterKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues { var paneOuter: CGFloat { get { self[PaneOuterKey.self] } set { self[PaneOuterKey.self] = newValue } } }
struct PaneReader<C: View>: View {
    @Environment(\.horizontalSizeClass) private var size
    @State private var landscape = true
    @ViewBuilder let content: () -> C
    var body: some View {
        content()
            .environment(\.paneLayout, size == .regular && landscape)
            // Measured behind the keyboard's reach, or typing in portrait would look like turning sideways.
            .background { Color.clear.ignoresSafeArea().onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { landscape = $0 } }
    }
}

// Whether a navigation stack is pushing or popping a page right now (Back tapped, or the edge swipe under the finger).
// A page sliding on or off is moved by UIKit, and what it reads of itself while it moves (its safe area, where the fold is
// in its own space) is the slide's, not the scene's: read as layout, it squeezed and re-flowed the page as it went
// (Richard, 2026-11-09: "when u swipe a page off screen the elements compact as u do so"). Pages hold what they read at
// rest until the move is over.
//
// The move is noted before its first frame is laid out, however it began. The edge swipe told the app when it began; the
// Back button told no one, so a pop from Back was only noticed once a page had already read the slide's numbers: the
// page going off was laid out squeezed for a frame and the page coming back split wrongly for two, then both snapped to
// what they hold (Richard, 2026-11-10, a recording open flat: "weird resizing issues at times when going back on a
// screen from another"). Now every page a stack is about to show reports in (viewWillAppear, which UIKit calls at the
// start of any push or pop, before it moves anything), in all three apps, with nothing for an app to register.
//
// Not watched by any view (no Observation): the move is noted inside UIKit's layout (a page's viewWillAppear, a page's
// geometry reading), and on iOS 26 UIKit tracks what a view reads while it lays out, so a watched flag written there
// worked out every view that had read it, inside the same layout, over and over: the Calendar-settings push spent most
// of a 0.7 to 47 s main-thread turn in SwiftUI's ObservationGraphMutation and UIKit's "feedback loop detected" (gate 2 on
// chumby-fix-1127, the build's stall samples). A view reads the flags as it is worked out for reasons of its own; one
// that must act on a move's start or end listens for `began` or `ended`.
@MainActor @Observable final class NavTransit {
    static let shared = NavTransit()
    @ObservationIgnored private(set) var active = false
    // The move in flight is the edge swipe, under the finger. Only then does UIKit resize a page as it goes; a page taken
    // back with Back keeps its size and safe area the whole way (CI 8b7b68e, the hold off: not one reading of a page's
    // size changed through five pops), so only the swipe needs a page's size held.
    @ObservationIgnored private(set) var underFinger = false
    // Posted as each move begins and ends, for a view that wants the moment without being worked out again for it.
    nonisolated static let began = Notification.Name("duo.move.began")
    nonisolated static let ended = Notification.Name("duo.move.ended")
    // Called as each move ends: what an app kept back while a page was moving (a reading from its device) lands then.
    @ObservationIgnored var onEnd: (() -> Void)?
    #if canImport(UIKit)
    @ObservationIgnored private let stacks = NSHashTable<UINavigationController>.weakObjects()
    @ObservationIgnored private weak var current: AnyObject?
    // The build's "before" films: -noHold YES turns the hold off, to film a page as the system alone moves it, and
    // -holdLate YES leaves a move to be noticed the way it was (the edge swipe's start, or a page's first changed reading).
    @ObservationIgnored private let off = UserDefaults.standard.bool(forKey: "noHold")
    @ObservationIgnored private let late = UserDefaults.standard.bool(forKey: "holdLate")
    private init() {
        if !off, !late { _ = Self.hook }
        SwipeLog.frames()
    }
    // UIViewController.viewWillAppear, with the move noted after it. Exchanged once; every page of every stack passes here.
    private static let hook: Void = {
        let c: AnyClass = UIViewController.self
        guard let a = class_getInstanceMethod(c, #selector(UIViewController.viewWillAppear(_:))),
              let b = class_getInstanceMethod(c, #selector(UIViewController.duoWillAppear(_:))) else { return }
        method_exchangeImplementations(a, b)
    }()
    func register(_ n: UINavigationController) { if !off { stacks.add(n) } }
    // A page is about to show in this stack: if the stack is moving it there, the move begins now.
    func appearing(in n: UINavigationController) {
        guard !off else { return }
        stacks.add(n)
        if let c = n.transitionCoordinator { begin(c) }
    }
    // Marks the move in flight until its coordinator says it's over (finished, or the swipe let go and sprang back).
    func begin(_ c: UIViewControllerTransitionCoordinator) {
        guard !off, current !== (c as AnyObject) else { return }
        current = c as AnyObject
        if SwipeLog.on { SwipeLog.note(String(format: "move began (%.2f s%@)", c.transitionDuration, c.isInteractive ? ", under the finger" : "")) }
        if underFinger != c.initiallyInteractive { underFinger = c.initiallyInteractive }
        if !active {
            active = true
            // Posted after this turn's layout, never inside it.
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.began, object: nil) }
        }
        let queued = c.animate(alongsideTransition: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.current === (c as AnyObject) else { return }
                self.end()
            }
        }
        // Never stuck holding: if the coordinator can't report its end, or the move is over without saying so, the hold
        // ends once no stack is moving (checked a few times a second while it lasts).
        if !queued { Task { @MainActor in self.end() }; return }
        Task { @MainActor [weak self] in
            while let self, self.active {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if self.active, !self.stacks.allObjects.contains(where: { $0.transitionCoordinator != nil }) { self.end() }
            }
        }
    }
    private func end() {
        current = nil; SwipeLog.note("move ended")
        if active { active = false }
        if underFinger { underFinger = false }
        onEnd?()
        NotificationCenter.default.post(name: Self.ended, object: nil)
    }
    // Asked as a reading lands: true while any known stack is mid-move, and the move is noted if it wasn't yet.
    func moving() -> Bool {
        if let c = stacks.allObjects.lazy.compactMap(\.transitionCoordinator).first { begin(c); return true }
        return active
    }
    // The same, asked while a view is being laid out: nothing is noted, so nothing changes under the layout.
    var inFlight: Bool { active || (!late && stacks.allObjects.contains { $0.transitionCoordinator != nil }) }
    #else
    func moving() -> Bool { false }
    var inFlight: Bool { false }
    #endif
}
#if canImport(UIKit)
extension UIViewController {
    // Stands in for viewWillAppear (NavTransit.hook), so this calls the original.
    @objc dynamic func duoWillAppear(_ animated: Bool) {
        duoWillAppear(animated)
        if let n = navigationController { NavTransit.shared.appearing(in: n) }
    }
}
#endif

// What a page reads of itself (its size and safe area) through every push, pop and edge swipe, for the build's swipe log
// (-swipeLog). It changes nothing in the layout. It used to: under the finger it put back a size read at rest, to stop
// pages squeezing as they slid (Richard, 2026-11-09). With the system's own bars and navigation (11-23) a sliding page's
// size and safe area never change, as the build's films with the hold off showed, open flat, upright and folded (CI
// 5a48486, -noHold: not one reading changed in a swipe). What the hold did was the squeeze itself: it framed the page at
// its safe area's size and padded it by the safe area again, so under the finger every page lost the side strip's width
// and its top and foot (84 x 58 pt open flat) and sprang back on release (Richard's recording of TestFlight 317,
// 2026-11-26: "the sizing swiping issue"); framed at its whole area instead, it was centred and jumped 42 pt left (CI
// f7ab4fa). What re-flowed in a swipe was a FoldSplit following the crease as the page carried it; FoldSplit takes no
// reading while a move is in flight (NavTransit), which still watches every move.
struct HoldsWhileMoving: ViewModifier {
    let name: String
    struct Reading: Equatable { var size: CGSize; var insets: EdgeInsets }
    init(name: String) { self.name = name }
    func body(content: Content) -> some View {
        content
            .background {
                if SwipeLog.on {
                    Color.clear.ignoresSafeArea()
                        .onGeometryChange(for: Reading.self) { Reading(size: $0.size, insets: $0.safeAreaInsets) } action: { r in
                            // Asked without noting anything: this runs inside the layout (see NavTransit).
                            let moving = NavTransit.shared.inFlight
                            SwipeLog.note("\(name) \(moving ? "moving" : "rest") size \(Int(r.size.width))x\(Int(r.size.height)) insets t\(Int(r.insets.top)) l\(Int(r.insets.leading)) b\(Int(r.insets.bottom)) r\(Int(r.insets.trailing))")
                        }
                }
            }
            // Heard, not watched, so no page is worked out again as a move begins and ends (see NavTransit).
            .onReceive(NotificationCenter.default.publisher(for: NavTransit.began)) { _ in
                if SwipeLog.on { SwipeLog.note("\(name) transit began\(NavTransit.shared.underFinger ? " under the finger" : "")") }
            }
            .onReceive(NotificationCenter.default.publisher(for: NavTransit.ended)) { _ in if SwipeLog.on { SwipeLog.note("\(name) transit ended") } }
    }
}
extension View {
    func holdsWhileMoving(_ name: String) -> some View { modifier(HoldsWhileMoving(name: name)) }
}

// For the build's films of a page swiped off (-swipeLog YES, never on the phone): every reading a page takes and when the
// move began and ended, to Caches/swipe-log.txt, so a page that changes as it slides is caught in numbers, not only seen.
enum SwipeLog {
    // The build's films turn it on with -swipeLog YES; on the phone, Settings' "Record smoothness log" (smoothLog) does, so
    // the same log can be taken from his own hands and sent to the Mac (resize regate, 2026-11-11).
    nonisolated(unsafe) static var on = UserDefaults.standard.bool(forKey: "swipeLog") || UserDefaults.standard.bool(forKey: "smoothLog")
    static var file: URL? { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("swipe-log.txt") }
    static let start = Date()
    nonisolated(unsafe) private static var landedWatch: CFAbsoluteTime = 0
    // A view's body being worked out, for the build's logs: which pages a move or a reading made the app redraw.
    static func mark(_ s: String) { if on { note(s) } }
    static func note(_ s: String) {
        guard on, let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        if s.hasSuffix("landed") { landedWatch = CFAbsoluteTimeGetCurrent() + 0.5 }
        let line = String(format: "%.3f ", Date().timeIntervalSince(start)) + s + "\n"
        let url = dir.appendingPathComponent("swipe-log.txt")
        // One handle kept open: opening and closing the file for every line cost the main thread on each frame of a scroll,
        // which matters now the log runs on the phone.
        writeLock.lock(); defer { writeLock.unlock() }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url); handle?.seekToEndOfFile()
        }
        handle?.write(Data(line.utf8))
    }
    private static let writeLock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?
    // Starts the log afresh (the file removed): the next line opens a new one.
    static func restart() {
        writeLock.lock(); defer { writeLock.unlock() }
        try? handle?.close(); handle = nil
        if let file { try? FileManager.default.removeItem(at: file) }
    }
    // Every frame the main thread was late for (over 1.5 display periods), noted beside the readings, so a page that
    // stalls as a move begins is caught in the same log as the move.
    #if canImport(UIKit)
    @MainActor private static var meter: FrameGaps?
    @MainActor static func frames() { if on, meter == nil { meter = FrameGaps(); busy(); FrameStalls.shared.start() } }
    // And every turn of the main thread over 50 ms, with when it began, so what a late frame was waiting on can be read
    // off the notes written inside that turn (a view's `mark`, a reading landing, a move beginning).
    @MainActor private static var woke: CFAbsoluteTime = 0
    @MainActor private static func busy() {
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, a in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                if a == .afterWaiting { woke = now }
                else if woke > 0, now - woke > 0.05 { note(String(format: "main busy %.0f ms", (now - woke) * 1000)); woke = 0 }
                // Within half a second of a reading landing, every turn over 8 ms: what the landing cost the main thread,
                // apart from what the simulator's drawing costs after it.
                else if woke > 0, now < landedWatch, now - woke > 0.008 { note(String(format: "turn %.0f ms", (now - woke) * 1000)); woke = 0 }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
    }
    @MainActor private final class FrameGaps: NSObject {
        private var last: CFTimeInterval = 0
        override init() {
            super.init()
            CADisplayLink(target: self, selector: #selector(tick(_:))).add(to: .main, forMode: .common)
        }
        @objc private func tick(_ l: CADisplayLink) {
            let period = max(l.targetTimestamp - l.timestamp, 1.0 / 120)
            if last > 0, l.timestamp - last > 1.5 * period { SwipeLog.note(String(format: "late frame %.0f ms", (l.timestamp - last) * 1000)) }
            last = l.timestamp
            FrameStalls.beat = CACurrentMediaTime()
        }
    }
    #else
    @MainActor static func frames() {}
    #endif
}

#if canImport(UIKit)
// For the build's films only (-swipeLog YES from CI; never the phone's smoothness log, never on the phone): what the main
// thread was doing while it missed frames, so a stall is named from its stacks rather than guessed (this Mac can't run a
// profiler, and a launch pose's push stalled 0.6 to 7 s in the 11-26 and 11-27 films with nothing in the log to say why).
// A watchdog thread watches SwipeLog's display-link heartbeat; once the main thread is 25 ms late it samples the main
// thread's stack every 4 ms until the heartbeat returns. Nothing is allocated while the main thread is suspended
// (the samples go into a buffer made up front), since a lock it holds would never be released. Caches/stalls.txt gets
// each stall over 40 ms: its start on the swipe log's clock, its length, and every sample's frames, the app's own as
// image+offset (named with atos on the runner by ci/stall-names.py), the system's as library`symbol. Ported from
// Rotation's sampler (lastfm branch, LFMStalls.swift).
final class FrameStalls: @unchecked Sendable {
    static let shared = FrameStalls()
    nonisolated(unsafe) static var beat: CFTimeInterval = 0
    private let armed = UserDefaults.standard.bool(forKey: "swipeLog")
    private var main: thread_act_t = 0
    private var origin: CFTimeInterval = 0
    private let depth = 48, capacity = 400_000
    private let buf: UnsafeMutablePointer<UInt64>
    private var used = 0
    private var started = false
    private init() { buf = .allocate(capacity: 400_000) }
    // On the main thread.
    func start() {
        guard armed, !started else { return }
        started = true
        main = mach_thread_self()
        origin = CACurrentMediaTime() - Date().timeIntervalSince(SwipeLog.start)
        FrameStalls.beat = CACurrentMediaTime()
        let t = Thread { [self] in run() }
        t.qualityOfService = .userInteractive
        t.start()
    }
    private func run() {
        while true {
            usleep(2_000)
            let now = CACurrentMediaTime()
            guard FrameStalls.beat > 0, now - FrameStalls.beat > 0.025 else { continue }
            let began = FrameStalls.beat, from = used
            var n = 0
            // Every 4 ms: every millisecond, suspending the main thread that often stretched the stalls it measured on the
            // build's slow simulator (CI chumby-fix-1127).
            while FrameStalls.beat == began, used + depth + 2 < capacity {
                sample(); n += 1
                usleep(4_000)
                if CACurrentMediaTime() - began > 8 { break }
            }
            let ms = (CACurrentMediaTime() - began) * 1000
            if ms >= 40, n > 0 { write(from: from, to: used, start: began - origin, ms: ms) }
            used = from
            // One stall is written once: past the 8 s cap (or with the app away) the same heartbeat wrote a new "stall" every
            // few milliseconds, 17,000 of them in one run.
            while FrameStalls.beat == began { usleep(20_000) }
        }
    }
    // One sample: the main thread suspended, its registers read, its frame-pointer chain walked into the buffer.
    private func sample() {
        guard thread_suspend(main) == KERN_SUCCESS else { return }
        let at = used
        var k = 0
        var pc: UInt64 = 0, fp: UInt64 = 0, lr: UInt64 = 0
        #if arch(arm64)
        var st = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &st) { p in p.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(main, ARM_THREAD_STATE64, $0, &count) } }
        if kr == KERN_SUCCESS { pc = UInt64(st.__pc); fp = UInt64(st.__fp); lr = UInt64(st.__lr) }
        #elseif arch(x86_64)
        var st = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &st) { p in p.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(main, x86_THREAD_STATE64, $0, &count) } }
        if kr == KERN_SUCCESS { pc = st.__rip; fp = st.__rbp }
        #endif
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        if pc != 0 { buf[at + 1 + k] = pc & mask; k += 1 }
        if lr != 0 { buf[at + 1 + k] = lr & mask; k += 1 }
        var frame = (UInt64(0), UInt64(0))
        while fp != 0, k < depth {
            var got: vm_size_t = 0
            let r = withUnsafeMutableBytes(of: &frame) { b in
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(16), vm_address_t(UInt(bitPattern: b.baseAddress!)), &got)
            }
            guard r == KERN_SUCCESS, got == 16 else { break }
            let next = frame.0, ret = frame.1 & mask
            if ret == 0 { break }
            buf[at + 1 + k] = ret; k += 1
            guard next > fp else { break }
            fp = next
        }
        thread_resume(main)
        buf[at] = UInt64(k)
        used = at + 1 + k
    }
    private var names: [UInt64: String] = [:]
    private func name(_ a: UInt64) -> String {
        if let n = names[a] { return n }
        var info = Dl_info()
        var out = String(format: "0x%llx", a)
        if dladdr(UnsafeRawPointer(bitPattern: UInt(a)), &info) != 0, let f = info.dli_fname {
            let path = String(cString: f)
            let lib = (path as NSString).lastPathComponent
            if path.contains(".app/") && !path.contains("/Frameworks/") {
                out = String(format: "@%@+0x%llx", lib, a - UInt64(UInt(bitPattern: info.dli_fbase)))
            } else if let s = info.dli_sname { out = lib + "`" + String(cString: s) } else { out = lib + "`?" }
        }
        names[a] = out
        return out
    }
    private func write(from: Int, to: Int, start: Double, ms: Double) {
        var lines = [String(format: "stall t %.2f ms %.0f", start, ms)]
        var i = from
        while i < to {
            let k = Int(buf[i])
            var frames: [String] = []
            for j in 0..<k { frames.append(name(buf[i + 1 + j])) }
            lines.append("  " + frames.joined(separator: " | "))
            i += 1 + k
        }
        guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("stalls.txt") else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
        SwipeLog.note(String(format: "stall %.0f ms (stacks in stalls.txt)", ms))
    }
}
#endif

// What one scrolling page is doing, for each app's hold on polled readings (its ScrollHold): read from the page's
// geometry as much as from its phase. Two things a phase alone never gave, and each let a reading land on a page pulled
// past its end, which a List answers by clamping its offset back into range in one frame instead of springing (Richard,
// 2026-11-08 and 2026-11-10: "it doesnt bounce back naturally its like a sudden move back"):
//  - a List reports no scroll phase (Mac Pro CI 6da2654), so a hold read from the phase alone never engaged on a List
//    page at all (Chumby's Alarms and settings, the TV's lists), and one read from the offset alone lapsed the moment a
//    finger held the page still past its end for more than its grace (every real pull pauses before it lets go; the
//    build's drags never do, which is why its films sprang and his phone snapped);
//  - past either end the page is held whatever the phase says, finger down and still, on its way back, or at rest short
//    of range. Readings land only once it's back in range and has been still for 0.6 s.
// `set` is the app's ScrollHold.set for this page; it's called again each tick while the page is held past the end, so a
// hold that counts from the last motion stays fresh. Every reading goes to the swipe log (never on the phone).
@MainActor
final class ScrollWatch {
    let name: String
    private let set: @MainActor (Bool) -> Void
    private var touching = false
    private(set) var past = false
    private var lastMove = Date.distantPast
    private var watch: Task<Void, Never>?
    private(set) var holding = false
    init(_ name: String, set: @escaping @MainActor (Bool) -> Void) { self.name = name; self.set = set }
    // Every change of the page's offset, content, insets or container. Past the end: more than half a point above the
    // top (its inset allowed for) or beyond the end, which is the content and both insets less the container, never
    // less than nothing for a page shorter than its container.
    func geometry(_ g: ScrollGeometry) {
        let y = g.contentOffset.y + g.contentInsets.top
        let end = max(g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom - g.containerSize.height, 0)
        let now = y < -0.5 || y > end + 0.5
        if SwipeLog.on { SwipeLog.note("\(name) y \(Int(y.rounded())) end \(Int(end.rounded()))\(now ? " past" : "")") }
        if now != past { past = now }
        moved()
    }
    func phase(touching t: Bool) { touching = t; moved() }
    private func moved() { lastMove = Date(); hold() }
    private func hold() {
        if !holding { holding = true; SwipeLog.note("\(name) hold on") }
        set(true)
        guard watch == nil else { return }
        watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self else { return }
                if self.past { self.set(true); continue }
                if !self.touching, Date().timeIntervalSince(self.lastMove) > 0.6 { self.release(); return }
            }
        }
    }
    private func release() { watch = nil; holding = false; SwipeLog.note("\(name) hold off"); set(false) }
    func stop() { watch?.cancel(); watch = nil; touching = false; past = false; if holding { holding = false; set(false) } }
}

// The fold as these pages last read it with the crease in sight, by the size of the page that read it. A page that
// isn't the one in front is told of no fold at all (open flat, it read "no crease" the whole time a page covered it),
// and that was what it held as it came back: a tab returned to with Back was split down its middle, off the crease,
// for the length of the pop, then snapped across to the crease as the pop ended (Richard's recording, 2026-11-10,
// and CI 8b7b68e frame by frame). A page that can't see the crease lays out by what was last seen instead.
// Kept across launches too: on a cold launch open flat nothing had been seen yet, so both panes were laid out split down
// the middle and moved across to the crease when it was first read, a second or two in, every row reflowing as they went
// (Mac Pro CI a6bba65, open flat: the dials' row 234 to 213 pt, the right pane's content 828 to 807, at 2.7 s).
@MainActor private enum FoldSeen {
    private static let key = "foldSeenSplits"
    static var bySize: [String: FoldSeenSplit] = load() { didSet { save() } }
    static var last: FoldSeenSplit? = bySize["last"]
    private static func load() -> [String: FoldSeenSplit] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] else { return [:] }
        return raw.compactMapValues { v in v.count == 3 ? FoldSeenSplit(ratio: v[0] < 0 ? nil : CGFloat(v[0]), gutter: CGFloat(v[1]), outer: CGFloat(v[2])) : nil }
    }
    private static func save() {
        var all = bySize; if let last { all["last"] = last }
        UserDefaults.standard.set(all.mapValues { [Double($0.ratio ?? -1), Double($0.gutter), Double($0.outer)] }, forKey: key)
    }
}
struct FoldSeenSplit: Equatable { var ratio: CGFloat?; var gutter: CGFloat; var outer: CGFloat }
// Two panes, in Apple's container: side by side when wide, stacked when tall, and clear of the fold when partly closed.
// Lying flat it would split the area left of the side bars, putting the seam off the crease, so it's told where the hinge is.
struct FoldSplit<L: View, R: View>: View {
    let left: L, right: R
    init(@ViewBuilder _ left: () -> L, @ViewBuilder right: () -> R) { self.left = left(); self.right = right() }
    typealias Split = FoldSeenSplit
    // The split this page lays out by: the one it last read at rest with the crease in sight, for the size of page it
    // was read for. The fold is read in the view's own space, so while a page slides off (or the page under it slides
    // back) the crease seemed to travel across it, and the seam followed: the left pane narrowed to a third as the page
    // went. A reading taken while a move is in flight, or with no crease in it, is never taken up.
    // Laying out never asks whether a move is in flight, only each new reading does: a page that watched for moves was
    // worked out again as every push and pop began and again as it ended, both panes of it, on the main thread at the
    // moment the move should start (CI f7a119a: Status's two panes three times over in one pop).
    @State private var held: (key: String, split: Split)?
    @MainActor final class Pending { var read: FoldSeenSplit?; var task: Task<Void, Never>? }
    @State private var pending = Pending()
    var body: some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            GeometryReader { g in
                let wide = g.size.width > g.size.height
                let folded = !g.reservedRegions(kind: .division).isEmpty
                let crease = g.reservedRegions(kind: .division, options: .includeInactive).first?.frame
                let hinge = crease?.midX
                // To the hundredth: a crease read a few thousandths apart (0.548, then 0.551) was a second reflow of every row.
                let ratio: CGFloat? = wide && !folded ? hinge.map { (min(max($0 / g.size.width, 0.3), 0.7) * 100).rounded() / 100 } : nil
                // Each pane stops short of the crease, which is about 40 pt wide: half of it plus a little air, and never
                // less than 24, so no card sits on the fold.
                let gutter: CGFloat = wide && !folded ? min(max(24, (crease?.width ?? 0) / 2 + 4), 40) : 0
                // Open, the left pane meets the display's bare outer edge (no safe area there), so its cards and titles get
                // the same air from that edge as the right pane has from the side column.
                let outer: CGFloat = wide && !folded ? 14 : 0
                let read = Split(ratio: ratio, gutter: gutter, outer: outer)
                // Open flat with no crease in the reading: covered, or not in front yet.
                let open = wide && !folded
                let blind = open && crease == nil
                // A split belongs to one size of page in one posture; turned or folded, the page reads afresh.
                let key = "\(Int(g.size.width))x\(Int(g.size.height))\(open ? " open" : "")"
                // Its own last reading at rest; else what a page this size last read (a tab first shown under a page);
                // else what any page last read open flat; else, with nothing to go by yet, what it reads now.
                // With nothing seen yet (the first launch open flat after an install), the hinge is taken to be the display's
                // centre, where the Duo's is, so the panes don't start split down the page's middle and move across when the
                // crease is first read (designer, resize gate: the first open-flat launch reflowed).
                // Where the Duo's hinge is: the middle of the window. With nothing seen yet, the panes split there; and a crease
                // read anywhere else is a reading taken mid-turn (0.35 with a 40 pt crease, 0.50), never one to lay out by
                // (designer, resize gate on cbdef0e: a turn adopted 0.350 and the panes moved twice).
                let centreRatio: CGFloat? = open ? {
                    let f = g.frame(in: .global)
                    let w = (UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.width) ?? (f.maxX + f.minX)
                    return (min(max((w / 2 - f.minX) / max(g.size.width, 1), 0.3), 0.7) * 100).rounded() / 100
                }() : nil
                let centre: Split? = blind ? Split(ratio: centreRatio, gutter: 24, outer: 14) : nil
                let plausible = !open || (read.ratio != nil && centreRatio != nil && abs(read.ratio! - centreRatio!) <= 0.03)
                let use = (held?.key == key ? held?.split : nil) ?? (open ? FoldSeen.bySize[key] ?? FoldSeen.last ?? centre : nil) ?? read
                // A reading at rest with the crease in sight (or where there's none to see: folded, upright) is the one to
                // lay out by and to remember.
                let take: () -> Void = {
                    guard !blind, plausible, !NavTransit.shared.moving() else { return }
                    // Turned into a posture this page has a split for already: that split stands until a different reading
                    // has held for 0.4 s. Mid-turn the crease reads half-way (0.50) for a frame or two, and the panes moved
                    // to it and back (designer, resize regate: 0.548, 0.500, 0.548 in one turn).
                    // A size of page not seen before counts too (mid-turn the page passes through sizes of its own, and one
                    // read half-way there was taken as that size's split, bd75948): whatever the panes are using stays
                    // until the new reading has lasted.
                    let current = (held?.key == key ? held?.split : nil) ?? FoldSeen.bySize[key] ?? FoldSeen.last
                    if open, let saved = current, saved != read {
                        pending.read = read
                        pending.task?.cancel()
                        pending.task = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            guard !Task.isCancelled, pending.read == read else { return }
                            FoldSeen.last = read; FoldSeen.bySize[key] = read
                            held = (key, read)
                        }
                        if held?.key != key { held = (key, saved) }
                        return
                    }
                    pending.task?.cancel(); pending.read = nil
                    if open, FoldSeen.bySize[key] != read || FoldSeen.last != read { FoldSeen.last = read; FoldSeen.bySize[key] = read }
                    if held?.key != key || held?.split != read { held = (key, read) }
                }
                // Two panes side by side: no scroll indicators in either. Each pane is its own scroll view, and each drew its
                // own bar, one at the fold and one by the rail (Richard, 2026-11-20, Status open flat: "this dual scroll
                // bar shit looks awful").
                let twoPanes = wide
                ArrangementView {
                    left.environment(\.paneOuter, use.outer).padding(.leading, use.outer).padding(.trailing, use.gutter)
                        .scrollIndicators(twoPanes ? .hidden : .automatic, axes: .vertical)
                        .splitArrangementLayoutRatio(use.ratio)
                } secondary: {
                    right.padding(.leading, use.gutter)
                        .scrollIndicators(twoPanes ? .hidden : .automatic, axes: .vertical)
                }
                .arrangementViewStyle(.split)
                .onChange(of: read, initial: true) { _, v in
                    take()
                    SwipeLog.note("split ratio \(v.ratio.map { String(format: "%.3f", $0) } ?? "nil") gutter \(Int(v.gutter))\(blind ? " (no crease)" : "")\(NavTransit.shared.inFlight ? " (moving)" : "") using \(use.ratio.map { String(format: "%.3f", $0) } ?? "nil")")
                }
                .onChange(of: key) { _, _ in take() }
                // What it read as a move ended is a reading at rest too, though it didn't change to become one.
                .onReceive(NotificationCenter.default.publisher(for: NavTransit.ended)) { _ in take() }
            }
        } else { sideBySide }
        #else
        sideBySide
        #endif
    }
    private var sideBySide: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity)
            right.frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden, axes: .vertical)
    }
}

// Side bar icons, every one fitted to the same box. Symbols and logos have their own natural proportions, which is
// what makes a wide display look bigger than a narrow remote.
#if canImport(UIKit)
// Sized by the shape actually drawn, not its canvas, since artwork like the Claude star has empty space around it.
private func inkBounds(_ image: UIImage) -> (CGImage, CGRect)? {
    let side = 192
    let k = CGFloat(side) / max(image.size.width, image.size.height)
    let w = max(Int(image.size.width * k), 1), h = max(Int(image.size.height * k), 1)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let made: CGImage? = px.withUnsafeMutableBytes { raw in
        guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        UIGraphicsPushContext(c)
        c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
        image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        UIGraphicsPopContext()
        return c.makeImage()
    }
    guard let made else { return nil }
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 24 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= minX else { return nil }
    return (made, CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
}
// The app redraws its root often and these only need working out once.
private let iconCache = NSCache<NSString, UIImage>()
private func cachedIcon(_ key: String, fit: CGFloat, _ make: () -> UIImage?) -> UIImage {
    let id = "\(key)-\(fit)" as NSString
    if let hit = iconCache.object(forKey: id) { return hit }
    let icon = evenIcon(make(), fit: fit)
    iconCache.setObject(icon, forKey: id)
    return icon
}
private func evenIcon(_ source: UIImage?, fit: CGFloat = 25) -> UIImage {
    let canvas = fit + 2
    guard let source, let (full, ink) = inkBounds(source), let cut = full.cropping(to: ink) else { return UIImage() }
    let k = fit / max(ink.width, ink.height)
    let w = ink.width * k, h = ink.height * k
    let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
    return UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas), format: format).image { _ in
        UIImage(cgImage: cut).draw(in: CGRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h))
    }.withRenderingMode(.alwaysTemplate)
}
#endif
func tabLabel(_ title: String, _ symbol: String) -> some View {
    Label {
        Text(title)
    } icon: {
        #if canImport(UIKit)
        Image(uiImage: cachedIcon(symbol, fit: 25) { UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 60, weight: .regular)) })
        #else
        Image(systemName: symbol)
        #endif
    }
}
func tabLabel(_ title: String, asset: String, fit: CGFloat = 25) -> some View {
    Label {
        Text(title)
    } icon: {
        #if canImport(UIKit)
        Image(uiImage: cachedIcon(asset, fit: fit) { UIImage(named: asset) })
        #else
        Image(asset)
        #endif
    }
}

// A tab: its value, name and icon, for the system's TabView.
struct RailItem: Identifiable {
    let value: Int
    let title: String
    var symbol: String? = nil
    var asset: String? = nil
    // How large an asset icon is fitted (the Chumby's octopus is drawn small in its box, so it takes 34).
    var fit: CGFloat = 25
    var id: Int { value }
    @ViewBuilder var label: some View {
        if let asset { tabLabel(title, asset: asset, fit: fit) } else { tabLabel(title, symbol ?? "circle") }
    }
}

// Whether a tab's page is on the tab in front. The system's TabView hands each tab's content this (RootView), so what
// must stop when he leaves a tab (polling, the Dashboard's music) follows it as well as its appearance.
private struct DuoTabFrontKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues { var duoTabFront: Bool { get { self[DuoTabFrontKey.self] } set { self[DuoTabFrontKey.self] = newValue } } }
// Whether iOS has its bars down the side strip (folded, open flat, folded on its side) rather than across the top and foot
// (open upright), read from the scene's safe area around the system's TabView: the status bar, the tab bar and the bar
// items stand in that strip, on the trailing edge, or the leading one folded and turned on its side with the camera
// there. The Mac Pro's Status portrait (small beside the strip, big open upright) and Mint Remote's gear (a bar item in
// the strip, the lip's key open upright) follow it.
private struct TabsSideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var tabsSide: Bool { get { self[TabsSideKey.self] } set { self[TabsSideKey.self] = newValue } } }
struct SideStripReader: ViewModifier {
    @State private var side = false
    func body(content: Content) -> some View {
        content
            .environment(\.tabsSide, side)
            .onGeometryChange(for: Bool.self) { g in
                let i = g.safeAreaInsets
                return i.trailing > 30 || (i.leading > 30 && i.leading > i.trailing)
            } action: { side = $0 }
    }
}
extension View { func readsSideStrip() -> some View { modifier(SideStripReader()) } }
// A `.task` that runs while its tab is in front: started when the page appears in front, ended when another tab comes in
// front, started afresh when its tab comes back, as a page in the system's TabView did.
struct TaskInFront: ViewModifier {
    @Environment(\.duoTabFront) private var front
    let work: @Sendable () async -> Void
    func body(content: Content) -> some View {
        content.task(id: front) { if front { await work() } }
    }
}
// The same, started afresh also whenever `id` changes, as `.task(id:)`.
struct TaskInFrontID<ID: Equatable>: ViewModifier {
    @Environment(\.duoTabFront) private var front
    let id: ID
    let work: @Sendable () async -> Void
    struct Key: Equatable { let front: Bool; let id: ID }
    func body(content: Content) -> some View {
        content.task(id: Key(front: front, id: id)) { if front { await work() } }
    }
}
extension View {
    func taskInFront(_ work: @escaping @Sendable () async -> Void) -> some View { modifier(TaskInFront(work: work)) }
    func taskInFront<ID: Equatable>(id: ID, _ work: @escaping @Sendable () async -> Void) -> some View { modifier(TaskInFrontID(id: id, work: work)) }
}

// Reading a value off a chart that sits in a scrolling page: rest a finger on it for a moment, then slide. It's the
// system's own long press, which never holds up the page: a finger that moves before the moment is up was scrolling,
// and the page has it at once. Once it's held, the page stays still while the finger slides.
#if canImport(UIKit)
struct ScrubRecognizer: UIGestureRecognizerRepresentable {
    var onChange: (CGPoint?) -> Void
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.4
        g.allowableMovement = 8
        g.cancelsTouchesInView = false
        return g
    }
    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        switch g.state {
        case .began:
            UISelectionFeedbackGenerator().selectionChanged()
            onChange(context.converter.localLocation)
        case .changed: onChange(context.converter.localLocation)
        default: onChange(nil)
        }
    }
}
struct HoldToScrub: ViewModifier {
    var onChange: (CGPoint?) -> Void
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).gesture(ScrubRecognizer(onChange: onChange))
    }
}
#else
struct HoldToScrub: ViewModifier {
    var onChange: (CGPoint?) -> Void
    func body(content: Content) -> some View { content }
}
#endif
extension View { func holdToScrub(_ onChange: @escaping (CGPoint?) -> Void) -> some View { modifier(HoldToScrub(onChange: onChange)) } }

// Tapping the tab you're already on goes back to its start, at the top, as in Apple's own apps. TabView hands the same
// value back on that tap, which a plain binding would ignore.
// A drag that starts on the system's bar along the foot (open upright) and leaves it came back as the tab in front tapped
// again, so the page jumped to its top (CI a8f6ba1, Chumby and Mint Remote upright: a drag up from the bar reset Home and
// Watch; later list 11-24, "swipes register on rest of screen"). Only a touch that stayed put is a tap again.
enum TabReset {
    static func binding(_ tab: Binding<Int>, onRepeat: @escaping (Int) -> Void) -> Binding<Int> {
        #if canImport(UIKit)
        DispatchQueue.main.async { TouchTrail.install() }
        #endif
        return Binding(get: { tab.wrappedValue }, set: { new in
            if new == tab.wrappedValue {
                #if canImport(UIKit)
                TouchTrail.note("again \(new)")
                if TouchTrail.wasDrag { return }
                #endif
                onRepeat(new)
            } else { tab.wrappedValue = new }
        })
    }
}
#if canImport(UIKit)
// How far the last touch travelled, read by a recognizer on the window that never recognizes, delays or cancels anything:
// it only watches.
@MainActor enum TouchTrail {
    static var moved: CGFloat = 0
    static var endedAt = Date.distantPast
    // The touch was taken over by another gesture before it ended (the system's tab bar, which takes a finger dragged
    // along or off it): its trail stopped there, short, so a drag off the bar read as a tap (CI 1528a8c, open upright:
    // a drag up from the tab in front threw the page to its top).
    static var cancelled = false
    private static var installed = false
    // The touch that just ended (or is still down) went more than 20 pt, or was taken over.
    static var wasDrag: Bool { (moved > 20 || cancelled) && Date().timeIntervalSince(endedAt) < 0.8 }
    // For the build's checks only (-findBack YES): each tab chosen again, with how the touch went, to Caches/tab-log.txt.
    private static let logs = UserDefaults.standard.bool(forKey: "findBack")
    static func note(_ what: String) {
        guard logs, let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let line = String(format: "%@ moved=%.0f cancelled=%@ sinceEnd=%.2f drag=%@\n", what, moved, cancelled ? "yes" : "no", Date().timeIntervalSince(endedAt), wasDrag ? "yes" : "no")
        let u = dir.appendingPathComponent("tab-log.txt")
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: u, atomically: true, encoding: .utf8) }
    }
    static func install() {
        guard !installed, let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        installed = true
        w.addGestureRecognizer(Watcher())
    }
    final class Watcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private var start: CGPoint?
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
            delegate = self
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if start == nil, let p = touches.first?.location(in: view) { start = p; TouchTrail.moved = 0; TouchTrail.cancelled = false; TouchTrail.endedAt = .distantFuture }
            // Before the touch can choose a tab, the system's tab bar asks the guard (ReselectGuard).
            if let w = view as? UIWindow { ReselectGuard.ensure(in: w) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let s = start, let p = touches.first?.location(in: view) else { return }
            TouchTrail.moved = max(TouchTrail.moved, hypot(p.x - s.x, p.y - s.y))
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { if start != nil { TouchTrail.cancelled = true; TouchTrail.note("cancelled") }; finish() }
        private func finish() { TouchTrail.endedAt = Date(); start = nil; state = .failed }
        override func reset() { start = nil }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        // Only watching: no other gesture taking the touch stops it seeing the rest of it.
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    }
}
// The system's tab bar does its own second-tap work: the tab in front chosen again throws its page to the top. A drag that
// starts on the tab in front and leaves the bar (open upright) came back as that second tap, so the page jumped to its
// top even with TabReset ignoring it (gate on mp-systabs-1128 a73df86: tab-log "again 0 moved=238 drag=yes", the page at
// its top all the same). The guard sits in front of the tab bar controller's own delegate (SwiftUI's), passes everything
// on, and only refuses the tab in front chosen again by a drag; a finger that stayed put still takes the page to its top.
@MainActor final class ReselectGuard: NSObject, UITabBarControllerDelegate {
    private weak var inner: UITabBarControllerDelegate?
    // The controller's delegate is weak: the guards are kept here, one per controller.
    private static var guards: [ObjectIdentifier: ReselectGuard] = [:]
    static func ensure(in w: UIWindow) {
        func walk(_ c: UIViewController?) {
            guard let c else { return }
            if let t = c as? UITabBarController, !(t.delegate is ReselectGuard) {
                let g = guards[ObjectIdentifier(t)] ?? ReselectGuard()
                g.inner = t.delegate
                guards[ObjectIdentifier(t)] = g
                t.delegate = g
                TouchTrail.note("guard on")
            }
            c.children.forEach(walk)
        }
        walk(w.rootViewController)
    }
    override func responds(to s: Selector!) -> Bool { super.responds(to: s) || (inner?.responds(to: s) ?? false) }
    override func forwardingTarget(for s: Selector!) -> Any? { inner?.responds(to: s) == true ? inner : super.forwardingTarget(for: s) }
    private func refuses(_ again: Bool) -> Bool {
        guard again else { return false }
        TouchTrail.note(TouchTrail.wasDrag ? "refused again" : "allowed again")
        return TouchTrail.wasDrag
    }
    func tabBarController(_ t: UITabBarController, shouldSelect vc: UIViewController) -> Bool {
        if refuses(vc === t.selectedViewController) { return false }
        return inner?.tabBarController?(t, shouldSelect: vc) ?? true
    }
    func tabBarController(_ t: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if refuses(tab === t.selectedTab) { return false }
        return inner?.tabBarController?(t, shouldSelectTab: tab) ?? true
    }
}
#endif

// For the build's recording: every tab in turn, twice, so anything that draws in, flashes or jumps between them shows
// up on film. Only with the "tour" pose; never on the phone.
enum TabTour {
    @MainActor static func run(_ tabs: [Int], set: @escaping (Int) -> Void) {
        guard UserDefaults.standard.string(forKey: "pose") == "tour" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for t in tabs + tabs { set(t); try? await Task.sleep(nanoseconds: 1_600_000_000) }
        }
    }
}

// The build's shots at a size the simulator hasn't: -windowSize 859x604 makes the app's window that many points, at the
// display's top left (his phone open flat is 859 x 604 pt, the simulator's 951 x 669; the system's rail holds fewer tabs
// in the shorter one). Only with the launch argument; never on the phone.
enum ShotWindow {
    static var size: CGSize? {
        guard let p = UserDefaults.standard.string(forKey: "windowSize")?.split(separator: "x").compactMap({ Double($0) }), p.count == 2, p[0] > 100, p[1] > 100 else { return nil }
        return CGSize(width: p[0], height: p[1])
    }
    @MainActor static func apply() {
        #if canImport(UIKit)
        guard let size else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows where w.frame.size != size { w.frame = CGRect(origin: .zero, size: size); w.clipsToBounds = true }
        }
        #endif
    }
}

// For the build's films of Back (-findBack YES, never on the phone): where the system put the Back button, as fractions
// of the window, to Caches/back-at.txt every half second, so a real tap or long press lands on it in every posture
// (iOS places it: the top of the side strip folded and open in landscape, the top bar open upright). The lines after
// the first list every bar button seen, for the log.
enum BackFinder {
    // Controls a film must touch that the label tap can't find (Chumby's Work lead menu), each where it was last laid out,
    // in the window's points; written as "spot NAME x y trailing-x" lines (a menu row opens from its trailing value).
    @MainActor static var spots: [String: CGRect] = [:]
    @MainActor static func start() {
        #if canImport(UIKit)
        guard UserDefaults.standard.bool(forKey: "findBack") else { return }
        Task { @MainActor in
            for _ in 0..<240 { try? await Task.sleep(nanoseconds: 500_000_000); write() }
        }
        #endif
    }
    #if canImport(UIKit)
    @MainActor private static func write() {
        guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first, w.bounds.width > 0 else { return }
        var back: CGRect?, close: CGRect?
        var seen: [String] = []
        // Every button of the system's tab bar, so the build's films tap each tab where it really is in every posture (the
        // tab strip's touches, later list 11-24).
        var tabs: [(String, CGRect)] = []
        // And the tab bar controller's own items: every tab listed, or a "More" holding the rest (never, Richard 11-19).
        var barItems: [String] = []
        func controllers(_ c: UIViewController?) {
            guard let c else { return }
            if let t = c as? UITabBarController {
                let items = t.tabBar.items?.map { $0.title ?? "?" } ?? []
                let overflow = (t.viewControllers?.count ?? 0) > items.count || t.tabs.count > items.count
                let more = overflow || items.contains("More")
                barItems.append("tabbar items=\(items.count) [\(items.joined(separator: ","))] tabs=\(t.tabs.count) controllers=\(t.viewControllers?.count ?? 0) more=\(more ? "yes" : "no")")
            }
            c.children.forEach(controllers)
            controllers(c.presentedViewController)
        }
        controllers(w.rootViewController)
        func look(_ v: UIView, _ depth: Int, _ inTabBar: Bool = false) {
            guard depth < 60, !v.isHidden, v.alpha > 0.01 else { return }
            let name = NSStringFromClass(type(of: v))
            let tabBar = inTabBar || name.contains("TabBar")
            let r = v.convert(v.bounds, to: w)
            let isBack = v.accessibilityIdentifier == "BackButton" || name.contains("BackButton")
            let onScreen = r.width > 4 && r.height > 4 && w.bounds.intersects(r)
            if isBack, onScreen { back = r }
            // A sheet's own way out, the system's toolbar item (Close, Cancel or Done).
            if !isBack, onScreen, close == nil, (v is UIControl || name.contains("Button")), ["Close", "Cancel", "Done"].contains(v.accessibilityLabel ?? "") { close = r }
            let isTab = name.contains("TabButton") || name.contains("TabBarButton") || (tabBar && v is UIControl && (v.accessibilityLabel ?? "").count > 1)
            if isTab, onScreen, !tabs.contains(where: { $0.1.contains(CGPoint(x: r.midX, y: r.midY)) }) {
                tabs.append(((v.accessibilityLabel ?? v.accessibilityIdentifier ?? name).replacingOccurrences(of: " ", with: "_"), r))
            }
            if (isBack || name.contains("BarButton")) && seen.count < 40 {
                seen.append(String(format: "%@ id=%@ label=%@ %.0f,%.0f %.0fx%.0f", name, v.accessibilityIdentifier ?? "-", v.accessibilityLabel ?? "-", r.minX, r.minY, r.width, r.height))
            }
            for s in v.subviews { look(s, depth + 1, tabBar) }
        }
        look(w, 0)
        let first = back.map { String(format: "%.4f %.4f", $0.midX / w.bounds.width, $0.midY / w.bounds.height) } ?? "none"
        let shut = close.map { String(format: "close %.4f %.4f", $0.midX / w.bounds.width, $0.midY / w.bounds.height) } ?? "close none"
        let tabLines = tabs.map { String(format: "tab %@ %.4f %.4f", $0.0, $0.1.midX / w.bounds.width, $0.1.midY / w.bounds.height) }
        let spotLines = spots.sorted { $0.key < $1.key }.map { String(format: "spot %@ %.4f %.4f %.4f", $0.key, $0.value.midX / w.bounds.width, $0.value.midY / w.bounds.height, max($0.value.midX, $0.value.maxX - 40) / w.bounds.width) }
        let text = ([first, shut, String(format: "window %.0fx%.0f", w.bounds.width, w.bounds.height)] + tabLines + spotLines + barItems + seen).joined(separator: "\n") + "\n"
        try? text.write(to: dir.appendingPathComponent("back-at.txt"), atomically: true, encoding: .utf8)
    }
    #endif
}

extension View {
    // Where this control is, for the build's films (-findBack YES only): BackFinder writes it as a "spot" line.
    @ViewBuilder func findSpot(_ name: String) -> some View {
        if UserDefaults.standard.bool(forKey: "findBack") {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { BackFinder.spots[name] = $0 }
        } else { self }
    }
}

#if canImport(UIKit)
// A pushed page's views made once ahead of his tap, so its first push costs what every later one does. The first push of
// a page was its views' types being looked up by the runtime for the first time (swift_conformsToProtocol under SwiftUI's
// DynamicPropertyCache and the layer commit): Chumby's Calendar settings slid in 1.6 to 2.4 s late on the build's Release
// films against about 0.2 s after, and Mint Remote's Settings and TV settings each froze a frame for 0.15 to 0.4 s (gate 2
// on chumby-fix-1127). Each page is hosted in the key window at the window's size, behind the app's own view and all but
// transparent, laid out and committed, kept for a few frames, then let go. Out of a window a hosting view lays nothing
// out (CI 6056476: "settings prewarmed 1 ms" and no change), so it must be in one. Once per page per launch; the caller
// waits for the app to sit still first (no slide, no scroll).
@MainActor enum PageWarm {
    private static var done = Set<String>()
    static func asked(_ name: String) -> Bool { done.contains(name) }
    static func run(_ name: String, _ pages: [AnyView]) {
        guard !done.contains(name), !pages.isEmpty,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        done.insert(name)
        let t0 = CACurrentMediaTime()
        let hosts = pages.map { page -> UIHostingController<AnyView> in
            let h = UIHostingController(rootView: page)
            h.view.frame = window.bounds
            h.view.backgroundColor = .clear
            h.view.alpha = 0.011
            h.view.isUserInteractionEnabled = false
            h.view.accessibilityElementsHidden = true
            // Under the app's own view, so even the faint copy is covered.
            window.insertSubview(h.view, at: 0)
            return h
        }
        for h in hosts { h.view.setNeedsLayout(); h.view.layoutIfNeeded() }
        let laid = CACurrentMediaTime()
        // The layer commit, where much of a first push's time went: done now, not in the turn of his tap.
        CATransaction.flush()
        let committed = CACurrentMediaTime()
        SwipeLog.note(String(format: "%@ prewarmed %.0f ms (layout %.0f, commit %.0f)", name, (committed - t0) * 1000, (laid - t0) * 1000, (committed - laid) * 1000))
        Task { @MainActor in
            // A few frames more, for anything SwiftUI makes on its next update, then gone.
            try? await Task.sleep(nanoseconds: 250_000_000)
            for h in hosts { h.view.removeFromSuperview() }
            SwipeLog.note(String(format: "%@ prewarm let go after %.0f ms", name, (CACurrentMediaTime() - t0) * 1000))
        }
    }
}
#endif
