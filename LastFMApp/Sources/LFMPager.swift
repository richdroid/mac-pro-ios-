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
    // Which page the names show, as a page number with the fraction of the way to the next (it may run past the count or
    // below 0 round a wrap; the names read it round).
    var f: CGFloat = 0
    // The slot the paging chose as the finger lifted, landed on once the scroll has stopped.
    @ObservationIgnored var target: Int?
    // The scroll's phase, kept out of view state: as state, each touch, lift and rest worked the whole hub out again,
    // the lift's in the first frame of the settle.
    @ObservationIgnored var phase: ScrollPhase = .idle
    // A page turned: the tick, felt as the finger lifts. Read only by the tick's own small view.
    var landed = 0
    @ObservationIgnored var ticked: Int?
    // Lands the pages itself (WP7's 0.35 s ease out), handed the scroll by FastSettle.
    @ObservationIgnored let lander = PageLander()
    // The carousel's page in its middle slot, and that slot (a pivot that wraps rests on slot 1).
    @ObservationIgnored var basePage = 0
    @ObservationIgnored var mid = 0
    // Where the scroll is, exactly when the scroll can be read.
    var offset: CGFloat { lander.offset ?? x }
    // For the build's swipe log: where a swipe began, how far the finger took it and how fast it let go.
    @ObservationIgnored private var startX: CGFloat?
    @ObservationIgnored private var release: (drag: CGFloat, v: CGFloat, at: Double)?
    // This touch's release has chosen its page (reset as the next touch begins).
    @ObservationIgnored private(set) var decided = false
    func began() { startX = offset; startT = Date().timeIntervalSinceReferenceDate; release = nil; decided = false; samples.removeAll(keepingCapacity: true) }
    @ObservationIgnored private var startT: Double = 0
    // Where the finger had the page over the last moments of the drag, for its own velocity: UIKit's at the lift is 0 when
    // the finger pauses before it lifts (profile runs 10 and 11: the folded flick read 0 page/s and sprang back, though
    // it moved a seventh of a page in three frames). WP7 judged a flick by the drag's speed.
    @ObservationIgnored private var samples: [(t: Double, x: CGFloat)] = []
    func sample(_ x: CGFloat) {
        guard phase == .interacting else { return }
        let now = Date().timeIntervalSinceReferenceDate
        samples.append((now, x))
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
    }
    // Points a second over the drag's last 0.1 s (0 when not known).
    // A whole drag shorter than 0.3 s is a flick judged by its mean speed: its moves and its lift can arrive together
    // after a stall, with no samples in between (profile run 12: a folded flick behind 40-85 ms stalls read 0 page/s).
    func dragVelocity(at x: CGFloat) -> CGFloat {
        let now = Date().timeIntervalSinceReferenceDate
        if let old = samples.first(where: { now - $0.t <= 0.1 }), now - old.t > 0.012, abs(x - old.x) > 0.5 {
            return (x - old.x) / CGFloat(now - old.t)
        }
        if let s = startX, startT > 0, now - startT < 0.3, now - startT > 0.008 { return (x - s) / CGFloat(now - startT) }
        return 0
    }
    func released(slot: Int, x: CGFloat, v: CGFloat, w: CGFloat) {
        decided = true
        target = slot
        release = ((x - (startX ?? x)) / w, v / w, Date().timeIntervalSinceReferenceDate)
    }
    // "land N": where a swipe came to rest against where it began, in pages, with the drag and the release velocity
    // (pages and pages a second) and the milliseconds from release to rest.
    func rested(w: CGFloat, slots: Int) {
        #if canImport(UIKit)
        guard let s = startX else { return }
        startX = nil
        let n = Int((offset / max(w, 1)).rounded()) - Int((s / max(w, 1)).rounded())
        if let r = release {
            HitchLog.shared.note(String(format: "land %d drag %.2f v %.2f settle_ms %.0f", n, r.drag, r.v, (Date().timeIntervalSinceReferenceDate - r.at) * 1000))
        } else {
            HitchLog.shared.note("land \(n)")
        }
        release = nil
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
    // Where the pager is, set by its exact offset (a slot's index times its width): asked for by a page's id, the
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
    // WP7's pivots are cyclic, built as a carousel: the page on show in slot 1, the one before it in slot 0 and the rest
    // after it in turn, so a swipe either way has a page to turn to. Once a swipe lands, the slots are dealt round so the
    // page landed on is in slot 1 again, unseen. The page landed on is the same view throughout: its rows, its scroll and
    // its figures stay as they were (gate on build 71: the wrap landed on a copy and was then put on the real page, built
    // afresh, which blanked, turned in again and re-counted). Two pages need a spare: the other page on both sides.
    struct Slot: Equatable { let page: Int; let key: Int }
    @State private var order: [Slot]
    @State private var spares = 100
    // The slots' views made so far (by key): the one it opens on at once, the others at rest from half a second in, one
    // at a time about 80 ms apart, nearest first, never mid-swipe (profile run 1: all built in one frame held the main
    // thread 2-3 s a few seconds after a hub opened).
    @State private var ready: Set<Int>
    @State private var opened = false
    // When it arrived: parts made more than a moment later never turn in (TurnstileIn).
    @State private var born = Date()
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
        let o = Self.arrange(start, panels.count)
        _order = State(initialValue: o)
        _ready = State(initialValue: [o[Self.mid(panels.count)].key])
        // Where it opens, known before the first frame, so the name lit and the page shown agree from the start (run 36:
        // "lately" opened with the names unlit over his page until the placing loop caught up).
        let m = PagerMotion(); m.f = CGFloat(start); m.basePage = start; m.mid = Self.mid(panels.count)
        _motion = State(initialValue: m)
    }

    private var n: Int { panels.count }
    private var cyclic: Bool { panels.count > 1 }
    private static func mid(_ n: Int) -> Int { n > 1 ? 1 : 0 }
    private var mid: Int { Self.mid(n) }
    // The slots for page c on show: c in slot 1, the page before it in slot 0, the rest after it.
    static func arrange(_ c: Int, _ n: Int) -> [Slot] {
        guard n > 1 else { return n == 1 ? [Slot(page: 0, key: 0)] : [] }
        if n == 2 { let o = 1 - c; return [Slot(page: o, key: 2), Slot(page: c, key: c), Slot(page: o, key: o)] }
        return (0..<n).map { j in let p = ((c - 1 + j) % n + n) % n; return Slot(page: p, key: p) }
    }
    // Dealt round after landing on slot r: the page there in slot 1, the same views kept (two pages: a new spare made for
    // the far side, offscreen).
    private func dealt(_ r: Int) -> [Slot] {
        guard cyclic, order.indices.contains(r), r != mid else { return order }
        if n == 2 {
            let o = order[1].page
            return r == 2 ? [order[1], order[2], Slot(page: o, key: spares)] : [Slot(page: o, key: spares), order[0], order[1]]
        }
        return Self.arrange(order[r].page, n)
    }
    private var index: Int { panels.firstIndex { $0.id == page } ?? 0 }
    private var slotCount: Int { order.count }

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
            ZStack(alignment: .topLeading) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(order, id: \.key) { slot in
                            Group {
                                if ready.contains(slot.key) || n == 1, panels.indices.contains(slot.page) {
                                    panel(panels[slot.page], head, cut, bars.bottom, pw, side)
                                } else { Color.clear }
                            }
                            .environment(\.turnstileUntil, born.addingTimeInterval(1.2))
                            .frame(width: W)
                        }
                    }
                    .scrollTargetLayout()
                    .background(alignment: .topLeading) { FastSettle(lander: motion.lander) }
                }
                .scrollTargetBehavior(WPPaging(width: W, count: slotCount, motion: motion))
                .scrollPosition($pos)
                .defaultScrollAnchor(UnitPoint(x: slotCount > 1 ? CGFloat(mid) / CGFloat(slotCount - 1) : 0, y: 0))
                .scrollIndicators(.hidden)
                .scrollDisabled(locked)
                .onScrollGeometryChange(for: CGSize.self) { CGSize(width: $0.contentOffset.x, height: $0.containerSize.width) } action: { _, v in
                    motion.x = v.width
                    motion.sample(v.width)
                    motion.f = CGFloat(motion.basePage) + v.width / max(v.height, 1) - CGFloat(motion.mid)
                    PagerMotion.moves += 1
                }
                // A finger let go: the paging chose a slot (WPPaging) and stopped the scroll; the lander takes it there in
                // 0.35 s and the tick plays as it starts. The page is said once it rests, so nothing is worked out again in
                // the landing's frames (§26: nothing heavy in a landing).
                .onScrollPhaseChange { old, new in
                    motion.phase = new
                    if new == .interacting, old != .interacting { motion.began() }
                    if new == .interacting { motion.lander.stop(); if !placed { placed = true } }
                    guard new == .idle, placed else { return }
                    if let t = motion.target {
                        motion.target = nil
                        arrive(max(0, min(slotCount - 1, t)), W)
                    } else if !motion.lander.active {
                        settle(W)
                    }
                }
                .task { await place() }
                // The other slots' views, at rest, nearest first; again whenever the slots are dealt round (a new spare).
                .task(id: order.map(\.key)) {
                    try? await Task.sleep(nanoseconds: opened ? 150_000_000 : 500_000_000)
                    opened = true
                    let missing = order.indices.filter { !ready.contains(order[$0].key) }.sorted { abs($0 - mid) < abs($1 - mid) }
                    for s in missing where !Task.isCancelled {
                        // Never round again once the hub has gone: a cancelled sleep throws at once.
                        while (phase != .idle || motion.lander.active), !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
                        guard !Task.isCancelled, order.indices.contains(s) else { return }
                        ready.insert(order[s].key)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                    let keys = Set(order.map(\.key))
                    if !ready.isSubset(of: keys) { ready.formIntersection(keys) }
                }
                // The page's width changed under it (a turn, the fold): put back on its slot's edge, at rest only.
                .onChange(of: W, initial: true) { _, w in
                    width = w
                    guard placed else { return }
                    let p = page
                    Task { @MainActor in
                        for _ in 0..<4 {
                            guard phase == .idle, !motion.lander.active, page == p else { return }
                            var t = Transaction(); t.disablesAnimations = true
                            withTransaction(t) { pos.scrollTo(x: CGFloat(mid) * w) }
                            try? await Task.sleep(nanoseconds: 80_000_000)
                        }
                    }
                }
                // Asked to move from outside (a stretch chosen, a link): turned to as a name tapped is.
                .onChange(of: page) { _, p in
                    if p == selfPage { selfPage = nil; return }
                    guard let i = panels.firstIndex(where: { $0.id == p }) else { return }
                    turn(to: i, W)
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
            if !panels.isEmpty, index != 0 { turn(to: 0, width) }
        }
    }

    // A name tapped: WP7 turns forward to it, round past the end if that's the way it lies (the page before the one on
    // show is turned back to, one page).
    private func go(_ i: Int, _ W: CGFloat) { turn(to: i, W) }
    private func turn(to i: Int, _ W: CGFloat) {
        guard W > 1, panels.indices.contains(i), order.indices.contains(mid), order[mid].page != i else { return }
        let target: Int
        if let s = order.indices.first(where: { $0 > mid && order[$0].page == i }) { target = s }
        else if let s = order.indices.first(where: { order[$0].page == i }) { target = s }
        else { return }
        motion.lander.stop()
        arrive(target, W)
    }

    // To slot s: the tick if it's another page, the 0.35 s landing, then rest.
    private func arrive(_ s: Int, _ W: CGFloat) {
        let p = order.indices.contains(s) ? order[s].page : index
        if p != index, placed { motion.ticked = p; motion.landed += 1 }
        let x = CGFloat(s) * W
        if !motion.lander.land(to: x, done: { settle(W) }) {
            withAnimation(Z.easeOut(0.35)) { pos.scrollTo(x: x) } completion: { settle(W) }
        }
    }

    // At rest: off a slot's edge (a drag let go with nothing chosen), landed first; on a slot, the swipe logged, the slots
    // dealt round so the page is in slot 1 again (unseen: the same view, moved with the scroll), and the page said.
    private func settle(_ W: CGFloat) {
        guard W > 1, !order.isEmpty else { return }
        let x = motion.offset
        let r = max(0, min(slotCount - 1, Int((x / W).rounded())))
        if abs(x - CGFloat(r) * W) > 1, placed {
            if motion.lander.land(to: CGFloat(r) * W, done: { settle(W) }) { return }
        }
        motion.rested(w: W, slots: slotCount)
        let p = order[r].page
        if cyclic, r != mid {
            let next = dealt(r)
            if n == 2 { spares += 1 }
            motion.basePage = next[mid].page
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                order = next
                pos.scrollTo(x: CGFloat(mid) * W)
            }
            // And on the scroll itself in this same turn, so the frame that shows the slots dealt round shows them at
            // their new place too (never a frame of the page beside it).
            motion.lander.jump(to: CGFloat(mid) * W)
            motion.x = CGFloat(mid) * W; motion.f = CGFloat(p)
        }
        land(p)
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
            if motion.lander.active { break }
            if width > 1 {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { pos.scrollTo(x: CGFloat(mid) * width) }
                motion.x = CGFloat(mid) * width; motion.f = CGFloat(order.indices.contains(mid) ? order[mid].page : 0)
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
