import SwiftUI

// Mint's queue, as a list he can edit from the phone: reorder by the handle, remove by a swipe, jump by a tap, "Play next" and
// "Play later" from any song or album elsewhere in the app. Read from the Mac (GET /api/tv/music-queue, Mint 0.9.109) with
// Mint's own ids, and edited through POST /api/tv/queue-op; what he does shows at once and the next reading confirms it.
struct QueueItem: Identifiable, Equatable {
    // Stable across moves: Mint's id, numbered when the same song stands in the queue twice.
    let uid: String
    let qid: String
    let title: String
    let artist: String
    let art: String
    var id: String { uid }
}

@MainActor
final class QueueStore: ObservableObject {
    static let shared = QueueStore()
    @Published private(set) var items: [QueueItem] = []
    // The whole queue after the song playing; `items` may be only its first part.
    @Published private(set) var total = 0
    @Published private(set) var shuffle = false
    // MusicKit's numbering: 0 off, 1 one song, 2 everything.
    @Published private(set) var repeatMode = 0
    @Published private(set) var loaded = false
    // Whether the full queue is up (a sheet, or the right pane open flat), watched on its own so the page isn't redrawn by the
    // rows changing.
    final class Showing: ObservableObject { @Published var on = false }
    let showing = Showing()
    private var wanted = 12
    private var misses = 0
    // Edits waiting to go (one at a time, in order: two at once would cross in Mint's page) and the one on its way.
    private var pending: [[String: Any]] = []
    private var sending = false
    private var editedAt = Date.distantPast
    // A row is in the hand: nothing read from the TV may change the list under the finger.
    var holding = false

    // How much of the queue is wanted from the next reading on: the page's few rows, or all of it for the full list.
    func want(_ n: Int) { wanted = max(12, n) }

    func read() async {
        guard !sending, pending.isEmpty, !holding else { return }
        let sent = Date()
        let data = await TVBridge.data(TVBridge.url("/api/tv/music-queue?limit=\(wanted)"), timeout: 9)
        guard !Task.isCancelled, !sending, pending.isEmpty, !holding, editedAt < sent else { return }
        guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["ok"] as? Bool == true else {
            misses += 1
            if misses >= 3, loaded { items = []; total = 0; loaded = false }
            return
        }
        misses = 0
        let rows = j["items"] as? [[String: Any]] ?? []
        var seen: [String: Int] = [:]
        let next: [QueueItem] = rows.compactMap { x in
            let id = x["id"] as? String ?? "", title = x["title"] as? String ?? ""
            guard !id.isEmpty, !title.isEmpty else { return nil }
            let n = seen[id, default: 0]; seen[id] = n + 1
            return QueueItem(uid: "\(id)#\(n)", qid: id, title: title, artist: x["artist"] as? String ?? "", art: x["art"] as? String ?? "")
        }
        if next != items { withAnimation(.snappy(duration: 0.25)) { items = next } }
        let t = max((j["total"] as? NSNumber)?.intValue ?? 0, next.count)
        if t != total { total = t }
        if let s = (j["shuffle"] as? NSNumber)?.intValue, (s == 1) != shuffle { shuffle = s == 1 }
        if let r = (j["repeat"] as? NSNumber)?.intValue, r != repeatMode { repeatMode = r }
        if !loaded { loaded = true }
    }

    // MARK: Edits
    func move(_ from: Int, to: Int) {
        guard items.indices.contains(from), from != to else { return }
        let to = min(max(to, 0), items.count - 1)
        let item = items[from]
        withAnimation(.snappy(duration: 0.22)) { items.remove(at: from); items.insert(item, at: to) }
        send(["op": "move", "id": item.qid, "from": from, "to": to])
    }
    func remove(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let item = items[i]
        withAnimation(.snappy(duration: 0.22)) { items.remove(at: i); total = max(0, total - 1) }
        Haptic.fire(.tap)
        send(["op": "remove", "id": item.qid, "at": i])
    }
    // Plays it now: everything before it in the queue is behind us.
    func jump(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let item = items[i]
        withAnimation(.snappy(duration: 0.25)) { items.removeFirst(i + 1); total = max(0, total - i - 1) }
        send(["op": "jump", "id": item.qid, "at": i]) { Task { try? await Task.sleep(nanoseconds: 500_000_000); MusicDetailStore.shared.moved() } }
    }
    func moveToTop(_ i: Int) { move(i, to: 0) }

    // A song or album from anywhere in the app, to follow the song playing or to wait at the queue's end.
    func add(_ item: MediaItem, next: Bool) {
        send(["op": next ? "next" : "later", "id": item.id, "title": item.title], confirming: true)
    }
    func setShuffle(_ on: Bool) {
        shuffle = on
        Haptic.fire(.tick)
        send(["op": "shuffle", "value": on ? 1 : 0])
    }
    // Off, then all, then one: Mint's own order.
    func cycleRepeat() {
        repeatMode = repeatMode == 0 ? 2 : repeatMode == 2 ? 1 : 0
        Haptic.fire(.tick)
        send(["op": "repeat", "value": repeatMode])
    }

    private func send(_ body: [String: Any], confirming: Bool = false, then: (() -> Void)? = nil) {
        editedAt = Date()
        pending.append(body.merging(["confirming": confirming]) { a, _ in a })
        thens.append(then)
        guard !sending else { return }
        sending = true
        Task { await drain() }
    }
    private var thens: [(() -> Void)?] = []
    private func drain() async {
        var failed = false, slow = false
        while !pending.isEmpty {
            var body = pending.removeFirst(); let after = thens.removeFirst()
            let confirming = body.removeValue(forKey: "confirming") as? Bool ?? false
            let op = body["op"] as? String ?? ""
            if op == "jump" || op == "shuffle" { slow = true }
            do {
                try await TVBridge.post("queue-op", body, timeout: 30)
                if confirming { Haptic.fire(.done) }
                after?()
            } catch {
                // The edits behind it were worked out against a list that never came to be: dropped, and the list read again.
                failed = true; Haptic.fire(.warn); pending.removeAll(); thens.removeAll()
            }
        }
        sending = false
        editedAt = Date()
        // What Mint says now is the truth. A jump or a new shuffle takes a few seconds to settle on the TV (the song changes,
        // the queue is laid out again), so those are read after it has.
        if failed { await read() } else { try? await Task.sleep(nanoseconds: slow ? 2_500_000_000 : 600_000_000); await read() }
    }
}

// The rows, one height each so the handle's travel is plain arithmetic. The handle drags a row through the others (a tick at each
// place it passes); a swipe to the left shows Remove, and a long one removes; a tap plays that song now.
struct QueueRows: View {
    let items: [QueueItem]
    var rowHeight: CGFloat = 60
    let move: (Int, Int) -> Void
    let remove: (Int) -> Void
    let jump: (Int) -> Void
    let toTop: (Int) -> Void
    // Where the list's scroll view stands on the screen, and a way to scroll it (it answers how far it really went): a row held
    // near either edge carries the list with it.
    var viewport: CGRect = .zero
    var scroll: ((CGFloat) -> CGFloat)? = nil
    @State private var dragging: String?
    @State private var dy: CGFloat = 0
    @State private var auto: CGFloat = 0
    @State private var fingerY: CGFloat = 0
    @State private var target = 0
    private var shift: CGFloat { dy + auto }
    private var from: Int { items.firstIndex { $0.uid == dragging } ?? 0 }
    private func retarget(_ i: Int) {
        let t = min(max(i + Int((shift / rowHeight).rounded()), 0), items.count - 1)
        if t != target { withAnimation(.snappy(duration: 0.2)) { target = t }; Haptic.fire(.tick) }
    }
    private func release() { dragging = nil; dy = 0; auto = 0; QueueStore.shared.holding = false }
    private func offset(_ i: Int) -> CGFloat {
        guard dragging != nil else { return 0 }
        let f = from
        if i == f { return min(max(shift, -CGFloat(f) * rowHeight), CGFloat(items.count - 1 - f) * rowHeight) }
        if f < target, i > f, i <= target { return -rowHeight }
        if target < f, i >= target, i < f { return rowHeight }
        return 0
    }
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.uid) { i, item in
                QueueRow(item: item, height: rowHeight, lifted: dragging == item.uid,
                         jump: { jump(i) }, remove: { remove(i) }, toTop: i > 0 ? { toTop(i) } : nil,
                         up: i > 0 ? { move(i, i - 1) } : nil, down: i < items.count - 1 ? { move(i, i + 1) } : nil,
                         drag: .init(
                            changed: { d in
                                if dragging == nil { dragging = item.uid; target = i; dy = 0; auto = 0; QueueStore.shared.holding = true; Haptic.fire(.snap) }
                                dy = d.dy; fingerY = d.y
                                retarget(i)
                            },
                            ended: {
                                guard dragging == item.uid else { return }
                                let f = i, t = target
                                QueueStore.shared.holding = false
                                // The list takes its new order and the rows their rest in one move, so nothing jumps a row and back.
                                withAnimation(.snappy(duration: 0.22)) { release(); if t != f { move(f, t) } }
                            }))
                    .offset(y: offset(i))
                    .zIndex(dragging == item.uid ? 1 : 0)
                    .animation(dragging == item.uid ? nil : .snappy(duration: 0.2), value: target)
            }
        }
        .animation(.snappy(duration: 0.25), value: items.map(\.uid))
        // The list changed so that the row in the hand is gone: let it go.
        .onChange(of: items.map(\.uid)) { _, now in
            if let d = dragging, !now.contains(d) { release() }
        }
        .onDisappear { if dragging != nil { release() } }
        // Held near the top or the foot of the list, it scrolls (faster the nearer the edge) and the row keeps its place under the
        // finger, so a song can be carried far through a long queue.
        .task(id: dragging) {
            guard dragging != nil, let scroll, viewport.height > 0 else { return }
            while !Task.isCancelled {
                guard (try? await Task.sleep(nanoseconds: 16_000_000)) != nil else { return }
                let top = viewport.minY + 72, bottom = viewport.maxY - 72
                var v: CGFloat = 0
                if fingerY < top { v = -min(16, 3 + (top - fingerY) / 5) } else if fingerY > bottom { v = min(16, 3 + (fingerY - bottom) / 5) }
                if v != 0 { let moved = scroll(v); if moved != 0 { auto += moved; retarget(from) } }
            }
        }
    }
}

struct HandleDrag: Equatable { let dy: CGFloat; let y: CGFloat }

private struct QueueRow: View {
    struct Drag { let changed: (HandleDrag) -> Void; let ended: () -> Void }
    let item: QueueItem
    let height: CGFloat
    let lifted: Bool
    let jump: () -> Void
    let remove: () -> Void
    let toTop: (() -> Void)?
    let up: (() -> Void)?
    let down: (() -> Void)?
    let drag: Drag
    @State private var x: CGFloat = 0
    @GestureState private var handle: HandleDrag? = nil
    @State private var swiping = false
    @State private var base: CGFloat = 0
    static let reveal: CGFloat = 88
    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) { withAnimation(.snappy(duration: 0.2)) { x = 0 }; remove() } label: {
                Text("Remove").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: Self.reveal - 12, height: 34).background(Color.red.opacity(0.85), in: Capsule())
            }
            .buttonStyle(.plain).padding(.trailing, 6).opacity(min(1, -x / 40)).allowsHitTesting(x < -20)
            HStack(spacing: 0) {
                Button { if x < -1 { withAnimation(.snappy(duration: 0.2)) { x = 0 } } else { Haptic.fire(.tap); jump() } } label: {
                    HStack(spacing: 12) {
                        Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: {
                            ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(.secondary) }
                        }
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if !item.artist.isEmpty { Text(item.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: height).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        if !swiping { guard abs(v.translation.width) > abs(v.translation.height) * 1.6 else { return }; swiping = true; base = x }
                        x = min(0, max(base + v.translation.width, -300))
                    }
                    .onEnded { v in
                        guard swiping else { return }
                        swiping = false
                        let end = v.predictedEndTranslation.width
                        if x < -190 || end < -300 { withAnimation(.snappy(duration: 0.2)) { x = -400 }; remove() }
                        else if x < -44 { withAnimation(.snappy(duration: 0.22)) { x = -Self.reveal } }
                        else { withAnimation(.snappy(duration: 0.22)) { x = 0 } }
                    })
                // The handle: a touch on it takes the row at once, and the finger carries it.
                Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 44, height: height).contentShape(Rectangle())
                    // A short hold first, so a scroll that starts on the handle is still a scroll; the state goes back to nil when
                    // the touch ends or is taken from us (a turn, a system gesture), and that is the drop.
                    .gesture(LongPressGesture(minimumDuration: 0.12).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                        .updating($handle) { v, state, _ in if case .second(true, let d) = v { state = HandleDrag(dy: d?.translation.height ?? 0, y: d?.location.y ?? 0) } })
                    .onChange(of: handle) { old, now in
                        if let now { drag.changed(now) } else if old != nil { drag.ended() }
                    }
                    .accessibilityHidden(true)
            }
            .offset(x: x)
            .background(lifted ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 10, y: 4)
        }
        .frame(height: height)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays it now")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play now") { jump() }
        .accessibilityAction(named: "Remove") { remove() }
        .accessibilityAction(named: "Move up") { up?() }
        .accessibilityAction(named: "Move down") { down?() }
        .contextMenu {
            if let toTop { Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { Haptic.fire(.tap); toTop() } }
            Button("Remove from queue", systemImage: "minus.circle", role: .destructive) { remove() }
        }
    }
}

// The whole queue as one scrolling list, in a sheet or, open flat, in the right pane. While it is up it follows the TV.
struct QueueList: View {
    @ObservedObject private var queue = QueueStore.shared
    let dismiss: () -> Void
    @State private var position = ScrollPosition(edge: .top)
    @State private var scrollY: CGFloat = 0
    @State private var maxY: CGFloat = 0
    @State private var viewport: CGRect = .zero
    // Scrolls by `dy` (within the list) and says how far it went.
    private func scrollBy(_ dy: CGFloat) -> CGFloat {
        let to = min(max(scrollY + dy, 0), maxY), moved = to - scrollY
        if moved != 0 { position.scrollTo(y: to); scrollY = to }
        return moved
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if queue.items.isEmpty {
                    ContentUnavailableView("Nothing queued", systemImage: "music.note.list", description: Text("Hold a song or an album and choose Play next or Play later."))
                        .padding(.top, 40)
                } else {
                    QueueRows(items: queue.items, move: { queue.move($0, to: $1) }, remove: { queue.remove($0) },
                              jump: { queue.jump($0); dismiss() }, toTop: { queue.moveToTop($0) }, viewport: viewport, scroll: scrollBy)
                    if queue.total > queue.items.count {
                        Text("\(queue.total - queue.items.count) more after these").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 14)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGPoint.self) {
            CGPoint(x: $0.contentOffset.y + $0.contentInsets.top, y: max(0, $0.contentSize.height - $0.containerSize.height + $0.contentInsets.top + $0.contentInsets.bottom))
        } action: { _, p in scrollY = p.x; maxY = p.y }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport = $0 }
        .task {
            queue.want(500)
            await queue.read()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await queue.read()
            }
        }
        .onDisappear { queue.want(12) }
    }
}

struct QueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            QueueList(dismiss: { dismiss() })
                .padding(.horizontal, 20)
                .navigationTitle("Up next")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationBackground(.regularMaterial)
    }
}

// Open flat, the full queue takes the right pane itself: no card laid across the hinge.
struct QueuePane: View {
    @ObservedObject private var showing = QueueStore.shared.showing
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RowTitle("Up next")
                Spacer(minLength: 12)
                Button { Haptic.fire(.tap); withAnimation(.easeOut(duration: 0.25)) { showing.on = false } } label: {
                    Text("Done").font(.subheadline.weight(.semibold)).foregroundStyle(TVLook.accent).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            QueueList(dismiss: { withAnimation(.easeOut(duration: 0.25)) { showing.on = false } }).padding(.horizontal, 20)
        }
        .padding(.top, 6)
        .transition(.opacity)
    }
}

// Where the queue shows: the right pane, open flat (the page hands this its pane), else a sheet over the page.
struct QueueOr<C: View>: View {
    @ObservedObject private var showing = QueueStore.shared.showing
    let content: C
    var body: some View {
        if showing.on { QueuePane() } else { content }
    }
}
struct QueueSheetHost: ViewModifier {
    @ObservedObject private var showing = QueueStore.shared.showing
    let panes: Bool
    func body(content: Content) -> some View {
        if panes { content } else { content.sheet(isPresented: $showing.on) { QueueSheet() } }
    }
}

// Shuffle, the queue and repeat (off, all, one) under the transport: the first and last show what Mint says and change it with a
// tick; the middle opens the whole queue, so it is one tap away in every posture.
struct PlayModes: View {
    @ObservedObject private var queue = QueueStore.shared
    @ObservedObject private var showing = QueueStore.shared.showing
    var body: some View {
        HStack(spacing: 28) {
            mode(icon: "shuffle", on: queue.shuffle, label: "Shuffle", value: queue.shuffle ? "On" : "Off") { queue.setShuffle(!queue.shuffle) }
                // Until Mint has said, the keys are there but quiet: they would be setting what isn't known.
                .opacity(queue.loaded ? 1 : 0.45).disabled(!queue.loaded)
            mode(icon: "list.bullet", on: showing.on, label: "Up next", value: queue.total > 0 ? "\(queue.total) songs" : "") {
                Haptic.fire(.tick); withAnimation(.easeOut(duration: 0.25)) { showing.on.toggle() }
            }
            mode(icon: queue.repeatMode == 1 ? "repeat.1" : "repeat", on: queue.repeatMode != 0, label: "Repeat",
                 value: queue.repeatMode == 0 ? "Off" : queue.repeatMode == 1 ? "One song" : "All") { queue.cycleRepeat() }
                .opacity(queue.loaded ? 1 : 0.45).disabled(!queue.loaded)
        }
        .animation(.easeOut(duration: 0.2), value: queue.loaded)
    }
    private func mode(icon: String, on: Bool, label: String, value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 46, height: 46).contentShape(Circle())
                .foregroundStyle(on ? TVLook.accent : .primary)
        }
        .buttonStyle(.plain).keyGlass()
        .overlay { if on { Circle().strokeBorder(TVLook.accent.opacity(0.55), lineWidth: 1.5) } }
        .accessibilityLabel(label).accessibilityValue(value)
    }
}

// Held on a song, album or playlist from Mint: where it goes in the queue.
struct QueueMenu: View {
    @Environment(TVModel.self) private var model
    let item: MediaItem
    let source: MediaSource
    var body: some View {
        // Only where Mint can take it: Mint is the app in front on the TV, and it isn't a stream's queue (that's the phone's).
        if source == .mint, ["song", "album", "playlist"].contains(item.kind),
           model.status?.app == MediaSource.mint.pkg, model.status?.airplay?.active != true {
            Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { QueueStore.shared.add(item, next: true) }
            Button("Play later", systemImage: "text.line.last.and.arrowtriangle.forward") { QueueStore.shared.add(item, next: false) }
        }
    }
}

// The foot of a scrolling pane that runs on past the screen: faded out over its last 28 pt, with room to scroll the last row
// clear of the fade, so nothing is ever cut flat at the glass.
struct PaneFoot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, 28, for: .scrollContent)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                }
                .ignoresSafeArea()
            }
    }
}
