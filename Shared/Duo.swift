import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Two panes only when there's room side by side. Open in portrait the bars go horizontal and the fold runs across,
// so lists read better as one column, the same as on the outer display.
private struct PaneLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var paneLayout: Bool { get { self[PaneLayoutKey.self] } set { self[PaneLayoutKey.self] = newValue } } }
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
// rest until the move is over. Only stacks that register (the Mac Pro app's) count; elsewhere it's never in flight.
@MainActor @Observable final class NavTransit {
    static let shared = NavTransit()
    private(set) var active = false
    #if canImport(UIKit)
    @ObservationIgnored private let stacks = NSHashTable<UINavigationController>.weakObjects()
    @ObservationIgnored private weak var current: AnyObject?
    // The build's "before" films turn the hold off (-noHold YES), to film a page swiped off as it was.
    @ObservationIgnored private let off = UserDefaults.standard.bool(forKey: "noHold")
    func register(_ n: UINavigationController) { if !off { stacks.add(n) } }
    // Marks the move in flight until its coordinator says it's over (finished, or the swipe let go and sprang back).
    func begin(_ c: UIViewControllerTransitionCoordinator) {
        guard !off, current !== (c as AnyObject) else { return }
        current = c as AnyObject
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
    private func end() { current = nil; if active { active = false } }
    // Asked as a reading lands: true while any registered stack is mid-move, and the move is noted if it wasn't yet.
    func moving() -> Bool {
        if let c = stacks.allObjects.lazy.compactMap(\.transitionCoordinator).first { begin(c); return true }
        return active
    }
    #else
    func moving() -> Bool { false }
    #endif
}

// A pushed page laid out from what it reads at rest while a push or pop moves it: the same size and safe area from the
// first frame of the slide to the last, so it goes off whole, rows and cards as they were. At rest it reads the system as
// usual (a turn, a fold, the keyboard), since nothing then is moving it.
struct HoldsWhileMoving: ViewModifier {
    let name: String
    private var transit = NavTransit.shared
    @State private var box = Box()
    struct Reading: Equatable { var size: CGSize; var insets: EdgeInsets }
    // `settled` once the page has been still on screen: after the move that brought it ends, or 0.6 s after it appears
    // with nothing moving. Until then it holds nothing. A page's very first reading can come before its push has a
    // coordinator, laid out before the bars and margins it will have; held through the push, that put its first open's
    // text against the edges, right only from the second open on.
    @MainActor final class Box { var rest: Reading?; var latest: Reading?; var settled = false }
    init(name: String) { self.name = name }
    func body(content: Content) -> some View {
        let hold = transit.active && box.settled ? box.rest : nil
        content
            .safeAreaPadding(hold?.insets ?? EdgeInsets())
            .frame(width: hold?.size.width, height: hold?.size.height, alignment: .topLeading)
            .ignoresSafeArea(.all, edges: hold == nil ? [] : .all)
            // The page's whole area and its safe area, as the system gives them.
            .background {
                Color.clear.ignoresSafeArea()
                    .onGeometryChange(for: Reading.self) { Reading(size: $0.size, insets: $0.safeAreaInsets) } action: { r in
                        box.latest = r
                        let moving = NavTransit.shared.moving()
                        if !moving, box.settled { box.rest = r }
                        SwipeLog.note("\(name) \(moving ? "moving" : "rest") size \(Int(r.size.width))x\(Int(r.size.height)) insets t\(Int(r.insets.top)) l\(Int(r.insets.leading)) b\(Int(r.insets.bottom)) r\(Int(r.insets.trailing))")
                    }
            }
            // Pushed in mid-move, it had no reading at rest yet: the last one counts once the move is over.
            .onChange(of: transit.active) { _, now in
                if !now, let l = box.latest { box.rest = l; box.settled = true }
                SwipeLog.note("\(name) transit \(now ? "began" : "ended")")
            }
            .task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !NavTransit.shared.moving(), let l = box.latest { box.rest = l; box.settled = true; SwipeLog.note("\(name) settled") }
            }
    }
}
extension View {
    func holdsWhileMoving(_ name: String) -> some View { modifier(HoldsWhileMoving(name: name)) }
}

// For the build's films of a page swiped off (-swipeLog YES, never on the phone): every reading a page takes and when the
// move began and ended, to Caches/swipe-log.txt, so a page that changes as it slides is caught in numbers, not only seen.
enum SwipeLog {
    static let on = UserDefaults.standard.bool(forKey: "swipeLog")
    static let start = Date()
    static func note(_ s: String) {
        guard on, let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let line = String(format: "%.3f ", Date().timeIntervalSince(start)) + s + "\n"
        let url = dir.appendingPathComponent("swipe-log.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
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

// Two panes, in Apple's container: side by side when wide, stacked when tall, and clear of the fold when partly closed.
// Lying flat it would split the area left of the side bars, putting the seam off the crease, so it's told where the hinge is.
struct FoldSplit<L: View, R: View>: View {
    let left: L, right: R
    init(@ViewBuilder _ left: () -> L, @ViewBuilder right: () -> R) { self.left = left(); self.right = right() }
    struct Split: Equatable { var ratio: CGFloat?; var gutter: CGFloat; var outer: CGFloat }
    // The split as last read at rest. The fold is read in the view's own space, so while a page slides off (or the page
    // under it slides back) the crease seemed to travel across it, and the seam followed: the left pane narrowed to a
    // third as the page went. Held while a move is in flight.
    @State private var held: Split?
    private var transit = NavTransit.shared
    var body: some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            GeometryReader { g in
                let wide = g.size.width > g.size.height
                let folded = !g.reservedRegions(kind: .division).isEmpty
                let crease = g.reservedRegions(kind: .division, options: .includeInactive).first?.frame
                let hinge = crease?.midX
                let ratio: CGFloat? = wide && !folded ? hinge.map { min(max($0 / g.size.width, 0.3), 0.7) } : nil
                // Each pane stops short of the crease, which is about 40 pt wide: half of it plus a little air, and never
                // less than 24, so no card sits on the fold.
                let gutter: CGFloat = wide && !folded ? min(max(24, (crease?.width ?? 0) / 2 + 4), 40) : 0
                // Open, the left pane meets the display's bare outer edge (no safe area there), so its cards and titles get
                // the same air from that edge as the right pane has from the side column.
                let outer: CGFloat = wide && !folded ? 14 : 0
                let live = Split(ratio: ratio, gutter: gutter, outer: outer)
                let use = transit.active ? (held ?? live) : live
                ArrangementView {
                    left.padding(.leading, use.outer).padding(.trailing, use.gutter).splitArrangementLayoutRatio(use.ratio)
                } secondary: {
                    right.padding(.leading, use.gutter)
                }
                .arrangementViewStyle(.split)
                .onChange(of: live, initial: true) { _, v in
                    if !NavTransit.shared.moving() { held = v }
                    SwipeLog.note("split ratio \(v.ratio.map { String(format: "%.3f", $0) } ?? "nil") gutter \(Int(v.gutter))\(transit.active ? " (held)" : "")")
                }
                .onChange(of: transit.active) { _, now in if !now { held = live } }
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
