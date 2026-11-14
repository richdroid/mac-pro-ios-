import Charts
import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

@main
struct MacProApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    #if canImport(UIKit)
    // Only for the notification token iOS hands to an app delegate.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    #endif
    init() { AlertWatch.shared.install() }
    var body: some Scene {
        WindowGroup {
            RootView(seeds: model.seedStore).modifier(StatusBarTopReader()).environmentObject(model).environmentObject(model.notice).environmentObject(model.liveStore).environmentObject(model.liveStore.display)
                .otaOffer(model)
                .preferredColorScheme(.dark)   // black, like the machine and the web dashboard
                .onChange(of: phase) { _, p in
                    if p == .active { Reach.shared.cameForward(); model.start(); PushToken.share(model.api) } else { model.stop() }
                    #if os(iOS)
                    if p == .background { AlertWatch.shared.scheduleRefresh(); WidgetCenter.shared.reloadAllTimelines() }
                    #endif
                }
                // A restart asked on the Mac's Console is followed here too.
                .task { await MacMirror.loop(model) }
                .onAppear {
                    model.start(); openScreenIfAsked(); AlertWatch.shared.askOnce(); TabTour.run([0, 1, 2, 4, 5, 9]) { model.tab = $0 }
                    if let id = AlertWatch.pending { openAlert(id) }
                    // The build's shots of a link from the Console landing (-openLink macproapp://…), without the system's
                    // "Open in Mac Pro?" question that simctl openurl leaves over every later shot.
                    if let l = UserDefaults.standard.string(forKey: "openLink"), let u = URL(string: l) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { _ = MacDeepLink.open(u, model) }
                    }
                    TransitionTour.run(model)
                    #if DEBUG && canImport(UIKit)
                    FrameLog.shared.start()
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: AlertWatch.openAlert)) { n in openAlert(n.object as? String ?? "") }
                .onReceive(NotificationCenter.default.publisher(for: ScreenRequest.notification)) { _ in openScreenIfAsked() }
                // macproapp://tab/<n>, and the places the Console names (MacHandoff.swift).
                .onOpenURL { _ = MacDeepLink.open($0, model) }
        }
        #if os(iOS)
        // iOS decides when, and may not for hours. The banner on Status is always current.
        .backgroundTask(.appRefresh(AlertWatch.refreshID)) {
            await AlertWatch.shared.backgroundCheck()
            AlertWatch.shared.scheduleRefresh()
        }
        #endif
    }
    // A tapped notification opens where its problem can be dealt with: a waiting session on its own page.
    private func openAlert(_ id: String) {
        AlertWatch.pending = nil
        // New apps waiting while he's away: straight to Apps, where the waiting ones start installing over the air (Richard,
        // 2026-11-07: "a method to remotely push updates").
        // Usage near its limit: the Claude tab, scrolled to the usage.
        if id.hasPrefix("session:") { model.openSession(key: String(id.dropFirst(8))) } else if id.hasPrefix("usage:") { model.show(tab: 3) } else if id == "ios:waiting" { model.tab = 1 } else { model.tab = 0 }
    }
    private func openScreenIfAsked() {
        if ScreenRequest.wanted || UserDefaults.standard.bool(forKey: "openScreen") { ScreenRequest.wanted = false; model.openScreen() }
    }
}

// For the build's film of the pushes and the screen cover: Status to History to Processes and back, Claude to a session
// and back, then the screen opening and closing. Only with the "transitions" pose; never on the phone.
enum TransitionTour {
    @MainActor static func run(_ model: AppModel) {
        // The resize check's film of a tab come back to: Status, Apps from 10 s to 42 s (an alert arrives meanwhile), then
        // Status again. Set here rather than tapped: the simulator's taps on the tab bar landed on the wrong tab or not at all.
        if model.pose == "tabback" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000); SwipeLog.note("tab to Apps"); model.tab = 1
                try? await Task.sleep(nanoseconds: 32_000_000_000); SwipeLog.note("tab to Status"); model.tab = 0
            }
            return
        }
        guard model.pose == "transitions" else { return }
        let steps: [(Double, () -> Void)] = [
            (3.0, { model.history = .cpu }), (5.0, { model.processes = .cpu }), (7.0, { model.processes = nil }), (8.5, { model.history = nil }),
            (10.0, { model.tab = 2 }), (11.0, { model.openSession(key: "chumby") }), (13.0, { model.sessionScreen = nil }),
            (14.5, { model.tab = 0 }), (15.5, { model.openScreen() }), (18.5, { model.screenOpen = false }),
        ]
        Task { @MainActor in
            var at = 0.0
            for (t, step) in steps {
                try? await Task.sleep(nanoseconds: UInt64((t - at) * 1e9)); at = t
                step()
            }
        }
    }
}

enum Side { case all, left, right }
extension View {
    @ViewBuilder func screenCover<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}
#if canImport(UIKit)
let groupedBackground = Color(uiColor: .systemGroupedBackground)
#else
let groupedBackground = Color.gray.opacity(0.1)
#endif
// One corner for every card the app draws itself, the same as the system's own list cards beside them.
let cardRadius: CGFloat = 26
let cardFill = Color(white: 0.11)
// How far the quick actions on Status fade while the Mac can't be reached, applied to each colour, all four alike.
let offlineDim = 0.25
// A button that draws its label as it is, so a disabled one shows only the dimming its own colours give it.
struct FlatStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.contentShape(Rectangle()) }
}

// One top edge for every page, Settings included: no band or hairline from the system on any pane. Only while something
// is scrolled under, solid black from the top of the display to the inline bar's foot, so no scrolled content shows behind
// a title glyph, then a 24 pt fade. At rest nothing is drawn, so the portrait and first cards show whole.
struct TopEdge: ViewModifier {
    // No bar of our own: Richard (2026-11-05) "just get rid of this top bar" — the solid black band that covered the top
    // of the page while scrolled. Content now runs to the top edge with nothing over it, and the title floats.
    func body(content: Content) -> some View {
        bar(content)
    }
    // The window's own top inset: the status bar, without the navigation bar a view's safe area adds.
    @MainActor static var statusBar: CGFloat {
        #if os(iOS)
        let w = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return w?.safeAreaInsets.top ?? 59
        #else
        return 0
        #endif
    }
    @ViewBuilder func bar<V: View>(_ v: V) -> some View {
        #if os(iOS)
        v.toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #else
        v
        #endif
    }
}
// The window's own top inset (the status bar), read at layout and handed down, so a page's first line moves with a fold or
// a turn as it happens. Read statically in each body (TopEdge.statusBar), it kept the old posture's value until the next
// reading redrew the page, and the whole page dropped 14 pt seconds after the turn, untouched (designer, resize regate).
private struct StatusBarTopKey: EnvironmentKey { static let defaultValue: CGFloat = 59 }
private struct CompactWindowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var compactWindow: Bool { get { self[CompactWindowKey.self] } set { self[CompactWindowKey.self] = newValue } } }
extension EnvironmentValues { var statusBarTop: CGFloat { get { self[StatusBarTopKey.self] } set { self[StatusBarTopKey.self] = newValue } } }
struct StatusBarTopReader: ViewModifier {
    @State private var top = TopEdge.statusBar
    @State private var compact = false
    func body(content: Content) -> some View {
        content
            .environment(\.statusBarTop, top)
            .environment(\.compactWindow, compact)
            // The window's new size arrives as a turn starts; its new top inset only as it ends (CI 7169d6b: 0.45 s later),
            // so the title moved after the page had settled. On the Duo the status bar is along the top only open upright
            // (wide enough for two columns, taller than wide), so the new posture's value is taken from the size at once;
            // the inset, when it comes, agrees.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard size.width > 0 else { return }
                let upright = size.width > 600 && size.height > size.width
                // The outer display, upright or on its side: the window's short side under 520 (designer, regate of
                // 5b34ffc: on its side, 678 by 466, it drew the full-size Mac with a tile row cut by the edge).
                let small = min(size.width, size.height) < 520
                if small != compact { compact = small }
                let predicted: CGFloat = upright ? max(top, 20) : min(top, 19)
                if (predicted < 20) != (top < 20) { top = predicted }
            }
            // The system gives the new inset as a turn ends; the title's 14 pt step then eases rather than jumps.
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { v in
                guard v != top else { return }
                if (v < 20) != (top < 20) { withAnimation(Motion.quick) { top = v } } else { top = v }
            }
    }
}
private struct TopEdgeUnderKey: EnvironmentKey { static let defaultValue: (Int, Bool) -> Void = { _, _ in } }
extension EnvironmentValues {
    var topEdgeUnder: (Int, Bool) -> Void { get { self[TopEdgeUnderKey.self] } set { self[TopEdgeUnderKey.self] = newValue } }
}
// Put on each scroll view inside a top edge. Content scrolled up under the title fades away with the system's own soft
// scroll edge, so the title never sits on top of text and there's no bar or band (Richard, 2026-11-05: "just get rid of
// this top bar"). It replaced a hand-made mask: kept in step with the scroll offset and the collapsing title every frame, it
// moved under his finger and made scrolling "absolutely fucked" on his phone (2026-11-06). Nothing here changes per frame
// now: the page is only told when its content goes under the title or comes back to rest.
struct ScrollsUnder: ViewModifier {
    @Environment(\.topEdgeUnder) private var report
    // Where the content rests (the offset once settled after layout), and the latest offset, kept outside SwiftUI's state so
    // a scroll redraws nothing.
    @State private var track: Track
    @Environment(\.refresh) private var refresh
    let id: Int
    init(id: Int) { self.id = id; _track = State(initialValue: Track(name: "list\(id)")) }
    @MainActor final class Track {
        var rest: CGFloat?; var now: CGFloat = 0; var under = false; var geo = ""
        // The page moving, and past either end: the Mac's readings wait while it is (ScrollHold), and land once it has
        // been still, back in range, for 0.6 s. Read from the page's geometry, since a List reports no phase (CI 6da2654:
        // once a second the whole of Apps sat 76 pt higher for a frame while the finger held it past the top). Past the
        // end it's held however still the finger is: with only a 0.6 s grace on motion, a pull that paused before letting
        // go got a reading under it, and the List clamped its offset into range in one move instead of springing
        // (Richard, 2026-11-08 and 11-10: "it doesnt bounce back naturally its like a sudden move back").
        let watch: ScrollWatch
        init(name: String) { let id = UUID(); watch = ScrollWatch(name) { ScrollHold.set(id, moving: $0) } }
    }
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, g in
                track.now = g.contentOffset.y
                track.watch.geometry(g)
                // For the build's logs: what of the page's frame changed, beside the offset, so a jump at rest names its
                // cause (the content's height, an inset, the container).
                if SwipeLog.on {
                    let geo = "content \(Int(g.contentSize.height.rounded())) top \(Int(g.contentInsets.top.rounded())) bottom \(Int(g.contentInsets.bottom.rounded())) container \(Int(g.containerSize.height.rounded()))"
                    if geo != track.geo { track.geo = geo; SwipeLog.note("list\(id) \(geo)") }
                }
                guard let r = track.rest else { return }
                let under = g.contentOffset.y > r + 4
                if under != track.under { track.under = under; report(id, under) }
            }
            // Settled after layout: the first reading can come before the title is laid out, so wait a moment, then take it.
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if track.rest == nil { track.rest = track.now }
            }
            // Only a stop can lower where it rests (back at the top after a bounce, say). A pull to refresh stops held down
            // under its spinner, which isn't where it rests, so a stop that far down never counts.
            .onDisappear { track.watch.stop() }
            .onScrollPhaseChange { _, phase in
                // Readings wait a moment past idle too: the spring back from a pull past the end can outlast the phase,
                // and a flick often follows a flick (CI f7bb947: 200 px jumps mid-pull, a 275 px first step of the spring).
                track.watch.phase(touching: phase != .idle)
                guard phase == .idle else { return }
                if track.rest == nil { track.rest = track.now }
                else if let r = track.rest, track.now < r, !(refresh != nil && track.now < r - 30) {
                    track.rest = track.now
                    if track.under { track.under = false; report(id, false) }
                }
            }
    }
}
// Which pages are moving right now. Readings from the Mac wait while any is, and for 4 s at most after it was last seen
// moving (a phase change, its content shifting a frame, or a tick of being held past its end): a phase stuck short of idle
// never holds them for good. Counted from the first motion instead, a few flicks and a pull used the 4 s up and the
// readings landed under his finger and as the page sprang back (CI f7bb947: "it doesnt bounce back naturally its like a
// sudden move back").
@MainActor
enum ScrollHold {
    private static var moving: Set<UUID> = []
    private static var alive = Date.distantPast
    static var onRelease: (() -> Void)?
    static var holding: Bool { !moving.isEmpty && Date().timeIntervalSince(alive) < 4 }
    static func set(_ id: UUID, moving now: Bool) {
        let was = !moving.isEmpty
        if now { moving.insert(id); alive = Date() } else { moving.remove(id) }
        if was && moving.isEmpty { onRelease?() }
    }
}
extension View {
    func topEdge() -> some View { modifier(TopEdge()) }
    func scrollsUnder(_ id: Int = 0) -> some View { modifier(ScrollsUnder(id: id)) }
    // A row that can be his place on its page: given an id to scroll to, and noted as the place while it's the row at the
    // top of the page.
    // The id goes on last, outside everything else on the row: a List finds a row to scroll to only by the id on its
    // outermost view, and with the place's own modifiers wrapped around it every scroll to a row did nothing (CI 90476df:
    // a turn restored Apps to its place nine times and the page never left its top; the build's scroll to the dials
    // never moved Status either).
    func place<ID: Hashable>(_ id: ID) -> some View { self.modifier(MarksPlace(id: AnyHashable(id))).id(id) }
    // On a page's scroll view, under a ScrollViewReader: puts the page back at his place when a change of posture rebuilt it.
    func keepsPlace(_ page: String, _ proxy: ScrollViewProxy) -> some View { modifier(KeepsPlace(page: page, proxy: proxy)) }
}

// His place on each page, kept across a change of posture. A page that's one column folded or upright and two panes open
// flat is a different view in each, so opening, turning or closing the Duo built it afresh at its top (audit finding 1,
// item 26: "keep his place"). Each page notes the row at its top as he scrolls, and when its layout changes, scrolls back
// to that row: one column scrolls to it, and of two panes the one that holds it does. Plain storage, never SwiftUI state,
// so noting the place redraws nothing.
@MainActor
final class PlaceKeeper {
    private static var pages: [String: PlaceKeeper] = [:]
    static func page(_ name: String) -> PlaceKeeper {
        if let p = pages[name] { return p }
        let p = PlaceKeeper(); pages[name] = p; return p
    }
    var top: AnyHashable?
    var layout: String?  // panes, and the outer display or not: a fold rebuilds the page as much as a turn does
    var restoring = Date.distantPast
    // While the rebuilt page lays out and scrolls back, its rows pass the line and must not count as his place.
    var settling: Bool { (pending && Date().timeIntervalSince(restoring) < 5) || Date().timeIntervalSince(restoring) < 2.0 }
    // A restore asked for by a change of layout and not yet carried through: the page can be rebuilt again as a turn
    // settles, cancelling the restore under way (CI 4eef8a9: one attempt, then the page sat at its top), so whichever
    // list appears next carries it on.
    var pending = false
    static let restores = false
    // Whether he had scrolled the page off its top, read at rest in the layout the place was noted in. A page at its top
    // has no place to keep: folding an untouched Status restored it to the Mac row the unfold's layout had noted, its
    // title cut off (designer, regate of 3bcef0e).
    var scrolled = false
    // When the page's content last changed height: the one restore waits for it to stop (a restore while rows were still
    // growing slid the page away and a second one cut it back; designer, regate of 3bcef0e).
    var grew = Date.distantPast
    var y: CGFloat = 0  // the page's offset now, whatever is moving it
}
// Where the top of each page is on screen (its scroll view's top plus the bars over it), in the window's points. Read in
// geometry transforms, which SwiftUI runs off the main actor, so it is behind a lock rather than on PlaceKeeper.
final class PlaceLines: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String: CGFloat] = [:]
    nonisolated static func line(_ page: String) -> CGFloat { lock.lock(); defer { lock.unlock() }; return lines[page] ?? 120 }
    nonisolated static func set(_ page: String, _ y: CGFloat) { lock.lock(); lines[page] = y; lock.unlock() }
}
private struct PlacePageKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues { var placePage: String? { get { self[PlacePageKey.self] } set { self[PlacePageKey.self] = newValue } } }

// Notes a row as the place when it's the one across the top of the page. Only the crossing is reported, a yes or no that
// changes once per row passing, so scrolling costs a comparison per row and frame and redraws nothing.
struct MarksPlace: ViewModifier {
    @Environment(\.placePage) private var page
    @Environment(\.paneLayout) private var panes
    @Environment(\.compactWindow) private var compactWindow
    let id: AnyHashable
    func body(content: Content) -> some View {
        content.modifier(LogsHeight(id: id)).onGeometryChange(for: Bool.self) { g in
            guard let page else { return false }
            // SwiftUI runs this off the main actor: MainActor.assumeIsolated here trapped (SIGTRAP, build dd1a9ce,
            // 2026-11-11), so the line is read from its own locked store, never from the main-actor PlaceKeeper.
            let f = g.frame(in: .global), line = PlaceLines.line(page)
            return f.minY <= line && f.maxY > line
        } action: { on in
            guard on, let page else { return }
            let k = PlaceKeeper.page(page)
            // Only from the layout the place was noted in: on a turn the new layout's first rows cross the line before its
            // restore begins, and noted the top of the page as his place, so the turn put him back at the top (designer,
            // regate of 5b34ffc: Apps scrolled down, turned flat and back, came back at its top).
            if !k.settling, k.layout == nil || k.layout == "\(panes)\(compactWindow)", k.top != id {
                k.top = id
                if SwipeLog.on { SwipeLog.note("place \(page) \(id.base)") }
            }
        }
    }
}

// For the build's logs only (-swipeLog YES): each placed row's height as it changes, so a page that grows or shrinks at
// rest says which row did it.
struct LogsHeight: ViewModifier {
    let id: AnyHashable
    func body(content: Content) -> some View {
        if SwipeLog.on {
            content.onGeometryChange(for: CGFloat.self) { ($0.size.height * 100).rounded() / 100 } action: { old, new in
                SwipeLog.note("row \(id.base) h \(old) -> \(new)")
            }
        } else { content }
    }
}

struct KeepsPlace: ViewModifier {
    @Environment(\.paneLayout) private var panes
    @Environment(\.compactWindow) private var compactWindow
    let page: String
    let proxy: ScrollViewProxy
    private struct Reading: Equatable { var y: CGFloat; var end: CGFloat }
    // This list's own end (of two panes, each has its own), kept off SwiftUI's state so reading it redraws nothing.
    private final class Own { var end: CGFloat = 0 }
    @State private var own = Own()
    func body(content: Content) -> some View {
        content
            .environment(\.placePage, page)
            // The line is just under the bars over the page: the scroll view's top in the window plus its top inset.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY + $0.safeAreaInsets.top + 8 } action: { PlaceLines.set(page, $0) }
            .onScrollGeometryChange(for: Reading.self) { g in
                // Its end, not just its content: open flat the bars' insets settled after the content had, and the end
                // moved 47 to 27 under a restore made at 47 (CI 8505660).
                Reading(y: (g.contentOffset.y + g.contentInsets.top).rounded(),
                        end: (g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom - g.containerSize.height).rounded())
            } action: { old, new in
                let k = PlaceKeeper.page(page)
                if old.end != new.end { k.grew = Date() }
                own.end = new.end
                k.y = new.y
                // Only his own scrolling, in the layout the place belongs to: never the new layout settling, nor the restore.
                if !k.settling, k.layout == "\(panes)\(compactWindow)" { k.scrolled = new.y > 8 }
            }
            .task(id: "\(panes)\(compactWindow)") {
                let k = PlaceKeeper.page(page), layout = "\(panes)\(compactWindow)"
                // Of two panes the first to appear starts the restore; the other, a moment later, scrolls too if it holds it.
                // Any change of layout starts the quiet time, his place or not: the new layout's rows settling at the top
                // aren't his choice (designer, regate of 23292ae: flat noted the top as his place and the turn back went there).
                if let was = k.layout, was != layout { k.restoring = Date(); k.pending = k.top != nil && k.scrolled }
                k.layout = layout
                // Off for now: a restore made after the turn's first frame shows the page at its top and then cuts to his
                // row, a 314 pt jump each time he turns back (designer, full regate of 1f6ad94). Top after a turn, with no
                // jump, until his place can be set in the new layout's first pass.
                guard PlaceKeeper.restores else { k.pending = false; return }
                guard k.pending, Date().timeIntervalSince(k.restoring) < 5, let top = k.top else { return }
                // Once, without animation, when the rebuilt page's rows have stopped growing (none for 200 ms, at most
                // 1.5 s in): retries 250, 350 and 600 ms in landed, slid away as rows grew, and were cut back (designer,
                // regate of 3bcef0e). A rebuild that cancels this leaves it pending for the next list to carry out.
                try? await Task.sleep(nanoseconds: 150_000_000)
                let start = Date()
                while !Task.isCancelled, Date().timeIntervalSince(k.grew) < 0.2, Date().timeIntervalSince(start) < 1.5 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                guard !Task.isCancelled else { return }
                // A list that all but fits has no place to keep: open flat, Apps' left pane scrolls 27 pt, its rows all in
                // sight. Restored to his row it went to its end, then sprang back 20 pt as a row below settled (CI 871244b).
                // It stays at its top; his place stays noted for the next posture.
                if own.end < 80 {
                    SwipeLog.note("place kept, not restored \(page): end \(Int(own.end)) (\(layout))")
                    k.pending = false; k.restoring = Date(); return
                }
                SwipeLog.note("place restore \(page) to \(top.base) (\(layout))")
                var still = Transaction(); still.disablesAnimations = true
                withTransaction(still) { proxy.scrollTo(top, anchor: .top) }
                // Once more only if that one didn't move the page at all (folded, CI 8505660: a restore to the Mac row
                // left Status at its top). Never a second scroll on a page the first one moved.
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !Task.isCancelled, k.y <= 8 {
                    SwipeLog.note("place restore again \(page) to \(top.base) (\(layout))")
                    withTransaction(still) { proxy.scrollTo(top, anchor: .top) }
                }
                k.pending = false; k.restoring = Date()
            }
    }
}

// One set of timings for the whole app: quick enough to feel instant, long enough to read as motion, and critically
// damped or close to it, so nothing wobbles into place.
enum Motion {
    // Things appearing, notes, state swaps, zoom resets.
    static let quick = Animation.spring(response: 0.24, dampingFraction: 0.86)
    // A key or card giving under the finger.
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.72)
    // Fades: the pointer, a value changing.
    static let fade = Animation.easeOut(duration: 0.16)
}

// A card that gives under the finger, as system rows highlight.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// A failure, said under the control that caused it.
struct FailText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}

// A pushed page reads from the Mac on its own. When the Mac stops answering (8 s of misses, MissClock), the page says so
// in one line with how old what it shows is, dims it, and takes nothing that would act on it: a session could be answered
// or a process quit against a screen that was minutes old and looked live (audit, 2026-11-10).
struct StaleLine: View {
    let lastRead: Date?
    static func ago(_ d: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        return s < 60 ? "\(max(s, 1)) s ago" : s < 3600 ? "\(s / 60) min ago" : Format.span(Double(s)) + " ago"
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { c in
            Label(lastRead.map { "Last read \(Self.ago($0, now: c.date)) · \(Phrase.macAwayShort)" } ?? Phrase.macAway, systemImage: "wifi.exclamationmark")
                .font(.footnote.weight(.medium)).foregroundStyle(.orange).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transition(.opacity)
    }
}
// What a stale page's own content is dimmed to.
let staleDim = 0.5

// System tabs and navigation get Liquid Glass and move to the Duo's right edge by themselves.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("accent") private var accent = "blue"
    @AppStorage("celsius") private var celsius = false
    @State private var resets: [Int: Int] = [:]
    @ObservedObject private var ota = OTAInstaller.shared
    // His apps, set only when they change: the root never redraws for a reading (StatusStore).
    @ObservedObject private var seeds: SeedStore
    init(seeds: SeedStore) { _seeds = ObservedObject(wrappedValue: seeds) }
    private var updateCount: Int { seeds.seed.map { UpdatesSection.updates($0).count } ?? 0 }
    // A new colour redraws the other tabs; Settings, where it was picked, stays put so the swatch can animate.
    func key(_ t: Int) -> String { "\(accent)-\(resets[t, default: 0])" }
    var body: some View {
        let _ = SwipeLog.mark("root body")
        PaneReader {
            TabView(selection: TabReset.binding(Binding(get: { model.tab }, set: { model.tab = $0 })) { t in
                // Back to the tab's own start. With a page open on it, the page goes back the way Back takes it, the
                // system's animated pop (the pushed page holding its layout as it slides, NavTransit). The tab was rebuilt
                // here too, which swapped the page for the tab's top with no motion at all (Richard, 2026-11-10: "press the
                // button again it jankily goes back no animation"). Only a tab already at its start is rebuilt at the top.
                let open = (t == 0 && (model.history != nil || model.processes != nil || model.nav.settingsOpen)) || (t == 1 && model.appHistory != nil) || (t == 2 && model.sessionScreen != nil) || (t == 5 && model.macPage != nil)
                if open {
                    if t == 0 { model.history = nil; model.processes = nil; model.nav.settingsOpen = false }
                    if t == 1 { model.appHistory = nil }
                    if t == 2 { model.sessionScreen = nil }
                    if t == 5 { model.macPage = nil }
                } else {
                    resets[t, default: 0] += 1
                }
            }) {
                // Six tabs, not seven: Usage is Claude's usage and lives on the Claude tab. Seven in the bar along the foot
                // (open in portrait) were squeezed, the labels nearly touching (Richard, 2026-11-07: "the bar like the
                // elements r squished tg looks ugly").
                Tab(value: 0) { Screen(tab: 0, title: "Status") { StatusTab($0, side: $1) }.id(key(0)) } label: { tabLabel("Status", "gauge.with.dots.needle.33percent") }
                Tab(value: 1) { Screen(tab: 1, title: "Apps") { AppsTab($0, side: $1) }.id(key(1)) } label: { tabLabel("Apps", "square.grid.2x2") }
                    // The updates waiting, as a number on the tab, the App Store's way.
                    .badge(updateCount)
                Tab(value: 2) { Screen(tab: 2, title: "Claude") { ClaudeTab($0, side: $1) }.id(key(2)) } label: { tabLabel("Claude", asset: "ClaudeTab") }
                // "macOS", not "Updates": the Mac's own system updates, kept apart from his apps' updates in Apps (designer, 2026-11-07).
                Tab(value: 4) { Screen(tab: 4, title: "macOS", listed: false) { UpgradeTab($0, side: $1) }.id(key(4)) } label: { tabLabel("macOS", "arrow.up.circle") }
                Tab(value: 5) { Screen(tab: 5, title: "Control") { ControlTab($0, side: $1) }.id(key(5)) } label: { tabLabel("Control", "display") }
                // The Mac's own screen, the Console, driven from here (Richard, 2026-11-13: "separate tab"). Settings went
                // behind the gear on Status to keep the bar at six.
                Tab(value: 6) { Screen(tab: 6, title: "Console") { ConsoleTab($0, side: $1) }.id(key(6)) } label: { tabLabel("Console", "macwindow") }
            }
            .tint(macBlue)
            .onChange(of: model.tab) { _, t in
                UserDefaults.standard.set(t, forKey: "tab")
                // A tab opens on the Mac as it is now, not as it was at the last 10-second reading.
                Task { await model.refresh() }
            }
        }
        .onAppear { MacPrefs.shareWithWidgets(); AppBadge.set(updateCount) }
        // And on the app's icon on the home screen, like the App Store's.
        .onChange(of: updateCount) { _, n in AppBadge.set(n) }
        .onChange(of: accent) { _, _ in MacPrefs.shareWithWidgets() }
        .onChange(of: celsius) { _, _ in MacPrefs.shareWithWidgets() }
        .onChange(of: model.address) { _, _ in MacPrefs.shareWithWidgets() }
        .screenCover(isPresented: $model.screenOpen) { NavigationStack { RemoteScreenView(model: model) }.modifier(ReportsScreen(model: model)) }
        .screenCover(isPresented: $model.signInSheet) { SignInView().environmentObject(model) }
        // Up here, so unfolding doesn't close it and lose what's typed.
        .sheet(isPresented: $model.signingIn) {
            LoginSheet { u, p in
                let filled = u.isEmpty ? p : u + "\t" + p
                return await model.runSealed("type-text", secret: filled, extra: ["enter": true])
            }
        }
    }
}

#if os(iOS)
// A pushed page hides its Back (Back is the side bar's), and UIKit turns the swipe from the left edge off with it. Back
// on, for any page with one under it: the swipe is the other way back every iPhone page has (as in the TV app).
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        // A page swiped off holds its layout from the moment the finger takes it (HoldsWhileMoving, FoldSplit).
        NavTransit.shared.register(self)
        interactivePopGestureRecognizer?.addTarget(self, action: #selector(edgeSwipeMoved(_:)))
    }
    // Called after the stack's own handler, which has begun the pop by now.
    @objc func edgeSwipeMoved(_ g: UIGestureRecognizer) {
        if g.state == .began, let c = transitionCoordinator { NavTransit.shared.begin(c) }
    }
    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        g === interactivePopGestureRecognizer ? viewControllers.count > 1 : true
    }
}
#endif

// Every pushed page names itself the way every tab does (Richard, 2026-11-09: the Back and titles were "not up to code"
// for the Duo): its name is its first line (PaneHeading), large, in one pane or two, and the system's bar holds only its
// Back, which iOS lays out where the Duo puts it (top of the side strip folded and open flat, the bar along the top open
// upright). No hand-made item in the bar. The system's large title was tried (CI f074caa): swiping a page back to a tab,
// whose bar is hidden, the bar shrank away under it and clipped the title's top half for most of the slide, the very
// "elements compact as u do so" he saw on Version History. A small bar title sat in a different place from the tabs'
// names and from Version History's. Named in the page, it slides off whole with the page.
extension View {
    @ViewBuilder func pushedTitle() -> some View {
        #if os(iOS)
        self.navigationTitle("")
            .toolbarVisibility(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        #else
        self.navigationTitle("")
        #endif
    }
}
// A page's name as its first line, at the tabs' size and height (paneTitle). The right pane carries it unseen, so both
// panes' first cards start level.
struct PaneHeading: View {
    @Environment(\.statusBarTop) private var statusBarTop
    let title: String
    var shown = true
    // false in a List row: the list's top margin gives the room (PaneHeading.roomAbove), since inside the row it pushed the
    // title into the row's rounded corner and notched its first letter (CI d9c229c: the F of Fans, the M of Mac).
    var roomAbove = true
    // The Console page that shows the same thing, for "Show on Mac" beside the name.
    var onMac: String? = nil
    static func roomAbove(_ statusBarTop: CGFloat) -> CGFloat { statusBarTop < 20 ? 14 : 0 }
    var body: some View {
        HStack(alignment: .center) {
            Text(title).font(.largeTitle.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            // Drawn unseen in the pane that carries the name unseen, so both title rows are as tall and both first cards level.
            if let onMac { ShowOnMacButton(page: onMac).padding(.trailing, 4).allowsHitTesting(shown) }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, roomAbove ? Self.roomAbove(statusBarTop) : 0)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(!shown)
            .accessibilityAddTraits(.isHeader)
    }
}

// A row's own separator, under its name (`inset` from the row's leading edge), on the cell's top edge. The system's ran
// the card's full width under one row or another wherever it fell on the screen (CI d9c229c and 43030e3: under Chumby
// proxy on Connections, under Chumby on Health, in every posture). The row takes the list's usual 20 pt sides and its
// usual 11 pt ends itself (`ends`), so it sits where it did. The first row of a card has none.
struct OwnSeparator: ViewModifier {
    let first: Bool
    var inset: CGFloat = 38
    var ends: CGFloat = 11
    func body(content: Content) -> some View {
        content
            .padding(.vertical, ends)
            .overlay(alignment: .top) { if !first { Divider().padding(.leading, inset) } }
    }
}
extension View {
    // The list's side of OwnSeparator, on the row's outermost view (after .place): inside it, under .place's wrapper, the
    // List never saw them, and drew its own line and ends as well as ours (CI 3609ee9: two lines between rows).
    func ownSeparatorRow() -> some View {
        listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }
}

// The chevron at the end of a row that opens a page, as the Control tab draws it: footnote, semibold, tertiary label grey,
// never the row’s tint, so the tertiary grey is drawn as a colour (designer, CI d9c229c: blue chevrons on Actions and Updates beside grey ones on Control).
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.primary.opacity(0.3))
    }
}

// A device's name as a word: its first letter capitalised, except names Apple spells its own way ("iphone" → "iPhone",
// "ipad-2" → "iPad-2"), which keep that spelling (designer, 2026-11-11, amending the capitals ruling).
func appleCased(_ name: String) -> String {
    for word in ["iPhone", "iPad", "iPod", "iMac", "macOS", "iOS"] where name.lowercased().hasPrefix(word.lowercased()) {
        return word + name.dropFirst(word.count)
    }
    return name.prefix(1).uppercased() + name.dropFirst()
}
// The Mac reports some states in capitals or lower case; the app says them one way.
func sentenceCase(_ t: String) -> String { t.prefix(1).uppercased() + t.dropFirst().lowercased() }

// Can't reach the Mac, or it wants its code: said once at the top of every tab, each with what to do about it.
struct Notice: View {
    @EnvironmentObject private var noticeState: NoticeStore  // redrawn when the Mac's reachability changes (not through the model)
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var retrying = false
    var body: some View {
        if model.needsSignIn {
            VStack(alignment: .leading, spacing: 10) {
                Label("Sign in needed", systemImage: "lock.fill").font(.body.weight(.semibold)).foregroundStyle(.orange)
                Text(model.address.isEmpty ? "Add the Mac’s address to connect." : "The Mac wants its access code for this address.").font(.footnote).foregroundStyle(.secondary)
                Button("Sign in") { model.signInSheet = true }.buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        } else if model.unreadable {
            VStack(alignment: .leading, spacing: 6) {
                Label("The Mac answered, but this version can’t read it.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("What’s here is the last it could read. Update the app in TestFlight.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else if let p = model.problem, !model.problemPutAway {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Label(p, systemImage: "wifi.exclamationmark").foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    // One ✕, full strength, a 44 pt target: put away, the card comes back with the next run of misses.
                    Button { withAnimation(Motion.quick) { model.problemPutAway = true } } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.primary).frame(width: 44, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
                HStack(spacing: 10) {
                    Button("Open Tailscale") { if let u = URL(string: "tailscale://") { openURL(u) } }.buttonStyle(.bordered)
                    Button {
                        Task { retrying = true; await model.refresh(); retrying = false }
                    } label: {
                        if retrying { ProgressView().frame(minWidth: 70) } else { Text("Try again").frame(minWidth: 70) }
                    }
                    .buttonStyle(.bordered).disabled(retrying)
                }
            }
            .padding(.vertical, 4)
        }
    }
    static func shows(_ model: AppModel) -> Bool { model.needsSignIn || (model.problem != nil && !model.problemPutAway) || model.unreadable }
}

// Shared frame for each tab: a large title, the notice above, and pull to refresh. Updates draws its own page, so its
// header can stay put while the log scrolls.
struct Screen<Content: View>: View {
    @EnvironmentObject private var noticeState: NoticeStore  // redrawn when the Mac's reachability changes (not through the model)
    @EnvironmentObject var model: AppModel
    @Environment(\.statusBarTop) private var statusBarTop
    @Environment(\.paneLayout) private var panes
    let tab: Int
    let title: String
    let listed: Bool
    let content: (Status, Side) -> Content
    init(tab: Int, title: String, listed: Bool = true, @ViewBuilder content: @escaping (Status, Side) -> Content) {
        self.tab = tab; self.title = title; self.listed = listed; self.content = content
    }
    // The status this tab shows. Taken from the store (never watched through the model, whose every landing redrew the whole
    // app), and only while this is the tab in front: a tab behind takes the latest as it comes forward.
    @State private var shown: Status?
    private func take(_ s: Status?) {
        guard let s else { return }
        // A tab behind takes it too, silently, so it is already as it is when he comes back to it: taken on the way back, a
        // card that had arrived meanwhile slid the page down in front of him (designer, resize gate on cbdef0e: in place,
        // nothing settling on arrival).
        guard model.tab == tab || shown == nil else {
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { shown = s }
            return
        }
        if model.statusStore.moves { withAnimation(Motion.quick) { shown = s } } else { shown = s }
    }
    @ViewBuilder var connecting: some View {
        if !Notice.shows(model) { HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) } }
    }
    func list(_ side: Side) -> some View {
        ScrollViewReader { proxy in
            List {
                // The page's name is its first line, in one pane or two, and goes up with the page: the system's large
                // title collapsed into the bar, and the rows ran on under it ("Open on the Mac (13)" printed behind
                // "Apps", 2026-11-07). The TV app does the same.
                // At the cards' edge and as far down as the system's large title sat, so nothing moved but its behaviour.
                // The row's foot sits 14 pt below the title, out of the corner the list rounds off: the A of Apps lost its left foot to
                // it (designer gate, 2026-11-14). The gap to the next block gives the 14 pt back.
                Section { paneTitle(side).padding(.top, statusBarTop < 20 ? 14 : 0).place("pagetop") }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0)).listRowSeparator(.hidden)
                    .listSectionSpacing(.custom(tab == 0 ? 14 : 3))
                if side != .right, Notice.shows(model) { Section { Notice() } }
                if let s = shown ?? model.status { content(s, side) }
                else if side != .right, !Notice.shows(model) { Section { connecting } }
            }
            // One gap between the blocks on Status, where they sit on the page's own background.
            .listSectionSpacing(tab == 0 ? .custom(28) : .default)
            .scrollsUnder(side == .right ? 1 : 0)
            .keepsPlace("tab\(tab)", proxy)
            // No pull to refresh: every figure follows the Mac by itself (each second on Status, every 10 seconds
            // otherwise, and at once on opening a tab), so pulling only ever showed what was already there (Richard,
            // 2026-11-07: the display key "should self update not requiring refresh which u can take the function out").
            .contentMargins(.top, 4, for: .scrollContent)
            // Asked for the usage (the Claude widget, or an old link to the Usage tab): the Claude tab opens at it.
            .task(id: model.usageAsked) {
                // Once per ask, so coming back to the tab later finds it where it was left.
                guard tab == 2, side != .right, model.usageAsked > model.usageShown else { return }
                for _ in 0..<60 where model.status == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                try? await Task.sleep(nanoseconds: 400_000_000)
                model.usageShown = model.usageAsked
                withAnimation(Motion.quick) { proxy.scrollTo("usage", anchor: .top) }
            }
            // The This Mac card's readings (MacConsole.swift, ConsoleSummary), from the Control tab's list itself: hung off a
            // card down the page, a List never drew it until scrolled to, so the card came in late and the shots scrolled
            // to nothing (CI 43030e3).
            .task(id: tab) { if tab == 5, side != .left { await ConsoleSummary.shared.loop(model) } }
            .task {
                // The build's shots of Apps and Claude scrolled part way, the title gone up with the page: Apps to its open
                // apps (his 2026-11-07 screenshot), Claude to the usage.
                // And of a state that sits down the page: Force Quit's question hangs off Apps' open apps, the secret being
                // typed is in Control's Passwords, Claude's service card is at the foot of its pane.
                if let (t, to) = ["forcequit": (1, "open"), "controlbusy": (5, "typebox"), "claudecard": (2, "cc-restart"), "macpower": (5, "macctl"), "oldbridge": (5, "power")][model.pose], t == tab {
                    for _ in 0..<60 where model.status == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                    // The This Mac card is drawn only once its first reads land: waited for, or the scroll found nothing
                    // and the open portrait and folded shots never showed it (CI d9c229c).
                    if to == "macctl" { for _ in 0..<40 where ConsoleSummary.shared.links.value == nil { try? await Task.sleep(nanoseconds: 250_000_000) } }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    proxy.scrollTo(to, anchor: .top)
                    return
                }
                guard model.pose != "scrolled" || tab == 0 else {
                    guard side != .left, let to = [1: "open", 2: "detail", 5: "power"][tab] else { return }
                    for _ in 0..<60 where model.status == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    proxy.scrollTo(to, anchor: .top)
                    return
                }
                // The build's shot of the heat heading over the dials (the bridge's verdict), the heading in view.
                if model.pose == "heat", tab == 0, side != .right {
                    for _ in 0..<60 where model.status == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    proxy.scrollTo("temps", anchor: UnitPoint(x: 0.5, y: 0.35))
                    return
                }
                // The build's shot of Status scrolled down to the dials and the disk.
                // The build's film of Status left at its end, where the top processes are (the resize check).
                if model.pose == "scrolledend", tab == 0, side != .right {
                    for _ in 0..<60 where model.status == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    proxy.scrollTo("procs-all", anchor: .bottom)
                    return
                }
                guard tab == 0, side != .left, model.pose == "scrolled" || model.pose == "scrollfilm" else { return }
                // A cold launch in the build's simulator takes ~10 s to show Status: wait for it, so the film shows scrolling.
                for _ in 0..<60 where model.status == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard model.pose == "scrollfilm" else { proxy.scrollTo("temps", anchor: .top); return }
                // The build's film of Status scrolling, down and back up twice, so scrolling is judged moving, never from
                // one still (Richard, 2026-11-06: "the scrolling is absolutely fucked").
                for _ in 0..<2 {
                    withAnimation(.easeInOut(duration: 1.4)) { proxy.scrollTo("temps", anchor: .top) }
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    withAnimation(.easeInOut(duration: 1.4)) { proxy.scrollTo("pagetop", anchor: .top) }
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                }
            }
        }
    }
    // With two panes the page's name is the left pane's first line, large, and the right pane keeps the same height empty
    // so both start level. It's not the system's large title: that collapses as either pane scrolls, and scrolling one
    // slid the other up and down (Richard, 2026-11-06: "the elements on status shrink and expand like on the side").
    func paneTitle(_ side: Side) -> some View {
        HStack(alignment: .center) {
            Text(title).font(.largeTitle.weight(.bold)).lineLimit(1)
            Spacer(minLength: 8)
            // The same page on the Mac's Console: Status is its overview, macOS its updates.
            // (Unseen and untouchable in the right pane, which carries the row's height so both panes start level.)
            if let page = [0: "overview", 4: "updates"][tab] { ShowOnMacButton(page: page).allowsHitTesting(side != .right) }
            // Settings, beside Status's name, the way the App Store keeps its account by its title.
            if tab == 0 {
                Button { model.nav.settingsOpen = true } label: {
                    Image(systemName: "gearshape").font(.title2).foregroundStyle(macBlue).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .padding(.trailing, 4)
                .allowsHitTesting(side != .right)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(side == .right ? 0 : 1)
            .accessibilityHidden(side == .right)
            .accessibilityAddTraits(.isHeader)
    }
    func page(_ side: Side) -> some View {
        VStack(spacing: 12) {
            // As high as the listed tabs' titles (the list's 4 pt margin, and 14 pt more where the clock is on the side):
            // macOS's sat 18 pt above Apps' folded, so the title jumped going from one tab to the next.
            paneTitle(side).padding(.top, (statusBarTop < 20 ? 14 : 0) + 4)
            if side != .right, Notice.shows(model) {
                Notice().frame(maxWidth: .infinity, alignment: .leading).padding(16).background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            }
            if let s = shown ?? model.status { content(s, side) }
            else if side != .right { connecting.frame(maxHeight: .infinity) }
        }
        .modifier(PageLead(on: side != .right))
    }
    var body: some View {
        let _ = SwipeLog.mark("screen \(tab) body")
        NavigationStack {
            Group {
                if listed {
                    if panes { FoldSplit { list(.left) } right: { list(.right) } }
                    else { list(.all) }
                } else {
                    if panes { FoldSplit { page(.left) } right: { page(.right) } }
                    else { page(.all) }
                }
            }
            .modifier(TabBarFade())
            .modifier(StatusBarFade())
            .background(groupedBackground.ignoresSafeArea())
            // Laid over both panes at once, so open there's one edge, not one per pane.
            .topEdge()
            .navigationTitle(title)
            // Large open too, so the page's name leads and its section headings follow. Small in the bar, it sat under
            // headings like "This Mac" and "Log" and read wrong (Richard, 2026-11-05).
            // No bar title at all, in one pane or two: the page's first line carries the name (paneTitle).
            .navigationBarTitleDisplayMode(.large)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .modifier(StackPages(tab: tab, model: model, nav: model.nav))
        }
        .onReceive(model.statusStore.$status) { take($0) }
        // Come back to with something added or gone while away (an alert, a sensor, a process): it moves in, not in one frame.
        .onChange(of: model.tab) { _, t in
            guard t == tab, let s = model.status else { return }
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { shown = s }
        }
    }
}
// A hand-drawn page's left edge, where the lists' cards are: 20 pt from the display's edge in every posture. Open flat
// the split has already moved the left pane 14 pt in, and the macOS tab added its 20 on top, so its title and cards
// started 14 pt right of every other tab's (designer, 2026-11-11: one page inset for every tab's left pane).
struct PageLead: ViewModifier {
    @Environment(\.paneOuter) private var outer
    let on: Bool
    func body(content: Content) -> some View { content.padding(.leading, on ? max(0, 20 - outer) : 0) }
}
// The pages a tab's stack can show. Alone here, watching the open pages (NavStore), so a page opening or closing works
// out this and nothing else: the tab under it is handed through untouched.
struct StackPages: ViewModifier {
    let tab: Int
    let model: AppModel
    @ObservedObject var nav: NavStore
    func body(content: Content) -> some View {
        content
            .navigationDestination(item: tab == 0 ? $nav.history : Binding<HistoryMetric?>.constant(nil)) { HistoryView(metric: $0) }
            // Settings, behind the gear beside Status's name.
            .navigationDestination(isPresented: tab == 0 ? $nav.settingsOpen : .constant(false)) { MacSettings(pushed: true) }
            // All processes, from Status itself; from a history, that page opens them over itself.
            .navigationDestination(item: tab == 0 && nav.history == nil ? $nav.processes : Binding<ProcessSort?>.constant(nil)) { ProcessesView(first: $0, model: model) }
            .navigationDestination(item: tab == 2 ? $nav.sessionScreen : Binding<Status.Session?>.constant(nil)) { SessionTerminal(session: $0, model: model) }
            .navigationDestination(item: tab == 1 ? $nav.appHistory : Binding<String?>.constant(nil)) { AppPage(file: $0, model: model) }
            // Everything on the Mac, or Restart the Mac, from the Control tab.
            .navigationDestination(item: tab == 5 ? $nav.macPage : Binding<MacPage?>.constant(nil)) { p in
                switch p {
                case .health: MacHealthView(model: model)
                case .restart: MacRestartView(model: model)
                // The Mac as a control surface (MacConsole.swift).
                case .links: LinksView(model: model)
                case .fans: FansView(model: model)
                case .updates: UpdatesView(model: model)
                case .storage: StorageView(model: model)
                case .startup: StartupView(model: model)
                case .actions: MacActionsView(model: model)
                }
            }
    }
}
// Processes over a history, the same way.
struct ProcessesOverHistory: ViewModifier {
    let model: AppModel
    @ObservedObject var nav: NavStore
    func body(content: Content) -> some View {
        content.navigationDestination(item: $nav.processes) { ProcessesView(first: $0, model: model) }
    }
}

struct StateRow: View {
    let label: String; let good: Bool; let value: String
    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) { Circle().fill(good ? Color.green : Color.red).frame(width: 9, height: 9); Text(value) }
        }
    }
}

// The web dashboard's tile: a label, a big number and a line you can drag along to read the past.
struct WebTile: View {
    let title: String, value: String, detail: String
    var spark: [Double] = []
    var top: Double?
    var read: (Double) -> String = { _ in "" }
    var open: () -> Void = {}
    var figure: Text {
        let big = Font.system(size: 26, weight: .semibold).monospacedDigit()
        let small = Font.system(size: 17, weight: .semibold)
        // "%" is a unit like the others (designer, resize gate): small beside its number.
        if value.hasSuffix("%") { return Text(value.dropLast()).font(big) + Text("%").font(small) }
        guard let gap = value.lastIndex(of: " ") else { return Text(value).font(big) }
        return Text(value[..<gap]).font(big) + Text(value[gap...]).font(small)
    }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                // Only the figure animates as it changes; the little chart just steps along, which costs nothing.
                // The number large and its unit smaller beside it, at one size always: shrunk to fit, the figure changed size
                // as its width did ("48.4 MB/s" one second, "3 KB/s" the next).
                figure.lineLimit(1).fixedSize(horizontal: false, vertical: true).contentTransition(.numericText())
                    // Not while a page slides on or off: Status comes back from a page with the readings it missed, and
                    // rolled them in mid-slide and after it (Richard's recording, 2026-11-10). They're simply there.
                    // Nor as he arrives on the tab: the first readings after coming back are simply there (resize gate).
                    .animation(NavTransit.shared.active || AppModel.justArrived ? nil : .easeOut(duration: 0.2), value: value)
                Text(detail).font(.footnote).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                if spark.count > 1 {
                    // Only a picture here: a touch on it belongs to the page's scrolling or opens the full history.
                    SparkLine(values: spark, top: top)
                        .frame(height: 42).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Show the past 24 hours", open)
    }
}

struct LiveTiles: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LiveStore
    let s: Status
    var body: some View {
        let _ = SwipeLog.mark("tiles body")
        let cpu = store.live?.cpu ?? s.cpu, mem = store.live?.mem ?? s.mem, net = store.live?.net ?? s.net, h = store.live?.hist ?? s.hist, load = store.live?.load ?? s.load
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                WebTile(title: "CPU", value: "\(cpu.total)%", detail: String(format: "Load %.2f", load.first ?? 0), spark: h.cpu, top: 100, read: { "\(Int($0))%" }, open: { model.history = .cpu })
                WebTile(title: "Memory", value: Format.bytes(mem.used), detail: "of \(Format.bytes(mem.total))", spark: h.mem, top: 100, read: { "\(Int($0))%" }, open: { model.history = .memory })
            }
            HStack(spacing: 12) {
                WebTile(title: "Download", value: Format.rate(net.rxRate), detail: net.kind, spark: h.rx, read: Format.rate, open: { model.history = .download })
                WebTile(title: "Upload", value: Format.rate(net.txRate), detail: net.ip, spark: h.tx, read: Format.rate, open: { model.history = .upload })
            }
        }
    }
}

// One dial per sensor: the number and how far the ticks reach say it all.
struct TempDials: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LiveStore
    let s: Status
    var body: some View {
        let _ = SwipeLog.mark("dials body")
        // The status's sensors, with the live reading's figures: a live reading with fewer (or none) never takes a row away.
        let live = store.live?.temps ?? []
        let temps = (s.temps ?? live).map { t in live.first { $0.name == t.name } ?? t }
        let hottest = temps.max { $0.c < $1.c }?.name
        // Laid out in the one pass from the width it is given (EvenGrid): read back with onGeometryChange, the grid was
        // three across for its first frame each time it was built, then four, and the page grew and shrank by a row.
        EvenGrid(spacing: 12, rowSpacing: 16) {
            ForEach(temps) { t in
                VStack(spacing: 6) {
                    ArcGauge(Heat.level(t.c), heat: true, ticks: 32, length: 7, width: 2.2) {
                        Text("\(Heat.shown(t.c))°").font(.system(.body).weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                    }
                    // The hottest sensor's name stands out, so the one to watch is found at a glance (Richard, 2026-11-12:
                    // "iterate on the features u removed and make it even better").
                    Text(t.name).font(.caption2.weight(t.name == hottest && temps.count > 1 ? .semibold : .regular))
                        .foregroundStyle(t.name == hottest && temps.count > 1 ? AnyShapeStyle(Heat.color(t.c) == .white ? Color.primary : Heat.color(t.c)) : AnyShapeStyle(.secondary))
                        // Its own width, centred under the dial, never shrunk: every name at the one size.
                        .lineLimit(1).fixedSize()
                }
                .contentShape(Rectangle())
                .onTapGesture { model.history = .temperature(t.name) }
                .accessibilityHint("Shows its last 24 hours")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.vertical, 6)
    }
}

// As many across as fit (76 pt each), then evened out, so the last row is never one short (eight dials are 4 + 4, not
// 3 + 3 + 2). Columns are equal; each row is as tall as its tallest, items at its top.
struct EvenGrid: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 16
    // A dial is never wider than this, centred in its column: sized by the column, it grew and shrank with every change of
    // the page's width (a turn into open portrait laid the dials out at 311 pt, then 343 as the side bar's inset went to the
    // foot; designer, resize regate). Wide pages had over-large dials anyway; folded and in a pane they're narrower than this.
    // 2026-11-13: as large as build 276 drew them (it filled the width open upright, 138 pt); 96 left the card sparse.
    var largest: CGFloat = 160
    // To whole steps of 8 pt: the page's width settles a few points at a time after a turn (the side bar's inset arriving),
    // and each step resized the dials and their row (CI 7169d6b: 220.5, 212.5, 212.0, 211.5 pt).
    // Steps of 2 pt now, not 8: to 8 the folded dials were 64 pt in a 71 pt column, smaller than build 276's and with
    // "Power supply" shrunk to fit them (Richard, 2026-11-13: spacing on Temperatures "the biggest problem").
    static func dial(_ cell: CGFloat, _ largest: CGFloat) -> CGFloat { min((cell / 2).rounded(.down) * 2, largest) }
    static func columns(_ n: Int, width: CGFloat) -> Int {
        let fit = max(Int((width + 12) / 76), 1)
        guard n > fit else { return max(n, 1) }
        let rows = (n + fit - 1) / fit
        return (n + rows - 1) / rows
    }
    private func grid(_ width: CGFloat, _ subviews: Subviews) -> (across: Int, cell: CGFloat, rows: [CGFloat]) {
        let across = Self.columns(subviews.count, width: width)
        let cell = max((width - spacing * CGFloat(across - 1)) / CGFloat(across), 0)
        var rows: [CGFloat] = []
        for (i, v) in subviews.enumerated() {
            let h = v.sizeThatFits(ProposedViewSize(width: Self.dial(cell, largest), height: nil)).height
            if i % across == 0 { rows.append(h) } else { rows[rows.count - 1] = max(rows[rows.count - 1], h) }
        }
        return (across, cell, rows)
    }
    // Each dial is measured once per width, not again to place it: building the row mid-scroll measured all eight twice.
    struct Cache { var width: CGFloat = -1; var grid: (across: Int, cell: CGFloat, rows: [CGFloat]) = (1, 0, []) }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.width = -1 }
    private func cached(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> (across: Int, cell: CGFloat, rows: [CGFloat]) {
        if cache.width != width { cache.grid = grid(width, subviews); cache.width = width }
        return cache.grid
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 76 * 4
        let g = cached(width, subviews, &cache)
        return CGSize(width: width, height: g.rows.reduce(0, +) + rowSpacing * CGFloat(max(g.rows.count - 1, 0)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let g = cached(bounds.width, subviews, &cache)
        var y = bounds.minY
        for (r, h) in g.rows.enumerated() {
            for c in 0..<g.across {
                let i = r * g.across + c
                guard i < subviews.count else { break }
                let w = Self.dial(g.cell, largest)
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (g.cell + spacing) + (g.cell - w) / 2, y: y), proposal: ProposedViewSize(width: w, height: h))
            }
            y += h + rowSpacing
        }
    }
}

// Over the dials: how the Mac is doing for heat (normal, warm, hot) and the sensor nearest its limit, in the bridge's words:
// each sensor against its own limits, the rule Fans & temperatures, alerts and the Console use (2026-11-12: a flat 75 °C
// here said "Warm" at a normal 83 °C CPU while everything else said Normal). The flat rule is kept only for an older bridge.
// A tap on any dial opens its 24 hours, as the tiles do.
struct TempsHeader: View {
    @EnvironmentObject var store: LiveStore
    let s: Status
    // Just the heading: the dials' own colour and tinted names say how hot it is, and a real problem is an alert. The
    // "Warm · hottest CPU 185°" line under it restated them (Richard, 2026-11-13: "ugly and unnecessary").
    var body: some View { Text("Temperatures") }
}

struct Hero: View {
    @EnvironmentObject private var noticeState: NoticeStore  // redrawn when the Mac's reachability changes (not through the model)
    @EnvironmentObject var model: AppModel
    let s: Status
    var body: some View {
        let _ = SwipeLog.mark("hero body")
        VStack(spacing: 2) {
            Image("MacPro").resizable().scaledToFit().frame(height: 148)
                // The glow fades to nothing inside the portrait's own height: a round one reached past the row's top and was
                // cut there in a straight line.
                .background(EllipticalGradient(colors: [.white.opacity(0.18), .clear], center: .center, startRadiusFraction: 0.02, endRadiusFraction: 0.5).frame(width: 190, height: 148))
                .accessibilityLabel("Mac Pro, Late 2013")
            Text("Mac Pro").font(.system(size: 28, weight: .bold)).padding(.top, 6)
            Text("Late 2013 · macOS \(s.macos) · up \(Format.span(s.uptime))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            // Claude's usage running out isn't the Mac being unwell: it has its banner row, and stays out of this.
            HeroChips(alerts: s.alerts?.filter { $0.id != OTAInstaller.alertID && $0.kind != "usage" }, healthBad: s.healthBad, offline: model.stale, fresh: model.gotFresh, route: model.route, pulse: model.pulse) {
                model.tab = 5; model.macPage = .health
            }
            .padding(.top, 9)
        }
        .frame(maxWidth: .infinity)
    }
}

// The machine's health and how the phone is reaching it. Offline, only how long ago it last answered.
// Health is said in the words Control's row and the Health page use, from the same count: "All running", or "2 need a
// look", which opens that page. It read "All systems go" from the alerts alone while Control said "2 need a look", and
// green before the Mac had said anything at all (audit, 2026-11-10); now that's a grey "Checking".
struct HeroChips: View {
    let alerts: [Status.Alert]?
    // The parts that need a look: from the status when the Mac's bridge says, else what the app last read itself.
    var healthBad: Int?
    let offline: Bool
    // The Mac has answered since launch. Until then the second chip says how old the kept figures are, not "Live".
    var fresh = true
    let route: String
    @ObservedObject var pulse: Pulse
    @AppStorage(AlertDismissals.key) private var dismissedRaw = ""
    @ObservedObject private var summary = HealthSummary.shared
    var openHealth: () -> Void = {}
    // `opens`: the chip is a way in (Health, when parts need a look), and shows it the way a row does.
    func chip<D: View>(@ViewBuilder _ dot: () -> D, _ text: String, opens: Bool = false) -> some View {
        HStack(spacing: 6) { dot(); Text(text).lineLimit(1); if opens { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) } }
            .font(.footnote.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 5).background(Color(white: 0.16), in: Capsule())
    }
    var parts: Int? { healthBad ?? summary.bad }
    var health: (Color, String) {
        func look(_ n: Int) -> String { "\(n) need\(n == 1 ? "s" : "") a look" }
        if let n = parts, n > 0 { return (.orange, look(n)) }
        let said = alerts ?? []
        if !said.isEmpty {
            let tint: Color = said.contains { $0.level == "critical" } ? .red : .orange
            // Every alert put away with its ✕: the problem is still there, so this names the worst of them rather than
            // counting what the page no longer shows. Never green while one is live.
            let put = AlertDismissals.set(dismissedRaw)
            if said.allSatisfy({ put.contains($0.dismissKey) }), let worst = said.first(where: { $0.level == "critical" }) ?? said.first { return (tint, worst.title) }
            return (tint, look(said.count))
        }
        // Nothing said yet, by the status or by the Mac's Health (a Mac that can't say how its parts are, an older
        // bridge, is judged by its alerts alone).
        if alerts == nil, parts == nil, !summary.cantSay { return (.gray, "Checking") }
        return (.green, "All running")
    }
    var body: some View {
        let _ = SwipeLog.mark("chips body")
        if offline {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                chip({ Circle().fill(Color.gray).frame(width: 9, height: 9) }, pulse.lastFresh.map { "Last read \(StaleLine.ago($0, now: Date()))" } ?? "Not reached yet")
            }
        } else {
            HStack(spacing: 8) {
                if (parts ?? 0) > 0 {
                    Button(action: openHealth) { chip({ Circle().fill(health.0).frame(width: 9, height: 9) }, health.1, opens: true) }
                        .buttonStyle(FlatStyle()).accessibilityHint("Opens Everything on the Mac")
                } else { chip({ Circle().fill(health.0).frame(width: 9, height: 9) }, health.1) }
                if !fresh {
                    // Last time's figures while the first answer comes: their age, quietly, never a dimmed page.
                    TimelineView(.periodic(from: .now, by: 5)) { c in
                        chip({ Circle().fill(Color.gray).frame(width: 9, height: 9) }, pulse.lastFresh.map { "Updated \(StaleLine.ago($0, now: c.date))" } ?? "Connecting")
                    }
                } else {
                    // The dot beats each time the Mac answers.
                    chip({
                        Circle().fill(Color.green).frame(width: 9, height: 9)
                            .keyframeAnimator(initialValue: 1.0, trigger: pulse.beats) { dot, k in dot.scaleEffect(k).opacity(2 - k) } keyframes: { _ in
                                KeyframeTrack {
                                    CubicKeyframe(1.45, duration: 0.15)
                                    CubicKeyframe(1.0, duration: 0.34)
                                }
                            }
                    }, "Live · \(route)")
                }
            }
        }
    }
}

// The things reached for most, one tap from the top of the app. Done shows as a tick on the button; a problem, under it.
struct QuickActions: View {
    @EnvironmentObject private var noticeState: NoticeStore  // redrawn when the Mac's reachability changes (not through the model)
    @EnvironmentObject var model: AppModel
    // The display's state as the last full status said, for the Display key between live readings.
    var displayOn: Bool?
    var displayOff = false
    @State private var done: Set<String> = []
    @State private var fails: [String: String] = [:]
    @State private var successes = 0
    func succeed(_ id: String) {
        fails[id] = nil; done.insert(id); successes += 1
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); done.remove(id) }
    }
    func fail(_ id: String, _ text: String) {
        fails[id] = text
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if fails[id] == text { fails[id] = nil } }
    }
    func button(_ id: String, _ icon: String, _ title: String, waits: Bool? = nil, _ action: @escaping () -> Void) -> some View {
        // They all need the Mac, so they wait, dimmed, while it can't be reached. The dim is in the face's own colours,
        // the same values Display uses, so the system's disabled dimming isn't stacked on top.
        Button(action: action) { face(id, icon, title, waits: waits ?? model.stale) }.buttonStyle(FlatStyle()).disabled(waits ?? model.stale)
    }
    func face(_ id: String, _ icon: String, _ title: String, waits: Bool) -> some View {
        let dim = waits ? offlineDim : 1
        return VStack(spacing: 6) {
            Image(systemName: done.contains(id) ? "checkmark" : icon).font(.system(size: 20)).foregroundStyle(.white.opacity(dim))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 52).background(Color(white: 0.16).opacity(dim), in: Circle())
            Text(title).font(.caption2).foregroundStyle(.secondary.opacity(dim)).lineLimit(1).minimumScaleFactor(0.8)
            if let f = fails[id] {
                Text(f).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // The Mac's screen has its own connection: it stays live while the status can't be read (Richard's ruling,
            // 2026-11-11), and waits only when the Mac can't be reached or wants its code.
            button("screen", "macwindow", "Screen", waits: model.problem != nil || model.needsSignIn) { model.openScreen() }
            // Dims itself, in its own colours, to match the other three.
            DisplayHoldButton(statusOn: displayOn, statusOff: displayOff).disabled(model.stale)
            button("copy", "doc.on.doc", "Copy from Mac") {
                fails["copy"] = nil
                Task {
                    guard let t = try? await model.api.clipboard() else { fail("copy", Phrase.macAway); return }
                    // The Mac only hands over text: a copied picture or file reads as nothing, so "empty" would be wrong.
                    if t.isEmpty { fail("copy", "No text on the Mac’s clipboard"); return }
                    #if canImport(UIKit)
                    UIPasteboard.general.string = t
                    #endif
                    succeed("copy")
                }
            }
            // "Paste to Mac", not "Send to Mac": that name is the files' (Control, the share sheet). This one puts the
            // iPhone's clipboard on the Mac's, the other way from Copy from Mac beside it (audit, 2026-11-10).
            button("send", "doc.on.clipboard", "Paste to Mac") {
                fails["send"] = nil
                #if canImport(UIKit)
                let t = UIPasteboard.general.string ?? ""
                #else
                let t = ""
                #endif
                Task {
                    if t.isEmpty { fail("send", "Nothing copied on this iPhone"); return }
                    do { try await model.api.setClipboard(t); succeed("send") } catch { fail("send", Phrase.macAway) }
                }
            }
        }
        // Room above and below for the Display key's hold ring and its swell (about 10 pt past the circle), which the
        // row's own bounds clipped flat at the top.
        .padding(.vertical, 10)
        .animation(Motion.fade, value: fails)
        .animation(Motion.fade, value: done)
        .sensoryFeedback(trigger: successes) { _, _ in MacPrefs.haptics ? .impact(weight: .light) : nil }
        .task {
            // The build's shot of a success: the tick, held long enough to be photographed.
            guard model.pose == "quickdone" else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            done.insert("copy")
        }
    }
}

struct StatusTab: View {
    @EnvironmentObject private var noticeState: NoticeStore  // redrawn when the Mac's reachability changes (not through the model)
    @EnvironmentObject var model: AppModel
    // What the page shows, chosen in Settings.
    @AppStorage("showQuick") private var showQuick = true
    @AppStorage("showTemps") private var showTemps = true
    @AppStorage("showDisk") private var showDisk = true
    @AppStorage("showAccess") private var showAccess = true
    @AppStorage("showThisMac") private var showThisMac = true
    @AppStorage("showProcesses") private var showProcesses = true
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    // Rows that sit on the page's background, spaced by the one section gap alone.
    let bare = EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
    // The figures, dimmed while they're only the last ones the Mac sent.
    @ViewBuilder var graphics: some View {
        // Only once the Mac has been away a while (Reach): at launch last time's figures look as they are, never a dimmed
        // page while the first answer comes over a slow link (Richard, 2026-11-12: "it was slightly darkened"). The chip
        // says how old they are until then.
        let dim = model.stale ? staleDim : 1
        Section { LiveTiles(s: s).opacity(dim).place("tiles") }.listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        if showTemps, let temps = s.temps, !temps.isEmpty {
            Section { TempDials(s: s).opacity(dim).place("temps") } header: { TempsHeader(s: s) }
        }
        if showDisk {
            Section("Disk") {
                Button { model.history = .disk } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(Format.bytes(s.disk.free)) free").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        Text("\(Format.bytes(s.disk.used)) used of \(Format.bytes(s.disk.total))").font(.footnote).foregroundStyle(.secondary)
                        ProgressView(value: s.disk.used, total: s.disk.total).tint(s.disk.used / max(s.disk.total, 1) > 0.9 ? .red : macBlue).padding(.top, 8)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .opacity(dim)
                }
                .buttonStyle(PressStyle())
                .place("disk")
            }
        }
    }
    // The alerts switch is in Settings' Behaviour card (Richard, 2026-11-11: "the notify setting should be in settings").
    @ViewBuilder var text: some View {
        if showAccess {
            Section("Remote access") {
                StateRow(label: "Claude remote sessions", good: s.claude.remoteControl, value: s.claude.remoteControl ? "Running" : "Stopped").place("access-Remote control")
                StateRow(label: "Desktop app", good: s.claude.desktop, value: s.claude.desktop ? "Running" : "Stopped").place("access-Desktop app")
                StateRow(label: "Tailscale", good: s.tailscale.state == "Running", value: s.tailscale.state == "Running" ? "Connected" : "Off").place("access-Tailscale")
                StateRow(label: "Public link", good: s.publicLinkActive, value: s.publicLinkActive ? "Active" : s.publicUrl.isEmpty ? "Off" : "Down").place("access-Public link")
                StateRow(label: "Screen Sharing", good: s.sharing.vnc, value: s.sharing.vnc ? "On" : "Off").place("access-Screen Sharing")
                StateRow(label: "SSH", good: s.sharing.ssh, value: s.sharing.ssh ? "On" : "Off").place("access-SSH")
            }
        }
        if showThisMac {
            Section("This Mac") {
                LabeledContent("Model", value: s.model).place("mac-model")
                LabeledContent("Processor", value: s.cpuModel.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "CPU ", with: "")).place("mac-cpu")
                LabeledContent("Tailnet", value: s.tailscale.name ?? "Not signed in").place("mac-tailnet")
                Button("Change connection") { model.signInSheet = true }.place("mac-change")
            }
        }
        if showProcesses {
            Section("Top processes") {
                // Eight rows by place, not by process: the Mac's top eight change order and members with every reading, and
                // rows keyed by process were taken out, put in and moved each time, a relayout of the list's very end
                // (where a pull past the end rests) once a second. By place, a reading changes a row's words and nothing
                // else; one line each, so no name can change a row's height either.
                ForEach(Array(s.procs.prefix(8).enumerated()), id: \.offset) { i, p in
                    LabeledContent(p.name, value: String(format: "%.0f%% · %.1f%% mem", p.cpu, p.mem)).lineLimit(1).place("proc-\(i)")
                }
                Button { model.processes = .cpu } label: {
                    HStack { Text("All processes").foregroundStyle(.primary); Spacer(); RowChevron() }
                        .contentShape(Rectangle())
                }
                .place("procs-all")
            }
        }
    }
    // Folded, one column in the approved order. Open, the machine and its actions on the left with the settings under
    // them, and the figures on the right, where they're all in view at once.
    var body: some View {
        let _ = SwipeLog.mark("status tab body")
        if side != .right {
            // Updates waiting are the number on the Apps tab, not a problem with the Mac.
            if let alerts = s.alerts?.filter({ $0.id != OTAInstaller.alertID }), !alerts.isEmpty { AlertBanner(alerts: alerts) }
            Section { Hero(s: s).place("top") }.listRowBackground(Color.clear).listRowInsets(bare).listRowSeparator(.hidden)
            if showQuick { Section { QuickActions(displayOn: s.displayOn, displayOff: s.screen == "display off").place("quick") }.listRowBackground(Color.clear).listRowInsets(bare).listRowSeparator(.hidden) }
        }
        if side != .left { graphics }
        if side != .right { text }
    }
}

struct AppsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var pending: Status.App?
    @State private var alert: String?
    // Quitting, the way the Processes page does it: asked to close first, and Force Quit offered only for an app that
    // was asked and stayed. The two were offered side by side in one alert here (audit, 2026-11-10).
    @State private var forcing: Status.App?
    @State private var working: Int?
    func quit(_ a: Status.App, force: Bool) async {
        working = a.pid; defer { working = nil }
        if let e = await model.run(force ? "app-kill" : "app-quit", ["pid": a.pid]) { alert = e; return }
        // The Mac gives it a few seconds, and so does this: gone from the list says it quit.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await model.refresh()
            if !(model.status?.apps.contains { $0.pid == a.pid && $0.mem != nil } ?? false) { return }
        }
        if force { alert = "\(a.name) is still running." } else { forcing = a }
    }
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    // Its memory, with its helpers', always; the CPU only while it's doing something, so a list of idle apps isn't a column
    // of "0% CPU" and a busy one stands out. Megabytes under a gigabyte: a few hundred MB read as "0.1 GB" in gigabytes.
    static func figures(_ a: Status.App) -> String {
        let mem = Format.memory(a.mem ?? 0), cpu = a.cpu ?? 0
        return cpu >= 1 ? "\(mem) · \(Int(cpu.rounded()))% CPU" : mem
    }
    var body: some View {
        if side != .right {
            // Updates first, as in the App Store, then what's on the iPhone.
            // Updates are for apps he added himself; his own three come from TestFlight, which updates them (2026-11-10).
            if let seed = s.iosApps {
                if seed.apps.contains(where: { $0.own && !$0.testFlight }) { UpdatesSection(seed: seed) }
                SeedSection(seed: seed)
            }
        }
        if side != .left {
            // Only apps that are really running: an older Mac listed ones that had quit, with no figures (Calendar and
            // Safari at 0 MB, 2026-11-07).
            let open = s.apps.filter { $0.mem != nil }
            Section("Open on the Mac (\(open.count))") {
                ForEach(open) { a in
                    // Quitting is a full-strength Quit capsule at the row's end, the same control as Update above it: a
                    // dim grey ✕ read as unavailable though it worked (Richard, 2026-11-07: "the greyed out xs when they r
                    // seemingly actionable r confusing and fucked"). Never a swipe (no swipe-to-delete on glass cards).
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            // One line each, so the CPU figure coming and going with each reading never changes the row's height.
                            Text(a.name).lineLimit(1)
                            Text(Self.figures(a)).font(.footnote).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if working == a.pid { ProgressView().frame(width: 60) }
                        else {
                            Button("Quit") { pending = a }
                                .rowCapsule(prominent: false)
                                .disabled(working != nil)
                                .accessibilityLabel("Quit \(a.name)")
                        }
                    }
                    // The first app is where the build's scrolled shot stops, its heading gone up under the top.
                    .place(open.first?.id == a.id ? AnyHashable("open") : AnyHashable(a.id))
                }
            }
            Section {
                Menu {
                    // What isn't already open, the Mac's own apps included (Terminal, Calendar and the rest).
                    ForEach(s.installed.filter { n in !open.contains { $0.name == n } }, id: \.self) { name in Button(name) { Task { alert = await model.run("app-open", ["name": name]) } } }
                } label: { Label("Launch another app", systemImage: "plus.square.on.square") }
                .place("launch")
            }
            // One question from the row's Quit; Force Quit is a second question, only for an app that didn't go.
            .alert(pending.map { "Quit \($0.name)?" } ?? "", isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                if let p = pending {
                    Button("Quit", role: .destructive) { Task { await quit(p, force: false) } }
                    Button("Cancel", role: .cancel) {}
                }
            } message: { Text("It’s asked to close. Unsaved work may be lost.") }
            .alert(forcing.map { "\($0.name) didn’t quit. Force it?" } ?? "", isPresented: .init(get: { forcing != nil }, set: { if !$0 { forcing = nil } })) {
                if let p = forcing {
                    Button("Force Quit", role: .destructive) { Task { await quit(p, force: true) } }
                    Button("Cancel", role: .cancel) {}
                }
            } message: { Text("Unsaved work is lost.") }
            .alert("That did not work", isPresented: .init(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("OK") {} } message: { Text(alert ?? "") }
            // The build's shot of the second question, for an app that was asked to quit and stayed.
            .task { if model.pose == "forcequit" { try? await Task.sleep(nanoseconds: 2_000_000_000); forcing = model.status?.apps.first { $0.mem != nil } } }
        }
    }
}

struct ClaudeTab: View {
    @EnvironmentObject var model: AppModel
    @State private var confirm = false
    @State private var restarting: String?
    @State private var sessionNote: String?
    @State private var rcFail: String?
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    func doRestart(_ x: Status.Session) async {
        guard let key = x.key else { return }
        sessionNote = nil
        restarting = key; defer { restarting = nil }
        do {
            let running = try await model.api.restartSession(key)
            // Back running speaks for itself in the row; only a session that couldn't start needs a word.
            sessionNote = running ? nil : "It will start when the Mac can reach Claude. It tries every two minutes."
        } catch { sessionNote = error.localizedDescription }
        await model.refresh()
    }
    // The limits first, the sessions straight under them, then the figures and the service (Richard, 2026-11-10: "also
    // have limits on top sessions below but be smart with how its laid out"). Open flat: limits, sessions and the service
    // on the left, the figures on the right.
    var body: some View {
        if side != .right {
            LimitsSection(s: s)
            Section("Sessions on this Mac (\(s.claude.sessions.count))") {
                if s.claude.sessions.isEmpty { Text("None running").foregroundStyle(.secondary) }
                ForEach(s.claude.sessions) { x in
                    let row = SessionRow(session: x, working: restarting != nil && restarting == x.key, restart: { Task { await doRestart(x) } })
                    // The whole row opens its page, on this tab's own stack, with Back where the system puts it.
                    // Through the model, so the side bar's Back knows a page is open over the tab.
                    // A tap on the row, not a button around it, so its own Restart and Start keep their taps.
                    if row.canOpen {
                        HStack(spacing: 8) { row; RowChevron() }
                            .contentShape(Rectangle())
                            .onTapGesture { model.open(session: x) }
                            .accessibilityAddTraits(.isButton)
                            .place("session-\(x.id)")
                    } else { row.place("session-\(x.id)") }
                }
                if let sessionNote { FailText(sessionNote) }
            }
            // Each session's screen read ahead, so a tap pushes a page that's already drawn.
            .task(id: s.claude.sessions.compactMap(\.key)) { await TermCache.warm(model.api, s.claude.sessions.compactMap(\.key)) }
        }
        if side != .left { UsageDetail(s: s) }
        if side != .right {
            Section("Claude Code") {
                StateRow(label: "Claude remote sessions", good: s.claude.remoteControl, value: s.claude.remoteControl ? "Running" : "Stopped")
                StateRow(label: "Restarts by itself", good: s.claude.keepAlive, value: s.claude.keepAlive ? "On" : "Off").place("cc-restart")
                StateRow(label: "Desktop app", good: s.claude.desktop, value: s.claude.desktop ? "Running" : "Stopped")
                LabeledContent("Version", value: s.claude.version.replacingOccurrences(of: " (Claude Code)", with: ""))
                LabeledContent("Its service on the Mac", value: sentenceCase(s.claude.service ?? "Unknown"))
                Link(destination: URL(string: "https://claude.ai/code")!) {
                    HStack { Text("Open in the Claude app"); Spacer(); Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)) }
                }
                // Each question hangs off the button that asked it, so it points at what was tapped.
                Button("Restart Claude remote sessions") { confirm = true }
                    .confirmationDialog("Restart Claude remote sessions?", isPresented: $confirm, titleVisibility: .visible) {
                        Button("Restart", role: .destructive) {
                            rcFail = nil
                            Task { rcFail = await model.run("rc-restart") }
                        }
                    } message: { Text("Connected sessions drop briefly, then reconnect.") }
                if let rcFail { FailText(rcFail) }
            }
        }
    }
}

// Model ids as people say them: "claude-opus-4-6" is Opus 4.6.
func modelName(_ id: String) -> String {
    let parts = id.lowercased().replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
    guard let family = parts.first(where: { ["opus", "sonnet", "haiku", "fable", "instant"].contains($0) }) else { return id }
    let numbers = parts.filter { $0.count <= 2 && Int($0) != nil }
    return family.prefix(1).uppercased() + family.dropFirst() + (numbers.isEmpty ? "" : " " + numbers.joined(separator: "."))
}
// How long until something starts again, said the same way on every dial.
func resetsIn(_ ms: Double) -> String {
    let left = ms / 1000 - Date().timeIntervalSince1970
    return left <= 0 ? "Reset" : "Resets in " + Format.span(left)
}

// A label, a figure and a line under it: the API card's right-hand column, and the plan card's.
struct UsageFigure: View {
    let title: String, value: String, detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            // Secondary, not tertiary: tertiary grey on the black card was hard to read (designer, 2026-11-11).
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// The limits, first on the Claude tab (Richard, 2026-11-10: "also have limits on top sessions below but be smart with how
// its laid out"): one card of dials side by side, the plan's week (and its 5 hours, only when Claude sends one) and the
// API's month, each the same dial with its name and when it resets under it, so the sessions come straight after
// instead of under two big cards. The figures behind them (tokens per hour, this Mac's totals, the API's day and week,
// by model) are further down, in UsageDetail.
struct LimitsSection: View {
    @EnvironmentObject var model: AppModel
    let s: Status
    // Watched, so a new budget in Settings shows on the dial at once.
    @AppStorage("apiBudget") private var savedBudget = 200.0
    var u: Status.Usage { s.usage }
    var api: Status.APIUsage? { s.apiUsage }
    var budget: Double { savedBudget > 0 ? savedBudget : MacPrefs.apiBudget }
    // Whole dollars once it's big enough that cents would crowd the dial.
    static func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 100 ? 0 : 2))) }
    // A Mac that has answered and still has nothing to say about the API (an older one) gets no dial for it, rather than
    // a grey placeholder that never fills in.
    var showsAPI: Bool { Self.showsAPI(s, model) }
    static func showsAPI(_ s: Status, _ model: AppModel) -> Bool { s.apiUsage != nil || !model.gotFresh }
    // A lone dial (the week, on a Mac that reports no API) would sit in the middle of a wide card: this Mac's own figures
    // go beside it, as the plan card had them, and the list further down leaves them out.
    static func lone(_ s: Status, _ model: AppModel) -> Bool { s.usage.plan?.fiveHour == nil && !showsAPI(s, model) }
    // One dial: the gauge, its name, and a line under it. Every dial on the card is this one.
    func dial(_ value: Double, tint: Color, title: Text, line: Text, @ViewBuilder centre: () -> some View) -> some View {
        VStack(spacing: 5) {
            ArcGauge(value, tint: tint, ticks: 36, length: 9, width: 2.6) { centre() }
                .frame(maxWidth: 104)
            title.font(.footnote.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
            line.font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }
    static func level(_ v: Double) -> Color { v > 0.9 ? .red : v > 0.75 ? .orange : macBlue }
    func planDial(_ title: String, _ pct: Double?, _ resets: Double?) -> some View {
        let over = (resets ?? .infinity) <= Date().timeIntervalSince1970 * 1000
        let live = !over && pct != nil, v = (pct ?? 0) / 100
        return dial(live ? v : 0, tint: Self.level(v), title: Text(title), line: Text(over ? "Reset" : live ? (resets.map(resetsIn) ?? "") : "No reading")) {
            Text(live ? "\(Int((v * 100).rounded()))%" : "–").font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
        }
    }
    // Until the credit renews: the Mac says when (the 19th), and older Macs fall back to the month's end.
    var renews: String {
        if let r = api?.renewsAt { return resetsIn(r) }
        guard let end = Calendar.current.dateInterval(of: .month, for: Date())?.end else { return "" }
        return resetsIn(end.timeIntervalSince1970 * 1000)
    }
    // The API's month, in whatever state the Mac reports it. One that needs the key added again opens the place to add it.
    @ViewBuilder var apiDial: some View {
        if let a = api, !a.configured {
            // A Mac that hasn't counted anything yet: the dial's shape, waiting, not a chore.
            dial(0, tint: macBlue, title: Text("API"), line: Text("Not counted yet")) { Text("–").font(.system(.title3, design: .rounded).weight(.semibold)) }
        } else if let a = api, let e = a.error, APIUsageNotes.refused(e) {
            Button { withAnimation(Motion.quick) { model.apiSetup = true } } label: {
                dial(0, tint: macBlue, title: Text("API"), line: Text("Key turned down").foregroundStyle(.red)) {
                    Text("Add again").font(.footnote.weight(.semibold)).foregroundStyle(macBlue).multilineTextAlignment(.center).padding(.horizontal, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Add your Admin key again")
        } else {
            // Before the Mac's first answer this launch, the dial's shape with made-up figures, redacted, so nothing moves
            // when the numbers come.
            let a = api ?? .placeholder, spent = a.month?.cost ?? 0, v = spent / budget
            // Spent, by Anthropic's own word: the key has stopped working until the credit renews (2026-11-06).
            let title = a.outOfCredit ? Text("Credit used up").foregroundStyle(.red) : Text("API of \(Self.money(budget))")
            dial(min(v, 1), tint: Self.level(v), title: title, line: Text(renews)) {
                Text(a.month.map { Self.money($0.cost) } ?? "–").font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 10)
            }
            .redacted(reason: api == nil ? .placeholder : [])
        }
    }
    // Whether there is a note under the card at all: an empty footer still takes its 10 pt, which made this section's gap to
    // the next 41 pt against 31 on every other (designer gate, 2026-11-14).
    var hasFooter: Bool {
        if let p = u.plan, Format.staleAge(ms: p.at) != nil { return true }
        if model.apiSetup { return true }
        if let a = api, a.configured, a.estimated { return true }
        if let at = api?.at, api?.configured == true, Format.staleAge(ms: at) != nil { return true }
        return false
    }
    @ViewBuilder var limitsRows: some View {
            HStack(alignment: .top, spacing: 8) {
                if u.plan?.fiveHour != nil { planDial("5 hours", u.plan?.fiveHour, u.plan?.fiveHourResets) }
                planDial("This week", u.plan?.sevenDay, u.plan?.sevenDayResets)
                if showsAPI { apiDial }
                if Self.lone(s, model) {
                    // "On this Mac" once, over both: it was under each figure, twice in tertiary grey (designer, 2026-11-11).
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Tokens on this Mac").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        UsageFigure(title: "Last 5 hours", value: Format.count(u.fiveHours.tokens), detail: nil)
                        UsageFigure(title: "Last 7 days", value: Format.count(u.week.tokens), detail: nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
            // What went wrong reading the API, said under the dials, without the Mac's "Couldn't read API usage:" lead-in.
            if let a = api, let e = a.error, !APIUsageNotes.refused(e) { Text(APIUsageNotes.plain(e)).font(.footnote).foregroundStyle(.red).lineLimit(3) }
            if model.apiSetup { APIKeyRow().transition(.opacity) }
    }
    @ViewBuilder var limitsFooter: some View {
            VStack(alignment: .leading, spacing: 6) {
                // Its age only once it's old enough to doubt: "Updated 43m ago" under a live reading read as stale (2026-11-07).
                if let p = u.plan, let age = Format.staleAge(ms: p.at) { Text("Plan last read \(age)") }
                if model.apiSetup {
                    Text("Made in the Claude Console under an organization. It goes to the Mac’s keychain and isn’t kept on this phone.")
                } else if let a = api, a.configured, a.estimated {
                    // Counted from the Mac's own sessions on the key. The Admin key is only an offer, for exact figures.
                    Button("API counted on the Mac. For exact numbers, add an Admin key") { withAnimation(Motion.quick) { model.apiSetup = true } }
                        .buttonStyle(.plain).foregroundStyle(macBlue).multilineTextAlignment(.leading)
                } else if let at = api?.at, api?.configured == true, let age = Format.staleAge(ms: at) { Text("API last read \(age)") }
            }
    }
    var body: some View {
        if hasFooter {
            Section { limitsRows } header: { Text("Limits") } footer: { limitsFooter }
                .id("usage")
        } else {
            Section { limitsRows } header: { Text("Limits") }
                .id("usage")
        }
    }
}
enum APIUsageNotes {
    // A key Anthropic turned down needs adding again; anything else is just said.
    static func refused(_ e: String) -> Bool { ["refused", "invalid", "401", "unauthorized"].contains { e.localizedCaseInsensitiveContains($0) } }
    static func plain(_ e: String) -> String {
        let t = e.replacingOccurrences(of: "Couldn’t read API usage: ", with: "").replacingOccurrences(of: "Couldn't read API usage: ", with: "")
        return "Couldn’t read the API’s usage: " + t + "."
    }
}

// The figures behind the limits, under the sessions (open flat, the right pane): tokens per hour, this Mac's totals, the
// API's day and week, and by model.
struct UsageDetail: View {
    @EnvironmentObject var model: AppModel
    let s: Status
    var u: Status.Usage { s.usage }
    var models: [(key: String, value: Status.ModelTally)] { u.week.models.filter { $0.value.tokens > 0 }.sorted { $0.value.tokens > $1.value.tokens } }
    func spend(_ x: Status.APIUsage.Spend?) -> String { x.map { "\(LimitsSection.money($0.cost)) · \(Format.count($0.tokens)) tokens" } ?? "–" }
    var body: some View {
        Section("Tokens per hour, last 24 hours") {
            VStack(alignment: .leading) {
                Text(Format.count(u.day.tokens)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("\(u.day.messages.formatted()) replies on this Mac").font(.footnote).foregroundStyle(.secondary)
                Chart(u.hours) { h in
                    BarMark(x: .value("Hour", Date(timeIntervalSince1970: h.t / 1000), unit: .hour), y: .value("Tokens", h.tokens), width: .ratio(0.7))
                        .foregroundStyle(macBlue).clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 90)
            }
        }
        .id("detail")
        if !LimitsSection.lone(s, model) {
            Section("Tokens on this Mac") {
                LabeledContent("Last 5 hours", value: Format.count(u.fiveHours.tokens))
                LabeledContent("Last 7 days", value: Format.count(u.week.tokens))
            }
        }
        if let a = s.apiUsage, a.configured, a.month != nil {
            Section("API spend") {
                LabeledContent("Today", value: spend(a.today))
                LabeledContent("This week", value: spend(a.week))
            }
        }
        if !models.isEmpty {
            Section("By model, last 7 days") {
                // Two lines a model, its figures under its name: one model alone was a one-line row, which the system
                // draws as a capsule beside the rounded cards (designer, 2026-11-11).
                ForEach(models, id: \.key) { name, v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(modelName(name))
                        Text("\(Format.count(v.tokens)) tokens · \(v.messages.formatted()) replies").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
extension Status.APIUsage {
    static var placeholder: Status.APIUsage {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Status.APIUsage.self, from: Data(#"{"configured":true,"month":{"cost":12.4,"tokens":1200000},"week":{"cost":4.1,"tokens":400000},"today":{"cost":0.8,"tokens":90000}}"#.utf8))
    }
    // For the build's shots: a reading taken a few minutes ago, part way through a period that renews on the 19th.
    static var sample: Status.APIUsage {
        var u = placeholder
        let now = Date().timeIntervalSince1970 * 1000
        u.month = .init(cost: 41.2, tokens: 3_900_000); u.week = .init(cost: 9.8, tokens: 920_000); u.today = .init(cost: 1.6, tokens: 140_000)
        u.at = now - 180_000; u.renewsAt = now + 15.5 * 86_400_000; u.periodStart = now - 15 * 86_400_000
        return u
    }
    // The same, counted on the Mac without an Admin key.
    static var estimateSample: Status.APIUsage {
        var u = sample
        u.source = "estimate"; u.at = Date().timeIntervalSince1970 * 1000 - 40_000
        return u
    }
}
// Giving the Mac the Admin key that reads the API's costs, in one row of the Usage card: a sheet never sized itself to
// the field on the Duo. It goes straight to the Mac, sealed, and the phone forgets it.
struct APIKeyRow: View {
    @EnvironmentObject var model: AppModel
    @State private var key = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool
    var blank: Bool { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !saving else { return }
        key = ""
        saving = true; failure = nil
        Task {
            // The Mac checks it, keeps it in its keychain and reads the usage at once, or says in a line why not.
            let err = await model.runSealed("api-admin-key", secret: k)
            saving = false
            if let err { failure = err } else { withAnimation(Motion.quick) { model.apiSetup = false } }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Not a password to iOS, so it never offers to save it.
                SecureField("Admin key", text: $key).textContentType(.oneTimeCode).autocorrectionDisabled()
                    .submitLabel(.done).onSubmit(save).focused($focused)
                if saving { ProgressView().frame(minWidth: 56) }
                else { Button("Save", action: save).buttonStyle(.borderedProminent).disabled(blank) }
            }
            if let failure { FailText(failure) }
        }
        .onAppear { if model.pose.isEmpty { focused = true } }
    }
}

// The Updates page: where the machine stands, pinned, with the log scrolling on its own underneath.
struct UpgradeTab: View {
    @EnvironmentObject var model: AppModel
    @State private var fail: String?
    @State private var agentFail: String?
    @State private var agentPassword = ""
    @State private var confirmRun = false
    @State private var trailingInset: CGFloat = 0
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    var onTahoe: Bool { (Int(s.macos.split(separator: ".").first ?? "") ?? 0) >= 26 }
    // The update service's status line comes as a log line: "2026-11-04 03:30:15 healthy: macos 26.7.2 (25g332), oclp …".
    // The card says only its word ("Healthy"), with when it was checked under it; the versions are already on the line below.
    var statusParts: (word: String, at: Date?, step: String?) {
        var t = s.upgrade.status.trimmingCharacters(in: .whitespaces)
        var at: Date?
        var step: String?
        if t.count >= 19, let d = Self.stamp.date(from: String(t.prefix(19))) { at = d; t = String(t.dropFirst(19)).trimmingCharacters(in: .whitespaces) }
        if let colon = t.firstIndex(of: ":") {
            let rest = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Only a short step name: a healthy line goes on with the versions, already in Details.
            if !rest.isEmpty, rest.count <= 32, !rest.lowercased().hasPrefix("macos") { step = rest }
            t = String(t[..<colon])
        }
        return (sentenceCase(t), at, step)
    }
    static let stamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    // A check in progress says so: "Running" over Details' "Running 26.7.2" said two things with one word (designer, 2026-11-11).
    var checking: Bool { statusParts.word.lowercased() == "running" }
    var headline: String {
        if s.upgrade.installed, checking { return "Checking for updates" }
        return s.upgrade.installed ? (s.upgrade.status.isEmpty ? "Starting…" : statusParts.word) : onTahoe ? "On Tahoe" : "Waiting for your password to start"
    }
    // The log's newest line without its time, for the step a running check is on.
    var lastStep: String? {
        guard let l = s.upgrade.log.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        var t = String(l)
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") { t = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
        if let r = t.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d "#, options: .regularExpression) { t.removeSubrange(r) }
        // In his words while it runs: "Checking softwareupdate catalogue, pass 160 of 160" was plumbing, cut mid-word
        // (designer gate, 2026-11-13).
        let low = t.lowercased()
        if low.contains("softwareupdate") || low.contains("catalog") || low.hasPrefix("tick") { return "Checking for a newer macOS" }
        if low.contains("kdk") || low.contains("kernel debug") { return "Getting what the patches need" }
        if low.contains("oclp") || low.contains("opencore") { return "Checking OpenCore Legacy Patcher" }
        if low.contains("root patch") || low.contains("patching") { return "Patching" }
        if low.contains("download") { return "Downloading" }
        if low.contains("install") { return "Installing" }
        return t.isEmpty ? nil : t
    }
    var oclp: String { s.upgrade.state["oclp_tag"] ?? s.oclp.version }
    // A newer macOS the service found and is holding back until OCLP can patch it, from its last run's lines
    // ("macOS Tahoe 26.7.3-25G342 is too new or has no KDK yet, holding").
    var held: String? {
        let lines = s.upgrade.log.components(separatedBy: "\n")
        let lastRun = lines.lastIndex { $0.contains("tick:") } ?? 0
        for l in lines[lastRun...] {
            guard l.contains("holding"), let r = l.range(of: #"macOS \S+ ([0-9.]+)-(\w+)"#, options: .regularExpression) else { continue }
            let parts = l[r].split(separator: " ").last?.split(separator: "-") ?? []
            if parts.count == 2 { return "\(parts[0]) (\(parts[1]))" }
        }
        return nil
    }
    // A seal for how it stands: done, working, or something to look at.
    var seal: (String, Color) {
        let t = s.upgrade.status.lowercased()
        if t.contains("fail") || t.contains("error") || t.contains("stuck") { return ("exclamationmark.triangle.fill", .orange) }
        if !s.upgrade.installed { return onTahoe ? ("checkmark.seal.fill", .green) : ("lock.fill", .secondary) }
        if t.isEmpty || ["install", "download", "patch", "running", "start", "wait", "check"].contains(where: t.contains) { return ("arrow.triangle.2.circlepath", macBlue) }
        return ("checkmark.seal.fill", .green)
    }
    // OCLP writes down the Darwin version it patched for ("25.6 (25G332)"), which under "macOS 26.7.2" read as an older
    // macOS. The build in brackets is what says whether the patches are for the system running now.
    var patchedBuild: String? {
        let t = s.oclp.patchedFor
        guard let open = t.lastIndex(of: "("), let close = t.lastIndex(of: ")"), open < close else { return nil }
        return String(t[t.index(after: open)..<close])
    }
    var patchedThis: Bool { patchedBuild == s.build }
    var patchedFor: String {
        if s.oclp.patchedFor.isEmpty { return "None yet" }
        if patchedThis { return "This macOS" }
        return patchedBuild.map { "Build \($0), not this one" } ?? s.oclp.patchedFor
    }
    var patched: String {
        if s.oclp.patchedFor.isEmpty { return "No root patches yet" }
        return patchedThis ? "Root patched for this macOS" : "Root patched for build \(patchedBuild ?? s.oclp.patchedFor)"
    }
    // Under the word: what the hidden log's last line said ("Up to date"), and when it was checked. The card is never a
    // lone line, which at the cards' 26 pt corner read as a capsule (designer, 2026-11-11).
    var summaryLine: String? {
        guard s.upgrade.installed else { return nil }
        // When, in the app's style: the update service checks once a day at 3:30 AM, so "23 hours ago" was true but
        // read as broken (Richard, 2026-11-13); "Yesterday, 3:30 AM" says the same plainly.
        let checked = statusParts.at.map { "checked " + Format.when($0).replacingOccurrences(of: "Today", with: "today").replacingOccurrences(of: "Yesterday", with: "yesterday") }
        if !logShown, !s.upgrade.log.isEmpty { return ["Up to date", checked].compactMap { $0 }.joined(separator: " · ") }
        // Running: the step it's on, from the log's newest line. Failed: which step, as the Mac names it after its word
        // ("FAILED: root patch" → "Root patch").
        // While it checks the heading says so; a second "Checking for a newer macOS" under it said it twice.
        let step = checking ? lastStep.flatMap { $0.hasPrefix("Checking") ? nil : $0 } : statusParts.step.map(sentenceCase)
        let line = [step, checked].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line.prefix(1).uppercased() + line.dropFirst()
    }
    // Only its word and when it was checked: the versions and the patch were under it and again in the rows card beside
    // it, four lines said twice (designer, 2026-11-11). The rows card carries them in every posture.
    var summary: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: seal.0).font(.system(size: 30)).foregroundStyle(seal.1).symbolRenderingMode(.hierarchical).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline).lineLimit(2)
                if let line = summaryLine { Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
    @ViewBuilder var agent: some View {
        if s.agentStale {
            VStack(alignment: .leading, spacing: 10) {
                Text("Update service improvements").font(.subheadline.weight(.semibold))
                // Also the helper that finds this iPhone again on Wi-Fi, when the Mac has never had it.
                Text("New versions of the Mac’s background helpers are ready to install. Your password is used once.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    SecureField("Mac password", text: $agentPassword).textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        agentFail = nil
                        let p = agentPassword; agentPassword = ""
                        Task { agentFail = await model.runSealed("agent-update", secret: p) }
                    }
                    .buttonStyle(.bordered).disabled(agentPassword.isEmpty)
                }
                if let agentFail { FailText(agentFail) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
    }
    // The facts behind the summary, as rows, and at their foot the one thing to do here: run the update check. It was a
    // round arrow on the summary, which read as a refresh against staleness (designer, 2026-11-11).
    var factRows: [(String, String)] {
        let patchedAt: String = s.oclp.patchedAt.isEmpty ? "Not yet" : (Format.stamp(s.oclp.patchedAt).map(Format.when) ?? s.oclp.patchedAt)
        var rows: [(String, String)] = [("Running", "\(s.macos) (\(s.build))"), ("OpenCore Legacy Patcher", oclp), ("Root patches for", patchedFor), ("Patched", patchedAt)]
        // "Newest macOS: 26.7.3 (25G342), waiting for patches" was cut with an ellipsis folded (CI f3a3118): the label says
        // the waiting, the value only the version.
        if let held { rows.append(("Waiting for patches", held)) }
        return rows
    }
    var facts: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(factRows.enumerated()), id: \.offset) { i, row in
                // The list cards' insets: text 20 pt in, separators stopping 20 pt short of the right edge.
                if i > 0 { Divider().padding(.horizontal, 20) }
                LabeledContent(row.0, value: row.1).padding(.horizontal, 20).padding(.vertical, 12)
            }
            if s.upgrade.installed {
                Divider().padding(.horizontal, 20)
                Button { confirmRun = true } label: {
                    Text("Check for updates").foregroundStyle(macBlue).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .confirmationDialog("Check for updates now?", isPresented: $confirmRun, titleVisibility: .visible) {
                    Button("Check now") { fail = nil; Task { fail = await model.run("upgrade-run") } }
                } message: { Text("This may restart the Mac.") }
                // The build's shot of the question.
                .task { if model.pose == "upgradeask" { try? await Task.sleep(nanoseconds: 1_500_000_000); confirmRun = true } }
                if let fail { FailText(fail).padding(.horizontal, 20).padding(.bottom, 12) }
            }
        }
        .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
    // The log only when it has something to read. "Update check finished. Nothing to do." on its own was success chatter
    // (designer, 2026-11-11). It's back while a check runs, and always when its last line is a failure.
    // Always, as in build 276: the last check's lines are information even when they say nothing was needed (Richard,
    // 2026-11-12: "there should be plenty of info and such everywhere").
    var logShown: Bool {
        !s.upgrade.log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var log: some View { VStack(alignment: .leading, spacing: 8) { header("Log"); UpdateLog(log: s.upgrade.log) } }
    // Folded and upright the log gets the room left under the facts: its newest lines, whole, as many as fit, and a tap
    // opens the whole log full screen (Richard, 2026-11-13: "log is too small when folded"; five lines, the last cut).
    @State private var fullLog = false
    @State private var pageHeight: CGFloat = 0
    @State private var aboveHeight: CGFloat = 0
    // What's left under Details (less the Log heading and the gaps), and at least twelve lines.
    var logRoom: CGFloat { max(LogPreview.twelveLines, pageHeight - aboveHeight - 26 - 44 - 12) }
    var logPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                header("Log")
                Spacer()
                Button("Show all") { fullLog = true }.font(.body).foregroundStyle(macBlue).padding(.trailing, 20)
            }
            Button { fullLog = true } label: { LogPreview(log: s.upgrade.log, room: logRoom) }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Log, newest lines").accessibilityHint("Opens the whole log")
        }
        .screenCover(isPresented: $fullLog) { FullLog(log: s.upgrade.log).environmentObject(model) }
        .task { if model.pose == "fulllog" { try? await Task.sleep(nanoseconds: 1_200_000_000); fullLog = true } }
    }
    // The Apps tab's section headings ("Updates", "On this iPhone"): bold, secondary, under the title rather than as loud
    // as it, in line with the text in the cards below. "Log" was white and semibold at the cards' very edge.
    // The list tabs' own section heading: the system's size, 12 pt lower so its cap-top sits where theirs does under the title
    // (designer gate, 2026-11-14: a size larger and 11 pt higher than every other tab's).
    func header(_ t: String) -> some View { Text(t).font(.headline).foregroundStyle(.secondary).padding(.leading, 20).padding(.top, 12).padding(.bottom, 3) }
    // The same edges as the system's list cards on every other tab: 20 pt in from the leading side, out to the trailing
    // edge of the space, and in the right pane open, from its leading edge.
    var body: some View {
        switch side {
        case .all:
            // Sections 26 pt apart, the other pages' heading rhythm (designer gate, 2026-11-13: 19 pt here against 34 pt on
            // Console, Connections and Storage, card foot to next heading).
            // The log takes the room left under Details, and never less than twelve lines: folded that is more than the
            // screen has, so the page scrolls to it (Richard, 2026-11-13: "log is too small when folded"; CI 35659b7 had
            // room for one entry).
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 26) {
                        // "This Mac" over the status card in every posture, as open flat (designer, 2026-11-11).
                        VStack(alignment: .leading, spacing: 8) { header("This Mac"); summary }
                        agent
                        VStack(alignment: .leading, spacing: 8) { header("Details"); facts }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { aboveHeight = $0 }
                    if logShown { logPreview }
                }
                // With the side bar beside the page, the cards end at its edge, as the list cards do. Open in portrait the
                // tabs are along the foot and nothing is there: the cards ran into the display's edge and lost their corners.
                .padding(.trailing, trailingInset > 20 ? 0 : 20).padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectHidden(true, for: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: { trailingInset = $0 }
        case .left:
            // A header of its own, like the details' beside it, so both panes' first cards start on one line.
            VStack(alignment: .leading, spacing: 8) {
                header("This Mac")
                // The summary with its facts under it, as in build 276, so the left pane is never one card over nothing
                // (Richard, 2026-11-12: "unfolded now the tabs and such feel barren").
                ScrollView { VStack(alignment: .leading, spacing: 12) { summary; facts; agent } }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollEdgeEffectHidden(true, for: .top)
            }
        case .right:
            // The rows beside the summary, and the log under them when it has something to say: with the log hidden the
            // right pane was empty (designer, 2026-11-11: option 2, nothing across the fold).
            // The log beside them, the pane's full height, as in build 276.
            VStack(alignment: .leading, spacing: 12) {
                if logShown { log } else {
                    // The same frame as the left pane's scroll view, so both first cards start on one line.
                    VStack(alignment: .leading, spacing: 8) {
                        header("Details")
                        ScrollView { facts }.scrollBounceBehavior(.basedOnSize).scrollEdgeEffectHidden(true, for: .top)
                    }
                }
            }
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// The update log, a line at a time, starting from its newest end. Errors read red and finished steps green.
struct UpdateLog: View {
    @EnvironmentObject var model: AppModel
    let log: String
    // Full screen: the card takes the whole height, however short the log.
    var fills = false
    // How tall the lines are, so a short log gets a card its own size rather than an empty slab with one line at its foot.
    @State private var contentHeight: CGFloat?
    @State private var scrolledDown = false
    @State private var atEnd = true
    static let bad = try? NSRegularExpression(pattern: #"\b(error|errors|failed|failure|fatal|cannot|couldn[’']t|panic)\b|✗"#, options: .caseInsensitive)
    static let good = try? NSRegularExpression(pattern: #"\b(finished|complete|completed|succeeded|success|healthy|installed|nothing to do|up to date)\b|✓"#, options: .caseInsensitive)
    static func matches(_ r: NSRegularExpression?, _ s: String) -> Bool { r?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    static func tone(_ line: String) -> Color {
        if matches(bad, line) { return Color(red: 1, green: 0.42, blue: 0.4) }
        if matches(good, line) { return Color(red: 0.4, green: 0.86, blue: 0.5) }
        return Color(white: 0.85)
    }
    var body: some View {
        let lines = log.isEmpty ? ["No log yet"] : log.components(separatedBy: "\n")
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack estimates the height of lines it hasn't laid out, so the scroll stopped short of the
                // true end and the last line sat half under the card's foot (designer gate, 2026-11-14).
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i].isEmpty ? " " : lines[i])
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(log.isEmpty ? Color.secondary : Self.tone(lines[i]))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                // The list rows' insets, so its lines start where every card's text does (designer, 2026-11-11).
                .padding(.horizontal, 20)
                .textSelection(.enabled)
            }
            .contentMargins(.bottom, 2, for: .scrollContent)
            // A line scrolled up fades out a full line deep, and only once the log is scrolled off its top, so a short
            // log's first line is untouched. The scroll view stops 14 pt inside the card's top and foot, so the fade has
            // reached nothing before any glyph meets the edge it's cut at.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: scrolledDown ? 30 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: atEnd ? 0 : 30)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 2 } action: { _, v in scrolledDown = v }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.containerSize.height >= $0.contentSize.height - 2 } action: { _, v in atEnd = v }
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectHidden(true, for: .top)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, h in contentHeight = h }
            .frame(maxHeight: fills ? .infinity : contentHeight ?? CGFloat(lines.count) * 21)
            .padding(.vertical, 14)
            .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .task {
                // The build's shot of the log read part way up.
                guard model.pose == "longlog" else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                proxy.scrollTo(lines.count / 2, anchor: .center)
            }
        }
    }
}
// The newest lines that fit a height, each whole: the height of every line is asked of the laid-out text at the width it
// has, so the card is as tall as the lines it shows, never a character-count guess (designer gate, 2026-11-14).
struct NewestLines: Layout {
    let room: CGFloat
    let gap: CGFloat
    private func heights(_ subviews: Subviews, _ width: CGFloat) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }
    // How many of the newest lines fit, and the height they take.
    private func fit(_ h: [CGFloat]) -> (n: Int, height: CGFloat) {
        var used: CGFloat = 0, n = 0
        for x in h.reversed() {
            let add = x + (n > 0 ? gap : 0)
            if used + add > room, n > 0 { break }
            used += add; n += 1
        }
        return (n, used)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 320
        return CGSize(width: w, height: fit(heights(subviews, w)).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let h = heights(subviews, bounds.width)
        let first = subviews.count - fit(h).n
        var y = bounds.minY
        for (i, v) in subviews.enumerated() {
            if i < first { v.place(at: CGPoint(x: bounds.minX, y: bounds.minY - 5000), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: h[i])); continue }
            v.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: h[i]))
            y += h[i] + gap
        }
    }
}
// The log's newest lines in the room it's given, each whole, wrapped, never a line cut through its glyphs.
struct LogPreview: View {
    let log: String
    // The height it may take, measured by the page around it.
    let room: CGFloat
    #if canImport(UIKit)
    static let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    static let lineHeight = ceil(font.lineHeight)
    #else
    static let lineHeight: CGFloat = 16
    #endif
    static let gap: CGFloat = 3
    static var twelveLines: CGFloat { 12 * lineHeight + 11 * gap + 28 }
    // Without the year and the seconds, so more of each line fits: "11-12 03:30 tick: macOS 26.7.2".
    static func short(_ l: String) -> String {
        guard l.count > 20, l.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d"#, options: .regularExpression) != nil else { return l }
        return String(l.dropFirst(5).prefix(11)) + String(l.dropFirst(19))
    }
    var body: some View {
        // The last forty lines are plenty to choose from; the layout keeps the newest that fit.
        let all = Array(log.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(Self.short).suffix(40))
        NewestLines(room: max(Self.lineHeight, room - 28), gap: Self.gap) {
            ForEach(all.indices, id: \.self) { i in
                Text(all[i]).font(.system(.footnote, design: .monospaced)).foregroundStyle(UpdateLog.tone(all[i]))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
}
// The whole log, full screen, wrapped, from its newest end.
struct FullLog: View {
    @Environment(\.dismiss) private var dismiss
    let log: String
    var body: some View {
        NavigationStack {
            UpdateLog(log: log, fills: true)
                .padding(.horizontal, 20).padding(.bottom, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(groupedBackground.ignoresSafeArea())
                .navigationTitle("Log")
                .toolbarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
extension Status.Upgrade {
    // A night's worth of log, a check still running at its end, for the build's shot of it scrolled.
    static var longSample: Status.Upgrade {
        var lines: [String] = []
        for i in 0..<160 {
            let t = String(format: "%02d:%02d:%02d", 1 + i / 60, i % 60, (i * 7) % 60)
            switch i % 23 {
            case 5: lines.append("[\(t)] Download failed: the connection was reset. Trying again in 30\u{00A0}s.")
            case 11: lines.append("[\(t)] Root patch step finished. Nothing to do.")
            default: lines.append("[\(t)] Checking softwareupdate catalogue, pass \(i + 1) of 160")
            }
        }
        return Status.Upgrade(installed: true, status: "RUNNING: checking", state: ["oclp_tag": "3.0.0"], log: lines.joined(separator: "\n"))
    }
    // The same night ending another way: a failed step, for the shot of the log that must stay up.
    static func longSample(ending: String, status: String) -> Status.Upgrade {
        let l = longSample
        return Status.Upgrade(installed: true, status: status, state: l.state, log: l.log + "\n" + ending)
    }
}

struct ControlTab: View {
    @EnvironmentObject var model: AppModel
    @State private var pressReturn = false
    @State private var confirmForget = false
    @State private var reveal = false
    @State private var restartService: Status.Service?
    // Each section's own failure, under the button that caused it, gone after a few seconds or the next action.
    @State private var fails: [String: String] = [:]
    @ObservedObject private var drafts = Drafts.shared
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }

    // What's on its way to the Mac, and what has just got there. An action in flight can't be pressed again: Type a
    // secret took two round trips of up to 25 s each with nothing on screen, and a second tap typed the password into
    // the Mac again, Return and all, wherever its focus then was (audit, 2026-11-10). Its button shows the wait, then a
    // tick; a failure stays under it until the next thing done here, not 4 s.
    @State private var busy: Set<String> = []
    @State private var ticked: Set<String> = []
    func act(_ key: String, _ work: @escaping () async -> String?) {
        guard !busy.contains(key) else { return }
        withAnimation(Motion.quick) { fails = [:] }
        busy.insert(key)
        Task {
            let e = await work()
            busy.remove(key)
            // Said with what it was that didn't happen: a bare "Can’t reach the Mac" under a red row read as another row.
            if let e { withAnimation(Motion.quick) { fails[key] = Self.undone(key) + e }; return }
            withAnimation(Motion.quick) { _ = ticked.insert(key) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(Motion.quick) { _ = ticked.remove(key) }
        }
    }
    @ViewBuilder func failLine(_ key: String) -> some View { if let f = fails[key] { FailText(f) } }
    static func undone(_ key: String) -> String {
        switch key {
        case "unlock": return "Not unlocked: "
        case "login": return "Not logged in: "
        case "forget": return "Not forgotten: "
        case "type": return "Not typed: "
        default: return key.hasPrefix("svc:") ? "Not restarted: " : ""
        }
    }
    // A row's button with its action's state at the row's end: waiting, then done.
    func actButton(_ title: String, _ key: String, role: ButtonRole? = nil, _ action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if busy.contains(key) { ProgressView() }
                else if ticked.contains(key) { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.green).transition(.opacity).accessibilityLabel("Done") }
            }
        }
        .disabled(busy.contains(key))
    }
    // The build's shots of a failure under its button, and of the Forget password question.
    func pose() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if model.pose == "controlfail" { withAnimation(Motion.quick) { fails["forget"] = "The Mac didn’t answer. Check Tailscale and try again." } }
        if model.pose == "forget" { confirmForget = true }
        // A secret on its way to the Mac (the arrow a spinner, no second tap), beside a failure that has stayed.
        if model.pose == "controlbusy" { drafts.typed = "correct horse"; busy = ["type"]; fails["forget"] = Self.undone("forget") + Phrase.macAway }
    }
    var locked: Bool { s.screen == "locked" }
    var displayOn: Bool { s.displayOn ?? (s.screen != "display off") }
    var typingReady: Bool { s.macLogin || s.typing == "trusted" }

    var body: some View {
        if side != .right {
            Section {
                if s.macLogin {
                    HStack(spacing: 8) {
                        Circle().fill(locked ? Color.orange : Color.green).frame(width: 9, height: 9)
                        Text(locked ? "Locked" : "Logged in")
                        Spacer()
                        HStack(spacing: 5) { Image(systemName: displayOn ? "sun.max.fill" : "moon"); Text(displayOn ? "Display on" : "Display off") }
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    if locked {
                        actButton("Unlock", "unlock") { act("unlock") { await model.run("mac-unlock") } }
                        failLine("unlock")
                    }
                    actButton("Forget password", "forget", role: .destructive) { confirmForget = true }
                        .task { await pose() }
                        .confirmationDialog("Forget the Mac’s password?", isPresented: $confirmForget, titleVisibility: .visible) {
                            Button("Forget password", role: .destructive) { act("forget") { await model.run("mac-logout") } }
                        } message: { Text("After its next restart, the Mac waits at the login window until you log in again from here.") }
                    failLine("forget")
                } else {
                    SecureField("Mac password", text: $drafts.macPassword).textContentType(.password)
                    actButton("Log in", "login") {
                        let p = drafts.macPassword; drafts.macPassword = ""
                        act("login") { await model.runSealed("mac-login", secret: p) }
                    }.disabled(drafts.macPassword.isEmpty && !busy.contains("login"))
                    failLine("login")
                }
            } header: { Text(s.macLogin ? "Mac login" : "Log in to this Mac") } footer: {
                // As in build 276 (Richard, 2026-11-12: "there should be plenty of info and such everywhere and functions").
                Text(s.macLogin ? "It stays logged in after restarts." : "Used once to log in, then saved in the Mac’s keychain. Forget password removes it.")
            }
            // The Screen from Control too, with how it's worked, as in build 276 (Richard, 2026-11-12).
            Section {
                Button("Open Screen") { model.openScreen() }
            } header: { Text("Screen") } footer: { Text("Tap to click · drag to move things · two fingers to scroll · pinch to zoom") }
            SendSection(route: model.route)
            Section {
                Button { model.signingIn = true } label: { Label("Fill a saved login", systemImage: "key.fill") }
                    .disabled(!typingReady)
                    .id("typebox")
                    .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
                if typingReady {
                    HStack(spacing: 10) {
                        Group {
                            if reveal { TextField("Type a secret", text: $drafts.typed).autocorrectionDisabled().textInputAutocapitalization(.never) }
                            else { SecureField("Type a secret", text: $drafts.typed) }
                        }
                        Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel(reveal ? "Hide what’s typed" : "Show what’s typed")
                        Button {
                            // It's encrypted on this iPhone, and that has a size limit. Keep the text so nothing is lost.
                            guard drafts.typed.utf8.count <= 130 else { act("type") { "That’s too long to type in one go. Try under 130 characters." }; return }
                            let t = drafts.typed, enter = pressReturn
                            act("type") {
                                let e = await model.runSealed("type-text", secret: t, extra: ["enter": enter])
                                if e == nil { drafts.typed = "" }
                                return e
                            }
                        } label: {
                            // While it's being typed on the Mac the arrow is a spinner and takes no second tap; then a tick.
                            if busy.contains("type") { ProgressView().frame(width: 28, height: 28) }
                            else { Image(systemName: ticked.contains("type") ? "checkmark.circle.fill" : "arrow.up.circle.fill").font(.title2).contentTransition(.symbolEffect(.replace)) }
                        }
                        .buttonStyle(.plain).foregroundStyle(ticked.contains("type") ? Color.green : drafts.typed.isEmpty ? Color.secondary : macBlue)
                        .disabled(drafts.typed.isEmpty || busy.contains("type")).accessibilityLabel(busy.contains("type") ? "Typing on the Mac" : "Type on Mac")
                    }
                    Toggle("Press Return afterward", isOn: $pressReturn)
                    failLine("type")
                } else {
                    Text("Log in to this Mac above to use this.").foregroundStyle(.secondary)
                }
            } header: { Text("Passwords") } footer: {
                Text("Click the field on the Mac first. Saved logins stay on this iPhone behind Face ID.")
            }
        }
        if side != .left {
            if let list = s.services {
                Section("Services") {
                    ForEach(list) { v in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(v.running ? Color.green : Color.red).frame(width: 9, height: 9)
                                Text(v.name)
                                Spacer()
                                // Only a service that's down has anything to restart.
                                if !v.running {
                                    if busy.contains("svc:" + v.label) { ProgressView().controlSize(.small) }
                                    Button("Restart") { restartService = v }.buttonStyle(.bordered).controlSize(.small).disabled(busy.contains("svc:" + v.label))
                                        .confirmationDialog("Restart \(v.name)?", isPresented: .init(get: { restartService?.label == v.label }, set: { if !$0 { restartService = nil } }), titleVisibility: .visible) {
                                            Button("Restart") { act("svc:" + v.label) { await model.run("service-restart", ["label": v.label]) } }
                                        }
                                }
                            }
                            failLine("svc:" + v.label)
                        }
                    }
                }
            }
            // The devices on his Tailscale and the public link, one card: each was a section of one row, which the system
            // draws as a capsule beside the rounded cards (designer, 2026-11-11: merge lone rows where they belong).
            Section {
                if s.tailscale.peers.isEmpty { Text("No other devices yet").foregroundStyle(.secondary) }
                // The device's name as a word and whether it's there; its OS was chatter (designer, 2026-11-11).
                ForEach(s.tailscale.peers) { p in StateRow(label: appleCased(p.name), good: p.online, value: p.os.isEmpty ? (p.online ? "Connected" : "Offline") : "\(p.os) · \(p.online ? "Connected" : "Offline")") }
                if !s.publicUrl.isEmpty, let u = URL(string: s.publicUrl) { Link("Open public link", destination: u) }
            } header: { Text("Remote access") } footer: {
                if !s.publicUrl.isEmpty { Text("The public link changes whenever the Mac restarts.") }
            }
            // Connections, fans and temperatures, updates, storage and startup items, each its own page (2026-11-13).
            MacConsoleSections()
            // Health and Restart the Mac, last and apart from the everyday buttons, each its own page.
            MacPowerSections()
                .onReceive(model.nav.$macPage.dropFirst()) { p in if p == nil { Task { await ConsoleSummary.shared.readAll(model.api) } } }
        }
    }
}

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var note: String?
    @State private var probing = false
    // Not a sheet: on the Duo a sheet is an inset card folded and sits across the crease open flat, its fields on the fold
    // (Richard, 2026-11-10: sheets fill the screen up to the side column; designer, 2026-11-11). A cover the size of the
    // screen, the page's name its first line as on every pushed page, Cancel and Connect the system's own bar items (the
    // side strip folded and open flat, the bar along the top upright), and open flat a pane each side of the hinge: the
    // address on the left, the code and what went wrong on the right.
    @ViewBuilder var addressSection: some View {
        Section {
            TextField("https://your-mac.your-tailnet.ts.net", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("Mac Pro address") } footer: { Text("Tailscale works from anywhere with the Tailscale app on and needs no code. The public link changes when the Mac restarts.") }
    }
    @ViewBuilder var codeSection: some View {
        Section {
            SecureField("Access code", text: $code).textContentType(.oneTimeCode).textInputAutocapitalization(.characters)
        } header: { Text("Public link only") }
        if let note { Section { FailText(note) } }
    }
    func heading(shown: Bool) -> some View {
        Section { PaneHeading(title: "Connection", shown: shown) }
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
    }
    var body: some View {
        NavigationStack {
            PaneReader {
                SignInPanes(left: { Form { heading(shown: true); addressSection } }, right: { Form { heading(shown: false); codeSection } },
                            all: { Form { heading(shown: true); addressSection; codeSection } })
            }
            .background(groupedBackground.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    // The address is tried before it's kept, and the wait shows where Connect was.
                    if probing { ProgressView() } else { Button("Connect") { Task { await connect() } }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
            .onAppear {
                address = model.address
                // The build's shots of the sheet trying an address, and of one that didn't answer.
                if model.pose == "signinprobe" { address = "mac-pro.example.ts.net"; probing = true }
                if model.pose == "signinbad" { address = "https://mac-pro.exmaple.ts.net"; note = "Can’t reach a Mac at this address. Is Tailscale on?" }
                if model.pose == "signincode" { note = "This address needs its access code." }
            }
        }
        .preferredColorScheme(.dark)
    }
    // What was typed, as an address the app can use: the scheme put on when it's left off (https, or http for a bare
    // local address), no trailing slash. Nil when it still isn't one.
    static func normalised(_ typed: String) -> String? {
        var t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.contains("://") {
            let host = t.split(separator: ":").first.map(String.init) ?? t
            let local = host.hasSuffix(".local") || host == "localhost" || (host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." })
            t = (local ? "http://" : "https://") + t
        }
        guard let u = URL(string: t), let h = u.host, !h.isEmpty, ["http", "https"].contains(u.scheme ?? "") else { return nil }
        return t
    }
    // Asks the address itself before keeping it. It was saved first and judged by the app's state, which starts out
    // "needs sign in" and takes 8 s of misses to say unreachable: a typo read as "needs an access code", and a wrong
    // address closed the sheet as if connected (audit, 2026-11-10).
    func connect() async {
        note = nil
        guard let fixed = Self.normalised(address), let base = URL(string: fixed) else { note = "That isn’t an address. It looks like https://your-mac.your-tailnet.ts.net"; return }
        address = fixed
        probing = true; defer { probing = false }
        let api = API(base: base)
        if !code.isEmpty {
            do { try await api.login(code: code) }
            catch { note = MacFiles.unreachable(error) || error is URLError ? "Can’t reach a Mac at this address. Is Tailscale on?" : error.localizedDescription; return }
        }
        do {
            _ = try await api.statusData()
            code = ""
            model.address = fixed
            await model.refresh()
            dismiss()
        } catch APIError.signInNeeded {
            note = code.isEmpty ? "This address needs its access code." : "The Mac didn’t take that access code."
        } catch {
            note = "Can’t reach a Mac at this address. Is Tailscale on?"
        }
    }
}

// One column, or a pane each side of the hinge open flat (FoldSplit), for a page that isn't one of the tabs.
struct SignInPanes<L: View, R: View, A: View>: View {
    @Environment(\.paneLayout) private var panes
    @ViewBuilder let left: () -> L
    @ViewBuilder let right: () -> R
    @ViewBuilder let all: () -> A
    var body: some View {
        if panes { FoldSplit { left().scrollContentBackground(.hidden) } right: { right().scrollContentBackground(.hidden) } }
        else { all().scrollContentBackground(.hidden) }
    }
}

// How many parts of the Mac need a look, as the app last read it from the Mac's Health (Control's row and the Health
// page read it; Status's chip shows it when the status itself doesn't say). Nil until read, and again once it can't be.
@MainActor
final class HealthSummary: ObservableObject {
    static let shared = HealthSummary()
    @Published private(set) var bad: Int?
    // Asked, and the Mac had no answer to give.
    @Published private(set) var cantSay = false
    private var asked = Date.distantPast
    // The programs the Mac says aren't responding ("1 program stuck: Safari; a restart clears it"), by name, for the
    // restart question to offer closing them first.
    @Published private(set) var stuck: [String] = []
    func set(_ r: MacReport?) {
        let n = r.map { $0.parts.filter(\.bad).count }; if n != bad { bad = n }; if r != nil, cantSay { cantSay = false }
        var names: [String] = []
        if let p = r?.parts.first(where: { $0.part == "stuck" && $0.bad }), let c = p.say.components(separatedBy: ";").first?.range(of: ": ") {
            names = String(p.say.components(separatedBy: ";").first![c.upperBound...]).components(separatedBy: ", ").filter { !$0.isEmpty }
        }
        if names != stuck { stuck = names }
    }
    // For Status, from a Mac whose status doesn't carry the count: asked once a minute at most.
    func refresh(_ api: API) {
        guard Date().timeIntervalSince(asked) > 60 else { return }
        asked = Date()
        Task { if let r = try? await api.macHealth() { set(r) } else if bad == nil, !cantSay { cantSay = true } }
    }
}

// Apps the Mac can put on this iPhone, and what the iPhone itself reports having.
struct SeedSection: View {
    @EnvironmentObject var model: AppModel
    let seed: Status.SeedStatus
    @State private var picking = false
    @State private var linking = false
    @State private var link = ""
    @State private var uploading = false
    // What went wrong, said in the row it happened to.
    @State private var rowFail: [String: String] = [:]
    // The TestFlight tip, shown once until he puts it away.
    @AppStorage("tfAutoTipDone") private var autoTipDone = false
    @State private var addFail: String?
    @ObservedObject private var ota = OTAInstaller.shared

    static func daysLeft(_ a: Status.SeedApp) -> Int? {
        a.expires > 0 ? Int(ceil((a.expires / 1000 - Date().timeIntervalSince1970) / 86400)) : nil
    }
    func daysLeft(_ a: Status.SeedApp) -> Int? { Self.daysLeft(a) }
    // How long the signature has left, in words, from the real end of its profile (a year, signed with his paid team), and
    // only once it's within a month: "340 days left" on every row was noise. Coloured only once it needs him.
    static func left(_ days: Int) -> (String, Color)? {
        days > 30 ? nil : days > 1 ? ("\(days) days left", .secondary) : days == 1 ? ("1 day left", .orange) : ("Expired", .red)
    }
    // One line under the name, as the Updates rows have ("Build 178 · Today"): the build in the same words, then what's
    // worth knowing about it. It was three: a green "Up to date · 6d left" (the section above already says everything is
    // up to date), "1.0 (12)" in a second numbering, and the chevron. Colour only for what needs him.
    func label(_ a: Status.SeedApp) -> (String, Color) {
        let build = "Build \(a.phoneBuild.isEmpty ? a.build : a.phoneBuild)"
        // From TestFlight: quiet. The version and build on the phone, or the newer build waiting in TestFlight. No days
        // left, no Install or Update: TestFlight installs and renews them (Richard, 2026-11-10).
        if a.testFlight {
            if let tf = a.tfNewer { return ("Build \(tf) in TestFlight", .secondary) }
            return ("\(a.version) · \(build)", .secondary)
        }
        // This app, already at the build the Mac still thinks is waiting (it can't see the phone away from home).
        if OTAInstaller.isThisApp(a), a.build == OTAInstaller.thisBuild, ["waiting", "update"].contains(a.state) {
            return ("Build \(a.build)" + (daysLeft(a).flatMap(Self.left).map { " · " + $0.0 } ?? ""), .secondary)
        }
        switch a.state {
        case "installing": return ("Installing build \(a.build)…", .secondary)
        case "waiting" where otaLink(a) != nil:
            return ota.wasOpened(a) ? ("Build \(a.build) sent to this iPhone", .secondary) : ("Build \(a.build) is ready", .secondary)
        case "waiting": return ("Build \(a.build) installs on home Wi-Fi", .secondary)
        case "failed": return ("\(build) · Install failed", .red)
        case "missing": return ("Not on this iPhone", .orange)
        case "update": return ("Build \(a.build) is ready", .secondary)
        case "external": return ("Installed outside the Mac", .secondary)
        case "unknown": return (build, .secondary)
        default:
            guard let days = daysLeft(a), let l = Self.left(days) else { return (build, .secondary) }
            return (days > 0 ? "\(build) · \(l.0)" : "\(build) · Expired", l.1)
        }
    }
    // A newer build signed for this iPhone installs over the air, at home or away: the Mac's link, opened here.
    func otaLink(_ a: Status.SeedApp) -> URL? {
        guard a.own, ["waiting", "update"].contains(a.state), let s = a.ota, !s.isEmpty,
              !(OTAInstaller.isThisApp(a) && a.build == OTAInstaller.thisBuild) else { return nil }
        return URL(string: s)
    }
    // Renewal is automatic, so a button only when something needs doing.
    func needsHand(_ a: Status.SeedApp) -> Bool {
        if ["missing", "update", "failed"].contains(a.state) { return true }
        if let d = daysLeft(a) { return d <= 1 }
        return false
    }
    var body: some View {
        // Updates have their own section above, App Store style; here, what's on the iPhone.
        let ups = Set(UpdatesSection.updates(seed).map(\.id))
        Section {
            // Only his own apps: one installed some other way (SideStore) has no package on the Mac, so no real icon and
            // nothing the Mac can do for it; a blank tile in its place is a placeholder (designer HOLD, 2026-11-07).
            ForEach(seed.apps.filter { $0.own && !ups.contains($0.id) }) { a in
                let l = label(a)
                Button { model.appHistory = a.file } label: {
                // The Updates rows' own layout, so the two sections read as one list: the 58 pt icon, the name in the
                // headline, one line under it, the capsule at the end. No chevron: the App Store's rows open their app
                // without one, as the Updates rows above already do.
                HStack(spacing: 14) {
                    AppIcon(app: a, size: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.headline)
                        Text(l.0).font(.subheadline).foregroundStyle(l.1).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        if !a.message.isEmpty { Text(a.message).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
                        if let f = rowFail[a.id] { Text(f).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 8)
                    if ota.current?.file == a.id { ProgressView().frame(width: 84) }
                    else if otaLink(a) != nil, !ota.wasOpened(a) {
                        // The way in now: a filled capsule, the one thing on the row to tap.
                        Button("Install") { ota.install([a]) }
                            .rowCapsule()
                            .disabled(ota.running)
                            .accessibilityLabel("Install \(a.name) build \(a.build)")
                    }
                    // At home the Mac installs it straight away. Away, every app gets its over-the-air link once the Mac has
                    // signed it, so until then there's nothing to press (the footer says it's on its way).
                    else if a.own, needsHand(a), seed.reachable {
                        Button(a.state == "missing" ? "Install" : a.state == "update" ? "Update" : "Renew") {
                            rowFail[a.id] = nil
                            Task { rowFail[a.id] = await model.run("ios-seed", ["file": a.file]) }
                        }
                        .rowCapsule(prominent: false)
                        .disabled(!seed.seeding.isEmpty)
                    }
                }
                .padding(.vertical, 6)
                // In its own colours: the list's button style tints its whole label, and .primary resolved to that tint
                // (CI f7bb947, every line blue). Color.primary is the label colour itself, and .secondary follows it.
                .foregroundStyle(Color.primary)
                }
                // The App Store's way: the app's row opens its page, Version History (Richard, 2026-11-08: "duos
                // changelogs in mac pro app"). Its own buttons keep their taps. The system's style, so the press is
                // the list's own row highlight, inside the card's corners (a wash of our own stuck out square past
                // them; designer HOLD 2026-11-08).
                .accessibilityHint(a.isOurs ? "Opens its version history" : "Opens its details")
                .place("seed-\(a.id)")
            }
            // His TestFlight apps: one way into TestFlight on the page, and once, the tip that makes it hands-off.
            if let tf = seed.apps.first(where: { $0.tfNewer != nil }) ?? seed.apps.first(where: { $0.testFlight }), let url = URL(string: tf.ota ?? "") {
                if !autoTipDone {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.title3).foregroundStyle(macBlue).frame(width: 58)
                        Text("Turn on Automatic Updates for each app in TestFlight, and new builds arrive by themselves.")
                            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { withAnimation(Motion.quick) { autoTipDone = true } } label: {
                            Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.primary).frame(width: 44, height: 30).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    .padding(.vertical, 4)
                    .transition(.opacity)
                }
                Link(destination: url) {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.up.forward.app").font(.title3.weight(.semibold)).frame(width: 58)
                        Text("Open TestFlight")
                    }
                }
                .place("testflight")
            }
            Menu {
                Button { picking = true } label: { Label("From Files", systemImage: "folder") }
                Button { linking = true } label: { Label("From a link", systemImage: "link") }
            } label: {
                // On the apps' grid: the plus in the icons' column, the words where the names start (they began 35 pt
                // short of them).
                HStack(spacing: 14) {
                    Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 58)
                    Text(uploading ? "Sending to the Mac…" : "Add an app")
                    if uploading || seed.fetch?.state == "working" { Spacer(); ProgressView() }
                }
            }
            .place("add")
            .disabled(uploading || seed.fetch?.state == "working")
            if let f = seed.fetch, f.state == "failed" { Text(f.message).font(.footnote).foregroundStyle(.red) }
            if let addFail { FailText(addFail) }
        } header: { Text("On this iPhone") } footer: {
            // Said only when it matters. The Mac signs every app ahead of time with his developer team, his own and any he
            // adds, and each installs over the air from anywhere; an app away from home without its link yet is still
            // being signed. Then one quiet line about where added apps come from.
            VStack(alignment: .leading, spacing: 6) {
                if !seed.reachable, seed.apps.contains(where: { $0.own && needsHand($0) && otaLink($0) == nil }) {
                    Text("Still being signed on the Mac. Install will be ready in a minute.")
                }
                Text("An app you add runs as one of your own, so add only apps from places you trust.")
            }
        }
        .alert("Add from a link", isPresented: $linking) {
            TextField("https://…/app.ipa", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Get") {
                addFail = nil
                let u = link
                Task { addFail = await model.run("ios-fetch", ["url": u]); if addFail == nil { link = "" } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A link to an app’s .ipa file. The Mac downloads it and installs it here.") }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task {
                addFail = nil
                uploading = true; defer { uploading = false }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await model.api.upload(url)
                    // At home it installs by itself; away, its row gets Install once the Mac has signed it.
                    await model.refresh()
                }
                catch { addFail = error.localizedDescription }
            }
        }
    }
}

#if canImport(UIKit)
import UIKit
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheet: View { let url: URL; var body: some View { Text(url.lastPathComponent) } }
#endif

// Open in portrait the tabs are a bar along the foot, and the page ran on to a hard edge above it (r24). The page fades
// out over 18 pt above the bar and is clear behind it. The inset is measured on the page itself: read in a view that
// ignores the safe area it is always 0. Only where the foot inset is a tab bar's, not just the home indicator's.
// Rows going up under the clock fade out just above the page's own top, so nothing reads crisp under the status bar,
// now that no bar is drawn there. Fixed to the safe area, never moved with the scroll, so it costs a scroll nothing.
// Only where the status bar is across the top (folded, it's in the side bar and there's nothing to fade under).
struct StatusBarFade: ViewModifier {
    @State private var top: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top = $0 }
            .mask {
                if top > 20 {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: top - 12)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                        Color.black
                    }
                    .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
    }
}

struct TabBarFade: ViewModifier {
    @State private var foot: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { foot = $0 }
            .mask {
                if foot > 40 {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                        Color.clear.frame(height: foot)
                    }
                    .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
    }
}
