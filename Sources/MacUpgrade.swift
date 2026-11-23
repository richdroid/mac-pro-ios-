import SwiftUI

// The macOS upgrade, from the phone (Richard, 2026-11-20: upgrade the Mac "and give me the ability to do all that and
// more from the mac pro app"). One upgrade told as steps, each with its real state, read from the Mac's own account of
// it (GET /api/mac/upgrade): room, the patcher, the download, the checks, the install, the patches after, everything up.
// Nothing here changes the Mac by itself. A clean-up asks the Mac first what it would remove (its dry run and one-time
// nonce, /api/mp) and runs only on his OK; the install needs his Mac password, sealed on the phone, and a held key.

struct UpgradeFeed: Decodable, Equatable {
    struct Target: Decodable, Equatable { var label: String?; var version: String; var size: String? }
    struct Cleanup: Decodable, Equatable, Identifiable { let id: String; let name: String; var why: String?; var bytes: Double? }
    struct Folder: Decodable, Equatable, Identifiable { let path: String; let name: String; var bytes: Double?; var id: String { path } }
    struct Patcher: Decodable, Equatable { var installed: String?; var latest: String?; var newer: Bool?; var ready: Bool? }
    struct Agent: Decodable, Equatable { var installed: Bool?; var status: String?; var attempts: Int?; var max: Int?; var blocked: Bool?; var shortRoom: Bool?; var lastTry: String? }
    struct Download: Decodable, Equatable { var percent: Double }
    struct Patches: Decodable, Equatable { var forBuild: String?; var thisBuild: String?; var ok: Bool? }
    var t: Double?
    var current: String
    var target: Target?
    var free: Double
    var total: Double?
    var required: Double?
    var want: Double
    var cleanups: [Cleanup]?
    var folders: [Folder]?
    var patcher: Patcher?
    var agent: Agent?
    var download: Download?
    var patches: Patches?
    // idle, room, held, ready, downloading, installing, patching, done
    var phase: String

    // Sizes as every other page of the app says them (Format.bytes), so this page, the Storage tile and Status agree on
    // the free space to the digit. The Mac's own update counts in thousands ("34.53 GB is required"), a little more.
    static func gb(_ b: Double) -> String { Format.bytes(b) }
    var name: String { target.map { "macOS \($0.version)" } ?? "macOS" }
    var short: Double { max(0, want - free) }
    // The clean-ups worth a row (50 MB or more: "0.0 GB" beside a live Remove key was a row for nothing).
    var shownCleanups: [Cleanup] { (cleanups ?? []).filter { ($0.bytes ?? 0) >= 50e6 } }
    // What the rows above free between them, added up as they are written, so the sum is the rows' own figures: the
    // exact total read "free 4.6 GB" under rows of 1.0 and 3.5 GB (gate 3, 2026-11-21), the left-out 7 MB and the
    // rounding between them.
    var safe: Double { shownCleanups.reduce(0) { $0 + Self.asShown($1.bytes ?? 0) } }
    static func asShown(_ b: Double) -> Double {
        let gib = 1_073_741_824.0, v = b / gib
        return (b < 17_179_869_184 ? (v * 10).rounded() / 10 : v.rounded()) * gib
    }
    // The version waiting, only while it isn't the one already running: patching after the install, the Mac is on it
    // and the page said "Waiting: macOS 26.7.3" under "Running: macOS 26.7.3" (gate 3).
    var waiting: Target? {
        guard let t = target, current.split(separator: " ").first.map(String.init) != t.version else { return nil }
        return t
    }
    // Something waiting or under way: the Dashboard shows its card.
    var pending: Bool { target != nil || ["downloading", "installing", "patching"].contains(phase) }
    var underWay: Bool { ["downloading", "installing", "patching"].contains(phase) }
    // The download in his terms: how much of how much, and how long is left (Richard, 2026-11-20: a useful update
    // screen). The size is the Mac's own ("12.4 GB", from softwareupdate), so the figures agree with it; the time left
    // is measured on the phone from how fast the percentage has moved.
    var downloadLine: String? {
        guard let d = download else { return nil }
        let p = min(100, max(0, d.percent))
        var parts: [String] = []
        if let s = target?.size, let r = s.range(of: #"^[\d.]+"#, options: .regularExpression), let total = Double(s[r]) {
            let unit = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
            parts.append(String(format: "%.1f of %@ %@", total * p / 100, String(s[r]), unit))
        } else {
            parts.append("\(Int(p.rounded()))% downloaded")
        }
        if let m = DownloadClock.shared.minutesLeft(p) { parts.append(m < 1 ? "under a minute left" : m < 60 ? "about \(m) min left" : "about \(m / 60) h \(m % 60) min left") }
        else if p < 100 { parts.append("time left after the next reading") }
        return parts.joined(separator: " · ")
    }
}

// How fast the download moves, from the readings the phone has seen: the percentage now against the earliest reading
// of the last ten minutes. Nothing is guessed before two readings a minute or more apart.
final class DownloadClock: @unchecked Sendable {
    static let shared = DownloadClock()
    private var seen: [(Date, Double)] = []
    func note(_ p: Double?) {
        guard let p else { seen = []; return }
        if let last = seen.last, last.1 == p { return }
        if let last = seen.last, p < last.1 { seen = [] }
        seen.append((Date(), p))
        seen.removeAll { Date().timeIntervalSince($0.0) > 600 }
    }
    func minutesLeft(_ p: Double) -> Int? {
        if MacConsole.pose == "upgrade-downloading" { return 18 }
        guard p < 100, let first = seen.first, let last = seen.last, last.1 > first.1 else { return nil }
        let secs = last.0.timeIntervalSince(first.0)
        guard secs >= 60 else { return nil }
        let rate = (last.1 - first.1) / secs
        return Int(((100 - p) / rate / 60).rounded(.up))
    }
}

// What the page says first, for the feed and for the Mac gone quiet in the middle of it.
struct UpgradeStanding: Equatable {
    var symbol: String, color: Color, title: String, line: String
    // What to do, in order, when there is something for his hands (the Mac not back): numbered under the line.
    var todo: [String] = []
    static func of(_ f: UpgradeFeed, away: Bool = false, awayMinutes: Int = 0) -> UpgradeStanding {
        let n = f.name
        if away, f.underWay || f.phase == "ready" {
            // The Mac restarts itself to install and again for its patches: about 40 minutes out of reach is the usual.
            if awayMinutes >= UpgradeView.backWithin {
                // Steps, not a paragraph: eight grey lines under the title were a wall to read in a hurry (gate 3).
                return UpgradeStanding(symbol: "exclamationmark.triangle.fill", color: .red, title: "The Mac hasn’t come back",
                                       line: "Quiet for \(awayMinutes) min while installing \(n). It is usually back within \(UpgradeView.backWithin).",
                                       todo: ["Look at its display: it may be waiting at a screen that needs a keyboard.",
                                              "Dark and staying dark: hold its power button for ten seconds.",
                                              "Then press the power button once to start it."])
            }
            return UpgradeStanding(symbol: "arrow.triangle.2.circlepath", color: macBlue, title: "The Mac is restarting",
                                   line: "Installing \(n). It restarts by itself, more than once, and is out of reach meanwhile: \(awayMinutes) min so far, usually back within \(UpgradeView.backWithin).")
        }
        switch f.phase {
        case "room":
            // What is wrong and what to do; the figures are step 1's, said once there (designer gate 1, 2026-11-20).
            var l = "Make room on the Mac’s disk first, then install."
            if f.agent?.blocked == true { l += " The nightly install has stopped trying after \(f.agent?.max ?? 4) failures; it starts again when you start it here." }
            else if f.agent?.shortRoom == true, let a = f.agent?.attempts, a > 0 { l += " The 3:30 AM install failed for this, \(a) of \(f.agent?.max ?? 4) tries." }
            return UpgradeStanding(symbol: "externaldrive.badge.exclamationmark", color: .orange, title: "Not enough room for \(n)", line: l)
        case "held":
            return UpgradeStanding(symbol: "hand.raised.fill", color: .orange, title: "\(n) waits for the patcher",
                                   line: "OpenCore Legacy Patcher doesn’t support \(n) yet. Installed now, the Mac would come back without its patches, so the upgrade stops here until the patcher does.")
        case "ready":
            let stopped = f.agent?.blocked == true ? " The nightly install has stopped trying; it starts again when you start it here." : ""
            return UpgradeStanding(symbol: "arrow.down.circle.fill", color: macBlue, title: "\(n) is ready to install", line: "There is room (\(UpgradeFeed.gb(f.free)) free) and the patcher supports it. It starts only when you hold the key below." + stopped)
        case "downloading":
            return UpgradeStanding(symbol: "arrow.down.circle", color: macBlue, title: "Downloading \(n)", line: (f.downloadLine.map { $0 + ". " } ?? "") + "The Mac installs and restarts by itself when it is done; nothing to do meanwhile.")
        case "installing":
            return UpgradeStanding(symbol: "gearshape.2.fill", color: macBlue, title: "Installing \(n)", line: "The Mac restarts by itself and is out of reach for a while.")
        case "patching":
            return UpgradeStanding(symbol: "bandage.fill", color: macBlue, title: "Patching after the restart", line: "The root patches are going back on. The Mac restarts once more if they need it.")
        case "done":
            return UpgradeStanding(symbol: "checkmark.seal.fill", color: .green, title: "Mac Pro is on \(f.current.split(separator: " ").first.map(String.init) ?? f.current)", line: "Up to date, patched, and everything checked.")
        default:
            return UpgradeStanding(symbol: "checkmark.circle", color: .secondary, title: "No macOS update waiting", line: "Running macOS \(f.current).")
        }
    }
}

extension UpgradeFeed {
    // The build's shots of every step (brief, pass criterion 21). Made-up names; the figures are the real case's.
    static func sample(_ phase: String) -> UpgradeFeed {
        UpgradeFeed(t: Date().timeIntervalSince1970 * 1000, current: "26.7.2 (25G332)", target: Target(label: "macOS Tahoe 26.7.3", version: "26.7.3", size: nil),
                    free: 28e9, total: 250.8e9, required: 34.53e9, want: 41e9,
                    cleanups: [Cleanup(id: "trash", name: "Trash", why: "Things you already threw away", bytes: 1.1e9), Cleanup(id: "caches", name: "App caches", why: "Apps rebuild these when they next run", bytes: 3.8e9), Cleanup(id: "old-logs", name: "Old logs", why: "Rotated logs and crash reports over two weeks old", bytes: 7e6)],
                    folders: [Folder(path: "/Users/you/Virtual Machines", name: "~/Virtual Machines", bytes: 69e9), Folder(path: "/Users/you/Library", name: "~/Library", bytes: 22e9), Folder(path: "/Users/you/code", name: "~/code", bytes: 21.5e9), Folder(path: "/Users/you/Applications", name: "~/Applications", bytes: 4.2e9), Folder(path: "/Users/you/Downloads", name: "~/Downloads", bytes: 1.6e9)],
                    patcher: Patcher(installed: "3.0.0", latest: "3.0.0", newer: false, ready: true),
                    agent: Agent(installed: true, status: "Update failed: not enough disk space", attempts: 2, max: 4, blocked: false, shortRoom: true, lastTry: "2026-11-20 03:30:04"),
                    download: nil, patches: Patches(forBuild: "25G332", thisBuild: "25G332", ok: true), phase: phase)
    }
    struct Posed { var feed: UpgradeFeed; var away = false; var awayMinutes = 0; var checksRed = false }
    static func posed(_ pose: String) -> Posed? {
        guard pose.hasPrefix("upgrade-") else { return nil }
        var f = sample("room")
        func roomy() { f.free = 46e9; f.agent?.shortRoom = false; f.agent?.status = "Waiting"; f.cleanups = f.cleanups?.map { Cleanup(id: $0.id, name: $0.name, why: $0.why, bytes: 0) } }
        switch pose {
        case "upgrade-room": return Posed(feed: f)
        case "upgrade-blocked": f.agent?.attempts = 4; f.agent?.blocked = true; return Posed(feed: f)
        case "upgrade-freed", "upgrade-checksgreen", "upgrade-hold": roomy(); f.phase = "ready"; return Posed(feed: f)
        case "upgrade-patcher": roomy(); f.phase = "ready"; f.patcher = Patcher(installed: "3.0.0", latest: "3.0.1", newer: true, ready: true); return Posed(feed: f)
        case "upgrade-held": roomy(); f.phase = "held"; f.patcher = Patcher(installed: "3.0.0", latest: "3.0.0", newer: false, ready: false); return Posed(feed: f)
        case "upgrade-checksred": roomy(); f.phase = "ready"; return Posed(feed: f, checksRed: true)
        case "upgrade-downloading": roomy(); f.phase = "downloading"; f.target?.size = "12.4 GB"; f.download = Download(percent: 35.4); return Posed(feed: f)
        case "upgrade-installing": roomy(); f.phase = "installing"; f.download = Download(percent: 100); return Posed(feed: f)
        case "upgrade-away": roomy(); f.phase = "installing"; return Posed(feed: f, away: true, awayMinutes: 12)
        case "upgrade-noreturn": roomy(); f.phase = "installing"; return Posed(feed: f, away: true, awayMinutes: 58)
        case "upgrade-patches": roomy(); f.phase = "patching"; f.current = "26.7.3 (25G342)"; f.patches = Patches(forBuild: "25G332", thisBuild: "25G342", ok: false); return Posed(feed: f)
        case "upgrade-done": roomy(); f.phase = "done"; f.current = "26.7.3 (25G342)"; f.target = nil; f.patches = Patches(forBuild: "25G342", thisBuild: "25G342", ok: true); return Posed(feed: f)
        default: return nil
        }
    }
    static func posedChecks(red: Bool) -> MacReport {
        let p: [(String, String, String)] = [("filevault", "ok", "Off; no password at boot"), ("autologin", "ok", "Logs in by itself"), ("tailscale", "ok", "Starts at login"),
                                             ("work", red ? "bad" : "ok", red ? "2 Claude sessions are mid-task: chumby, translator" : "Nothing long-running"), ("keep", "ok", "Scripts from /tmp kept")]
        return MacReport(ok: !red, at: Date().timeIntervalSince1970 * 1000, parts: p.map { MacPart(part: $0.0, state: $0.1, say: $0.2) })
    }
}

// The Dashboard's card for it: full width, whenever anything is pending. It says where the upgrade stands and opens
// the page; it does nothing itself.
struct UpgradeCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var feed = ConsoleSummary.shared.upgrade
    var body: some View {
        if let f = feed.value, f.pending {
            let st = UpgradeStanding.of(f, away: feed.away, awayMinutes: UpgradeView.minutesAway(feed.lastRead))
            Section {
                Button { model.macPage = .upgrade } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: st.symbol).font(.title2).foregroundStyle(st.color).symbolRenderingMode(.hierarchical).frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(st.title).font(.headline).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                                Text(st.line).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            RowChevron().padding(.top, 4)
                        }
                        if f.phase == "room" { RoomBar(free: f.free, want: f.want, caption: true) }
                        else if f.phase == "downloading", let d = f.download { ProgressView(value: min(100, max(0, d.percent)), total: 100).tint(macBlue) }
                        UpgradeDots(feed: f)
                    }
                    .multilineTextAlignment(.leading)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityIdentifier("upgrade.card")
                .onChange(of: f.download?.percent, initial: true) { _, p in DownloadClock.shared.note(p) }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
            } header: { Text("Upgrade") }
        }
    }
}

// Free against what the update wants: the bar fills to the mark as room is made.
struct RoomBar: View {
    let free: Double, want: Double
    // The figures under the bar, where nothing beside it says them (the Dashboard's card).
    var caption = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule().fill(free >= want ? Color.green : Color.orange).frame(width: g.size.width * min(1, max(0.02, free / max(want, 1))))
                }
            }
            .frame(height: 8)
            if caption { Text("\(UpgradeFeed.gb(free)) free of the \(UpgradeFeed.gb(want)) it needs · \(UpgradeFeed.gb(max(0, want - free))) short").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .accessibilityElement(children: .combine)
    }
}

enum StepState { case done, now, waiting, refused
    var symbol: String { switch self { case .done: "checkmark.circle.fill"; case .now: "arrow.right.circle.fill"; case .waiting: "circle"; case .refused: "xmark.octagon.fill" } }
    var color: Color { switch self { case .done: .green; case .now: macBlue; case .waiting: Color(white: 0.4); case .refused: .red } }
}

extension UpgradeFeed {
    // The seven steps' states, in order: room, patcher, download, checks, install, patches, everything up.
    func steps(checksRed: Bool = false, checked: Bool = false) -> [StepState] {
        let order = ["room", "held", "ready", "downloading", "installing", "patching", "done"]
        let at = order.firstIndex(of: phase) ?? -1
        if phase == "done" { return Array(repeating: .done, count: 7) }
        if phase == "idle" { return Array(repeating: .waiting, count: 7) }
        let room: StepState = free >= want || at >= 3 ? .done : .now
        let patcher: StepState = patcher?.ready == false ? .refused : room == .done ? .done : .waiting
        let download: StepState = at >= 4 ? .done : phase == "downloading" ? .now : .waiting
        let checks: StepState = at >= 3 ? .done : phase == "ready" ? (checksRed ? .refused : checked ? .done : .now) : .waiting
        let install: StepState = at >= 5 ? .done : phase == "installing" ? .now : phase == "ready" && checks == .done ? .now : .waiting
        let patch: StepState = phase == "patching" ? .now : .waiting
        return [room, patcher, download, checks, install, patch, .waiting]
    }
    static let stepNames = ["Room", "Patcher", "Download", "Checks", "Install", "Patches", "Everything up"]
}

// The seven steps as a row of lights, on the Dashboard's card.
struct UpgradeDots: View {
    let feed: UpgradeFeed
    var body: some View {
        let s = feed.steps()
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                Capsule().fill(s[i] == .waiting ? Color(white: 0.24) : s[i].color).frame(height: 5).frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \((s.firstIndex { $0 == .now || $0 == .refused } ?? 0) + 1) of 7")
    }
}

// A key that acts only when held for a moment and a half, filling as it is held: the one deliberate press an install
// and restart takes. Let go early and nothing happens.
struct HoldKey: View {
    let title: String
    let busy: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var holding = false
    static let seconds = 1.5
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(enabled ? Color.red.opacity(0.22) : Color(white: 0.17))
            GeometryReader { g in
                Rectangle().fill(Color.red).frame(width: holding ? g.size.width : 0)
                    .animation(holding ? .linear(duration: Self.seconds) : .easeOut(duration: 0.2), value: holding)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(.white) }
                Text(title).font(.body.weight(.semibold)).foregroundStyle(enabled ? Color.white : Color.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 52)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: Self.seconds, maximumDistance: 40) {
            holding = false; Haptic.fire(.done); action()
        } onPressingChanged: { p in holding = p && enabled && !busy }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Hold for a moment and a half")
        .accessibilityAction { action() }
        .accessibilityIdentifier("upgrade.hold")
    }
}

// One safe clean-up: what it is, how much it frees, and Remove. Remove asks the Mac what it would take away (a dry run,
// nothing changed), shows that as the question, and runs only on his OK with the Mac's one-time nonce.
struct CleanupRow: View {
    @Environment(\.paneLayout) private var panes
    let model: AppModel
    let item: UpgradeFeed.Cleanup
    let done: () -> Void
    @State private var busy = false
    @State private var asking: (say: String, nonce: String)?
    @State private var answer: MPEnvelope?
    @State private var failure: String?
    var empty: Bool { (item.bytes ?? 0) < 1e6 }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    if let w = item.why { Text(w).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Text(empty ? "Empty" : UpgradeFeed.gb(item.bytes ?? 0)).foregroundStyle(.secondary).monospacedDigit()
                // The key stays put while the Mac is asked, its wait drawn in its place, and the question hangs off
                // the key itself: hung off the row, its bubble pointed at the row's middle, not at Remove (gate 3).
                Button("Remove") { start() }.buttonStyle(.bordered).tint(.red).disabled(empty || busy)
                    .opacity(busy ? 0 : 1)
                    .overlay { if busy { ProgressView().controlSize(.small) } }
                    .frame(minWidth: 76, minHeight: 44)
                    .accessibilityIdentifier("cleanup." + item.id)
                    // Open flat the question opens to the key's left, in its own pane: the system's bubble, centred on the
                    // key, crossed the fold with its Remove on the hinge (gate 3 on dd63870, his size).
                    .popover(isPresented: .init(get: { panes && asking != nil }, set: { if !$0 { asking = nil } }), attachmentAnchor: .point(.leading), arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Remove \(item.name)?").font(.headline)
                            Text(asking.map { "This will " + MPActionRow.lowerFirst($0.say) } ?? "").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                Button("Cancel") { asking = nil }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                                Button("Remove", role: .destructive) { if let a = asking { asking = nil; run(a.nonce) } }
                                    .buttonStyle(.borderedProminent).tint(.red).frame(maxWidth: .infinity)
                                    .accessibilityIdentifier("cleanup.confirm")
                            }
                        }
                        .padding(16).frame(width: 250)
                        .presentationCompactAdaptation(.popover)
                    }
                    .confirmationDialog("Remove \(item.name)?", isPresented: .init(get: { !panes && asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible) {
                        if let a = asking {
                            Button("Remove", role: .destructive) { run(a.nonce) }
                            Button("Cancel", role: .cancel) {}
                        }
                    } message: { Text(asking.map { "This will " + MPActionRow.lowerFirst($0.say) } ?? "") }
            }
            if let a = answer {
                Label(a.say ?? (a.ok == true ? "Done" : "Not done"), systemImage: a.ok == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.footnote).foregroundStyle(a.ok == true ? Color.green : Color.red).fixedSize(horizontal: false, vertical: true)
            }
            if let failure { FailText(failure) }
        }
    }
    func start() {
        failure = nil; answer = nil; busy = true
        Task {
            // The key is live again before its question is asked: the question hangs off the key.
            defer { busy = false }
            if !model.pose.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000); busy = false; asking = ("Dry run: would remove \(UpgradeFeed.gb(item.bytes ?? 0)). Nothing was removed.", "posed"); return }
            do {
                let (e, n) = try await model.api.mp("clean", [item.id], dryRun: true)
                if e.ok == false || n == nil || !MPActionRow.wouldDo(e.say) { withAnimation(Motion.quick) { answer = e }; return }
                busy = false
                asking = (e.say ?? "remove it", n!)
            } catch { failure = MacFiles.unreachable(error) ? Phrase.macAway : error.localizedDescription }
        }
    }
    func run(_ nonce: String) {
        busy = true
        Task {
            defer { busy = false }
            if !model.pose.isEmpty { try? await Task.sleep(nanoseconds: 800_000_000); withAnimation(Motion.quick) { answer = MPEnvelope(ok: true, say: "Removed \(UpgradeFeed.gb(item.bytes ?? 0)).") }; return }
            do {
                let (e, _) = try await model.api.mp("clean", [item.id], confirm: true, nonce: nonce)
                withAnimation(Motion.quick) { answer = e }
                done()
            } catch {
                failure = "The Mac didn’t answer, so it’s not known whether that ran. The free space above will show."
                done()
            }
        }
    }
}

struct UpgradeView: View {
    let model: AppModel
    @Environment(\.paneLayout) private var panes
    @ObservedObject private var feed = ConsoleSummary.shared.upgrade
    @State private var fullLog = false
    @State private var checks: MacReport?
    @State private var checking = false
    @State private var password = ""
    @State private var sending = false
    @State private var started: String?
    @State private var failure: String?
    // Minutes: the Mac is usually back within this of going quiet to install.
    static let backWithin = 45
    static func minutesAway(_ lastRead: Date?) -> Int {
        if let p = UpgradeFeed.posed(MacConsole.pose) { return p.awayMinutes }
        return lastRead.map { max(0, Int(Date().timeIntervalSince($0)) / 60) } ?? 0
    }
    var posed: UpgradeFeed.Posed? { UpgradeFeed.posed(model.pose) }
    var away: Bool { posed?.away ?? feed.away }
    // The bridge's own rule (upgrade-go): any red check but the patches line, which is about this very update.
    var red: [MacPart] { checks?.parts.filter { $0.bad && $0.part != "oclp" } ?? [] }
    var publicLink: Bool { model.route == "public link" }

    func step(_ n: Int, _ state: StepState, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol).font(.title3).foregroundStyle(state.color).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n). \(UpgradeFeed.stepNames[n - 1])").font(.body.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(state == .refused ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // What holds a ready install, said at the top of the page in place of "ready to install … hold the key", which stood
    // over a red check (Fable gate on 9c093cb): the reason leads, once; the check's own row only names it.
    func held(_ f: UpgradeFeed) -> UpgradeStanding? {
        guard f.phase == "ready", !away, checks != nil, !checking else { return nil }
        if !red.isEmpty {
            return UpgradeStanding(symbol: "hand.raised.fill", color: .red, title: "Held by \(red.count == 1 ? "a check" : "\(red.count) checks")",
                                   line: red.map { MacParts.say($0, check: true) }.joined(separator: "; ") + ". It can start once that’s clear.")
        }
        if publicLink { return UpgradeStanding(symbol: "hand.raised.fill", color: .red, title: "Held: on the public link", line: "The install only starts over Tailscale.") }
        return nil
    }
    @ViewBuilder func standing(_ f: UpgradeFeed) -> some View {
        let st = held(f) ?? UpgradeStanding.of(f, away: away, awayMinutes: Self.minutesAway(feed.lastRead))
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: st.symbol).font(.system(size: 30)).foregroundStyle(st.color).symbolRenderingMode(.hierarchical).frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(st.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(st.line).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(st.todo.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1).").font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: 18, alignment: .leading)
                            Text(st.todo[i]).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                    // The download's bar under its figures, at the top of the page: open flat it is in the left pane,
                    // beside the steps, not only down in step 3.
                    if f.phase == "downloading", let d = f.download {
                        ProgressView(value: min(100, max(0, d.percent)), total: 100).tint(macBlue).padding(.top, 6)
                    }
                }
            }
            .padding(.vertical, 4)
            LabeledContent("Running", value: "macOS \(f.current)")
            if let t = f.waiting { LabeledContent("Waiting", value: t.label ?? "macOS \(t.version)") }
        }
    }

    func roomLine(_ f: UpgradeFeed, _ s: [StepState]) -> String {
        if f.phase == "done" { return "There was room." }
        return s[0] == .done ? "\(UpgradeFeed.gb(f.free)) free; the update needs about \(UpgradeFeed.gb(f.want))." : "It needs about \(UpgradeFeed.gb(f.want)) free. There are \(UpgradeFeed.gb(f.free)): \(UpgradeFeed.gb(f.short)) short."
    }
    // The Make room section is shown (else step 1 heads the steps, so the list never starts at 2).
    func showsRoom(_ f: UpgradeFeed) -> Bool { f.phase != "idle" && f.phase != "done" && !(away && f.underWay) }
    @ViewBuilder func room(_ f: UpgradeFeed, _ s: [StepState]) -> some View {
        Section {
            step(1, s[0], roomLine(f, s))
            if s[0] != .done {
                RoomBar(free: f.free, want: f.want).padding(.vertical, 4)
            }
            if s[0] != .done {
                // A clean-up with nothing worth taking (under 50 MB) is left out: "0.0 GB" beside a live Remove key.
                ForEach(f.shownCleanups) { c in CleanupRow(model: model, item: c) { Task { await feed.read(model.api, query: "?fresh=1") } } }
            }
        } header: { Text("Make room") } footer: {
            if s[0] != .done {
                // Plainly: the safe clean-ups alone may not be enough, and then how much more.
                let left = f.short - f.safe
                Text(left > 0 ? "These are safe to remove and free \(UpgradeFeed.gb(f.safe)) between them. That leaves \(UpgradeFeed.gb(left)) to find in the folders below. This step turns green by itself when there is room."
                              : "These are safe to remove and free \(UpgradeFeed.gb(f.safe)) between them, enough for the update. This step turns green by itself when there is room.")
            }
        }
        if s[0] != .done, let folders = f.folders, !folders.isEmpty {
            Section {
                ForEach(folders) { d in LabeledContent(d.name, value: d.bytes.map { UpgradeFeed.gb($0) } ?? "–").monospacedDigit() }
                Button { model.macPage = .storage } label: {
                    HStack { Text("Open Storage").foregroundStyle(macBlue); Spacer(minLength: 8); RowChevron() }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: { Text("What takes the space") } footer: {
                Text("Nothing in these is removed from here: what is safe to delete in them is yours to decide.")
            }
        }
    }

    func checkLine(_ s: StepState) -> String {
        if checking || (checks == nil && failure == nil && s != .waiting) { return "Checking…" }
        if s == .waiting { return "Run when there is room and the patcher supports it." }
        // Why is said at the top of the page; here only where.
        if !red.isEmpty { return "Held by the check in red below." }
        if publicLink { return "Held: it only starts over Tailscale." }
        return checks == nil ? "Not checked: the Mac didn’t answer." : "Nothing in the way."
    }

    @ViewBuilder func rest(_ f: UpgradeFeed, _ s: [StepState]) -> some View {
        Section {
            // Step 1 here when Make room isn't on the page (done, or the Mac away mid-install): the steps started at 2.
            if !showsRoom(f) { step(1, s[0], roomLine(f, s)) }
            step(2, s[1], patcherLine(f))
            if f.patcher?.newer == true, f.phase == "ready" || f.phase == "room" || f.phase == "held" {
                // The patcher updates in its own app on the Mac: the Mac's screen, from here, is where to do it.
                Button { model.openScreen() } label: {
                    HStack { Label("Update the patcher on the Mac’s screen", systemImage: "display").foregroundStyle(macBlue); Spacer(minLength: 8); RowChevron() }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 40)
                .accessibilityIdentifier("upgrade.patcherScreen")
            }
            // Its figures and bar are at the top of the page while it runs: said once.
            step(3, s[2], f.phase == "downloading" ? "Under way; how far it has got is at the top." : s[2] == .done ? "Downloaded." : "Starts with the install; the Mac fetches it itself\(f.target?.size.map { " (\($0))" } ?? "").")
            step(4, s[3], checkLine(s[3]))
            if s[3] != .waiting, let c = checks {
                ForEach(c.parts.filter { $0.part != "oclp" && $0.part != "updates" && $0.part != "restart" }) { p in
                    // One short line a check, never wrapped: a pass says what is so ("Signs in by itself"), a red one names
                    // the check (its reason leads the page). Name and state side by side said the same thing twice and
                    // broke into three lines at his size open flat (Fable gate on 9c093cb).
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(p.bad ? Color.red : Color.green).frame(width: 8, height: 8)
                        Text(p.bad ? MacParts.name(p.part, check: true) : (MacParts.passed(p.part) ?? MacParts.name(p.part, check: true)))
                            .font(.subheadline).foregroundStyle(p.bad ? Color.red : Color.primary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 40)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(p.bad ? MacParts.say(p, check: true) : "")
                }
                if !red.isEmpty { Button { Task { await check() } } label: { Label("Check again", systemImage: "arrow.clockwise") }.disabled(checking) }
            }
        } header: { Text("Before installing") }
        Section {
            step(5, s[4], s[4] == .done ? "Installed." : f.phase == "installing" ? "Under way. The Mac restarts by itself." : "Starts with your Mac password and a held key. The Mac downloads, installs and restarts by itself.")
            if f.phase == "ready" || f.phase == "room" || f.phase == "held" { install(f, s) }
            step(6, s[5], f.phase == "patching" ? "Root patches going back on\(f.patches?.thisBuild.map { " for build \($0)" } ?? ""). A second restart if they need it." : f.phase == "done" ? "Root patches on for this build." : "After the restart the root patches go back on, with a second restart if they need it.")
            step(7, s[6], f.phase == "done" ? "Every part checked and running." : "Then every part of the Mac is checked and brought up, each by name.")
            if f.underWay || f.phase == "done" {
                Button { model.macPage = .health } label: {
                    HStack { Text("Everything on the Mac").foregroundStyle(macBlue); Spacer(minLength: 8); RowChevron() }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: { Text("Install") } footer: {
            if f.phase == "ready" || f.phase == "room" || f.phase == "held" { Text("Never automatic from here: nothing installs until you hold the key. Your password is sealed on this iPhone, used once on the Mac and forgotten.") }
        }
    }
    func patcherLine(_ f: UpgradeFeed) -> String {
        let p = f.patcher
        let has = p?.installed.map { "OpenCore Legacy Patcher \($0) is installed" } ?? "The patcher’s version isn’t known"
        if p?.ready == false { return "\(has) and doesn’t support \(f.name) yet. The upgrade is refused here until it does." }
        if p?.newer == true, let l = p?.latest { return "\(has); \(l) is out. It supports \(f.name) as it is. Updating it is optional: open OpenCore-Patcher on the Mac’s screen." }
        return "\(has) and supports \(f.name)."
    }
    // Why the key is off, in the order to fix them; nil when it can be held.
    func waitsFor(_ f: UpgradeFeed) -> String? {
        if f.phase == "room" { return "Waits for room: \(UpgradeFeed.gb(f.short)) more." }
        if f.phase == "held" { return "Waits for the patcher to support \(f.name)." }
        if publicLink { return "Only over Tailscale, never the public link." }
        if checking || checks == nil { return checking ? "Waits for the checks." : "Waits for the checks: the Mac didn’t answer." }
        if !red.isEmpty { return "Waits for the red check\(red.count == 1 ? "" : "s") above." }
        // (The build's shots can't type; their posed key is ready without it and reaches no Mac.)
        if password.isEmpty, model.pose.isEmpty { return "Waits for your Mac password." }
        return nil
    }
    @ViewBuilder func install(_ f: UpgradeFeed, _ s: [StepState]) -> some View {
        let waits = waitsFor(f)
        if let started { Label(started, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true) }
        else {
            SecureField("Mac password", text: $password).textContentType(.oneTimeCode).autocorrectionDisabled().submitLabel(.done)
                .disabled(f.phase != "ready")
            HoldKey(title: "Hold to install and restart", busy: sending) { go() }
                .disabled(waits != nil || sending)
                .listRowSeparator(.hidden)
            if let waits { Text(waits).font(.footnote).foregroundStyle(.secondary) }
            if let failure { FailText(failure) }
        }
    }

    func check() async {
        if let p = posed { checks = UpgradeFeed.posedChecks(red: p.checksRed); return }
        checking = true; defer { checking = false }
        checks = try? await model.api.macChecks()
    }
    func go() {
        let p = password; password = ""
        guard !p.isEmpty || !model.pose.isEmpty, !sending else { return }
        sending = true; failure = nil
        Task {
            defer { sending = false }
            // The build's shots never reach a Mac.
            if !model.pose.isEmpty { try? await Task.sleep(nanoseconds: 800_000_000); started = "Started. The Mac downloads the update, then restarts by itself."; return }
            if let e = await model.runSealed("upgrade-go", secret: p, extra: ["confirm": true]) { failure = e }
            else { started = "Started. The Mac downloads the update, then restarts by itself."; await feed.read(model.api, query: "?fresh=1") }
        }
    }

    var body: some View {
        let f = feed.value
        ConsolePage(title: "Upgrade", place: "macupgrade", away: false, lastRead: feed.lastRead) {
            if let f {
                let s = f.steps(checksRed: !red.isEmpty || publicLink, checked: checks != nil && !checking)
                if !(panes && fullLog) {
                    standing(f)
                    if showsRoom(f) { room(f, s) }
                }
            } else if feed.unsupported {
                Section { Text("The Mac’s bridge doesn’t report upgrades yet. It does after its next restart.").foregroundStyle(.secondary) }
            } else {
                Section { HStack { ProgressView(); Text("Asking the Mac where the upgrade stands…").foregroundStyle(.secondary) } }
            }
            // Open flat the log fills the left pane under where the upgrade stands, beside the steps: the left pane was
            // half empty (gate 3). In one column it stays at the foot, after the steps. Show all, open flat, opens the
            // whole log in this pane, the steps staying beside it.
            if panes { UpgradeLog(store: model.statusStore, full: $fullLog, whole: fullLog) }
        } right: {
            if let f, f.phase != "idle" {
                rest(f, f.steps(checksRed: !red.isEmpty || publicLink, checked: checks != nil && !checking))
                    .disabled(away)
            }
            if !panes { UpgradeLog(store: model.statusStore, full: $fullLog) }
        }
        // The whole log in one column: a page pushed from this one, with the system's Back (from the page, not from a
        // row of its list, which went with the row when the list let it go: gate 3).
        .navigationDestination(isPresented: Binding(get: { fullLog && !panes }, set: { if !$0 { fullLog = false } })) {
            LogPage(log: model.statusStore.status?.upgrade.log ?? "").railRoom(listMargin: 20)
        }
        .onChange(of: feed.value?.download?.percent, initial: true) { _, p in DownloadClock.shared.note(p) }
        .task {
            if let p = posed { feed.set(p.feed); await check(); return }
            while !Task.isCancelled {
                if !model.screenOpen { await feed.read(model.api) }
                if checks == nil, feed.value?.phase == "ready" { await check() }
                try? await Task.sleep(nanoseconds: UInt64((feed.value?.underWay == true ? 5 : 15) * 1e9))
            }
        }
    }
}

// The update service's own log on the page (Richard, 2026-11-20: "have a good and useful update screen" with the log in
// the app): its newest lines, whole, and a tap for all of it full screen. The same log as the Updates page's, read from
// the Mac's status as it lands; while the Mac is restarting it is the last one it gave.
struct UpgradeLog: View {
    // Read straight from the status as it lands, not copied in from inside the section's header: a header the list
    // hadn't drawn yet never copied it, and the row stood empty (gate 3, "the Log row is blank").
    @ObservedObject var store: StatusStore
    @Binding var full: Bool
    // Open flat with Show all pressed: every line, in this pane, as tall as the pane allows.
    var whole = false
    // The newest lines, drawn plainly: the Updates page's LogPreview parks the lines that don't fit 5000 pt above
    // itself, which inside a List row left the row, and at the page's foot the whole page, blank (CI 017ec21).
    static let shown = 12
    var log: String { store.status?.upgrade.log.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    static func lines(_ log: String) -> [String] { Array(log.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(LogPreview.short).suffix(shown)) }
    var body: some View {
        let log = self.log
        Section {
            if log.isEmpty {
                Text("The Mac hasn’t sent its update log yet.").foregroundStyle(.secondary)
            } else if whole {
                UpdateLog(log: log, fills: true)
                    .containerRelativeFrame(.vertical) { h, _ in max(h - 150, 240) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("upgrade.log")
            } else {
                let all = Self.lines(log)
                VStack(alignment: .leading, spacing: LogPreview.gap) {
                    ForEach(all.indices, id: \.self) { i in
                        Text(all[i]).font(.system(.footnote, design: .monospaced)).foregroundStyle(UpdateLog.tone(all[i]))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { full = true }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Update log, newest lines").accessibilityHint("Opens the whole log").accessibilityAddTraits(.isButton)
                .accessibilityAction { full = true }
                .accessibilityIdentifier("upgrade.log")
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Log")
                Spacer()
                if !log.isEmpty { Button(whole ? "Fewer" : "Show all") { full.toggle() }.textCase(nil).foregroundStyle(macBlue).accessibilityIdentifier("upgrade.logAll") }
            }
        } footer: { if !log.isEmpty, !whole { Text("The update service’s own lines, newest at the foot; tap for all of them. Red is a failure, green a step done.") } }
    }
}
