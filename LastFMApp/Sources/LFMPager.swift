import SwiftUI

// Zune's two ways across, in Apple's grammar (Richard, 2026-11-14: "emulate the windows phone app layout like swipe
// right and shit on tabs where that makes sense", and "there's not enough friction").
// - A panorama: a hub's sections side by side, the next one peeking at the far edge, the hub's huge title behind them
//   sliding at a fraction of their speed so where he is reads in the title's place; each section's own header moves
//   with its section.
// - A pivot: sibling views of one thing (a chart's stretches, the library's shelves), their names in large light type
//   across the top; the one he's on leads at the margin, the next ones follow dimmed and run off the edge, and slide
//   along as he swipes.
// Both land one section per swipe and snap to it (view-aligned, one at a time), bounce at their ends, and answer the
// landing with a haptic (a snap for a panorama's section, a tick for a pivot, the app's shared words). They only live at
// a tab's root, where there's no Back to fight; pushed pages keep the system's edge swipe.

struct Panel: Identifiable {
    let id: Int
    let header: String
    let content: AnyView
    init<V: View>(_ id: Int, _ header: String, @ViewBuilder _ content: () -> V) {
        self.id = id; self.header = header; self.content = AnyView(content())
    }
}

// Where the pager is, read only by the title and the headers, so the panels aren't worked out again as it moves.
@MainActor @Observable final class PagerMotion {
    var x: CGFloat = 0
    var lifts: [Int: CGFloat] = [:]
    // How many sections across the pager is (1.0 = resting on the second), kept beside x for the opening placement.
    var f: CGFloat = 0
}

struct Pager: View {
    enum Look { case panorama, pivot }
    let look: Look
    var title: String? = nil
    let panels: [Panel]
    @Binding var page: Int
    let top: Int
    var accessory: AnyView? = nil
    var locked = false
    @State private var motion = PagerMotion()
    @State private var position: Int?
    @State private var landed = 0
    // Opened on a section other than the first (a widget's link, a build's pose): not settled, and nothing read from
    // where the scroll is, until it has really been put there.
    @State private var placed = false
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1

    init(_ look: Look, title: String? = nil, page: Binding<Int>, top: Int, locked: Bool = false, accessory: AnyView? = nil, panels: [Panel]) {
        self.look = look; self.title = title; self.panels = panels; _page = page; self.top = top
        self.accessory = accessory; self.locked = locked
        _position = State(initialValue: page.wrappedValue)
        start = panels.firstIndex { $0.id == page.wrappedValue } ?? 0
    }
    private let start: Int

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            // The bars above and below (the clock; the tab bar across the foot open upright): the sections scroll on under
            // them, faded there by the page's BarFade, as a single page does, never cut off at their edge.
            let bars = (top: g.safeAreaInsets.top, bottom: g.safeAreaInsets.bottom)
            let peek: CGFloat = look == .panorama ? min(max((w * 0.05).rounded(), 22), 40) : 0  // 24 pt folded: the peek hints, the content keeps its width (review 2026-11-14, item 6)
            let pw = max(w - peek, 1)
            let titleSize = titleFont(w)
            let headSize = headFont(pw)
            ZStack(alignment: .topLeading) {
                if look == .panorama, let title {
                    PanoramaTitle(text: title, size: titleSize, small: Self.eyebrow, motion: motion, pw: pw, count: panels.count)
                        .padding(.top, bars.top)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if look == .pivot {
                        PivotHeaders(names: panels.map(\.header), motion: motion, pw: pw) { i in
                            withAnimation(.snappy(duration: 0.4)) { position = i }
                        }
                        // The names run on to the right and fade out before the page's edge: never a word cut at the
                        // side bar or lying under the camera (review 2026-11-14, item 7).
                        .mask { HStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 44); Color.clear.frame(width: 4) } }
                        .padding(.top, bars.top + S.head)
                        if let accessory { accessory.padding(.top, S.head) }
                    }
                    ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        Group {
                            if look == .pivot {
                                LazyHStack(alignment: .top, spacing: 0) { ForEach(panels) { p in panel(p, titleSize, headSize, bars).frame(width: pw).id(p.id) } }
                            } else {
                                HStack(alignment: .top, spacing: 0) { ForEach(panels) { p in panel(p, titleSize, headSize, bars).frame(width: pw).id(p.id) } }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                    .scrollPosition(id: $position, anchor: .leading)
                    // The last section comes to rest at the margin like the others, not pushed back by the peek.
                    .contentMargins(.trailing, peek, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .scrollDisabled(locked)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, v in motion.x = v; motion.f = v / pw }
                    .onScrollPhaseChange { _, phase in if phase == .idle { settle(pw) } }
                    // Opened on a section other than the first (a link, a pose): put there before anything shows it
                    // elsewhere, and checked, since a scroll asked to move before it has laid out doesn't (run 20: every
                    // posed section showed the first).
                    .task { await place(reader) }
                    // A pivot's pages slide up under its names: faded there, not cut. A panorama's next section is a
                    // hint at the far edge: it fades to nothing across the peek, so no half word or cut picture sits
                    // there, nothing runs under the side bar, and the section left behind stops at the leading edge
                    // (review 2026-11-14, item 5).
                    .mask {
                        VStack(spacing: 0) {
                            if look == .pivot { LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: S.head) }
                            if look == .panorama {
                                HStack(spacing: 0) {
                                    Color.black
                                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.5), location: 0.22), .init(color: .clear, location: 1)],
                                                   startPoint: .leading, endPoint: .trailing).frame(width: peek + 8)
                                }
                            } else { Color.black }
                        }
                    }
                    }
                    .padding(.top, look == .pivot ? S.pair : 0)
                }
                // Never wider than the display's width for it, whatever a title or a row of names would take.
                .frame(minWidth: w, maxWidth: w, maxHeight: .infinity, alignment: .topLeading)
            }
            .ignoresSafeArea(.container, edges: .vertical)
        }
        .sensoryFeedback(look == .pivot ? .tick : .snap, trigger: landed)
        .onChange(of: page) { _, p in if position != p { withAnimation(.snappy(duration: 0.4)) { position = p } } }
        // The tab tapped again: back to the first section first, then to the top.
        .onChange(of: top) { _, _ in
            if let first = panels.first?.id, page != first { withAnimation(.snappy(duration: 0.45)) { position = first } }
        }
    }

    // Each section scrolls on its own. A panorama's leaves room at its top for the title behind it, then its header.
    private func panel(_ p: Panel, _ titleSize: CGFloat, _ headSize: CGFloat, _ bars: (top: CGFloat, bottom: CGFloat)) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Color.clear.frame(height: 0).id("top")
                VStack(alignment: .leading, spacing: 0) {
                    if look == .panorama, !p.header.isEmpty || title != nil {
                        // The first section sits under his name at its full size; the others under his name small, each
                        // with its own name as large and thin as his (the same title, one per section).
                        if title != nil { Color.clear.frame(height: p.header.isEmpty ? ceil(titleSize * 1.18) : ceil(Self.eyebrow * 1.5)) }
                        if !p.header.isEmpty {
                            Text(p.header).font(.system(size: headSize, weight: .thin)).tracking(-1.2).foregroundStyle(.white.opacity(0.94))
                                .lineLimit(1).fixedSize()
                                .padding(.leading, S.margin - 4).padding(.bottom, S.head)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    p.content
                }
                .padding(.top, look == .pivot || title == nil ? S.head : 0)
                .padding(.bottom, S.section)
            }
            .contentMargins(.top, look == .pivot ? 0 : bars.top, for: .scrollContent)
            .contentMargins(.bottom, bars.bottom, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in
                if look == .panorama, title != nil { motion.lifts[p.id] = v }
            }
            .onChange(of: top) { _, _ in if page == p.id { withAnimation(.smooth) { proxy.scrollTo("top", anchor: .top) } } }
        }
    }

    private func place(_ reader: ScrollViewProxy) async {
        guard start > 0, start < panels.count else { placed = true; return }
        for _ in 0..<20 {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { reader.scrollTo(panels[start].id, anchor: .leading) }
            try? await Task.sleep(nanoseconds: 120_000_000)
            if abs(motion.f - CGFloat(start)) < 0.02 { break }
        }
        placed = true
    }

    private func settle(_ pw: CGFloat) {
        guard placed else { return }
        let i = max(0, min(panels.count - 1, Int((motion.x / pw).rounded())))
        let id = panels[i].id
        if id != page { page = id; landed += 1 }
    }

    // His name small, over every section but the first.
    static let eyebrow: CGFloat = 22
    // The title as large as the panorama's first section allows, from 88 pt, and always whole: a long name is set
    // smaller until all of it fits, never run off an edge (Richard, 2026-11-14: his name cut at the side bar, then cut at
    // the left as the panorama moved; "his name must never look broken").
    private func titleFont(_ w: CGFloat) -> CGFloat {
        guard let title else { return 0 }
        let base = 88 * min(max(k, 0.9), 1.25)
        return base * HubTitle.scale(title, base: base, room: w, least: 0.3)
    }
    // A section's own name: as thin and nearly as large, fitting its section.
    private func headFont(_ pw: CGFloat) -> CGFloat {
        let base = 56 * min(max(k, 0.9), 1.2)
        let longest = panels.map(\.header).max { $0.count < $1.count } ?? ""
        return base * HubTitle.scale(longest, base: base, room: pw, least: 0.5)
    }
}

// His name over a panorama. On the first section it is the title, huge and thin. As he moves on it doesn't slide away
// and get cut (a name with its first letters gone reads as broken): it stays where it starts, whole, and settles into a
// small line over the section's own title, so every section reads "his name, then where he is". It rises with the
// section's scroll.
private struct PanoramaTitle: View {
    let text: String
    let size: CGFloat
    let small: CGFloat
    let motion: PagerMotion
    let pw: CGFloat
    let count: Int
    var body: some View {
        let f = max(0, motion.x / pw)
        let i0 = min(count - 1, Int(f.rounded(.down)))
        let t = min(1, f - CGFloat(i0))
        let lift = (motion.lifts[i0] ?? 0) * (1 - t) + (motion.lifts[min(i0 + 1, count - 1)] ?? 0) * t
        // 0 on the first section, 1 from the second on.
        let away = min(1, f)
        let name = text.lowercased()
        ZStack(alignment: .topLeading) {
            Text(name)
                .font(.system(size: size, weight: .thin)).tracking(-1.5)
                .lineLimit(1).fixedSize()
                .foregroundStyle(.white.opacity(0.94 * (1 - away)))
                .scaleEffect(1 - away * (1 - small / size), anchor: .topLeading)
                .offset(x: S.margin - 6 + 4 * away, y: 6 * away)
                .accessibilityAddTraits(.isHeader)
            Text(name)
                .font(.system(size: small, weight: .regular))
                .lineLimit(1).fixedSize()
                .foregroundStyle(.white.opacity(0.66 * away))
                .offset(x: S.margin - 2, y: 6)
                .accessibilityHidden(true)
        }
        .offset(y: -lift)
        .allowsHitTesting(false)
    }
}

// A pivot's names across the top: the one he's on at the margin, full white; the rest after it, dimmed, running off the
// edge. They slide as the pages do, each name reaching the margin as its page lands. Tapping one goes to it.
private struct PivotHeaders: View {
    let names: [String]
    let motion: PagerMotion
    let pw: CGFloat
    let choose: (Int) -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1
    var body: some View {
        let size = 40 * min(max(k, 0.9), 1.2)
        let gap: CGFloat = 20
        let widths = names.map { textWidth($0, size: size, tracking: -0.8, weight: -0.4) }
        let starts = widths.indices.map { i in widths.prefix(i).reduce(0, +) + gap * CGFloat(i) }
        let f = max(0, min(CGFloat(names.count - 1), motion.x / pw))
        let i0 = Int(f.rounded(.down)), i1 = min(i0 + 1, names.count - 1)
        let t = f - CGFloat(i0)
        let shift = starts[i0] * (1 - t) + starts[i1] * t
        HStack(alignment: .firstTextBaseline, spacing: gap) {
            ForEach(names.indices, id: \.self) { i in
                let near = max(0, 1 - abs(CGFloat(i) - f))
                // The ones already passed fade as they leave, so no half a word waits at the left edge.
                let gone = CGFloat(i) < f ? min(1, f - CGFloat(i)) : 0
                Button { choose(i) } label: {
                    Text(names[i]).font(.system(size: size, weight: .light)).tracking(-0.8).fixedSize()
                        .foregroundStyle(.white.opacity((0.36 + 0.6 * near) * (1 - gone)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(near > 0.5 ? .isSelected : [])
            }
        }
        .fixedSize()
        .offset(x: S.margin - 3 - shift)
        // Both bounds: with only a maximum the row took its own width and widened the pivot past the display.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: ceil(size * 1.2))
    }
}
