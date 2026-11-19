import SwiftUI

// The Dashboard tab (Richard, 2026-11-14: "have it so i have a version of the dashboard on my phone like same stats etc
// diff tab and consolidate console into it"; and of the Console tab's buttons: "awful"). The Mac's Console, on the phone:
// what the Mac's screen is on with three plain keys, then the same tiles as the Console's Home, each opening the phone's
// own page for it and, held, putting that page on the Mac. Boards and pages for the Mac's screen follow as chips.

struct DashboardTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LiveStore
    @ObservedObject private var remote = ConsoleRemote.shared
    @ObservedObject private var links = ConsoleSummary.shared.links
    @ObservedObject private var updates = ConsoleSummary.shared.updates
    @ObservedObject private var startup = ConsoleSummary.shared.startup
    @ObservedObject private var summary = ConsoleSummary.shared
    @ObservedObject private var tv = ConsoleSummary.shared.tv
    @Environment(\.openURL) private var openURL
    @ObservedObject private var watch = RestartWatch.shared
    @ObservedObject private var health = HealthSummary.shared
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    var st: ConsoleState? { remote.state }
    var running: Bool { st?.running == true }
    // The Mac's page on screen now, when it's a page and not a board.
    var onMac: String? { running && st?.board == nil ? st?.page : nil }

    var body: some View {
        Group {
            switch side {
            case .all: screenCard; tiles; showOnMac
            // Open flat, the Console and what's on its screen on the left, the Mac's tiles filling the right: the screen's
            // two settings alone left the right pane half empty (CI 5ee8ad1).
            case .left: screenCard; showOnMac
            case .right: tiles
            }
        }
        .task(id: side) { if side != .right { await remote.loop(model) } }
        // The tiles from the Mac's own pages (connections, updates, startup) every 30 s while the Dashboard is up, as
        // Control's This Mac rows were; read once only, they went stale under him.
        .task(id: side) { if side != .right { await ConsoleSummary.shared.loop(model) } }
        // Done when the Console answers yes, warn when it says no or can't be reached: once per tap, on the answer.
        .haptic(.done, trigger: remote.answered) { _, _ in side != .right }
        .haptic(.warn, trigger: remote.refused) { _, _ in side != .right }
        // Back from one of its pages (an update installed, a startup item started), the tiles read the Mac again.
        .onReceive(model.nav.$dashPage.dropFirst()) { p in if p == nil, side != .right, model.pose.isEmpty { Task { await ConsoleSummary.shared.readAll(model.api) } } }
    }

    // MARK: The Mac's screen

    // The Console's state in one line under its name, with a light (Richard, 2026-11-15: "I NEED INDICATOR"): green while
    // it is on the Mac's screen, orange while it runs but can't be seen there, grey while it isn't running. Only what the
    // Console itself last said; never a guess.
    var light: (say: String, color: Color) {
        // A key's refusal is said here, in the status line's own place, for a few seconds: a line of its own under the
        // keys grew the card and moved every tile below it down and back (CI 68b580c).
        if let f = remote.fail, ["show", "hide", "display", "glance"].contains(where: { f.key.hasPrefix($0) }) { return (f.text, .red) }
        if remote.unsupported { return ("Not on this Mac yet", .secondary) }
        if !remote.read { return ("Looking at the Mac…", .secondary) }
        if !running { return remote.busy == "show" ? ("Starting on the Mac…", macBlue) : ("Not running", Color(white: 0.45)) }
        guard let st else { return ("Not running", Color(white: 0.45)) }
        // The page (or board, or Glance) it shows, then where: green on the Mac's screen; blue while it runs out of sight
        // (the display asleep is the Mac's usual state, not a fault: orange reads as a warning here and on the tiles).
        let page = ConsolePlace.name(st).0
        if st.screenStepAside == true { return ("\(page) · stepped aside for Screen", macBlue) }
        if st.display == "asleep" { return ("\(page) · the display is asleep", macBlue) }
        if st.frontmost == false { return ("\(page) · behind other apps", macBlue) }
        if st.fullscreen == false { return ("\(page) · in a window on the Mac’s screen", .green) }
        return ("\(page) · on the Mac’s screen", .green)
    }

    var screenCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    // Always named the Console, so the card says what it is; the page it shows is in the line under it.
                    let (name, symbol) = ("Console", running ? ConsolePlace.name(st!).1 : "macwindow")
                    Image(systemName: symbol).font(.title3).foregroundStyle(running ? macBlue : .secondary)
                        .frame(width: 44, height: 44).background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(remote.read ? name : " ").font(.headline).lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(light.color).frame(width: 8, height: 8)
                            Text(light.say).font(.footnote).foregroundStyle(light.color == .red ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary)).lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Spacer(minLength: 0)
                }
                .animation(Motion.quick, value: light.say)
                HStack(spacing: 10) {
                    // Before the Mac has said, the keys wait (greyed) in their places, so none changes under his finger.
                    if !running {
                        Key("Start", "play.fill", busy: remote.busy == "show", on: false) { remote.send(model, "show", "show") }
                    } else if st?.frontmost != true || st?.fullscreen != true {
                        Key("Show", "macwindow", busy: remote.busy == "show", on: false) { remote.send(model, "show", "show") }
                    } else {
                        Key("Hide", "eye.slash", busy: remote.busy == "hide", on: false) { remote.send(model, "hide", "hide") }
                    }
                    // Wake only on his tap (API.md): never sent by itself.
                    if st?.display == "asleep" {
                        Key("Wake", "sun.max", busy: remote.busy == "display:wake", on: false) { remote.send(model, "display:wake", "display", "wake") }.disabled(!running)
                    } else {
                        Key("Sleep", "moon", busy: remote.busy == "display:sleep", on: false) { remote.send(model, "display:sleep", "display", "sleep") }.disabled(!running)
                    }
                    Key("Glance", "bed.double", busy: remote.busy == "glance", on: st?.glance == true) {
                        remote.send(model, "glance", "glance", st?.glance == true ? "off" : "on")
                    }
                    .disabled(!running)
                }
                // A key waiting on the Console's answer shows its own wait; the others stay as they are (one command at
                // a time is the remote's own rule), so nothing greys or flickers under a tap.
                .disabled(!remote.read || remote.unsupported)
            }
            .padding(16)
            .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
        .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
    }

    // One of the three keys: a glyph over its word, all the same size, filled when it's on. The wait is drawn over the glyph,
    // so a key never changes size.
    struct Key: View {
        let title: String, symbol: String, busy: Bool, on: Bool, action: () -> Void
        @Environment(\.isEnabled) private var enabled
        init(_ title: String, _ symbol: String, busy: Bool, on: Bool, action: @escaping () -> Void) {
            self.title = title; self.symbol = symbol; self.busy = busy; self.on = on; self.action = action
        }
        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    Image(systemName: symbol).font(.title3.weight(.medium)).frame(height: 24)
                        .opacity(busy ? 0 : 1).overlay { if busy { ProgressView().controlSize(.small).tint(on ? .white : macBlue) } }
                    Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                }
                .foregroundStyle(on ? Color.white : macBlue)
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(on ? macBlue : Color(white: 0.17), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(title)
            .accessibilityIdentifier("key." + title)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    // MARK: The tiles, as on the Console's Home

    struct TileData: Identifiable {
        let id: String, title: String, symbol: String
        var figure: String?, line: String?, good: Bool? = nil
        var alts: [String] = []    // shorter second lines, the longest that fits whole is shown
        var figs: [String] = []    // shorter figures, likewise (a figure is never shrunk)
        let page: String?          // the Console page it puts on the Mac's screen, held
        let open: () -> Void
    }
    // When the Mac last checked every part, said the way Status's chip and Everything's page do: the second line adds.
    var checkedLine: String {
        guard let at = s.healthAt, at > 0 else { return " " }
        let m = Int(Date().timeIntervalSince1970 - at / 1000) / 60
        return m < 1 ? "Checked just now" : m < 60 ? "Checked \(m) min ago" : "Checked \(m / 60) h ago"
    }
    // The tiles' words, shorter, for a narrow tile: never a shrunk figure.
    static func shorter(_ f: String?) -> [String] {
        switch f { case "All running": ["Running"]; case "Up to date": ["Current"]; case "Restarting": ["Restart"]; default: [] }
    }
    func everything(_ bad: Int?) -> TileData {
        let open = { model.macPage = .health }
        if watch.active { return TileData(id: "everything", title: "Everything", symbol: "checklist", figure: "Restarting", line: "Getting everything up", page: "everything", open: open) }
        guard let n = bad, n > 0 else {
            return TileData(id: "everything", title: "Everything", symbol: "checklist", figure: bad.map { _ in "All running" }, line: bad.map { _ in checkedLine }, good: bad.map { _ in true }, page: "everything", open: open)
        }
        let w = health.say(n)
        return TileData(id: "everything", title: "Everything", symbol: "checklist", figure: w.figure, line: w.line, good: false, alts: w.alts, figs: w.figs, page: "everything", open: open)
    }
    var tileData: [TileData] {
        let cpu = store.live?.cpu ?? s.cpu, mem = store.live?.mem ?? s.mem, net = store.live?.net ?? s.net
        let temps = store.live?.temps ?? s.temps ?? []
        // The figure is the warmest reading; the line says whether any sensor is near its own limit (the bridge's verdict,
        // whose "hottest" is the one nearest its limit: on 2026-11-18 that was the intake air at 28.8 °C beside a 69 °C
        // CPU, and the tile read "28.8°, Intake air, the hottest").
        let warmest = temps.max { $0.c < $1.c }
        let verdict = s.heat?.verdict
        let near = s.heat?.hottest
        let memPct = mem.total > 0 ? Int((mem.used / mem.total * 100).rounded()) : 0
        let top = s.procs.max { $0.cpu < $1.cpu }
        // The build's pose of one part needing a look says so on every surface (chip, tile, page).
        let bad = model.pose == "chipbad" ? 1 : s.healthBad
        var t: [TileData] = [
            // CPU and Memory as on Status, each opening its own history by the same name ("Mac Pro" opened a page called CPU).
            TileData(id: "cpu", title: "CPU", symbol: "gauge.with.dots.needle.67percent", figure: "\(cpu.total)%", line: String(format: "Load %.2f", (store.live?.load ?? s.load).first ?? 0), page: "overview") { model.history = .cpu },
            TileData(id: "memory", title: "Memory", symbol: "memorychip", figure: "\(memPct)%", line: "\(Format.bytes(mem.used)) of \(Format.bytes(mem.total))", alts: [Format.bytes(mem.used)], page: "overview") { model.history = .memory },
            // Named as the page it opens, so the fans are findable from here (Richard, 2026-11-13: "fan speed").
            TileData(id: "temps", title: "Fans & heat", symbol: "thermometer.medium", figure: warmest.map { MacConsole.degrees($0.c) },
                     line: verdict.map { v in v == "Normal" || near == nil ? warmest.map { "\($0.name), the warmest" } ?? v : "\(v) · \(near!.name) \(MacConsole.degrees(near!.c))" } ?? warmest.map { "\($0.name), the warmest" },
                     good: verdict.map { $0 == "Normal" }, alts: [verdict == nil || verdict == "Normal" || near == nil ? warmest?.name : near?.name].compactMap { $0 }, page: "temps") { model.macPage = .fans },
            // One part down is named ("Programs", "needs a look"), two or more named as a count always is; the count alone
            // until the Mac's report agrees with it (designer gate, 2026-11-19: "1 / part needs a look" named nothing).
            everything(bad),
            TileData(id: "activity", title: "Network", symbol: "arrow.up.arrow.down", figure: Format.rate(net.rxRate), line: "down · up \(Format.rate(net.txRate))", alts: ["down"], page: "overview") { model.history = .download },
            TileData(id: "processes", title: "Processes", symbol: "cpu", figure: top.map { "\(Int($0.cpu.rounded()))%" }, line: top?.name, page: "processes") { model.processes = .cpu },
            TileData(id: "storage", title: "Storage", symbol: "internaldrive", figure: Format.bytes(s.disk.free), line: "free of \(Format.bytes(s.disk.total))", alts: ["free"], page: "storage") { model.macPage = .storage },
        ]
        // The tiles from the Mac's own pages hold their places from the first draw, a dash until they're read, and go
        // only for a Mac whose bridge hasn't the feed: arriving a moment late, they moved the tiles after them (CI 68b580c).
        let linksOpen = { model.macPage = .links }, updatesOpen = { model.macPage = .updates }, startupOpen = { model.macPage = .startup }
        let tvOpen = { if let u = URL(string: "tvremoteapp://") { openURL(u) } }
        if let l = links.value {
            let x = MacConsole.linkSummary(l)
            t.append(TileData(id: "links", title: "Connections", symbol: "point.3.connected.trianglepath.dotted", figure: x.good ? "All up" : "\(max(1, l.links.filter { !$0.up && $0.state != "off" }.count))", line: x.good ? "\(l.links.filter(\.up).count) links" : x.text, good: x.good, page: nil, open: linksOpen))
        } else if !links.unsupported { t.append(TileData(id: "links", title: "Connections", symbol: "point.3.connected.trianglepath.dotted", page: nil, open: linksOpen)) }
        if let u = updates.value {
            let waiting = (u.macos.pending ?? []).count + (u.brew?.outdated ?? []).count
            t.append(TileData(id: "updates", title: "Updates", symbol: "arrow.down.circle", figure: u.macos.pending == nil ? nil : waiting == 0 ? "Up to date" : "\(waiting)", line: waiting == 0 ? "macOS \(u.macos.current.split(separator: " ").first ?? "")" : "waiting", good: waiting == 0 ? true : nil, page: "updates", open: updatesOpen))
        } else if !updates.unsupported { t.append(TileData(id: "updates", title: "Updates", symbol: "arrow.down.circle", page: "updates", open: updatesOpen)) }
        if let items = startup.value?.items {
            let stopped = StartupView.stopped(items.filter(\.mine)).count
            t.append(TileData(id: "startup", title: "Startup", symbol: "power", figure: stopped == 0 ? "\(items.filter(\.mine).count) running" : "\(stopped)", line: stopped == 0 ? "None stopped" : "stopped", good: stopped == 0, page: "startup", open: startupOpen))
        } else if !startup.unsupported { t.append(TileData(id: "startup", title: "Startup", symbol: "power", page: "startup", open: startupOpen)) }
        // The TV, as the Console's Home has it: what's playing, or whether it's on. A tap opens the TV app.
        if let v = tv.value {
            let ep = v.session?.description?.first, song = v.music?.playing == true ? v.music?.title : nil
            let fig = v.online == false ? "Away" : ep != nil ? (v.session?.playing == false ? "Paused" : "Playing") : song != nil ? "Music" : v.screen == "asleep" ? "Asleep" : v.screen == "on" ? "On" : "Off"
            let line = v.online == false ? "Not answering" : ep.map { [$0, v.session?.description?.dropFirst().first].compactMap { $0 }.joined(separator: " · ") } ?? song.map { [$0, v.music?.artist].compactMap { $0 }.joined(separator: " · ") } ?? "Nothing playing"
            t.append(TileData(id: "tv", title: "Google TV", symbol: "tv", figure: fig, line: line, alts: [ep ?? song].compactMap { $0 }, page: "tv", open: tvOpen))
        } else if !tv.unsupported { t.append(TileData(id: "tv", title: "Google TV", symbol: "tv", page: "tv", open: tvOpen)) }
        if let w = s.usage.plan?.sevenDay {
            t.append(TileData(id: "claude", title: "Claude", symbol: "sparkle", figure: "\(Int(w.rounded()))%", line: "of the week · \(s.claude.sessions.count) session\(s.claude.sessions.count == 1 ? "" : "s")", good: w < 90, alts: ["of the week"], page: "activity") { model.tab = 2 })
        }
        return t
    }

    // The same tiles as Status's (WebTile), each opening the phone's page for it: two across where a tile would be narrower
    // than 175 pt (folded upright, a pane open flat), three where there's room (open upright, and folded on its side, where
    // two across made the short page twice as long to scroll). Chosen from the width in the one layout pass (TileGrid),
    // never read back afterwards, so the first frame is already the right grid.
    var tiles: some View {
        Section {
            TileGrid {
                ForEach(tileData) { d in
                    WebTile(title: d.title, value: d.figure ?? "–", detail: d.line ?? " ", symbol: d.symbol, good: d.good, onMac: d.page != nil && d.page == onMac, open: d.open, details: d.alts, figures: d.figs.isEmpty ? Self.shorter(d.figure) : d.figs)
                }
            }
            .opacity(model.stale ? staleDim : 1)
            // The row runs edge to edge of the card; the header is the system's own, laid out as Control's are (its
            // spacing tuned by hand was 2-9 pt off theirs, designer gate 2026-11-18).
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        } header: {
            // Open flat the tiles have the right pane to themselves and start level with the Console's card on the left.
            if side == .all { Text("The Mac") }
        }
    }

    // MARK: For the Mac's screen: boards and pages

    func chip(_ name: String, _ symbol: String, on: Bool, busy: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.subheadline).opacity(busy ? 0 : 1).overlay { if busy { ProgressView().controlSize(.mini) } }
                Text(name).font(.subheadline.weight(.medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 14).frame(height: 40)
            .background(on ? macBlue : Color(white: 0.15), in: Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(name)
        .accessibilityIdentifier("chip." + id)
        .accessibilityAddTraits(on ? .isSelected : [])
        .id(id)
    }

    var showOnMac: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    // Clear of the header above (it was cut to "oards", CI 68b580c).
                    // In line with the headings, clear of the card's rounded corner (it cut "Boards" to "3oards", CI 64e4a2c).
                    Text("Boards").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 20)
                    chips(shown: (running ? st?.board : nil).map { "board." + $0 }) {
                        ForEach(ConsolePlace.boards, id: \.id) { b in
                            let on = running && st?.board == b.id
                            chip(b.name, b.symbol, on: on, busy: remote.busy == "board:" + b.id, id: "board." + b.id) { remote.send(model, "board:" + (on ? "off" : b.id), "board", on ? "off" : b.id) }
                        }
                    }
                    Text("Pages").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 20).padding(.top, 4)
                    chips(shown: onMac.map { "page." + $0 }) {
                        ForEach(ConsolePlace.pages, id: \.id) { p in
                            chip(p.name, p.symbol, on: onMac == p.id, busy: remote.busy == "page:" + p.id, id: "page." + p.id) { remote.send(model, "page:" + p.id, "page", p.id) }
                        }
                    }
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
            } header: { Text("For the Mac’s screen") }
            // Two settings, as rows of the system's own card, as in Settings.
            Section {
                Toggle(isOn: Binding(get: { st?.rotate == true }, set: { on in remote.send(model, "rotate", "rotate", on ? "on" : "off") })) {
                    Text("Boards take turns")
                }
                .tint(macBlue)
                HStack {
                    Text("Animations")
                    Spacer(minLength: 12)
                    Picker("Animations", selection: Binding(get: { st?.animations ?? "full" }, set: { remote.send(model, "animations", "animations", $0) })) {
                        Text("Full").tag("full"); Text("Gentle").tag("gentle"); Text("Off").tag("off")
                    }
                    .pickerStyle(.segmented).fixedSize()
                }
            } footer: {
                if let f = remote.fail, ["board", "page", "rotate", "animations"].contains(where: { f.key.hasPrefix($0) }) { FailText(f.text) }
            }
        }
        .disabled(!running)
        .opacity(running ? 1 : 0.4)
    }
    // A row of chips that scrolls sideways out to the display's edges, its first chip lined up with the cards.
    // The first chip in line with the headings; the row fades out at its end rather than cutting a chip in half.
    // The row follows what's lit: the page on the Mac's screen was a blue sliver cut by the pane's edge when it was the
    // fourth chip or later (CI 7809d95, open flat; designer gate 2026-11-19). In place as the row appears, glided after.
    func chips<C: View>(shown: String?, @ViewBuilder _ content: () -> C) -> some View {
        ChipRow(shown: shown, content: content())
    }
}

// The chip row's scroll, following the lit chip: scrollTo in onAppear ran before the List had laid the row out, and the
// change never fired (designer gate, 2026-11-19); a scroll position keyed by the chips' .id() never matched, since it
// reads the ForEach's own ids (third gate). Now scrollTo, which finds a chip by its .id(), from a task keyed by the lit
// chip, after a turn of the run loop: in place the first time, glided on every change after, whether from a tap or the
// Mac's own (Boards take turns).
struct ChipRow<C: View>: View {
    let shown: String?
    let content: C
    @State private var placed = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { content } }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .task(id: shown) {
                    guard let shown else { return }
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if placed { withAnimation(Motion.quick) { proxy.scrollTo(shown, anchor: .center) } }
                    else { proxy.scrollTo(shown, anchor: .center); placed = true }
                }
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
    }
}

// The Dashboard's tiles in even columns: three across when each would be at least 175 pt wide, else two (twelve tiles fill
// either whole). Every tile in a row is offered the row's height, laid out from the width alone.
struct TileGrid: Layout {
    var spacing: CGFloat = 12
    static func columns(_ width: CGFloat) -> Int { width >= 175 * 3 + 12 * 2 ? 3 : 2 }
    struct Cache { var width: CGFloat = -1; var rows: [CGFloat] = [] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.width = -1 }
    private func cell(_ width: CGFloat) -> (Int, CGFloat) {
        let n = Self.columns(width)
        return (n, max((width - spacing * CGFloat(n - 1)) / CGFloat(n), 0))
    }
    private func rows(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> [CGFloat] {
        if cache.width == width { return cache.rows }
        let (n, w) = cell(width)
        var r: [CGFloat] = []
        for (i, v) in subviews.enumerated() {
            let h = v.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            if i % n == 0 { r.append(h) } else { r[r.count - 1] = max(r[r.count - 1], h) }
        }
        cache.width = width; cache.rows = r
        return r
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 400
        let r = rows(width, subviews, &cache)
        return CGSize(width: width, height: r.reduce(0, +) + spacing * CGFloat(max(r.count - 1, 0)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let r = rows(bounds.width, subviews, &cache)
        let (n, w) = cell(bounds.width)
        var y = bounds.minY
        for (row, h) in r.enumerated() {
            for c in 0..<n {
                let i = row * n + c
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (w + spacing), y: y), proposal: ProposedViewSize(width: w, height: h))
            }
            y += h + spacing
        }
    }
}
