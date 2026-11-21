import SwiftUI

// Zune's pivot, in Apple's grammar: sibling views of one thing (a chart's stretches, the library's shelves, the sections
// of his own page) side by side, their names in large light type across the top. One page per swipe with the system's
// own paging, a bounce at the ends, a tick as it lands. The names follow his finger at their own rate. Pivots only
// live at a tab's root, where there's no Back to fight; pushed pages keep the system's edge swipe.
// (It was also a panorama once; he called that "almost impossible to use" on 2026-11-18 and every use is a pivot.)

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
    @State private var landed = 0
    // Opened on a section other than the first (a widget's link, a build's pose): not settled, and nothing read from
    // where the scroll is, until it has really been put there.
    @State private var placed = false
    // The scroll's phase, so nothing moves the pager while his finger or a fling is on it.
    @State private var phase: ScrollPhase = .idle
    // The page the pager set itself as it landed (not asked for from outside): no correction follows that change.
    @State private var selfPage: Int?
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1

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

    var body: some View {
        // The bars are read out here, where the safe area still stands: the reader inside is laid out past it and was
        // told there were none (run 40: upright, the names sat under the clock and its fade).
        GeometryReader { out in
        let insets = out.safeAreaInsets
        // The pager runs the full width of the screen, under the side bars, and each page keeps its content clear of
        // them. Inside the safe area the scroll still drew under the side bar and paged by its own wider bounds, while
        // the pages were the narrower width: folded, opened on today, it rested a side bar's width past the page with
        // the names cut at the left (run 43, lfm-now). Now a page is exactly the scroll's width, so every rest is a
        // page's edge, and the side bar arriving changes no page width at all.
        GeometryReader { g in
            let side = (leading: insets.leading, trailing: insets.trailing)
            let W = max(g.size.width, 1)
            let pw = max(W - side.leading - side.trailing, 1)
            // The bars above and below (the clock; the tab bar across the foot open upright): the pages run on under
            // them. Above, they pass under the names, into a fade drawn over them in the ground's own colour: no mask,
            // which cost an off-screen pass of the whole pager every frame (run 39 review, fault 8).
            let bars = (top: max(insets.top, g.safeAreaInsets.top), bottom: max(insets.bottom, g.safeAreaInsets.bottom))
            let nameSize = PivotHeaders.size(panels.count, k)
            let head = bars.top + S.head + ceil(nameSize * 1.25) + (accessory == nil ? 0 : S.head + accessoryHeight)
            ZStack(alignment: .topLeading) {
                ScrollViewReader { _ in
                    ScrollView(.horizontal) {
                        // Every section built at once, at rest: lazily, a section was built whole on its first reveal,
                        // mid-drag (run 39: 180 and 720 ms with no frame on the first swipe to a stretch).
                        HStack(alignment: .top, spacing: 0) { ForEach(panels) { p in panel(p, head, bars.bottom, pw, side).frame(width: W).id(p.id) } }
                            .scrollTargetLayout()
                    }
                    // The system's own paging: a light flick turns the page (Richard, 2026-11-15: "too much like weight
                    // with swipes").
                    .scrollTargetBehavior(.paging)
                    .scrollPosition($pos)
                    // Laid out on the section it opens to in its first frame.
                    .defaultScrollAnchor(UnitPoint(x: panels.count > 1 ? CGFloat(start) / CGFloat(panels.count - 1) : 0, y: 0))
                    .scrollIndicators(.hidden)
                    .scrollDisabled(locked)
                    // The offset and the width together: a width change with the offset left where it was is a move off the page's
                    // edge too, and was missed (run 43: f stayed 1.0 over a stale offset, so the placing thought it was done).
                    .onScrollGeometryChange(for: CGSize.self) { CGSize(width: $0.contentOffset.x, height: $0.containerSize.width) } action: { _, v in
                        motion.x = v.width; motion.f = v.width / max(v.height, 1); PagerMotion.moves += 1
                    }
                    // The landing is decided as his finger lifts (from where the page is and how hard it was thrown), so
                    // the page, the lit name and the tick all move together with the page, not after it has come to
                    // rest (run 39: the names swapped only as the page landed). At rest, checked.
                    .onScrollPhaseChange { _, new, context in
                        phase = new
                        if new == .decelerating {
                            let f = motion.f, v = context.velocity?.dx ?? 0
                            let i = v > 250 ? f.rounded(.up) : v < -250 ? f.rounded(.down) : f.rounded()
                            land(Int(i))
                        } else if new == .idle {
                            land(Int(motion.f.rounded()))
                        }
                    }
                    // Opened on a section other than the first (a link, a pose): put there before anything shows it
                    // elsewhere, and checked, since a scroll asked to move before it has laid out doesn't (run 20).
                    .task { await place() }
                    // The page's width changed under it (the side bar arriving, a turn, the fold): the scroll keeps its
                    // old offset, which is no longer a page's edge, so the page before showed at the side (run 41:
                    // today sat 12 pt off with his page's chevron beside it). Put back on its page, at rest only.
                    .onChange(of: W, initial: true) { _, w in
                        width = w
                        guard placed else { return }
                        let p = page
                        guard let i = panels.firstIndex(where: { $0.id == p }) else { return }
                        Task { @MainActor in
                            for _ in 0..<4 {
                                guard phase == .idle, page == p else { return }
                                var t = Transaction(); t.disablesAnimations = true
                                withTransaction(t) { pos.scrollTo(x: CGFloat(i) * w) }
                                try? await Task.sleep(nanoseconds: 80_000_000)
                            }
                        }
                    }
                    // Asked to move from outside (a name tapped, a stretch chosen, a link): by position, and if the scroll
                    // hasn't got there once the move has had time, put there directly. Only for a change from outside:
                    // one the pager made itself as it landed is never corrected, and nothing is moved while a scroll is
                    // under way (run 39 review: a second quick swipe was thrown back).
                    .onChange(of: page) { _, p in
                        if p == selfPage { selfPage = nil; return }
                        guard let i = panels.firstIndex(where: { $0.id == p }) else { return }
                        if abs(motion.f - CGFloat(i)) > 0.004 { withAnimation(.snappy(duration: 0.4)) { pos.scrollTo(x: CGFloat(i) * W) } }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            if page == p, phase == .idle, abs(motion.f - CGFloat(i)) > 0.004 { pos.scrollTo(x: CGFloat(i) * width) }
                        }
                    }
                }
                // The ground's colour over the top of the pages, solid behind the clock and the names and gone a little
                // under them: what scrolls up fades out beneath the names.
                // A shade, not a box: it runs out under the side bars too and thins over a long tail, so no edge of it shows
                // against the cover's colour (run 40: a black rectangle with a hard right edge).
                LinearGradient(stops: [.init(color: S.ground.opacity(0.92), location: 0), .init(color: S.ground.opacity(0.86), location: (head - 30) / (head + 28)), .init(color: S.ground.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: W, height: head + 28)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: S.head) {
                    PivotHeaders(names: panels.map(\.header), motion: motion, pw: pw, size: nameSize,
                                 current: panels.firstIndex { $0.id == page } ?? 0) { i in
                        withAnimation(.snappy(duration: 0.4)) { pos.scrollTo(x: CGFloat(i) * W) }
                    }
                    if let accessory { accessory.frame(height: accessoryHeight) }
                }
                .padding(.top, bars.top + S.head)
                .frame(width: pw, alignment: .leading)
                .padding(.leading, side.leading)
            }
            .frame(width: W, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .all)
        }
        .sensoryFeedback(.tick, trigger: landed)
        // The tab tapped again: back to the first section first, then to the top.
        .onChange(of: top) { _, _ in
            if let first = panels.first?.id, page != first { withAnimation(.snappy(duration: 0.45)) { pos.scrollTo(x: 0) } }
        }
    }

    // Each section scrolls on its own, starting under the names and passing beneath them as it goes up.
    private func panel(_ p: Panel, _ head: CGFloat, _ foot: CGFloat, _ pw: CGFloat, _ side: (leading: CGFloat, trailing: CGFloat)) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Color.clear.frame(height: 0).id("top")
                p.content
                    .padding(.top, S.head)
                    .padding(.bottom, S.section)
                    .frame(width: pw, alignment: .topLeading)
                    .padding(.leading, side.leading)
                    .padding(.trailing, side.trailing)
            }
            // The page is cut just under the names, so nothing scrolled up is ever read through them (run 44,
            // scroll-now at 20 s: a row's title under "sam today"); the shade over that line lets it come in soft.
            .contentMargins(.top, S.head, for: .scrollContent)
            .padding(.top, head - S.head)
            .contentMargins(.bottom, foot, for: .scrollContent)
            .scrollIndicators(.hidden)
            .environment(\.pageWidth, pw)
            .environment(\.pageBleed, EdgeInsets(top: 0, leading: side.leading, bottom: 0, trailing: side.trailing))
            .onScrollPhaseChange { _, new in Store.shared.scrolling = new != .idle }
            .onChange(of: top) { _, _ in if page == p.id { withAnimation(.smooth) { proxy.scrollTo("top", anchor: .top) } } }
            .task {
                guard let a = Pose.anchor, page == p.id else { return }
                // Again as the page fills above it (covers and cards arriving push it down).
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation(.smooth) { proxy.scrollTo(a, anchor: .top) }
                }
            }
        }
    }

    private func place() async {
        guard start > 0, start < panels.count else { placed = true; return }
        // Up to 10 s: on a busy first launch 2.4 s wasn't enough and Now opened on his page (run 34, lfm-now folded).
        for _ in 0..<80 {
            // Never against his finger: the first touch ends the placing.
            if phase != .idle { break }
            // Checked against the offset and the width as they are now, never a fraction worked out before a width change.
            if width > 1, abs(motion.x - CGFloat(start) * width) < 0.5 { break }
            var t = Transaction(); t.disablesAnimations = true
            if width > 1 { withTransaction(t) { pos.scrollTo(x: CGFloat(start) * width) } }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        placed = true
    }

    private func land(_ index: Int) {
        guard placed || phase != .idle else { return }
        placed = true
        let id = panels[max(0, min(panels.count - 1, index))].id
        if id != page { selfPage = id; page = id; landed += 1 }
    }
}

// A pivot's names across the top, the way Zune and Windows Phone set them: large and light, the one he's on in full
// white, the rest dimmed and running off the right edge. They follow his finger every frame: each name lights as its
// page comes across, and the row travels a name's width while the page travels a page, so the two move at different
// rates (run 39: they waited for the page to stop, then jumped). Every name is a button, the one before the current
// one stays in view at the left, and the row can be dragged on its own to reach the far ones (Richard, 2026-11-18:
// names that left the screen made it "almost impossible to use").
private struct PivotHeaders: View {
    let names: [String]
    let motion: PagerMotion
    let pw: CGFloat
    let size: CGFloat
    let current: Int
    let choose: (Int) -> Void
    @State private var pos = ScrollPosition(edge: .leading)
    static let gap: CGFloat = 20
    // Seven stretches at full size left most of them off the screen folded; past four names they're set smaller.
    static func size(_ count: Int, _ k: CGFloat) -> CGFloat { (count > 4 ? 34 : 46) * min(max(k, 0.9), 1.2) }
    var body: some View {
        let f = max(0, min(CGFloat(names.count - 1), motion.f))
        let rests = Self.rests(names, size)
        ScrollView(.horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
                ForEach(names.indices, id: \.self) { i in
                    let near = max(0, 1 - abs(CGFloat(i) - f))
                    Button { choose(i) } label: {
                        Text(names[i]).font(.system(size: size, weight: .light)).tracking(-0.8).fixedSize()
                            .foregroundStyle(.white)
                            .opacity(0.4 + 0.6 * near)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(i == current ? [.isSelected, .isHeader] : [])
                }
            }
            .padding(.leading, S.margin - 2)
            // Room after the last name, so the last ones reach the left as the others do.
            .padding(.trailing, max(48, pw * 0.7))
        }
        .scrollPosition($pos)
        .scrollIndicators(.hidden)
        .frame(width: pw, height: ceil(size * 1.25))
        // The names run on to the right and fade out before the page's edge: never a word cut at the side bar, or
        // showing again beyond it under the camera (run 40). A mask of this one row, not a patch of colour over it.
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 1 - 96 / max(pw, 192)), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .onAppear { pos.scrollTo(x: Self.at(f, rests)) }
        .onChange(of: f) { _, f in pos.scrollTo(x: Self.at(f, rests)) }
        .onChange(of: size) { _, _ in pos.scrollTo(x: Self.at(f, Self.rests(names, size))) }
    }
    // Where the row rests for each page: scrolled so the name before the current one leads at the margin (the first two
    // pages rest at the row's start).
    static func rests(_ names: [String], _ size: CGFloat) -> [CGFloat] {
        var starts: [CGFloat] = [], x: CGFloat = 0
        for n in names { starts.append(x); x += textWidth(n, size: size, tracking: -0.8, weight: -0.4) + gap }
        return names.indices.map { $0 == 0 ? 0 : starts[$0 - 1] }
    }
    // Between two pages, between their two rests.
    static func at(_ f: CGFloat, _ rests: [CGFloat]) -> CGFloat {
        guard !rests.isEmpty else { return 0 }
        let i = max(0, min(rests.count - 1, Int(f.rounded(.down)))), j = min(rests.count - 1, i + 1)
        return rests[i] + (rests[j] - rests[i]) * (f - CGFloat(i))
    }
}
