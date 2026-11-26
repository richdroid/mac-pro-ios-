import SwiftUI

// Windows Phone 7's pivot (lastfm.md §27; Richard, 2026-11-25: "remember the way the text at the top is supposed to
// behave"): sibling views of one thing side by side under the hub's small capitals and their names, huge and light. The
// current name at the left margin, the others trailing dimmed and running off the right edge; the names travel with the
// page, a name's width for a page's width, and the pivot wraps round: past the last page comes the first, its name
// arriving from the right. The page follows the finger 1:1 and a flick turns one page (WPPaging). Pushed hubs keep a
// strip at the left edge for the system's Back swipe.

struct Panel: Identifiable {
    let id: Int
    let header: String
    let content: AnyView
    init<V: View>(_ id: Int, _ header: String, @ViewBuilder _ content: () -> V) {
        self.id = id; self.header = header; self.content = AnyView(content())
    }
}

// Where the pager is, read only by the names, so the pages aren't worked out again as it moves.
@MainActor @Observable final class PagerMotion {
    var x: CGFloat = 0
    // How many times any pager told its names where it is, for the build's hitch log: proof the names are driven every
    // frame of a drag.
    @ObservationIgnored static var moves = 0
    // How many sections across the pager is (1.0 = resting on the second), kept beside x for the opening placement.
    var f: CGFloat = 0
    // The slot the paging chose as the finger lifted (read once, as the scroll starts to settle).
    @ObservationIgnored var target: Int?
    // The scroll's phase, kept out of view state: as state, each touch, lift and rest worked the whole hub out again,
    // the lift's in the first frame of the settle.
    @ObservationIgnored var phase: ScrollPhase = .idle
    // A page turned: the tick, felt as the finger lifts. Read only by the tick's own small view.
    var landed = 0
    @ObservationIgnored var ticked: Int?
    // The section a swipe began on (for the build's swipe log).
    @ObservationIgnored var from: Int?
    func swiped(_ old: ScrollPhase, _ new: ScrollPhase, at: Int) {
        #if canImport(UIKit)
        if old == .idle, new != .idle { from = at }
        if new == .idle, let f = from { from = nil; HitchLog.shared.note("land \(at - f)") }
        #endif
    }
}

// The landing's haptic, alone in a view of its own, so a tick redraws nothing else.
struct PagerTick: View {
    let motion: PagerMotion
    var body: some View { Color.clear.frame(width: 0, height: 0).sensoryFeedback(.tick, trigger: motion.landed).accessibilityHidden(true) }
}

struct Pager: View {
    enum Look { case pivot }
    let look: Look
    var title: String? = nil
    let panels: [Panel]
    @Binding var page: Int
    let top: Int
    var accessory: AnyView? = nil
    // The accessory's height, said by who gives it (a row of 44 pt controls): the pages' top inset is known in the
    // first layout, never measured a frame late.
    var accessoryHeight: CGFloat = 44
    var locked = false
    @State private var motion: PagerMotion
    // Where the pager is, set by its exact offset (a page's index times its width): asked for by a page's id, the
    // scroll landed a side bar's width out when the page's width changed under it (run 42, today folded).
    @State private var pos = ScrollPosition(edge: .leading)
    // A page's full width now, side bars included (it changes on a turn and at the fold, not as a side bar arrives).
    @State private var width: CGFloat = 0
    // Opened on a section other than the first (a widget's link, a build's pose): not settled, and nothing read from
    // where the scroll is, until it has really been put there.
    @State private var placed = false
    // The scroll's phase (kept in `motion`), so nothing moves the pager while his finger or a fling is on it.
    private var phase: ScrollPhase { motion.phase }
    // The page the pager set itself as it landed (not asked for from outside): no correction follows that change.
    @State private var selfPage: Int?
    // Only the page it opens on is built in the push's first frames; the others half a second later, at rest, before
    // any swipe can reach them (gate 2b: a hub built all its pages in the frame it was pushed).
    // Then one page at a time, about 80 ms apart, the pages beside it first: built all in one frame (two or three pages
    // and their cards), the main thread was held 2-3 s a few seconds after a hub opened (profile run 1).
    @State private var ready: Set<Int> = []
    @State private var copies = false
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1
    // WP7's application title over the names: the hub's name in small capitals (or a title given).
    @Environment(\.hubName) private var hubName
    @Environment(\.paneLayout) private var paned
    private var caps: String? { title ?? hubName }
    // The application title's line and the gap under it.
    private var capsHeight: CGFloat { caps == nil ? 0 : ceil(20 * min(max(k, 0.9), 1.3)) + 2 }

    init(_ look: Look, title: String? = nil, page: Binding<Int>, top: Int, locked: Bool = false, accessory: AnyView? = nil, accessoryHeight: CGFloat = 44, panels: [Panel]) {
        self.look = look; self.title = title; self.panels = panels; _page = page; self.top = top
        self.accessory = accessory; self.accessoryHeight = accessoryHeight; self.locked = locked
        let start = panels.firstIndex { $0.id == page.wrappedValue } ?? 0
        self.start = start
        // Where it opens, known before the first frame, so the name lit and the page shown agree from the start (run 36:
        // "lately" opened with the names unlit over his page until the placing loop caught up).
        let m = PagerMotion(); m.f = CGFloat(start)
        _motion = State(initialValue: m)
    }
    private let start: Int

    // WP7's pivots are cyclic: one copy of the last page before the first and of the first after the last, so a swipe
    // past either end carries on round; at rest on a copy the pager is put on the real page, unseen.
    private var n: Int { panels.count }
    private var cyclic: Bool { panels.count > 1 }
    private var off: Int { cyclic ? 1 : 0 }
    private var slots: [Int] { cyclic ? [n - 1] + Array(0..<n) + [0] : Array(0..<n) }
    private func slot(_ i: Int) -> Int { i + off }
    private func real(_ s: Int) -> Int { ((s - off) % max(n, 1) + max(n, 1)) % max(n, 1) }
    private var index: Int { panels.firstIndex { $0.id == page } ?? 0 }

    var body: some View {
        // The bars are read out here, where the safe area still stands: the reader inside is laid out past it.
        GeometryReader { out in
        let insets = out.safeAreaInsets
        // The window's foot below this page, covered explicitly: ignoring the safe area left pushed hubs ~17 pt short of
        // the bottom edge with their last row cut under a black band (run 61 gate).
        let foot = Win.foot(out)
        GeometryReader { g in
            let side = (leading: insets.leading, trailing: insets.trailing)
            let W = max(g.size.width, 1)
            let pw = max(W - side.leading - side.trailing, 1)
            let bars = (top: max(insets.top, g.safeAreaInsets.top), bottom: max(insets.bottom, g.safeAreaInsets.bottom, foot))
            let nameSize = PivotHeaders.size(panels.count, k)
            // WP7's top: the small capitals at the top margin (or on Back's row when the bar runs across the top), the
            // names right under them, nothing a bar's height lower (Richard, 2026-11-25: "artificially lowered").
            let tb = TopBar.caps(top: bars.top, height: capsHeight, pushed: true)
            let namesTop = caps == nil ? tb.y : tb.below - ceil(nameSize * 0.12)
            let namesHeight = ceil(nameSize * 1.25)
            let head = namesTop + namesHeight + (accessory == nil ? 0 : S.head + accessoryHeight)
            // Where the pages are cut: just under the names' descenders, or at a pinned row's foot. A hard line, as WP7's
            // pivot clips its items: no shade, no fade.
            let cut = accessory == nil ? head - S.head + 6 : head
            let built = slot(index)
            ZStack(alignment: .topLeading) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { k, i in
                            // The real pages at rest half a second in; the wrap's two copies a second after that.
                            let copy = cyclic && (k == 0 || k == slots.count - 1)
                            Group { if (ready.contains(k) && (!copy || copies)) || k == built || n == 1 { panel(panels[i], head, cut, bars.bottom, pw, side) } else { Color.clear } }
                                .frame(width: W).id(k)
                        }
                    }
                    .scrollTargetLayout()
                    .background(alignment: .topLeading) { FastSettle() }
                }
                .scrollTargetBehavior(WPPaging(width: W, count: slots.count, release: { motion.x }, chosen: { motion.target = $0 }))
                .scrollPosition($pos)
                .defaultScrollAnchor(UnitPoint(x: slots.count > 1 ? CGFloat(slot(start)) / CGFloat(slots.count - 1) : 0, y: 0))
                .scrollIndicators(.hidden)
                .scrollDisabled(locked)
                .onScrollGeometryChange(for: CGSize.self) { CGSize(width: $0.contentOffset.x, height: $0.containerSize.width) } action: { _, v in
                    motion.x = v.width; motion.f = v.width / max(v.height, 1) - CGFloat(off); PagerMotion.moves += 1
                }
                // The landing is decided as his finger lifts: the tick then (the lit name follows the scroll itself). The
                // page is said at rest, so nothing is worked out again in the settle's frames (§26: nothing heavy in a
                // landing). At rest, checked; a rest on a copy is put on its real page.
                .onScrollPhaseChange { old, new in
                    motion.swiped(old, new, at: Int(motion.f.rounded()))
                    motion.phase = new
                    if new == .decelerating, let t = motion.target {
                        motion.target = nil
                        let i = real(t)
                        if panels.indices.contains(i), panels[i].id != page, placed { motion.ticked = i; motion.landed += 1 }
                    } else if new == .idle {
                        let r = Int((motion.f).rounded())
                        if cyclic, r < 0 || r >= n {
                            let i = real(r + off)
                            var t = Transaction(); t.disablesAnimations = true
                            withTransaction(t) { pos.scrollTo(x: CGFloat(slot(i)) * W) }
                            motion.x = CGFloat(slot(i)) * W; motion.f = CGFloat(i)
                            land(i)
                        } else {
                            land(max(0, min(n - 1, r)))
                        }
                    }
                }
                .task { await place() }
                .task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    // Nearest first (the next page, then the one before), each in a frame of its own, never mid-swipe.
                    let b = slot(index)
                    let order = Array(slots.indices).sorted { abs($0 - b) < abs($1 - b) }.filter { $0 != b }
                    for k in order where !Task.isCancelled {
                        while phase != .idle, !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
                        ready.insert(k)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                    // The copies only once nothing is moving, so their build never lands in a swipe's frames.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    // Never round again once the hub has gone: a cancelled sleep throws at once, so a hub popped mid-swipe
                    // spun here on the main thread for as long as the app was open.
                    while phase != .idle, !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
                    guard !Task.isCancelled else { return }
                    copies = true
                }
                // The page's width changed under it (a turn, the fold): put back on its page's edge, at rest only.
                .onChange(of: W, initial: true) { _, w in
                    width = w
                    guard placed else { return }
                    let p = page
                    Task { @MainActor in
                        for _ in 0..<4 {
                            guard phase == .idle, page == p else { return }
                            var t = Transaction(); t.disablesAnimations = true
                            withTransaction(t) { pos.scrollTo(x: CGFloat(slot(index)) * w) }
                            try? await Task.sleep(nanoseconds: 80_000_000)
                        }
                    }
                }
                // Asked to move from outside (a stretch chosen, a link): by position, then checked.
                .onChange(of: page) { _, p in
                    if p == selfPage { selfPage = nil; return }
                    guard let i = panels.firstIndex(where: { $0.id == p }) else { return }
                    if abs(motion.f - CGFloat(i)) > 0.004 { withAnimation(Z.easeOut(0.35)) { pos.scrollTo(x: CGFloat(slot(i)) * W) } }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        if page == p, phase == .idle, abs(motion.f - CGFloat(i)) > 0.004 { pos.scrollTo(x: CGFloat(slot(i)) * width) }
                    }
                }
                // The system's Back swipe starts at the left edge of a pushed page: a strip there the pages never take.
                Color.clear.contentShape(Rectangle())
                    .frame(width: side.leading + 24)
                    .frame(maxHeight: .infinity)
                    .padding(.top, cut)
                    .accessibilityHidden(true)
                if let caps {
                    AppTitle(text: caps)
                        .frame(height: capsHeight, alignment: .center)
                        .padding(.leading, side.leading + tb.lead)
                        .offset(y: tb.y)
                        .turnstile(0)
                }
                VStack(alignment: .leading, spacing: 0) {
                    PivotHeaders(names: panels.map(\.header), motion: motion, pw: pw, lead: side.leading, size: nameSize,
                                 current: index) { i in go(i, W) }
                        .frame(height: namesHeight)
                        .turnstile(0)
                    if let accessory { accessory.frame(height: accessoryHeight).padding(.top, S.head).turnstile(1) }
                }
                .frame(width: pw, alignment: .leading)
                .padding(.leading, side.leading)
                .offset(y: namesTop)
            }
            .frame(width: W, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: [.top, .horizontal])
        .padding(.bottom, -foot)
        }
        .background { PagerTick(motion: motion) }
        // The hub asked again: back to the first section.
        .onChange(of: top) { _, _ in
            if let first = panels.first?.id, page != first { withAnimation(Z.easeOut(0.35)) { pos.scrollTo(x: CGFloat(slot(0)) * width) } }
        }
    }

    // A name tapped: WP7 turns forward to it, round past the end if that's the way it lies.
    private func go(_ i: Int, _ W: CGFloat) {
        let cur = index
        let d = (i - cur + n) % max(n, 1)
        guard d != 0 else { return }
        var target = slot(cur) + d
        if target > slots.count - 1 { target = slot(i) }
        withAnimation(Z.easeOut(0.35)) { pos.scrollTo(x: CGFloat(target) * W) }
    }

    // Each section scrolls on its own, starting under the names and cut at the line under them.
    private func panel(_ p: Panel, _ head: CGFloat, _ cut: CGFloat, _ foot: CGFloat, _ pw: CGFloat, _ side: (leading: CGFloat, trailing: CGFloat)) -> some View {
        ScrollViewReader { proxy in
            WPScroll {
                Color.clear.frame(height: 0).id("top")
                p.content
                    .padding(.top, S.head)
                    .padding(.bottom, S.section)
                    .frame(width: pw, alignment: .topLeading)
                    .padding(.leading, side.leading)
                    .padding(.trailing, side.trailing)
            }
            .contentMargins(.top, head - cut, for: .scrollContent)
            .padding(.top, cut)
            .contentMargins(.bottom, foot, for: .scrollContent)
            .scrollIndicators(.automatic)
            .turnstile(0)
            .environment(\.pageWidth, pw)
            .environment(\.pageBleed, EdgeInsets(top: 0, leading: side.leading, bottom: 0, trailing: side.trailing))
            .onScrollPhaseChange { _, new in Store.shared.scrolling = new != .idle }
            .onChange(of: top) { _, _ in if page == p.id { withAnimation(.smooth) { proxy.scrollTo("top", anchor: .top) } } }
            .task {
                guard let a = Pose.anchor, page == p.id else { return }
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation(.smooth) { proxy.scrollTo(a, anchor: .top) }
                }
            }
        }
    }

    // Pinned to its page for its first three seconds, until his first touch (a pushed pivot is laid out more than once).
    private func place() async {
        var settledOnce = false
        for k in 0..<12 {
            if phase != .idle { break }
            if width > 1 {
                let i = index
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { pos.scrollTo(x: CGFloat(slot(i)) * width) }
                motion.x = CGFloat(slot(i)) * width; motion.f = CGFloat(i)
                settledOnce = true
            }
            if k == 1, settledOnce { placed = true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        placed = true
    }

    private func land(_ i: Int) {
        guard placed || phase != .idle else { return }
        placed = true
        let id = panels[max(0, min(panels.count - 1, i))].id
        if id != page { selfPage = id; page = id; if motion.ticked != i { motion.landed += 1 } }
        motion.ticked = nil
    }
}

// A pivot's names across the top, WP7's way: the current name at the left margin in full white, the others after it in
// turn, dimmed, running off the right edge, the ones before it wrapped round to the end. They travel with the page: as the
// page moves a page's width the row moves the current name's width, so the next name slides into the margin as its
// page arrives and the one leaving slides off the left edge (and comes round again at the end). Every name is a button.
private struct PivotHeaders: View {
    let names: [String]
    let motion: PagerMotion
    let pw: CGFloat
    let lead: CGFloat
    let size: CGFloat
    let current: Int
    let choose: (Int) -> Void
    static let gap: CGFloat = 22
    // WP7's pivot names: 64 px Semilight on a 480 px screen (recalled), here 58 pt for four or fewer; past four (WP7's
    // limit) a step smaller.
    static func size(_ count: Int, _ k: CGFloat) -> CGFloat { (count > 4 ? 44 : 58) * min(max(k, 0.9), 1.2) }
    var body: some View {
        let n = names.count
        let f = n > 1 ? motion.f : 0
        let base = Int(f.rounded(.down)), frac = f - f.rounded(.down)
        let widths = Self.widths(names, size)
        let first = n > 0 ? ((base % n) + n) % n : 0
        let shift = n > 1 ? frac * (widths[first] + Self.gap) : 0
        HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
            ForEach(0..<(n > 1 ? n + 1 : n), id: \.self) { j in
                let i = ((base + j) % n + n) % n
                let near = max(0, 1 - abs(CGFloat(j) - frac))
                // The name that leaves at the left comes round again at the end as it goes.
                let again: CGFloat = j == n ? frac : 1
                Button { choose(i) } label: {
                    Text(names[i]).font(.zuneLower(size: size)).tracking(-1).fixedSize()
                        .foregroundStyle(.white)
                        .opacity((0.4 + 0.6 * near) * again)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(j == n)
                .accessibilityAddTraits(i == current && j < n ? [.isSelected, .isHeader] : [])
            }
        }
        .fixedSize()
        .padding(.leading, lead + S.margin - 3)
        .offset(x: -shift)
        // From the screen's left edge to the page's right edge: names leave off the left edge and run off the right.
        .frame(width: pw + lead, alignment: .leading)
        .clipped()
        .padding(.leading, -lead)
    }
    // Each name's width, measured once per set of names and size, never in a frame of a swipe.
    @MainActor private static var kept: [String: [CGFloat]] = [:]
    @MainActor static func widths(_ names: [String], _ size: CGFloat) -> [CGFloat] {
        let key = "\(size)|" + names.joined(separator: "\u{1}")
        if let hit = kept[key] { return hit }
        let out = names.map { textWidth($0, size: size, tracking: -1, weight: -0.4, face: Z.lower()) }
        kept[key] = out
        return out
    }
}
