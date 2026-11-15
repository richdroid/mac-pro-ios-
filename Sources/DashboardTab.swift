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
    @Environment(\.horizontalSizeClass) private var size
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
            case .left: screenCard; tiles
            case .right: showOnMac
            }
        }
        .task(id: side) { if side != .right { await remote.loop(model) } }
        .task { if model.pose.isEmpty { await ConsoleSummary.shared.readAll(model.api) } }
    }

    // MARK: The Mac's screen

    var screenCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    let (name, symbol) = running ? ConsolePlace.name(st!) : ("Not open", "moon.zzz")
                    Image(systemName: symbol).font(.title3).foregroundStyle(running ? macBlue : .secondary)
                        .frame(width: 44, height: 44).background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On the Mac’s screen").font(.footnote).foregroundStyle(.secondary)
                        Text(remote.read ? name : " ").font(.headline).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if running, st?.display == "asleep" {
                        Text("Display asleep").font(.footnote).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
                HStack(spacing: 10) {
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
                .disabled(remote.busy != nil || remote.unsupported)
                if let f = remote.fail, ["show", "hide", "display", "glance"].contains(where: { f.key.hasPrefix($0) }) { FailText(f.text) }
            }
            .padding(16)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 20)
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
            .sensoryFeedback(.impact(weight: .light), trigger: busy) { _, now in now }
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    // MARK: The tiles, as on the Console's Home

    struct TileData: Identifiable {
        let id: String, title: String, symbol: String
        var figure: String?, line: String?, good: Bool? = nil
        let page: String?          // the Console page it puts on the Mac's screen, held
        let open: () -> Void
    }
    var tileData: [TileData] {
        let cpu = store.live?.cpu ?? s.cpu, mem = store.live?.mem ?? s.mem, net = store.live?.net ?? s.net
        let temps = store.live?.temps ?? s.temps ?? []
        let hottest = s.heat?.hottest ?? temps.max { $0.c < $1.c }
        let memPct = mem.total > 0 ? Int((mem.used / mem.total * 100).rounded()) : 0
        let top = s.procs.max { $0.cpu < $1.cpu }
        let bad = s.healthBad
        var t: [TileData] = [
            TileData(id: "mac", title: "Mac Pro", symbol: "gauge.with.dots.needle.67percent", figure: "\(cpu.total)%", line: "CPU · memory \(memPct)%", page: "overview") { model.history = .cpu },
            TileData(id: "temps", title: "Temperatures", symbol: "thermometer.medium", figure: hottest.map { MacConsole.degrees($0.c) }, line: hottest.map { "\($0.name), the hottest" }, page: "temps") { model.macPage = .fans },
            TileData(id: "everything", title: "Everything", symbol: "checklist", figure: bad.map { $0 == 0 ? "All well" : "\($0)" }, line: bad.map { $0 == 0 ? "Every part answering" : $0 == 1 ? "part needs a look" : "parts need a look" }, good: bad.map { $0 == 0 }, page: "everything") { model.macPage = .health },
            TileData(id: "activity", title: "Network", symbol: "arrow.up.arrow.down", figure: Format.rate(net.rxRate), line: "down · up \(Format.rate(net.txRate))", page: "activity") { model.history = .download },
            TileData(id: "processes", title: "Processes", symbol: "cpu", figure: top.map { "\(Int($0.cpu.rounded()))%" }, line: top?.name, page: "processes") { model.processes = .cpu },
            TileData(id: "storage", title: "Storage", symbol: "internaldrive", figure: Format.bytes(s.disk.free), line: "free of \(Format.bytes(s.disk.total))", page: "storage") { model.macPage = .storage },
        ]
        if let l = links.value { let x = MacConsole.linkSummary(l); t.append(TileData(id: "links", title: "Connections", symbol: "point.3.connected.trianglepath.dotted", figure: x.good ? "All up" : "Look", line: x.text, good: x.good, page: nil) { model.macPage = .links }) }
        if let u = updates.value {
            let waiting = (u.macos.pending ?? []).count + (u.brew?.outdated ?? []).count
            t.append(TileData(id: "updates", title: "Updates", symbol: "arrow.down.circle", figure: u.macos.pending == nil ? nil : waiting == 0 ? "Up to date" : "\(waiting)", line: waiting == 0 ? "macOS \(u.macos.current.split(separator: " ").first ?? "")" : waiting == 1 ? "waiting" : "waiting", page: "updates") { model.macPage = .updates })
        }
        if let items = startup.value?.items {
            let stopped = StartupView.stopped(items.filter(\.mine)).count
            t.append(TileData(id: "startup", title: "Startup", symbol: "power", figure: stopped == 0 ? "All running" : "\(stopped)", line: stopped == 0 ? "\(items.filter(\.mine).count) of his own" : "stopped", good: stopped == 0, page: "startup") { model.macPage = .startup })
        }
        if let w = s.usage.plan?.sevenDay {
            t.append(TileData(id: "claude", title: "Claude", symbol: "sparkle", figure: "\(Int(w.rounded()))%", line: "of the week · \(s.claude.sessions.count) sessions", good: w < 90, page: nil) { model.tab = 2 })
        }
        return t
    }

    var tiles: some View {
        Section {
            let cols = size == .regular ? 3 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols), spacing: 12) {
                ForEach(tileData) { d in tile(d) }
            }
            .opacity(model.stale ? staleDim : 1)
            .padding(.horizontal, 20)
        } header: { Text("The Mac").padding(.leading, 20) }
        .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
    }

    func tile(_ d: TileData) -> some View {
        Button(action: d.open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: d.symbol).font(.footnote.weight(.semibold)).foregroundStyle(macBlue)
                    Text(d.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    // This page is the one on the Mac's screen now.
                    if let p = d.page, p == onMac { Image(systemName: "macwindow").font(.caption.weight(.semibold)).foregroundStyle(macBlue).accessibilityLabel("On the Mac’s screen") }
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let g = d.good, !g { Circle().fill(Color.orange).frame(width: 8, height: 8) }
                    Text(d.figure ?? "–").font(.system(size: 28, weight: .light)).monospacedDigit().foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                }
                Text(d.line ?? " ").font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .contextMenu {
            if let p = d.page {
                Button { remote.send(model, "page:" + p, "page", p) } label: { Label("Show on the Mac", systemImage: "arrow.up.forward.app") }
            }
        }
    }

    // MARK: For the Mac's screen: boards and pages

    func chip(_ name: String, _ symbol: String, on: Bool, busy: Bool, action: @escaping () -> Void) -> some View {
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
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    var showOnMac: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Boards").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ConsolePlace.boards, id: \.id) { b in
                            let on = running && st?.board == b.id
                            chip(b.name, b.symbol, on: on, busy: remote.busy == "board:" + b.id) { remote.send(model, "board:" + (on ? "off" : b.id), "board", on ? "off" : b.id) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                Text("Pages").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ConsolePlace.pages, id: \.id) { p in
                            chip(p.name, p.symbol, on: onMac == p.id, busy: remote.busy == "page:" + p.id) { remote.send(model, "page:" + p.id, "page", p.id) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                VStack(spacing: 0) {
                    Toggle(isOn: Binding(get: { st?.rotate == true }, set: { on in remote.send(model, "rotate", "rotate", on ? "on" : "off") })) {
                        Text("Boards take turns")
                    }
                    .tint(macBlue).padding(.vertical, 10)
                    Divider()
                    HStack {
                        Text("Animations")
                        Spacer(minLength: 12)
                        Picker("Animations", selection: Binding(get: { st?.animations ?? "full" }, set: { remote.send(model, "animations", "animations", $0) })) {
                            Text("Full").tag("full"); Text("Gentle").tag("gentle"); Text("Off").tag("off")
                        }
                        .pickerStyle(.segmented).fixedSize()
                    }
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 16)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 20).padding(.top, 4)
                if let f = remote.fail, ["board", "page", "rotate", "animations"].contains(where: { f.key.hasPrefix($0) }) { FailText(f.text).padding(.horizontal, 20) }
            }
            .disabled(!running || remote.busy != nil)
            .opacity(running ? 1 : 0.4)
        } header: { Text("For the Mac’s screen").padding(.leading, 20) }
        .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
    }
}
