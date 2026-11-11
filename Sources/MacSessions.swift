import SwiftUI

// One numbered choice in a menu the session is showing, such as "❯ 1. Yes".
struct TermOption: Identifiable, Equatable { let number: Int; let text: String; let current: Bool; var id: Int { number } }

// The last screen each session showed, so its page slides in with the text already there rather than a spinner.
// Filled while the Claude tab is open and by each page as it reads.
@MainActor
enum TermCache {
    static var screens: [String: API.Term] = [:]
    static func warm(_ api: API, _ keys: [String]) async {
        for k in keys where !Task.isCancelled {
            if let t = try? await api.termScreen(k) { screens[k] = t }
        }
    }
    // Before a push asked for from elsewhere: a short wait for the text, then the page goes regardless.
    static func warm(_ api: API, _ key: String, within seconds: Double) async {
        guard screens[key] == nil else { return }
        // Not cancelled when the wait runs out: the text still lands in the cache for the page to pick up.
        let fetch = Task { await warm(api, [key]) }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await fetch.value }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            await g.next()
            g.cancelAll()
        }
    }
}

// A kept session's own screen, to answer whatever it's waiting on from here: its menu's choices as buttons, keys for
// anything else, and a box to tell it something.
struct SessionTerminal: View {
    // Held, not watched: the page redraws for its own session's entry (sessions), never for a reading.
    let model: AppModel
    @ObservedObject private var sessions: SessionStore
    @Environment(\.paneLayout) private var panes
    let session: Status.Session
    @State private var text: String
    @State private var running: Bool
    @State private var loaded: Bool
    init(session: Status.Session, model: AppModel) {
        self.session = session
        self.model = model
        _sessions = ObservedObject(wrappedValue: model.sessionStore)
        let kept = TermCache.screens[session.key ?? session.name]
        _text = State(initialValue: kept?.text ?? "")
        _running = State(initialValue: kept?.running ?? true)
        _loaded = State(initialValue: kept != nil)
    }
    @State private var message = ""
    @State private var misses = MissClock()
    @State private var note: String?
    // A send that didn't reach the session: said until the next one that does, with what was typed put back in the box.
    @State private var sendFailed: String?
    // The screen has stopped coming (8 s of misses): how old it is, and nothing typed or pressed against it.
    @State private var stale = false
    @State private var lastRead: Date?
    @State private var sends = 0
    @State private var width: CGFloat = 0
    @State private var starting = false
    // Following the newest line, unless scrolled back to read what came before.
    @State private var following = true
    // Where the screen starts in its column (under the name and the "Waiting for you" chip), so the choices across the fold
    // start level with it.
    @State private var screenTop: CGFloat = 0
    // The posture's layout as last read at rest: the fold is read in the page's own space, which moves as the page slides
    // off, so it's held while a push or pop is in flight (NavTransit).
    @State private var heldMode: SessionFoldLayout.Mode?
    // Glyphs short enough for a sixth of the folded width, each with its full name for VoiceOver.
    static let keys: [(String, String, String)] = [("esc", "esc", "Escape"), ("enter", "⏎", "Enter"), ("up", "↑", "Up"), ("down", "↓", "Down"), ("left", "←", "Left"), ("right", "→", "Right"),
                                                   ("1", "1", "1"), ("2", "2", "2"), ("3", "3", "3"), ("tab", "⇥", "Tab"), ("shift-tab", "⇧⇥", "Shift Tab"), ("ctrl-c", "⌃C", "Control C")]
    var key: String { session.key ?? session.name }
    // The latest the Mac has said about this session, rather than what it was when the page opened.
    var current: Status.Session { sessions.sessions.first { $0.key == session.key } ?? session }

    // A numbered menu at the foot of the screen, with the ❯ marking the highlighted choice. Only the last few lines are
    // read, so a list from earlier in the conversation never turns into buttons.
    static let optionLine = try? NSRegularExpression(pattern: #"^\s*(❯|>)?\s*(\d{1,2})[.)]\s+(.+?)\s*$"#)
    static func options(in text: String) -> [TermOption] {
        guard let r = optionLine else { return [] }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(14).map(String.init)
        var group: [TermOption] = [], best: [TermOption] = []
        for line in tail {
            guard let m = r.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let numR = Range(m.range(at: 2), in: line), let textR = Range(m.range(at: 3), in: line), let n = Int(line[numR]) else {
                // Description lines under a choice are indented; anything else that isn't blank ends the menu.
                if !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("     ") { if group.count >= 2 { best = group }; group = [] }
                continue
            }
            let marked = m.range(at: 1).location != NSNotFound
            if n == 1 { if group.count >= 2 { best = group }; group = [] }
            if n == (group.last?.number ?? 0) + 1 { group.append(TermOption(number: n, text: String(line[textR]), current: marked)) } else { group = [] }
        }
        if group.count >= 2 { best = group }
        // Claude Code marks its highlighted choice; a numbered list without one is just text.
        return best.contains { $0.current } ? best : []
    }
    var options: [TermOption] { Self.options(in: text) }
    var waiting: Bool { current.waiting == true || !options.isEmpty }

    func show(_ t: API.Term) {
        TermCache.screens[key] = t
        // The first text lands already in place, at the foot, with nothing rising into it.
        var first = Transaction(); first.disablesAnimations = !loaded
        withTransaction(first) {
            running = t.running ?? true
            if let s = t.text, s != text { text = s }
            loaded = true
        }
    }
    func load() async {
        do {
            show(try await model.api.termScreen(key)); misses.hit(); lastRead = Date()
            // The build's shots: the screen two minutes old, and a message that didn't get through, back in the box.
            if model.pose == "sessionstale" { stale = true; lastRead = Date().addingTimeInterval(-130); return }
            if model.pose == "sessionfail", sendFailed == nil { message = "run the tests again and tell me what fails"; sendFailed = "Not sent: \(Phrase.macAway) Your message is back in the box." }
            if stale { withAnimation(Motion.quick) { stale = false } }
            if note == Phrase.macAway { note = nil }
        }
        catch is CancellationError {}
        catch is DecodingError { misses.hit() }
        // Only after 8 s without an answer (MissClock): one missed screen said it at once.
        catch {
            guard misses.miss() else { return }
            if loaded { if !stale { withAnimation(Motion.quick) { stale = true } } } else { note = Phrase.macAway }
        }
    }
    // One after another, in the order pressed: ↓ then Enter must never reach the Mac as Enter then ↓.
    @State private var queue: Task<Void, Never>?
    // `restore` is a message from the box: if it doesn't reach the session it goes back in the box (ahead of anything
    // typed since), and the failure stays said until a send gets through. It was cleared as it was sent and the note
    // went after 3 s, so a long instruction typed at work was simply gone (audit, 2026-11-10).
    func send(_ body: [String: Any], restore: String? = nil) {
        sends += 1
        let before = queue
        queue = Task {
            await before?.value
            do {
                show(try await model.api.termSend(key, body)); lastRead = Date()
                if sendFailed != nil { withAnimation(Motion.quick) { sendFailed = nil } }
            } catch {
                if let restore { message = message.isEmpty ? restore : restore + "\n" + message }
                let why = MacFiles.unreachable(error) ? Phrase.macAway : error.localizedDescription
                withAnimation(Motion.quick) { sendFailed = restore != nil ? "Not sent: \(why) Your message is back in the box." : why }
            }
        }
    }
    func start() {
        guard let k = session.key else { return }
        starting = true
        Task {
            do { if !(try await model.api.restartSession(k)) { withAnimation(Motion.quick) { note = "It will start when the Mac can reach Claude." } } }
            catch { withAnimation(Motion.quick) { note = error.localizedDescription } }
            starting = false
            await load()
        }
    }
    var screen: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Color.clear.frame(height: 1).id("end")
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 60 } action: { _, atEnd in following = atEnd }
            .background(Color(white: 0.05), in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: cardRadius, style: .continuous).strokeBorder(.white.opacity(0.08)) }
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay {
                if !loaded { ProgressView() }
                else if !running {
                    ContentUnavailableView {
                        Label("Not running", systemImage: "moon.zzz")
                    } description: {
                        Text("The Mac starts it again within two minutes.")
                    } actions: {
                        Button(action: start) { if starting { ProgressView() } else { Text("Start now") } }
                            .buttonStyle(.borderedProminent).disabled(starting)
                    }
                }
            }
            // A failure shows at the foot of the screen, right above the keys and the box that caused it.
            .overlay(alignment: .bottom) {
                if let note {
                    Text(note).font(.footnote.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular.tint(.red.opacity(0.35)), in: Capsule())
                        .padding(.bottom, 10).padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: note) { try? await Task.sleep(nanoseconds: 3_000_000_000); withAnimation(Motion.quick) { self.note = nil } }
                }
            }
            // Only new lines glide; the first text is laid out at the foot by the anchor alone.
            .onChange(of: text) { old, _ in if following, !old.isEmpty { withAnimation(Motion.fade) { proxy.scrollTo("end", anchor: .bottom) } } }
        }
    }
    // The menu's own choices, big enough to hit without reading the screen. A tap types the number, which picks it.
    var choices: some View {
        VStack(spacing: 6) {
            ForEach(options) { o in
                Button { send(["text": "\(o.number)", "enter": false]) } label: {
                    HStack(spacing: 12) {
                        Text("\(o.number)").font(.subheadline.weight(.bold)).monospacedDigit()
                            .frame(width: 26, height: 26).background(.white.opacity(o.current ? 0.22 : 0.1), in: Circle())
                        Text(o.text).font(.body.weight(o.current ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 10).padding(.trailing, 16).frame(minHeight: 46)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(o.current ? .regular.tint(macBlue.opacity(0.45)).interactive() : .regular.interactive(), in: Capsule())
                .accessibilityLabel("Choose \(o.number), \(o.text)")
            }
        }
        .disabled(stale).opacity(stale ? staleDim : 1)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    func glyph(_ k: String, _ label: String) -> Text {
        let tab = Image(systemName: "arrow.right.to.line")
        switch k {
        case "tab": return Text(tab)
        case "shift-tab": return Text("\(Image(systemName: "shift"))\(tab)")
        default: return Text(label)
        }
    }
    func keyButton(_ k: String, _ label: String, _ name: String) -> some View {
        Button { send(["key": k]) } label: {
            // One fixed size for every glyph. The font's own ⇥ is drawn small, so Tab is the symbol in both keys, and Shift
            // beside it is the symbol too, so ⇧⇥ is drawn at the same size as ⇥.
            glyph(k, label).lineLimit(1).fixedSize().frame(maxWidth: .infinity)
        }
        .font(.system(size: 15, weight: .semibold))
        .buttonStyle(.bordered)
        .tint(k == "ctrl-c" ? .red : nil)
        .accessibilityLabel(name)
    }
    // Every key in view at once: one row when there's room, two on the folded screen, so the numbers and Ctrl-C are
    // never cut off when a menu needs them.
    var keyRows: some View {
        VStack(spacing: 6) {
            if width >= 520 {
                HStack(spacing: 6) { ForEach(Self.keys, id: \.0) { keyButton($0.0, $0.1, $0.2) } }
            } else {
                HStack(spacing: 6) { ForEach(Self.keys.prefix(6), id: \.0) { keyButton($0.0, $0.1, $0.2) } }
                HStack(spacing: 6) { ForEach(Self.keys.suffix(6), id: \.0) { keyButton($0.0, $0.1, $0.2) } }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
    var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the session", text: $message, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                let m = message; message = ""
                send(["text": m], restore: m)
            } label: {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 40, height: 40)
                    .background(macBlue, in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            // Not against a screen that has stopped coming: the box still takes what's typed, to send once it's back.
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || stale)
            .opacity(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || stale ? 0.4 : 1)
            .accessibilityLabel("Send")
        }
    }
    // Under the title: what the session wants, in the same orange as its row on the Claude tab.
    @ViewBuilder var stateChip: some View {
        if waiting {
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("Waiting for you").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }
    // The page's two halves: the screen (with what the session wants under the title), and the controls, which read from
    // the foot up: the box, the keys, then the menu's choices.
    var terminalColumn: some View {
        VStack(spacing: 8) {
            // The name heads the screen's column (its pane open flat), as on every pushed page.
            PaneHeading(title: session.name)
            stateChip.opacity(stale ? staleDim : 1)
            if stale { StaleLine(lastRead: lastRead) }
            screen.opacity(stale ? staleDim : 1).onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("termcol")).minY } action: { screenTop = $0 }
        }
        .coordinateSpace(.named("termcol"))
    }
    // The menu's choices at the top, level with the screen's top beside it (under the chip, which only the screen's side
    // has), the keys and the box at the foot. In one column the space between is nothing, so they sit together as before.
    func controls(lead: CGFloat) -> some View {
        VStack(spacing: 8) {
            if !options.isEmpty { choices }
            Spacer(minLength: 0)
            keyRows.disabled(stale).opacity(stale ? staleDim : 1)
            // A send that failed, said in the layout above the box its text went back to, never over the session's own
            // lines (it stays until a send gets through, and laid over the screen it hid the menu being answered;
            // designer, 2026-11-10). One ✕ puts it away.
            if let f = sendFailed {
                HStack(alignment: .top, spacing: 8) {
                    Text(f).font(.footnote.weight(.medium)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { withAnimation(Motion.quick) { sendFailed = nil } } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.white).frame(width: 44, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
                .padding(.leading, 6)
                .transition(.opacity)
            }
            composer
        }
        .padding(.top, lead)
    }
    // Where the fold runs, in this view's own space, read as the Screen reads it. Only for the build's shots, the Screen's
    // made-up laptop posture applies here too (-screenPosture laptop), since the simulator can't fold upright.
    func arrangement(_ g: GeometryProxy) -> SessionFoldLayout.Mode {
        let w = g.size.width, h = g.size.height
        if UserDefaults.standard.string(forKey: "screenPosture") == "laptop", h >= 600, h > w {
            let y = (h * 0.478).rounded(); return .stacked(above: y, below: y + 40)
        }
        #if os(iOS)
        if #available(iOS 27.1, *) {
            // Partly open: the crease across (laptop) stacks the screen above it and the controls below; down the middle
            // (book) it's one page each, nothing across the fold.
            if let c = g.reservedRegions(kind: .division).first?.frame {
                return c.width >= c.height ? .stacked(above: c.minY, below: c.maxY) : .panes(seam: c.midX, gutter: min(max(24, c.width / 2 + 4), 40))
            }
            if panes {
                let crease = g.reservedRegions(kind: .division, options: .includeInactive).first?.frame
                return .panes(seam: min(max(crease?.midX ?? w / 2, w * 0.3), w * 0.7), gutter: min(max(24, (crease?.width ?? 0) / 2 + 4), 40))
            }
            return .column
        }
        #endif
        return panes ? .panes(seam: w / 2, gutter: 24) : .column
    }
    var body: some View {
        // A page of its own, pushed like any other, so Back is where the system puts it, on the side on the Duo.
        // Open flat in landscape the screen is the left pane and the controls the right, as FoldSplit lays other pages;
        // folded or open in portrait it's one column; partly open it keeps to either side of the crease. One layout for
        // all of them, so the box is the same view through every change of posture, with its text and focus.
        GeometryReader { g in
            let live = arrangement(g)
            let mode = NavTransit.shared.inFlight ? (heldMode ?? live) : live
            SessionFoldLayout(mode: mode) {
                terminalColumn
                controls(lead: { if case .panes = mode { return screenTop } else { return 0 } }())
            }
            // The parts move to their new places in the Screen's own spring as the hinge moves.
            .animation(RemoteScreenView.posture, value: mode)
            .onChange(of: live, initial: true) { _, m in if !NavTransit.shared.moving() { heldMode = m } }
            .onChange(of: NavTransit.shared.active) { _, now in if !now { heldMode = live } }
        }
        .holdsWhileMoving("session")
        .animation(Motion.fade, value: options)
        .animation(Motion.fade, value: waiting)
        .background(Color.black.ignoresSafeArea())
        // The system's own Back: on the Duo it lays out at the top of the side strip, along the top open in portrait, and
        // the edge swipe goes with it (Apple's HIG for iPhone Duo, "Vertical controls"; Richard, 2026-11-08: "the back
        // button is retarded and not iphone duo standard"). The name is placed as every pushed page's is.
        .pushedTitle()
        .preferredColorScheme(.dark)
        .sensoryFeedback(trigger: sends) { _, _ in MacPrefs.haptics ? .impact(weight: .light) : nil }
        .task {
            while !Task.isCancelled {
                // Not under the Mac's screen, which has the link to itself while it's open.
                if !model.screenOpen { await load() }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}

// The session page's two parts, the screen and the controls, placed for the posture: one column (the controls at the
// foot, the screen taking the rest), stacked either side of a crease across, or a pane each side of the hinge. The same
// two children in every mode, so nothing in them is made anew when the Duo folds.
struct SessionFoldLayout: Layout {
    enum Mode: Equatable { case column, stacked(above: CGFloat, below: CGFloat), panes(seam: CGFloat, gutter: CGFloat) }
    var mode: Mode
    // The page's own margins: the sides, the foot, the gap between the parts, and the display's bare outer edge open
    // flat, where the left pane gets the same air FoldSplit gives it.
    static let side: CGFloat = 12, foot: CGFloat = 8, gap: CGFloat = 8, outer: CGFloat = 14
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { proposal.replacingUnspecifiedDimensions() }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let w = b.width, h = b.height, inner = max(w - Self.side * 2, 0)
        var screen = CGRect.zero, controls = CGRect.zero
        // The controls at the foot, as tall as they ask (the box grows as it's typed in), the screen above them.
        func column() {
            let want = min(subviews[1].sizeThatFits(ProposedViewSize(width: inner, height: nil)).height, max(h - Self.foot, 0))
            controls = CGRect(x: Self.side, y: h - Self.foot - want, width: inner, height: want)
            screen = CGRect(x: Self.side, y: 0, width: inner, height: max(controls.minY - Self.gap, 0))
        }
        switch mode {
        case .column: column()
        case .stacked(let above, let below):
            // Below the crease the controls sit at the foot, the choices nearest it. When the system keyboard leaves too
            // little room there, they ride above it instead, as in one column.
            let room = h - Self.foot - below - Self.gap
            if room >= subviews[1].sizeThatFits(ProposedViewSize(width: inner, height: nil)).height {
                screen = CGRect(x: Self.side, y: 0, width: inner, height: max(above - Self.gap, 0))
                controls = CGRect(x: Self.side, y: below + Self.gap, width: inner, height: room)
            } else { column() }
        case .panes(let seam, let gutter):
            screen = CGRect(x: Self.outer, y: 0, width: max(seam - gutter - Self.outer, 0), height: max(h - Self.foot, 0))
            controls = CGRect(x: seam + gutter, y: 0, width: max(w - seam - gutter - Self.side, 0), height: max(h - Self.foot, 0))
        }
        subviews[0].place(at: CGPoint(x: b.minX + screen.minX, y: b.minY + screen.minY), proposal: ProposedViewSize(screen.size))
        subviews[1].place(at: CGPoint(x: b.minX + controls.minX, y: b.minY + controls.minY), proposal: ProposedViewSize(controls.size))
    }
}
