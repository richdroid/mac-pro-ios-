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
    @EnvironmentObject var model: AppModel
    let session: Status.Session
    @State private var text: String
    @State private var running: Bool
    @State private var loaded: Bool
    init(session: Status.Session) {
        self.session = session
        let kept = TermCache.screens[session.key ?? session.name]
        _text = State(initialValue: kept?.text ?? "")
        _running = State(initialValue: kept?.running ?? true)
        _loaded = State(initialValue: kept != nil)
    }
    @State private var message = ""
    @State private var note: String?
    @State private var sends = 0
    @State private var width: CGFloat = 0
    @State private var starting = false
    // Following the newest line, unless scrolled back to read what came before.
    @State private var following = true
    // Glyphs short enough for a sixth of the folded width, each with its full name for VoiceOver.
    static let keys: [(String, String, String)] = [("esc", "esc", "Escape"), ("enter", "⏎", "Enter"), ("up", "↑", "Up"), ("down", "↓", "Down"), ("left", "←", "Left"), ("right", "→", "Right"),
                                                   ("1", "1", "1"), ("2", "2", "2"), ("3", "3", "3"), ("tab", "⇥", "Tab"), ("shift-tab", "⇧⇥", "Shift Tab"), ("ctrl-c", "⌃C", "Control C")]
    var key: String { session.key ?? session.name }
    // The latest the Mac has said about this session, rather than what it was when the page opened.
    var current: Status.Session { model.status?.claude.sessions.first { $0.key == session.key } ?? session }

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
        do { show(try await model.api.termScreen(key)); if note == "Can’t reach the Mac" { note = nil } }
        catch { if !loaded { note = "Can’t reach the Mac" } }
    }
    // One after another, in the order pressed: ↓ then Enter must never reach the Mac as Enter then ↓.
    @State private var queue: Task<Void, Never>?
    func send(_ body: [String: Any]) {
        sends += 1
        let before = queue
        queue = Task {
            await before?.value
            do { show(try await model.api.termSend(key, body)) }
            catch { withAnimation(Motion.quick) { note = error.localizedDescription } }
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
                send(["text": m])
            } label: {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 40, height: 40)
                    .background(macBlue, in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
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
    var body: some View {
        // A page of its own, pushed like any other, so Back is where the system puts it, on the side on the Duo.
        VStack(spacing: 8) {
            stateChip
            screen
            if !options.isEmpty { choices }
            keyRows
            composer
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .animation(Motion.fade, value: options)
        .animation(Motion.fade, value: waiting)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(session.name)
        .toolbarVisibility(.visible, for: .navigationBar)
        // Back is the side bar's; the swipe from the left edge still goes back (BackSwipe).
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .sensoryFeedback(trigger: sends) { _, _ in MacPrefs.haptics ? .impact(weight: .light) : nil }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}
