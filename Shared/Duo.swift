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
@MainActor @Observable final class NavTransit {
    static let shared = NavTransit()
    private(set) var active = false
    // The move in flight is the edge swipe, under the finger. Only then does UIKit resize a page as it goes; a page taken
    // back with Back keeps its size and safe area the whole way (CI 8b7b68e, the hold off: not one reading of a page's
    // size changed through five pops), so only the swipe needs a page's size held.
    private(set) var underFinger = false
    // Posted as each move ends, for a view that wants the moment without being worked out again for it.
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
        if !active { active = true }
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
    private var transit = NavTransit.shared
    struct Reading: Equatable { var size: CGSize; var insets: EdgeInsets }
    init(name: String) { self.name = name }
    func body(content: Content) -> some View {
        content
            .background {
                if SwipeLog.on {
                    Color.clear.ignoresSafeArea()
                        .onGeometryChange(for: Reading.self) { Reading(size: $0.size, insets: $0.safeAreaInsets) } action: { r in
                            let moving = NavTransit.shared.moving()
                            SwipeLog.note("\(name) \(moving ? "moving" : "rest") size \(Int(r.size.width))x\(Int(r.size.height)) insets t\(Int(r.insets.top)) l\(Int(r.insets.leading)) b\(Int(r.insets.bottom)) r\(Int(r.insets.trailing))")
                        }
                }
            }
            // Read only with the log on, so no page is worked out again as a move begins and ends on the phone.
            .onChange(of: SwipeLog.on ? transit.active : false) { _, now in SwipeLog.note("\(name) transit \(now ? "began" : "ended")\(now && transit.underFinger ? " under the finger" : "")") }
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
    @MainActor static func frames() { if on, meter == nil { meter = FrameGaps(); busy() } }
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
        }
    }
    #else
    @MainActor static func frames() {}
    #endif
}

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
    // The icon alone, fitted the same as in the tab's label.
    var icon: Image {
        #if canImport(UIKit)
        if let asset { return Image(uiImage: cachedIcon(asset, fit: fit) { UIImage(named: asset) }) }
        let name = symbol ?? "circle"
        return Image(uiImage: cachedIcon(name, fit: 25) { UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 60, weight: .regular)) })
        #else
        return asset.map { Image($0) } ?? Image(systemName: symbol ?? "circle")
        #endif
    }
}

// Room a page keeps at its foot for the tab bar DuoTabs draws there open upright (0 where the tabs are down the side).
private struct TabBarRoomKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues { var tabBarRoom: CGFloat { get { self[TabBarRoomKey.self] } set { self[TabBarRoomKey.self] = newValue } } }
// And the column the capsule down the side needs from the display's edge (0 open upright), and which edge: the trailing
// one, or the leading one where iOS put its strip there (folded and turned on its side the other way, the strip stays with
// the camera's edge; HIG, "controls on the vertical axis stay aligned with the hardware").
private struct TabRailColumnKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues { var tabRailColumn: CGFloat { get { self[TabRailColumnKey.self] } set { self[TabRailColumnKey.self] = newValue } } }
private struct TabRailLeadingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var tabRailLeading: Bool { get { self[TabRailLeadingKey.self] } set { self[TabRailLeadingKey.self] = newValue } } }
// Each page takes the bar's room itself, a tab's root and every page pushed on it: room given from outside a navigation
// stack never reaches the pages UIKit hosts inside it (designer gate 1, 2026-11-20: a list's last row under the bar).
// Down the side the system's strip is the room (the capsule stands inside it); only were the strip ever narrower than the
// capsule's column would a page take the difference, never the strip twice.
struct TabBarRoom: ViewModifier {
    @Environment(\.tabBarRoom) private var room
    @Environment(\.tabRailColumn) private var column
    @Environment(\.tabRailLeading) private var leading
    @State private var has: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(leading ? .leading : .trailing, column > has ? column - has : 0)
            .safeAreaPadding(.bottom, room)
            .onGeometryChange(for: CGFloat.self) { leading ? $0.safeAreaInsets.leading : $0.safeAreaInsets.trailing } action: { has = $0 }
    }
}
extension View { func tabBarRoom() -> some View { modifier(TabBarRoom()) } }

// Every tab one tap away in every posture, never "More" (Richard, 2026-11-19 and 2026-11-26: "i expressly told u to fix
// these ... the side bar not encompassing everything"). The system's TabView can't promise that on his phone: its side
// strip holds five slots there once the camera or the island (a recording, a Live Activity) takes the strip's top, and
// six only in the build's simulator, which has neither; and once it has overflowed (opened folded) it kept "•••" after
// unfolding. Hiding only its bar isn't safe either: UIKit still files the fifth tab on into More's own navigation stack.
// So the tab bar is drawn here, where iOS draws its own and as it draws it, holding every tab: down the side strip
// (folded, open flat, folded on its side), on the clock's and the gear's centre line at the strip's foot, a Liquid Glass
// capsule of icons; along the foot open upright, where iOS keeps a horizontal bar. Everything else stays the system's:
// each tab is its own NavigationStack with the system Back, edge swipe and toolbar placed by iOS (HIG, iPhone Duo,
// "Vertical controls"). Tabs once shown are kept, as TabView keeps them, so coming back finds each as it was left.
// Tapping the tab in front hands its value back, as TabView does, so TabReset takes it to its start.
struct DuoTabs<Content: View>: View {
    @Binding var selection: Int
    let items: [RailItem]
    let badge: (Int) -> Int
    @ViewBuilder let content: (Int) -> Content
    @State private var shown: Set<Int> = []
    // The system's side strip: the safe area the status bar and the bar items take where iOS puts them on the side (84 pt
    // open flat, about as much folded), on the trailing edge, or the leading one folded and turned on its side with the
    // camera there; none open upright, where its bars run across.
    @State private var strip = Strip()
    struct Strip: Equatable { var leading: CGFloat = 0; var trailing: CGFloat = 0; var height: CGFloat = 0 }
    @State private var keyboardUp = false
    @Environment(\.colorScheme) private var scheme
    private var onLeading: Bool { strip.leading > 30 && strip.leading > strip.trailing }
    private var side: Bool { strip.trailing > 30 || onLeading }
    private var footRoom: CGFloat { side || keyboardUp ? 0 : Self.barHeight + Self.barInset * 2 + 6 }
    private var railColumn: CGFloat { side ? Self.centre + Self.width / 2 + 10 : 0 }
    // Folded and turned on its side the display is 466 pt tall, and the strip's top holds the camera and the gear or Back
    // above the capsule (about 150 pt on his phone; 49 pt cells met the gear, CI 5a48486). The cells give up height there,
    // never below the HIG's 44 pt; everywhere else they're the system's 49.
    private var cellHeight: CGFloat {
        guard strip.height > 0, !items.isEmpty else { return Self.cellHeight }
        let room = strip.height - Self.foot - Self.inset * 2 - Self.topReserve
        return min(Self.cellHeight, max(44, room / CGFloat(items.count)))
    }
    static var topReserve: CGFloat { 150 }
    // The system's own strip, measured on its shots (CI 6d22d62 open flat and folded, his recording of 317): its icons on
    // the clock's and gear's centre line 48 pt in from the display's edge, a capsule 26 pt clear of the foot, an icon
    // every 49 to 52 pt; each cell the HIG's least tap target, 44 pt wide.
    static var cell: CGFloat { 44 }
    static var cellHeight: CGFloat { 49 }
    static var inset: CGFloat { 3 }
    static var centre: CGFloat { 48 }
    static var foot: CGFloat { 26 }
    static var width: CGFloat { cell + inset * 2 }
    // Open upright: the system's floating bar, icons over their names.
    static var barHeight: CGFloat { 54 }
    static var barInset: CGFloat { 4 }
    var body: some View {
        ZStack {
            ForEach(items) { it in
                let front = it.value == selection
                if front || shown.contains(it.value) {
                    content(it.value)
                        .opacity(front ? 1 : 0)
                        .allowsHitTesting(front)
                        .accessibilityHidden(!front)
                        .zIndex(front ? 1 : 0)
                }
            }
        }
        // Down the side the strip already keeps every page clear of the capsule (it stands inside the strip's 84 pt);
        // along the foot each page keeps the bar's room, none with the keyboard up (the bar is behind it then).
        .environment(\.tabBarRoom, footRoom)
        .environment(\.tabRailColumn, railColumn)
        .environment(\.tabRailLeading, onLeading)
        .onGeometryChange(for: Strip.self) { Strip(leading: $0.safeAreaInsets.leading, trailing: $0.safeAreaInsets.trailing, height: $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom) } action: { strip = $0 }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            let screen = UIScreen.main.bounds.height
            keyboardUp = f.height > 120 && f.minY < screen - 120
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        #endif
        .onChange(of: selection, initial: true) { _, s in shown.insert(s) }
        .overlay { if side { sideRail } }
        .overlay(alignment: .bottom) { if !side, !keyboardUp { footFade } }
        .overlay(alignment: .bottom) { if !side { footBar } }
    }
    // Under the bar the page fades into the ground, the system's soft edge, so no card's words read through the glass
    // (Richard, 2026-11-21).
    private var footFade: some View {
        let ground: Color = scheme == .dark ? .black : .white
        let stops: [Gradient.Stop] = [.init(color: ground.opacity(0), location: 0), .init(color: ground, location: 0.4), .init(color: ground, location: 1)]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .frame(height: Self.barHeight + Self.barInset * 2 + 52)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
    }
    private var footBar: some View {
        bar.frame(maxWidth: 470).padding(.horizontal, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.keyboard)
    }
    // Behind the keyboard when it's up, as the system's stays at its foot: never riding up into the clock.
    private var sideRail: some View {
        let edge: Edge.Set = onLeading ? .leading : .trailing
        let corner: Alignment = onLeading ? .bottomLeading : .bottomTrailing
        return rail.padding(edge, Self.centre - Self.width / 2).padding(.bottom, Self.foot)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
            .ignoresSafeArea(.all, edges: [edge, .bottom])
    }
    @ViewBuilder private func badgeView(_ value: Int) -> some View {
        let n = badge(value)
        if n > 0 {
            Text("\(n)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                .background(Color.red, in: Capsule())
        }
    }
    private var rail: some View {
        VStack(spacing: 0) {
            ForEach(items) { it in
                let front = it.value == selection
                Button { selection = it.value } label: {
                    it.icon
                        .foregroundStyle(front ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .frame(width: Self.cell, height: cellHeight)
                        // Always there, shown or not: put in and taken out, it trailed the tint by a tab in the films.
                        .background { Capsule().fill(scheme == .dark ? Color.black.opacity(0.38) : Color.primary.opacity(0.08)).opacity(front ? 1 : 0) }
                        .overlay(alignment: .topTrailing) { badgeView(it.value).offset(x: 2, y: 1) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(it.title)
                .accessibilityIdentifier("tab." + it.title)
                .accessibilityValue(badge(it.value) > 0 ? "\(badge(it.value))" : "")
                .accessibilityAddTraits(front ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(Self.inset)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
    private var bar: some View {
        HStack(spacing: 0) {
            ForEach(items) { it in
                let front = it.value == selection
                Button { selection = it.value } label: {
                    VStack(spacing: 2) {
                        it.icon.resizable().scaledToFit().frame(width: 24, height: 22)
                        Text(it.title).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(front ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    // Each cell at least its name and 8 pt of air either side, the rest shared (designer gate, 2026-11-20).
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: Self.barHeight)
                    .background { Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08)).opacity(front ? 1 : 0) }
                    .overlay(alignment: .top) { badgeView(it.value).offset(x: 14, y: 3) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(it.title)
                .accessibilityIdentifier("tab." + it.title)
                .accessibilityValue(badge(it.value) > 0 ? "\(badge(it.value))" : "")
                .accessibilityAddTraits(front ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(Self.barInset)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
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
enum TabReset {
    static func binding(_ tab: Binding<Int>, onRepeat: @escaping (Int) -> Void) -> Binding<Int> {
        Binding(get: { tab.wrappedValue }, set: { new in if new == tab.wrappedValue { onRepeat(new) } else { tab.wrappedValue = new } })
    }
}

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
        func look(_ v: UIView, _ depth: Int) {
            guard depth < 60, !v.isHidden, v.alpha > 0.01 else { return }
            let name = NSStringFromClass(type(of: v))
            let r = v.convert(v.bounds, to: w)
            let isBack = v.accessibilityIdentifier == "BackButton" || name.contains("BackButton")
            let onScreen = r.width > 4 && r.height > 4 && w.bounds.intersects(r)
            if isBack, onScreen { back = r }
            // A sheet's own way out, the system's toolbar item (Close, Cancel or Done).
            if !isBack, onScreen, close == nil, (v is UIControl || name.contains("Button")), ["Close", "Cancel", "Done"].contains(v.accessibilityLabel ?? "") { close = r }
            if (isBack || name.contains("BarButton")) && seen.count < 40 {
                seen.append(String(format: "%@ id=%@ label=%@ %.0f,%.0f %.0fx%.0f", name, v.accessibilityIdentifier ?? "-", v.accessibilityLabel ?? "-", r.minX, r.minY, r.width, r.height))
            }
            for s in v.subviews { look(s, depth + 1) }
        }
        look(w, 0)
        let first = back.map { String(format: "%.4f %.4f", $0.midX / w.bounds.width, $0.midY / w.bounds.height) } ?? "none"
        let shut = close.map { String(format: "close %.4f %.4f", $0.midX / w.bounds.width, $0.midY / w.bounds.height) } ?? "close none"
        let text = ([first, shut, String(format: "window %.0fx%.0f", w.bounds.width, w.bounds.height)] + seen).joined(separator: "\n") + "\n"
        try? text.write(to: dir.appendingPathComponent("back-at.txt"), atomically: true, encoding: .utf8)
    }
    #endif
}
