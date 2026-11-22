import SwiftUI

// The Dashboard tab: a remote for the Mac's dashboard (the MacPro Console), and nothing else (Richard, 2026-11-21: "i want
// to be able to drive whats on the dashboard from my phone its supposed to be a remote control thing basically ... make
// the dashboard tab far simpler"). One screen, top to bottom: what the Mac's screen shows now, the mode it is in and
// what is taking turns, with Previous and Next; the boards as six big keys (the sixth holds the pages); then one switch
// each for the things he turns on and off: the dashboard itself, the display, the turns, the large text, Glance. Every
// press is answered in the card's own status line with what the Console said. The figures live on Status and the Mac's
// pages on Control and Status; nothing here but the remote.

struct DashboardTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var remote = ConsoleRemote.shared
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    var st: ConsoleState? { remote.state }
    var running: Bool { st?.running == true }
    // The Mac can be asked: it has been read, has the routes, and can be reached.
    var ready: Bool { remote.read && !remote.unsupported && !model.stale }

    // Where the dashboard is, as the Console and the bridge last said. Never a guess.
    enum Seen { case looking, unsupported, away, off, asleep, aside, behind, on }
    var seen: Seen {
        if remote.unsupported { return .unsupported }
        if !remote.read { return .looking }
        if model.stale { return .away }
        guard let st, st.running else { return .off }
        if st.display == "asleep" { return .asleep }
        if st.screenStepAside == true { return .aside }
        if st.frontmost == false { return .behind }
        return .on
    }
    // A switch shows what was asked for until the Console answers, then what the Console says.
    @State private var asked: [String: Bool] = [:]
    func flag(_ key: String, _ now: Bool, _ cmd: String, on: String = "on", off: String = "off") -> Binding<Bool> {
        Binding(get: { asked[key] ?? now }, set: { want in
            guard remote.busy == nil else { return }
            asked[key] = want
            remote.send(model, key, cmd, want ? on : off)
        })
    }

    var body: some View {
        Group {
            switch side {
            case .all: now; boards; switches
            // Open flat: what's on and the boards on the left, the switches on the right.
            case .left: now; boards
            case .right: switches
            }
        }
        .task(id: side) { if side != .right { await remote.loop(model) } }
        .onChange(of: remote.busy) { _, b in if b == nil { asked = [:] } }
        // Done when the Console answers yes, warn when it says no or can't be reached: once per press, on the answer.
        .haptic(.done, trigger: remote.answered) { _, _ in side != .right }
        .haptic(.warn, trigger: remote.refused) { _, _ in side != .right }
    }

    // MARK: What's on the Mac now

    var title: (name: String, symbol: String) {
        guard running, let st else { return ("The Mac’s dashboard", "rectangle.3.group") }
        let n = ConsolePlace.name(st)
        return (n.0, n.1)
    }
    // The card's one status line: the Console's answer to the last press for a few seconds, else where the dashboard is.
    var status: (say: String, color: Color, busy: Bool) {
        if remote.busy != nil { return ("Asking the Mac…", .secondary, true) }
        if let f = remote.fail { return (f.text, .red, false) }
        if let d = remote.said { return (d, .green, false) }
        switch seen {
        case .looking: return ("Looking at the Mac…", .secondary, false)
        case .unsupported: return ("This Mac has no dashboard to drive yet", .secondary, false)
        case .away: return ("Can’t reach the Mac", .secondary, false)
        case .off: return ("Not running on the Mac", .secondary, false)
        case .asleep: return ("The Mac’s display is off", .secondary, false)
        case .aside: return ("Out of the way while Screen is open", .secondary, false)
        case .behind: return ("Behind another app on the Mac", .secondary, false)
        case .on: return ("On the Mac’s screen", .green, false)
        }
    }
    // The mode, in his two names for it, and what is taking turns. Only said while the dashboard runs.
    var mode: (name: String, symbol: String, say: String)? {
        // Nothing is said of the mode while the Mac can't be asked.
        guard ready, running, let st else { return nil }
        let bed = ConsolePlace.fromBed(st, pose: model.pose)
        let name = bed ? "From bed" : "At the desk", symbol = bed ? "bed.double" : "desktopcomputer"
        if st.glance == true { return (name, symbol, "Glance covers the boards with big, dim figures until you turn it off") }
        guard st.board != nil else { return (name, symbol, "A page stays up until you pick a board") }
        let large = st.text == "room" ? ", in large text" : ""
        guard st.rotate == true else { return (name, symbol, "Staying on this board\(large)") }
        // The boards the Console says are taking turns, and its own pace (an older bridge: the phone's reckoning).
        let turns = ConsolePlace.turns(st, pose: model.pose).map(\.name)
        let every = " every \(secs) s"
        if turns.count == ConsolePlace.boards.count { return (name, symbol, "All \(turns.count) boards take turns\(every)\(large)") }
        if turns.count == 1 { return (name, symbol, "Only \(turns[0]) is in the turns\(large)") }
        return (name, symbol, "\(turns.dropLast().joined(separator: ", ")) and \(turns.last ?? "") take turns\(every)\(large)")
    }
    // The Console's pace between boards; 45 s, its default, until it says.
    var secs: Int { st?.rotateSecs.map { $0 > 0 ? Int($0) : 45 } ?? 45 }
    // The board before or after the one up now. The Console steps through its own turns (board next|previous) and
    // restarts its timer; an older bridge without its mode gets the board the phone works out.
    func step(_ by: Int) {
        if st?.mode != nil || st?.rotating != nil { remote.send(model, by > 0 ? "next" : "previous", "board", by > 0 ? "next" : "previous"); return }
        let turns = ConsolePlace.turns(st, pose: model.pose)
        guard !turns.isEmpty else { return }
        let i = turns.firstIndex { $0.id == st?.board }
        let next = i.map { ($0 + by + turns.count) % turns.count } ?? (by > 0 ? 0 : turns.count - 1)
        remote.send(model, by > 0 ? "next" : "previous", "board", turns[next].id)
    }

    var now: some View {
        Section {
            VStack(alignment: .leading, spacing: Space.card) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: title.symbol).font(.title2.weight(.medium)).foregroundStyle(seen == .on ? macBlue : Color(white: 0.5))
                        .frame(width: 52, height: 52).background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title.name).font(.title2.weight(.bold)).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                        HStack(alignment: .center, spacing: 6) {
                            if status.busy { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
                            else if remote.said != nil && remote.fail == nil { Image(systemName: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green).frame(width: 12, height: 12) }
                            else { Circle().fill(status.color == .secondary ? Color(white: 0.45) : status.color).frame(width: 8, height: 8).frame(width: 12, height: 12) }
                            Text(status.say).font(.subheadline).foregroundStyle(status.color == .red ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("remote.status")
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .animation(Motion.quick, value: status.say)
                if let m = mode {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(m.name, systemImage: m.symbol).font(.footnote.weight(.semibold)).foregroundStyle(macBlue).labelStyle(.titleAndIcon).fixedSize()
                        Text(m.say).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("remote.mode")
                }
                keys
            }
            .padding(Space.card)
            .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        }
    }
    // Previous and Next while the dashboard can be seen; while it can't, the one thing that brings it back.
    @ViewBuilder var keys: some View {
        HStack(spacing: Space.gap) {
            switch seen {
            case .off:
                BigKey("Start the dashboard", "play.fill", busy: remote.busy == "show", filled: true) { remote.send(model, "show", "show") }
            case .asleep:
                BigKey("Turn the display on", "sun.max.fill", busy: remote.busy == "display", filled: true) { remote.send(model, "display", "display", "on") }
            case .behind, .aside:
                BigKey("Bring it to the front", "macwindow", busy: remote.busy == "show", filled: true) { remote.send(model, "show", "show") }
            default:
                BigKey("Previous", "chevron.left", busy: remote.busy == "previous", filled: false) { step(-1) }
                BigKey("Next", "chevron.right", busy: remote.busy == "next", filled: false, trailingIcon: true) { step(1) }
            }
        }
        .disabled(!ready || (seen == .on && st?.glance == true))
    }

    // A wide key, one height everywhere on the remote; its wait is drawn in the glyph's place, so it never changes size.
    struct BigKey: View {
        let title: String, symbol: String, busy: Bool, filled: Bool
        var trailingIcon = false
        let action: () -> Void
        @Environment(\.isEnabled) private var enabled
        init(_ title: String, _ symbol: String, busy: Bool, filled: Bool, trailingIcon: Bool = false, action: @escaping () -> Void) {
            self.title = title; self.symbol = symbol; self.busy = busy; self.filled = filled; self.trailingIcon = trailingIcon; self.action = action
        }
        var glyph: some View {
            Image(systemName: symbol).font(.body.weight(.semibold)).opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.small).tint(filled ? .white : macBlue) } }
                .frame(width: 22)
        }
        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    if !trailingIcon { glyph }
                    Text(title).font(.body.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    if trailingIcon { glyph }
                }
                .foregroundStyle(filled ? Color.white : macBlue)
                .frame(maxWidth: .infinity).frame(height: Space.key)
                .background(filled ? macBlue : Color(white: 0.17), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(title)
            .accessibilityIdentifier("remote." + title)
        }
    }

    // MARK: Put on the Mac

    // A board's key: its sign and name, filled while it is the one on the Mac's screen.
    func cell(_ name: String, _ symbol: String, on: Bool, busy: Bool, menu: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 24).opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.small).tint(on ? .white : macBlue) } }
                .foregroundStyle(on ? Color.white : macBlue)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(on ? Color.white : Color.primary).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            // A menu, not a board: marked as the system marks one.
            if menu { Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary) }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity).frame(height: Space.key)
        .background(on ? macBlue : cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
    // The page on the Mac's screen, when it shows a page and not a board or Glance.
    var page: (id: String, name: String, symbol: String)? {
        guard running, let st, st.glance != true, st.board == nil else { return nil }
        return ConsolePlace.pages.first { $0.id == st.page }
    }
    var boards: some View {
        Section {
            // Two across folded and in a pane, three where there's room: six keys, so no row ends in a hole.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Space.gap)], spacing: Space.gap) {
                ForEach(ConsolePlace.boards, id: \.id) { b in
                    let on = running && st?.glance != true && st?.board == b.id
                    Button { remote.send(model, "board:" + b.id, "board", b.id) } label: { cell(b.name, b.symbol, on: on, busy: remote.busy == "board:" + b.id) }
                        .buttonStyle(PressStyle())
                        .accessibilityLabel(b.name).accessibilityHint(b.about)
                        .accessibilityIdentifier("board." + b.id)
                        .accessibilityAddTraits(on ? .isSelected : [])
                }
                // The Console's pages, tucked behind the sixth key: the one on the Mac's screen is named on it.
                Menu {
                    ForEach(ConsolePlace.pages, id: \.id) { p in
                        Button { remote.send(model, "page", "page", p.id) } label: { Label(p.name, systemImage: page?.id == p.id ? "checkmark" : p.symbol) }
                    }
                } label: { cell(page?.name ?? "Pages", page?.symbol ?? "square.grid.2x2", on: page != nil, busy: remote.busy == "page", menu: true) }
                .accessibilityIdentifier("board.pages")
            }
            .disabled(!ready || !running)
            .opacity(ready && running ? 1 : 0.4)
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        } header: { Text("Put on the Mac") }
    }

    // MARK: The switches

    func row(_ title: String, _ note: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                // Whole in the narrowest pane (open flat at his size): short names, and a note that may take a second line.
                Text(title).fixedSize(horizontal: false, vertical: true)
                Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(macBlue) }
    }
    var switches: some View {
        Section {
            Toggle(isOn: Binding(get: { asked["show"] ?? (seen == .on || (running && st?.frontmost == true)) }, set: { want in
                guard remote.busy == nil else { return }
                asked["show"] = want
                remote.send(model, "show", want ? "show" : "hide")
            })) { row("On screen", "Over other apps", "rectangle.inset.filled") }
                .accessibilityIdentifier("switch.show")
            Toggle(isOn: flag("display", st?.keepOn == true, "display")) { row("Display on", "Until you turn it off", "sun.max") }
                .accessibilityIdentifier("switch.display")
            Group {
                Toggle(isOn: flag("rotate", st?.rotate == true, "rotate")) { row("Take turns", "Every \(secs) s", "arrow.triangle.2.circlepath") }
                    .accessibilityIdentifier("switch.rotate")
                Toggle(isOn: flag("text", st?.text == "room", "text", on: "room", off: "desk")) { row("Large text", "Across the room", "textformat.size") }
                    .accessibilityIdentifier("switch.text")
                // Glance in plain words, one switch (Richard, 2026-11-21: "glance is so confusing"): its one line says what it does; the name stays the Mac's own ("Glance from Bed" in its menu).
                Toggle(isOn: flag("glance", st?.glance == true, "glance")) { row("Glance", "Time, alarm and TV in big, dim figures", "eye") }
                    .accessibilityIdentifier("switch.glance")
            }
            .disabled(!running)
            // The Mac's real display, to see for himself.
            Button { model.openScreen() } label: {
                HStack { Label("See the Mac’s screen", systemImage: "macwindow"); Spacer(minLength: 8); RowChevron() }.contentShape(Rectangle())
            }
            .accessibilityIdentifier("dash.screen")
        } header: { Text("Switches") }
        .disabled(!ready)
    }
}

// The remote's one spacing system: the card's padding, the gap between keys, a key's height.
enum Space {
    static let card: CGFloat = 16
    static let gap: CGFloat = 10
    static let key: CGFloat = 56
}

// MARK: - The Mac's pages, on Control (they were tiles and a "Drive the Mac" list on the Dashboard until 2026-11-21:
// "drive the mac stuff should be interspersed throughout the interface"). Each row says how its part stands and opens
// its page, where it is driven.
struct UpkeepSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var links = ConsoleSummary.shared.links
    @ObservedObject private var updates = ConsoleSummary.shared.updates
    @ObservedObject private var startup = ConsoleSummary.shared.startup
    @ObservedObject private var fans = ConsoleSummary.shared.fans
    @ObservedObject private var upgrade = ConsoleSummary.shared.upgrade
    let s: Status
    func row(_ title: String, _ symbol: String, _ value: String?, bad: Bool = false, page: MacPage) -> some View {
        Button { model.macPage = page } label: {
            HStack(spacing: 10) {
                Label { Text(title).foregroundStyle(Color.primary).lineLimit(1).fixedSize() } icon: { Image(systemName: symbol).foregroundStyle(macBlue) }
                Spacer(minLength: 8)
                Text(value ?? "–").font(.subheadline).foregroundStyle(bad ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("upkeep." + title)
    }
    var body: some View {
        Section {
            let bad = s.healthBad
            row("Everything", "checklist", bad.map { $0 == 0 ? "All running" : $0 == 1 ? "1 needs a look" : "\($0) need a look" }, bad: (bad ?? 0) > 0, page: .health)
            row("Fans & heat", "fan", fans.value?.fans.first.map { "\(Int($0.rpm.rounded())) rpm" }, page: .fans)
            row("Storage", "internaldrive", "\(Format.bytes(s.disk.free)) free", page: .storage)
            if let items = startup.value?.items {
                let stopped = StartupView.stopped(items.filter(\.mine)).count
                row("Startup items", "power", stopped == 0 ? "\(items.filter(\.mine).count) running" : "\(stopped) stopped", bad: stopped > 0, page: .startup)
            } else { row("Startup items", "power", nil, page: .startup) }
            if let l = links.value {
                let x = MacConsole.linkSummary(l)
                row("Connections", "point.3.connected.trianglepath.dotted", x.good ? "All up" : x.text, bad: !x.good, page: .links)
            } else { row("Connections", "point.3.connected.trianglepath.dotted", nil, page: .links) }
            if let g = upgrade.value, g.pending {
                // Under way it says what it is doing; "waiting" only while the version isn't the one running (gate 3).
                let doing = ["downloading": "Downloading", "installing": "Installing", "patching": "Patching"][g.phase]
                row("Updates", "arrow.down.circle", doing ?? (g.waiting?.version).map { "macOS \($0) waiting" } ?? "macOS waiting", page: .upgrade)
            } else if let u = updates.value {
                let waiting = (u.macos.pending ?? []).count + (u.brew?.outdated ?? []).count
                row("Updates", "arrow.down.circle", u.macos.pending == nil ? nil : waiting == 0 ? "Up to date" : "\(waiting) waiting", page: .updates)
            } else { row("Updates", "arrow.down.circle", nil, page: .updates) }
        } header: { Text("Upkeep") }
        .task { await ConsoleSummary.shared.loop(model) }
    }
}
