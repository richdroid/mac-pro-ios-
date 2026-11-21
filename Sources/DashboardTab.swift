import SwiftUI

// The Dashboard tab (Richard, 2026-11-14: "have it so i have a version of the dashboard on my phone like same stats etc
// diff tab and consolidate console into it"; 2026-11-20: "not up to par at all and integration is very lacking").
// Rebuilt to the 2026-11-20 brief, top to bottom: the Mac's screen now (what the Console shows, in words and as a small
// picture, with its three keys); what the Console can show, as a strip of small screens, the one on the Mac ringed and
// following the Mac both ways; the Console's Home tiles in groups (the machine, the house and work, upkeep), each opening
// the phone's page with the Console following (MacFollow); the upgrade, full width, whenever one is pending; then the
// things that drive the Mac. No setting lives here (Boards take turns and Animations are in Settings).

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
    @ObservedObject private var fans = ConsoleSummary.shared.fans
    @ObservedObject private var upgrade = ConsoleSummary.shared.upgrade
    let s: Status
    var side: Side = .all
    init(_ s: Status, side: Side = .all) { self.s = s; self.side = side }
    var st: ConsoleState? { remote.state }
    var running: Bool { st?.running == true }
    // The Mac's page on screen now, when it's a page and not a board.
    // Not under Glance: the Mac shows its Glance face then, no page, so nothing here is marked as on its screen (the
    // card said "Glance" while the strip ringed a page, designer gate 1, 2026-11-20).
    var paged: Bool { running && st?.glance != true }
    var onMac: String? { paged && st?.board == nil ? st?.page : nil }
    // Short of room or held for the patcher: the upgrade needs him, so its card comes second, not under the tiles.
    var upgradeStuck: Bool { upgrade.value.map { $0.pending && ($0.phase == "room" || $0.phase == "held") } ?? false }

    var body: some View {
        Group {
            switch side {
            case .all: screenCard; if upgradeStuck { UpgradeCard() }; strip; tiles; if !upgradeStuck { UpgradeCard() }; drive
            // Open flat: the screen, its strip and the driving on the left; the tiles and the upgrade on the right.
            case .left: screenCard; strip; drive
            case .right: if upgradeStuck { UpgradeCard() }; tiles; if !upgradeStuck { UpgradeCard() }
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
        // Out of reach, the card says what it last saw as the past, greyed: a green "on the Mac's screen" under "Can't
        // reach the Mac" claimed what nobody could know (CI 5fb9358).
        if model.stale, remote.read, let st, running { return ("\(ConsolePlace.name(st).0) · when last seen; out of reach now", Color(white: 0.45)) }
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

    // What the Console shows, as a small screen: the page's sign on a dark display, dark with a moon while the display
    // sleeps, empty while the Console isn't running. Drawn, not a picture from the Mac: the bridge has no still of the
    // screen to give. Tapped, it opens Screen, the Mac's real display.
    struct MiniScreen: View {
        let symbol: String?, name: String?, lit: Bool, ring: Bool
        var width: CGFloat = 132
        var body: some View {
            let h = (width * 0.62).rounded()
            VStack(spacing: width > 110 ? 6 : 0) {
                if let symbol { Image(systemName: symbol).font(width > 110 ? .title2 : .body).foregroundStyle(lit ? macBlue : Color(white: 0.45)) }
                if width > 110, let name { Text(name).font(.caption2.weight(.medium)).foregroundStyle(lit ? Color.primary : Color.secondary).lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 6) }
            }
            .frame(width: width, height: h)
            .background(Color(white: lit ? 0.17 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ring ? macBlue : Color(white: 0.24), lineWidth: ring ? 2 : 1) }
        }
    }
    var screenCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                // The state in words leads (what the Mac's screen shows, then where), with the light; Screen, the Mac's
                // real display, is the key beside it. No drawn stand-in for a picture: a symbol in a box said the page's
                // name a second time and was not the Mac's screen (designer gate 1, 2026-11-20).
                HStack(alignment: .center, spacing: 12) {
                    let parts = light.say.components(separatedBy: " · ")
                    let split = parts.count > 1 && light.color != .red
                    VStack(alignment: .leading, spacing: 4) {
                        Text(split ? parts[0] : "Console").font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(light.color).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            Text(split ? parts.dropFirst().joined(separator: " · ") : light.say).font(.subheadline).foregroundStyle(light.color == .red ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    Button { model.openScreen() } label: {
                        Label("Screen", systemImage: "macwindow").font(.subheadline.weight(.semibold)).foregroundStyle(macBlue)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color(white: 0.17), in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("Open Screen").accessibilityHint("The Mac’s real display")
                    .accessibilityIdentifier("dash.screen")
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
                    Key("Glance", "bed.double", busy: remote.busy == "glance", on: st?.glance == true) {
                        remote.send(model, "glance", "glance", st?.glance == true ? "off" : "on")
                    }
                    .disabled(!running)
                    // Wake only on his tap (API.md): never sent by itself.
                    if st?.display == "asleep" {
                        Key("Wake", "sun.max", busy: remote.busy == "display:wake", on: false) { remote.send(model, "display:wake", "display", "wake") }.disabled(!running)
                    } else {
                        Key("Sleep", "moon", busy: remote.busy == "display:sleep", on: false) { remote.send(model, "display:sleep", "display", "sleep") }.disabled(!running)
                    }
                }
                // A key waiting on the Console's answer shows its own wait; the others stay as they are (one command at
                // a time is the remote's own rule), so nothing greys or flickers under a tap.
                .disabled(!remote.read || remote.unsupported || model.stale)
            }
            .padding(16)
            .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        } header: { Text("The Mac’s screen") }
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
    // The tiles' words, shorter, for a narrow tile: never a shrunk figure.
    static func shorter(_ f: String?) -> [String] {
        switch f { case "All running": ["Running"]; case "Up to date": ["Current"]; case "Restarting": ["Restart"]; default: [] }
    }
    func everything(_ bad: Int?) -> TileData {
        let open = { model.macPage = .health }
        if watch.active { return TileData(id: "everything", title: "Everything", symbol: "checklist", figure: "Restarting", line: "Getting everything up", page: "everything", open: open) }
        guard let n = bad, n > 0 else {
            return TileData(id: "everything", title: "Everything", symbol: "checklist", figure: bad.map { _ in "All running" }, line: bad.map { _ in "No part needs a look" }, good: bad.map { _ in true }, page: "everything", open: open)
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
        // The macOS update that is waiting says where it stands and opens the upgrade itself: "1 waiting" on a tile like
        // any other said nothing of the room it was short of (Richard, 2026-11-20).
        if let g = upgrade.value, g.pending, let v = g.target?.version ?? g.current.split(separator: " ").first.map(String.init) {
            let line = g.phase == "room" ? "needs \(UpgradeFeed.gb(g.short)) more room" : g.phase == "held" ? "waits for the patcher" : g.phase == "ready" ? "ready to install" : g.phase == "downloading" ? "downloading" : g.phase == "patching" ? "patching" : "installing"
            t.append(TileData(id: "updates", title: "Updates", symbol: "arrow.down.circle", figure: v, line: line, good: g.phase == "room" || g.phase == "held" ? false : nil, alts: g.phase == "room" ? ["needs room"] : [], page: "updates") { model.macPage = .upgrade })
        } else if let u = updates.value {
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
        if let f = fans.value?.fans.first {
            t.append(TileData(id: "fan", title: "Fan", symbol: "fan", figure: "\(Int(f.rpm.rounded()))", line: "rpm · \(Int((f.level * 100).rounded()))% of its range", alts: ["rpm"], page: nil) { model.macPage = .fans })
        } else if !fans.unsupported { t.append(TileData(id: "fan", title: "Fan", symbol: "fan", page: "temps") { model.macPage = .fans }) }
        let n = s.claude.sessions.count
        t.append(TileData(id: "sessions", title: "Sessions", symbol: "terminal", figure: "\(n)", line: n == 0 ? "None running" : s.claude.sessions.prefix(3).map(\.name).joined(separator: ", "), alts: [n == 1 ? "session" : "sessions"], page: "activity") { model.tab = 2 })
        if let w = s.usage.plan?.sevenDay {
            t.append(TileData(id: "claude", title: "Claude", symbol: "sparkle", figure: "\(Int(w.rounded()))%", line: "of the week’s limit", good: w < 90, alts: ["of the week"], page: "activity") { model.tab = 2 })
        }
        return t
    }

    // The Console's Home tiles, in its groups: the machine first, then the house and work, then upkeep. The same tiles as
    // Status's (WebTile), each opening the phone's page for it, the Console following (MacFollow): two across where a tile
    // would be narrower than 175 pt (folded upright, a pane open flat), three where there's room. Chosen from the width in
    // the one layout pass (TileGrid), never read back afterwards, so the first frame is already the right grid; a last
    // row that isn't full shares the width, so no group ends in a hole.
    static let groups: [(title: String, ids: [String])] = [
        ("The machine", ["cpu", "memory", "temps", "fan", "activity", "processes"]),
        ("The house and work", ["tv", "claude", "sessions"]),
        ("Upkeep", ["everything", "storage", "updates", "startup", "links"]),
    ]
    var tiles: some View {
        let all = tileData
        return ForEach(Self.groups, id: \.title) { g in
            let mine = g.ids.compactMap { id in all.first { $0.id == id } }
            if !mine.isEmpty {
                Section {
                    TileGrid {
                        ForEach(mine) { d in
                            WebTile(title: d.title, value: d.figure ?? "–", detail: d.line ?? " ", symbol: d.symbol, good: d.good, onMac: d.page != nil && d.page == onMac, open: d.open, details: d.alts, figures: d.figs.isEmpty ? Self.shorter(d.figure) : d.figs)
                        }
                    }
                    .opacity(model.stale ? staleDim : 1)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                } header: { Text(g.title) }
            }
        }
    }

    // MARK: What the Console can show

    // One page or board as a small screen with its name under it; the one on the Mac's screen has the ring.
    func thumb(_ name: String, _ symbol: String, on: Bool, busy: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                MiniScreen(symbol: busy ? nil : symbol, name: nil, lit: on, ring: on, width: 92)
                    .overlay { if busy { ProgressView().controlSize(.small) } }
                Text(name).font(.caption.weight(on ? .semibold : .regular)).foregroundStyle(on ? Color.primary : Color.secondary).lineLimit(1).fixedSize()
            }
            .frame(minWidth: 92)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(name)
        .accessibilityIdentifier("chip." + id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
    // Home, Mac Pro and Fans & heat, then the boards, then the other pages.
    static let stripIds: [String] = ConsolePlace.pages.prefix(3).map { "page." + $0.id } + ConsolePlace.boards.map { "board." + $0.id } + ConsolePlace.pages.dropFirst(3).map { "page." + $0.id }
    var strip: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                // Tap one and the Mac goes there; the Mac changing page at the desk moves the ring here (the row watches
                // the Console itself).
                ChipRow(ids: Self.stripIds, lit: { paged ? (st?.board.map { "board." + $0 } ?? onMac.map { "page." + $0 }) : nil }) { id in
                    if let b = ConsolePlace.boards.first(where: { "board." + $0.id == id }) {
                        let on = paged && st?.board == b.id
                        thumb(b.name, b.symbol, on: on, busy: remote.busy == "board:" + b.id, id: id) { remote.send(model, "board:" + (on ? "off" : b.id), "board", on ? "off" : b.id) }
                    } else if let p = ConsolePlace.pages.first(where: { "page." + $0.id == id }) {
                        thumb(p.name, p.symbol, on: onMac == p.id, busy: remote.busy == "page:" + p.id, id: id) { remote.send(model, "page:" + p.id, "page", p.id) }
                    }
                }
                if let f = remote.fail, ["board", "page"].contains(where: { f.key.hasPrefix($0) }) { FailText(f.text).padding(.leading, 20) }
            }
            .disabled(!running)
            .opacity(running ? (model.stale ? staleDim : 1) : 0.4)
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        } header: { Text("Showing on the Mac") }
    }

    // MARK: Drive the Mac

    func driveRow(_ title: String, _ symbol: String, _ note: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(destructive ? Color.red : macBlue).frame(width: 28)
                Text(title).foregroundStyle(destructive ? Color.red : Color.primary)
                Spacer(minLength: 8)
                Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drive." + title)
    }
    var drive: some View {
        Section {
            // Sending lives on Control, with the files on their way; one tap there.
            driveRow("Send to Mac", "square.and.arrow.up", "Photos, files") { model.tab = 5 }
            if summary.mp { driveRow("Run an action", "bolt", "Clean, ship, tests") { model.macPage = .actions } }
            driveRow("Bring everything up", "checklist", "By name") { model.macPage = .health }
            driveRow("Startup items", "power", "On and off") { model.macPage = .startup }
            driveRow("Restart the Mac…", "arrow.clockwise", "Checks first", destructive: true) { model.macPage = .restart }
        } header: { Text("Drive the Mac") }
    }
}

// A row of chips that scrolls sideways out to the display's edges, its first chip in line with the headings, fading out
// at its end rather than cutting a chip in half; it keeps the lit chip (the page or board on the Mac's screen) in view.
// Three tries by id failed inside the List row (designer gates on 5fdaedf, b6e8a0b, 8dac002): the lit Storage chip stayed
// off to the right while the row sat at Home. Inside a List, an .id() in a row is a target of the List's own scroll, so
// ScrollViewReader.scrollTo moved nothing sideways, and scrollPosition(id:) reads the ForEach's ids, which were the bare
// page names. So nothing here is found by id: each chip's centre is measured in the row's own space and the row is
// scrolled to an offset, held in a ScrollPosition. The row watches the Console itself, so it follows a change the Mac
// makes by itself (Boards take turns) as well as a tap, whatever the List does with the row around it.
struct ChipRow<C: View>: View {
    let ids: [String]
    let lit: () -> String?
    let chip: (String) -> C
    init(ids: [String], lit: @escaping () -> String?, @ViewBuilder chip: @escaping (String) -> C) { self.ids = ids; self.lit = lit; self.chip = chip }
    @ObservedObject private var remote = ConsoleRemote.shared
    @State private var position = ScrollPosition(x: 0)
    @State private var mids: [String: CGFloat] = [:]
    @State private var content: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @State private var placed = false
    @State private var scrolled = false
    static var margin: CGFloat { 20 }
    // The offset that puts a chip's centre (measured in the row, its 20 pt margins included) mid-view, clamped to the row.
    static func offset(mid: CGFloat, viewport: CGFloat, content: CGFloat) -> CGFloat {
        min(max(mid - viewport / 2, 0), max(content - viewport, 0))
    }
    func follow() {
        guard let id = lit(), let mid = mids[id], viewport > 0, content > 0 else { return }
        let x = Self.offset(mid: mid, viewport: viewport, content: content)
        if placed { withAnimation(Motion.quick) { position.scrollTo(x: x) } } else { position.scrollTo(x: x); placed = true }
    }
    var body: some View {
        let shown = lit()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    chip(id).onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("chiprow")).midX } action: { mids[id] = $0 }
                }
            }
            // Past the last chip, as much room as the fade takes, so the last chip lit can come clear of the fade too.
            .padding(.leading, Self.margin).padding(.trailing, max(Self.margin, (viewport * 0.14).rounded(.up) + 4))
            .coordinateSpace(.named("chiprow"))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { content = $0 }
        }
        .scrollPosition($position)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        .onChange(of: shown, initial: true) { follow() }
        // The first time, in place as soon as the chips are measured; after that only a change of page or width moves it.
        .onChange(of: mids) { if !placed { follow() } }
        .onChange(of: viewport) { follow() }
        // Scrolled, the chips leaving at the leading edge fade out as they do at the trailing one: a name cut hard there
        // read "gle TV" (CI 5fb9358).
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x > 6 } action: { _, now in withAnimation(Motion.quick) { scrolled = now } }
        .mask(LinearGradient(stops: [.init(color: scrolled ? .clear : .black, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
    }
}

// The Dashboard's tiles in even columns: three across when each would be at least 175 pt wide, else two. Every tile in a
// row is offered the row's height, laid out from the width alone. A last row that isn't full shares the whole width
// between its tiles, so a group of five or three never ends in a hole.
struct TileGrid: Layout {
    var spacing: CGFloat = 12
    static func columns(_ width: CGFloat) -> Int { width >= 175 * 3 + 12 * 2 ? 3 : 2 }
    struct Cache { var width: CGFloat = -1; var rows: [CGFloat] = [] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.width = -1 }
    // How many tiles are in the row a tile is in, and that row's tile width.
    private func span(_ i: Int, of count: Int, _ width: CGFloat) -> (Int, CGFloat) {
        let n = Self.columns(width)
        let inRow = i / n == (count - 1) / n ? count - (i / n) * n : n
        return (inRow, max((width - spacing * CGFloat(inRow - 1)) / CGFloat(inRow), 0))
    }
    private func rows(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> [CGFloat] {
        if cache.width == width { return cache.rows }
        let n = Self.columns(width)
        var r: [CGFloat] = []
        for (i, v) in subviews.enumerated() {
            let h = v.sizeThatFits(ProposedViewSize(width: span(i, of: subviews.count, width).1, height: nil)).height
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
        let n = Self.columns(bounds.width)
        var y = bounds.minY
        for (row, h) in r.enumerated() {
            for c in 0..<n {
                let i = row * n + c
                guard i < subviews.count else { break }
                let w = span(i, of: subviews.count, bounds.width).1
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (w + spacing), y: y), proposal: ProposedViewSize(width: w, height: h))
            }
            y += h + spacing
        }
    }
}
