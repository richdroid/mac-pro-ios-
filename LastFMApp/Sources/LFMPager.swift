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
            let peek: CGFloat = look == .panorama ? min(max((w * 0.09).rounded(), 28), 56) : 0
            let pw = max(w - peek, 1)
            let titleSize = titleFont(w)
            ZStack(alignment: .topLeading) {
                if look == .panorama, let title {
                    PanoramaTitle(text: title, size: titleSize, motion: motion, pw: pw, rate: rate(title, titleSize, w: w, pw: pw), count: panels.count)
                        .padding(.top, bars.top)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if look == .pivot {
                        PivotHeaders(names: panels.map(\.header), motion: motion, pw: pw) { i in
                            withAnimation(.snappy(duration: 0.4)) { position = i }
                        }
                        .padding(.top, bars.top + S.head)
                        if let accessory { accessory.padding(.top, S.head) }
                    }
                    ScrollView(.horizontal) {
                        Group {
                            if look == .pivot {
                                LazyHStack(alignment: .top, spacing: 0) { ForEach(panels) { p in panel(p, titleSize, bars).frame(width: pw).id(p.id) } }
                            } else {
                                HStack(alignment: .top, spacing: 0) { ForEach(panels) { p in panel(p, titleSize, bars).frame(width: pw).id(p.id) } }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                    .scrollPosition(id: $position, anchor: .leading)
                    // The last section comes to rest at the margin like the others, not pushed back by the peek.
                    .contentMargins(.trailing, peek, for: .scrollContent)
                    // A panorama's next section runs on under the side bar and off the display, never cut at the bar.
                    .scrollClipDisabled(look == .panorama)
                    // Opened on a section other than the first (a link, a pose): there from the first frame. The content
                    // is the sections plus the peek, so section i rests at i / (n - 1) of the way across.
                    .defaultScrollAnchor(UnitPoint(x: panels.count > 1 ? CGFloat(start) / CGFloat(panels.count - 1) : 0, y: 0), for: .initialOffset)
                    .scrollIndicators(.hidden)
                    .scrollDisabled(locked)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, v in motion.x = v }
                    .onScrollPhaseChange { _, phase in if phase == .idle { settle(pw) } }
                    // A pivot's pages slide up under its names: faded there, not cut.
                    .mask {
                        VStack(spacing: 0) {
                            if look == .pivot { LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: S.head) }
                            Color.black
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
    private func panel(_ p: Panel, _ titleSize: CGFloat, _ bars: (top: CGFloat, bottom: CGFloat)) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Color.clear.frame(height: 0).id("top")
                VStack(alignment: .leading, spacing: 0) {
                    if look == .panorama, !p.header.isEmpty || title != nil {
                        if title != nil { Color.clear.frame(height: ceil(titleSize * 1.18)) }
                        if !p.header.isEmpty {
                            Text(p.header).font(.system(size: 34, weight: .light)).tracking(-0.6).foregroundStyle(.white.opacity(0.94))
                                .lineLimit(1).fixedSize()
                                .padding(.leading, S.margin - 2).padding(.bottom, S.head)
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

    private func settle(_ pw: CGFloat) {
        let i = max(0, min(panels.count - 1, Int((motion.x / pw).rounded())))
        let id = panels[i].id
        if id != page { page = id; landed += 1 }
    }

    // The title as large as the panorama's first section allows, from 88 pt (shrinking to 70 % before running off).
    private func titleFont(_ w: CGFloat) -> CGFloat {
        guard let title else { return 0 }
        let base = 88 * min(max(k, 0.9), 1.25)
        return base * HubTitle.scale(title, base: base, room: w)
    }
    // How fast the title slides against the sections: so its end comes to rest a little under halfway across by the last.
    private func rate(_ text: String, _ size: CGFloat, w: CGFloat, pw: CGFloat) -> CGFloat {
        let travel = max(CGFloat(panels.count) * pw - w, 1)
        let t = textWidth(text.lowercased(), size: size, tracking: -1.5)
        return min(max((S.margin - 6 + t - w * 0.45) / travel, 0.08), 0.45)
    }
}

// The hub's title behind a panorama: slower than the sections, rising with the section he's in.
private struct PanoramaTitle: View {
    let text: String
    let size: CGFloat
    let motion: PagerMotion
    let pw: CGFloat
    let rate: CGFloat
    let count: Int
    var body: some View {
        let f = max(0, motion.x / pw)
        let i0 = min(count - 1, Int(f.rounded(.down)))
        let t = min(1, f - CGFloat(i0))
        let lift = (motion.lifts[i0] ?? 0) * (1 - t) + (motion.lifts[min(i0 + 1, count - 1)] ?? 0) * t
        Text(text.lowercased())
            .font(.system(size: size, weight: .thin))
            .tracking(-1.5)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white.opacity(0.94))
            .offset(x: S.margin - 6 - motion.x * rate, y: -lift)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
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
