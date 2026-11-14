import SwiftUI

// Restart the Mac and get everything up (Richard, 2026-11-10: "build tools for restarting and getting everything up both
// from mac and mac pro app side"). Two pushed pages on the Control tab: "Everything on the Mac", each part by name with
// its state and a Fix only when something fixable is red; and "Restart the Mac", its checks first, refusing while any is
// red, then the same parts coming back one by one. Never one spinner that hides which part is stuck.

enum MacPage: String, Identifiable, Hashable { case health, restart, links, fans, updates, storage, startup, actions; var id: String { rawValue } }

// One part, as the Mac's scripts report it: state ok, fixed or bad, and what it means.
struct MacPart: Decodable, Identifiable, Hashable {
    let part: String
    let state: String
    let say: String
    var id: String { part }
    var bad: Bool { state == "bad" }
}
struct MacReport: Decodable, Equatable {
    let ok: Bool
    let at: Double
    let parts: [MacPart]
}

enum MacParts {
    // The health check's parts, in the order the Mac reports them, by the names he'd use.
    static let health = ["tailscale", "serve", "bridge", "sessions", "tv", "letterboxd", "chumby", "oclp", "stuck", "memory"]
    static let checks = ["oclp", "updates", "filevault", "autologin", "tailscale", "work", "keep"]
    // The ones the Mac can bring back itself (mac-bringup.sh); the rest need a hand, and say what to do.
    static let fixable: Set<String> = ["tailscale", "bridge", "sessions", "tv", "letterboxd"]
    static func name(_ p: String, check: Bool = false) -> String {
        if check {
            switch p {
            case "oclp": return "macOS patches"
            case "updates": return "Automatic macOS updates"
            case "filevault": return "FileVault"
            case "autologin": return "Signs in by itself"
            case "tailscale": return "Remote access at login"
            case "work": return "Work in progress"
            case "keep": return "Temporary files saved"
            default: break
            }
        }
        switch p {
        case "tailscale": return "Remote access"
        case "serve": return "Remote access"
        case "bridge": return "Mac dashboard"
        case "sessions": return "Claude sessions"
        case "tv": return "TV"
        case "letterboxd": return "Letterboxd sign-in"
        case "chumby": return "Chumby"
        case "oclp": return "macOS patches"
        case "stuck": return "Programs"
        case "memory": return "Memory"
        default: return p.prefix(1).uppercased() + p.dropFirst()
        }
    }
    // A check that passed, said as one line.
    static func passed(_ p: String) -> String? {
        switch p {
        case "oclp": return "macOS patches healthy"
        case "updates": return "No macOS update will install"
        case "filevault": return "No password at startup"
        case "autologin": return "Signs in by itself"
        case "tailscale": return "Remote access starts at login"
        case "work": return "Nothing long-running"
        case "keep": return "Temporary files kept"
        default: return nil
        }
    }
    static func symbol(_ p: String) -> String {
        switch p {
        case "tailscale": return "network"
        case "serve": return "link"
        case "bridge": return "point.3.connected.trianglepath.dotted"
        case "sessions": return "terminal"
        case "tv": return "tv"
        case "letterboxd": return "film"
        case "chumby": return "alarm"
        case "oclp": return "wrench.and.screwdriver"
        case "stuck": return "hourglass"
        case "memory": return "memorychip"
        case "updates": return "arrow.down.circle"
        case "filevault": return "lock"
        case "autologin": return "person.crop.circle"
        case "work": return "gearshape.2"
        case "keep": return "tray.full"
        default: return "circle"
        }
    }
    // The Mac's words for a part, in his: no capitals shouting, no paths or internal names, nothing the hint below repeats.
    static func say(_ p: MacPart, check: Bool = false) -> String {
        var t = p.say
        if hand(p.part, check: check) != nil, let open = t.range(of: " (") { t = String(t[..<open.lowerBound]) }
        if !check {
            switch (p.part, p.bad) {
            case ("serve", false): return "Lets this app reach the Mac"
            case ("serve", true): return "This app’s link isn’t set up"
            case ("stuck", true):
                // "2 programs stuck; a restart clears them": the hint under it says the second half.
                if let semi = t.range(of: "; ") { return String(t[..<semi.lowerBound]) }
            case ("oclp", _):
                if t.hasPrefix("HEALTHY: ") { t = "Healthy: " + t.dropFirst(9) }
            default: break
            }
        } else if p.part == "keep", !p.bad { return "Saved, so nothing is lost in the restart" }
        else if p.part == "oclp", t.hasPrefix("OCLP isn’t healthy: ") || t.hasPrefix("OCLP isn't healthy: ") { t = "Not healthy" }
        return t
    }
    // What his hands would do, for a red part the Mac can't fix by itself.
    static func hand(_ p: String, check: Bool = false) -> String? {
        if check {
            switch p {
            case "oclp": return "Re-apply the root patches in OpenCore Legacy Patcher, then check again."
            case "updates": return "On the Mac, turn off Install macOS updates in Software Update’s Automatic Updates."
            case "filevault": return "Turn FileVault off in Privacy & Security, or the Mac stops at a password after the restart."
            case "autologin": return "Turn on automatic login in Users & Groups."
            case "tailscale": return "In Tailscale’s settings on the Mac, turn on Launch at login."
            case "work": return "Wait for it to finish, then check again."
            default: return nil
            }
        }
        switch p {
        case "serve": return "Ask a Claude session on the Mac to turn this app’s link back on."
        case "chumby": return "Check the Chumby is on and on Wi-Fi."
        case "oclp": return "Re-apply the root patches in OpenCore Legacy Patcher."
        case "stuck": return "Restarting the Mac clears this."
        case "memory": return "Quit something large, or restart the Mac."
        default: return nil
        }
    }
}

extension API {
    private func macRequest(_ path: String, post: Bool = false, timeout: TimeInterval = 20) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if post {
            r.httpMethod = "POST"
            r.setValue(MacFiles.origin(base), forHTTPHeaderField: "Origin")
            r.setValue("1", forHTTPHeaderField: "x-dash")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }
    private func report(_ r: URLRequest, accept: Set<Int> = [200]) async throws -> (MacReport, Int) {
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard accept.contains(code) else { throw SendError.say(MacFiles.reason(code, d)) }
        return (try JSONDecoder().decode(MacReport.self, from: d), code)
    }
    func macHealth(fresh: Bool = false) async throws -> MacReport { try await report(macRequest("/api/mac/health" + (fresh ? "?fresh" : ""), timeout: 30)).0 }
    func macChecks() async throws -> MacReport { try await report(macRequest("/api/mac/prerestart", timeout: 60)).0 }
    // Up to about two minutes: each part the Mac can bring back, brought back.
    func macBringUp() async throws -> MacReport { try await report(macRequest("/api/mac/bringup", post: true, timeout: 180)).0 }
    // True when it's restarting; the checks, when it refused (something red).
    func macRestart() async throws -> (Bool, MacReport) {
        var r = macRequest("/api/mac/restart", post: true, timeout: 60)
        r.httpBody = Data(#"{"confirm":true}"#.utf8)
        let (rep, code) = try await report(r, accept: [200, 409])
        return (code == 200, rep)
    }
}

// A restart asked for from here, kept across leaving the page and the app being closed, so coming back finds the
// bring-up where it was.
@MainActor
final class RestartWatch: ObservableObject {
    static let shared = RestartWatch()
    @Published var askedAt: Date? { didSet { save() } }
    @Published var wentAway = false { didSet { save() } }
    @Published var backAt: Date?
    // The restart was sent but the Mac's answer never arrived (a timeout, the link dropping): it may be restarting.
    @Published var unconfirmed = false
    // An old restart is over, whatever happened.
    static let longest: TimeInterval = 30 * 60
    private init() {
        let d = UserDefaults.standard
        askedAt = d.object(forKey: "restartAskedAt") as? Date
        wentAway = d.bool(forKey: "restartWentAway")
        expire()
        // The build's shots start clean, apart from the one of a restart under way.
        if let pose = d.string(forKey: "pose"), !pose.isEmpty, pose != "healthback", pose != "healthstuck", pose != "didntconfirm" { askedAt = nil; wentAway = false }
    }
    // The build's poses set a restart up for one shot; it isn't kept for the next launch.
    private var posed: Bool { !(UserDefaults.standard.string(forKey: "pose") ?? "").isEmpty }
    private func save() {
        if posed { return }
        UserDefaults.standard.set(askedAt, forKey: "restartAskedAt")
        UserDefaults.standard.set(wentAway, forKey: "restartWentAway")
    }
    var active: Bool { askedAt != nil }
    func asked(confirmed: Bool = true) { askedAt = Date(); wentAway = false; backAt = nil; unconfirmed = !confirmed }
    func done() { askedAt = nil; wentAway = false; unconfirmed = false }
    // Checked at launch and every time the Mac fails to answer, so a page left open doesn't wait for ever either.
    func expire() { if let a = askedAt, Date().timeIntervalSince(a) > Self.longest { done() } }
    // Gone for over ten minutes (a minute's notice, then ten): it's not coming back by itself.
    func stuck(_ now: Date) -> Bool { wentAway && backAt == nil && askedAt.map { now.timeIntervalSince($0) > 660 } == true }
}

// The Mac's parts as he knows them, one line each on Everything. Its own ids (tailscale, serve, bridge…) stay in here:
// Remote access is Tailscale and the link that points this app at the Mac, together.
struct MacGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let parts: [String]
    let about: String
    static let known: [MacGroup] = [
        MacGroup(id: "remote", name: "Remote access", symbol: "network", parts: ["tailscale", "serve"], about: "Lets this iPhone reach the Mac from anywhere."),
        MacGroup(id: "bridge", name: "Mac dashboard", symbol: "gauge.with.dots.needle.33percent", parts: ["bridge"], about: "What this app talks to on the Mac."),
        MacGroup(id: "sessions", name: "Claude sessions", symbol: "terminal", parts: ["sessions"], about: "The Claude sessions the Mac keeps running."),
        MacGroup(id: "tv", name: "TV", symbol: "tv", parts: ["tv"], about: "The Mac’s link to the Google TV, for the remote and sending things to it."),
        MacGroup(id: "chumby", name: "Chumby", symbol: "alarm", parts: ["chumby"], about: "The alarm clock by the bed."),
        MacGroup(id: "letterboxd", name: "Letterboxd sign-in", symbol: "film", parts: ["letterboxd"], about: "Signs Letterboxd on the TV in through the Mac."),
        MacGroup(id: "oclp", name: "macOS patches", symbol: "wrench.and.screwdriver", parts: ["oclp"], about: "The patches that let macOS Tahoe run on this Mac Pro."),
        MacGroup(id: "stuck", name: "Programs", symbol: "hourglass", parts: ["stuck"], about: "Programs on the Mac that have stopped answering."),
        MacGroup(id: "memory", name: "Memory", symbol: "memorychip", parts: ["memory"], about: "How hard the Mac’s memory is working."),
    ]
    // In the Mac's order; a part this app doesn't know yet gets a line of its own.
    static func groups(for ids: [String]) -> [MacGroup] {
        var out: [MacGroup] = []
        for id in ids {
            if let g = known.first(where: { $0.parts.contains(id) }) { if !out.contains(g) { out.append(g) } }
            else { out.append(MacGroup(id: id, name: MacParts.name(id), symbol: MacParts.symbol(id), parts: [id], about: "")) }
        }
        return out
    }
    // "1 program stuck: Safari; a restart clears it" → "Safari isn't responding". The Mac names them since 2026-11-13;
    // an older Mac only counts them.
    static func stuckLine(_ t: String) -> String {
        let head = t.components(separatedBy: ";").first ?? t
        if let c = head.range(of: ": ") {
            let names = head[c.upperBound...].components(separatedBy: ", ").filter { !$0.isEmpty }
            if names.count == 1 { return "\(names[0]) isn’t responding" }
            if let last = names.last, names.count > 1 { return names.dropLast().joined(separator: ", ") + " and \(last) aren’t responding" }
        }
        return head.replacingOccurrences(of: "stuck", with: "not responding")
    }
    // What the Fix button does for a part, said on the button.
    static func fixLabel(_ part: String) -> String {
        switch part {
        case "tailscale": return "Start remote access"
        case "bridge": return "Restart the Mac dashboard"
        case "sessions": return "Start the Claude sessions"
        case "tv": return "Reconnect the TV"
        case "letterboxd": return "Restart Letterboxd sign-in"
        default: return "Fix"
        }
    }
    // The Connections rows behind a part, whose facts fill its card open (designer gate, 2026-11-13: the card said only
    // what the part is, again, over half a pane of nothing).
    var links: [String] {
        switch id {
        case "remote": return ["tailscale", "serve", "funnel"]
        case "bridge": return ["bridge", "public", "novnc"]
        case "tv": return ["tv"]
        case "letterboxd": return ["letterboxd"]
        case "chumby": return ["chumby", "chumby-remote"]
        case "sessions": return ["sessions"]
        default: return []
        }
    }
    // How a part stands, in his words.
    static func human(_ g: MacGroup, _ p: MacPart) -> String {
        let t = p.say
        if p.bad {
            switch p.part {
            case "tailscale": return "Tailscale is off on the Mac"
            case "serve": return "The Mac’s link for this app is off"
            case "bridge": return "Not answering"
            case "stuck": return stuckLine(t)
            default: return MacParts.say(p)
            }
        }
        switch p.part {
        case "tailscale", "serve": return "Reachable from anywhere"
        case "bridge": return "Answering"
        case "letterboxd": return "Ready"
        case "sessions":
            // "6 of 6 kept running · 2 others"
            let n = t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if n.count >= 2 { return (n[0] == n[1] ? "All \(n[1]) running" : "\(n[0]) of \(n[1]) running") + (n.count > 2 && n[2] > 0 ? ", and \(n[2]) more" : "") }
            return MacParts.say(p)
        case "oclp":
            if let r = t.range(of: #"macOS [0-9.]+"#, options: .regularExpression) { return "Patched for " + t[r] }
            return "Healthy"
        default: return MacParts.say(p)
        }
    }
}

// A card at the head of a page: a sign, a line, what it means, and what to do, with its button.
struct HeroCard<Action: View>: View {
    let symbol: String?
    let color: Color
    let title: String
    let detail: String?
    var note: String? = nil
    // Only a short state word is coloured ("Not connected"); a sentence stays grey (designer gate, 2026-11-13).
    var tintDetail = false
    @ViewBuilder var action: () -> Action
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(color).symbolRenderingMode(.hierarchical) }
                else { ProgressView() }
            }
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(tintDetail ? color : .secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true) }
                if let note { Text(note).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                action().padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// A part's row: its sign, its name, what it means, and what to do when it needs his hands.
struct MacPartRow: View {
    let id: String
    let part: MacPart?
    var check = false
    // Shown in place of the state: "Checking…", "Fixing…", "Waiting for the Mac".
    var pending: String?
    // Red, but only because the Mac is still coming up after a restart: amber, with a spinner, not a failure yet.
    var starting = false
    // The first in its card: no separator above (OwnSeparator).
    var first = true
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: MacParts.symbol(id)).font(.body).foregroundStyle(.secondary).frame(width: 26).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                // A passed check is one line that says what passed ("No password at boot"): its name over a second line
                // saying the same again was the wall of grey second lines (designer gate, 2026-11-13).
                if check, pending == nil, let p = part, p.state == "ok", let passed = MacParts.passed(id) {
                    Text(passed)
                } else {
                Text(MacParts.name(id, check: check))
                if let pending {
                    Text(pending).font(.footnote).foregroundStyle(.secondary)
                } else if let p = part, starting, p.bad {
                    Text("Still starting: " + MacParts.say(p, check: check)).font(.footnote).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let p = part {
                    Text(p.state == "fixed" ? "Fixed: " + MacParts.say(p, check: check) : MacParts.say(p, check: check)).font(.footnote).foregroundStyle(p.bad ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if p.bad, let h = MacParts.hand(id, check: check) {
                        Text(h).font(.footnote).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                }
            }
            Spacer(minLength: 8)
            sign.frame(width: 24)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .modifier(OwnSeparator(first: first))
    }
    @ViewBuilder var sign: some View {
        if pending != nil, part == nil || pending == "Fixing…" { ProgressView().controlSize(.small) }
        else if pending == nil, starting, part?.bad == true { ProgressView().controlSize(.small).tint(.orange) }
        else if pending != nil { Image(systemName: "circle.dashed").foregroundStyle(.secondary) }
        else if let p = part {
            Image(systemName: p.bad ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.title3).foregroundStyle(p.bad ? Color.red : Color.green)
                .accessibilityLabel(p.bad ? "Needs a look" : p.state == "fixed" ? "Fixed" : "Running")
        } else { ProgressView().controlSize(.small) }
    }
}

// Everything on the Mac, each part by name, read every few seconds while the page is up. After a restart asked from here,
// the same page is "Getting everything up": the Mac going away and each part coming back.
struct MacHealthView: View {
    @Environment(\.statusBarTop) private var statusBarTop
    let model: AppModel
    @Environment(\.paneLayout) private var panes
    @ObservedObject private var watch = RestartWatch.shared
    @State private var report: MacReport?
    @State private var misses = MissClock()
    @State private var away = false
    @State private var fixing: Date?
    @State private var fixNote: String?
    @State private var now = Date()
    @State private var fixingWhat = ""
    // Folded and upright, the parts opened to say what they are; open flat, the one shown in the right pane.
    @State private var expanded: Set<String> = []
    @State private var chosen: String?
    @StateObject private var links = FeedReader<LinksFeed>("/api/mac/links")
    @State private var macAction: MacAction?
    // Open upright there's room under the parts: the chosen part is said whole there, as in the right pane open flat,
    // rather than an empty half page (Richard, 2026-11-12: open "feels barren").
    @State private var roomy = false
    // Short, so it fits folded at the tabs' size (Richard, 2026-11-13: the old name was a huge title).
    var title: String { "Everything" }
    var bad: [MacPart] { report?.parts.filter(\.bad) ?? [] }
    var canFix: [MacPart] { bad.filter { MacParts.fixable.contains($0.part) } }
    // While the Mac is down every part waits for it; nothing pretends to know.
    var down: Bool { away || (watch.active && watch.wentAway && watch.backAt == nil) }

    // A restart asked for that the Mac isn't back from yet.
    var awaited: Bool { watch.active && watch.backAt == nil }
    var ids: [String] {
        let known = report?.parts.map(\.part) ?? []
        return known.isEmpty ? MacParts.health : known
    }
    // The first three minutes after the Mac answers again: a part not up yet is still starting.
    var startingWindow: Bool { watch.backAt.map { now.timeIntervalSince($0) < 180 } ?? false }
    func pending(_ id: String) -> String? {
        if down { return "Waiting for the Mac" }
        if fixing != nil, bad.contains(where: { $0.part == id && MacParts.fixable.contains(id) }) { return "Fixing…" }
        if report == nil { return "Checking…" }
        return nil
    }

    // A restart under way, or the Mac away: said in the hero's place, with how long it has been.
    struct Line { let symbol: String; let color: Color; let title: String; let detail: String }
    var bannerLine: Line? {
        func clock(_ s: TimeInterval) -> String { let t = max(0, Int(s)); return String(format: "%d:%02d", t / 60, t % 60) }
        func minutes(_ s: TimeInterval) -> String { let m = max(1, Int((s / 60).rounded())); return m == 1 ? "1 minute" : "\(m) minutes" }
        if let a = watch.askedAt {
            let since = now.timeIntervalSince(a)
            if watch.stuck(now) {
                return Line(symbol: "exclamationmark.triangle.fill", color: .red, title: "The Mac hasn’t come back", detail: "Asked \(minutes(since)) ago. It may be stuck at startup and need someone at it.")
            }
            if !watch.wentAway {
                if watch.unconfirmed, since <= 240 { return Line(symbol: "questionmark.circle", color: .orange, title: "The Mac didn’t confirm", detail: "It may be restarting; watching for it. Asked \(clock(since)) ago.") }
                if since > 240 { return Line(symbol: "questionmark.circle", color: .orange, title: "The Mac hasn’t restarted", detail: "It was asked \(clock(since)) ago and is still answering. Check it with Screen.") }
                return Line(symbol: "arrow.clockwise.circle", color: .orange, title: "Restarting in about a minute", detail: since < 60 ? "Goes down in about \(clock(60 - since)). The app reconnects by itself." : "Going down any moment now. The app reconnects by itself.")
            }
            if let b = watch.backAt {
                if bad.isEmpty, report != nil { return Line(symbol: "checkmark.circle.fill", color: .green, title: "Everything is up", detail: "Back \(minutes(b.timeIntervalSince(a))) after the restart was asked.") }
                return Line(symbol: "arrow.triangle.2.circlepath", color: .orange, title: "The Mac is back", detail: "Back \(minutes(b.timeIntervalSince(a))) after the restart was asked.")
            }
            return Line(symbol: "power.circle", color: .secondary, title: "The Mac is restarting", detail: "Asked \(clock(since)) ago. It usually takes three to five minutes; each part below fills in as it comes back.")
        }
        if away { return Line(symbol: "wifi.exclamationmark", color: .red, title: Phrase.macAwayShort, detail: "It may be restarting, or Tailscale may be off on this iPhone.") }
        return nil
    }

    // MARK: The page (Richard, 2026-11-13, of the old wall of rows: "horrific"). All well: one calm line over a compact
    // list, one line a part in his words, a small dot each, tap for what it is. Something wrong: that part leads, named,
    // with the plain fix and its button. Fix and Restart are buttons, never rows.

    // The parts as he knows them: the Mac's own ids stay inside the app.
    var groups: [MacGroup] { MacGroup.groups(for: ids) }
    func parts(_ g: MacGroup) -> [MacPart] { g.parts.compactMap { id in report?.parts.first { $0.part == id } } }
    func isBad(_ g: MacGroup) -> Bool { parts(g).contains(where: \.bad) }
    var badGroups: [MacGroup] { groups.filter(isBad) }
    func dot(_ g: MacGroup) -> Color {
        if down || report == nil { return Color(white: 0.4) }
        if isBad(g) { return startingWindow ? .orange : .red }
        return .green
    }

    @ViewBuilder var hero: some View {
        if let line = bannerLine {
            HeroCard(symbol: line.symbol, color: line.color, title: line.title, detail: line.detail) {
                if watch.stuck(now) { Button("Stop waiting") { withAnimation(Motion.quick) { watch.done() } }.buttonStyle(.bordered) }
            }
        } else if let a = macAction, a.by == "console", a.state == "running", a.kind != "send" {
            HeroCard(symbol: nil, color: .secondary, title: a.kind == "restart" ? "Checking before the restart…" : "Bringing everything up…", detail: "Started on the Mac’s Console") { EmptyView() }
        } else if let f = fixing {
            HeroCard(symbol: nil, color: .secondary, title: "Fixing \(fixingWhat)…", detail: "This can take up to two minutes · \(Int(now.timeIntervalSince(f))) s") { EmptyView() }
        } else if report == nil {
            HeroCard(symbol: nil, color: .secondary, title: "Checking the Mac…", detail: nil) { EmptyView() }
        } else if badGroups.isEmpty {
            HeroCard(symbol: "checkmark.circle.fill", color: .green, title: "Everything’s running", detail: nil) { EmptyView() }
        } else {
            VStack(spacing: 16) { ForEach(badGroups) { g in problem(g) } }
        }
    }
    // A part that needs a look: its name, what's wrong, and the one thing to do, on its button.
    func needsRestart(_ g: MacGroup) -> Bool {
        let p = parts(g).first(where: \.bad)
        let fixable = parts(g).contains { $0.bad && MacParts.fixable.contains($0.part) }
        return !fixable && (["stuck", "memory"].contains(p?.part ?? "") || p.flatMap { MacParts.hand($0.part) } == nil)
    }
    func problem(_ g: MacGroup) -> some View {
        let p = parts(g).first(where: \.bad)
        let fixPart = parts(g).first { $0.bad && MacParts.fixable.contains($0.part) }
        let hand = p.flatMap { MacParts.hand($0.part) }
        // The Restart button says what it does; a hand line that only says "restarting clears this" isn't said again.
        let note: String? = startingWindow || fixPart != nil ? nil : needsRestart(g) && p?.part == "stuck" ? nil : hand ?? "A restart may bring it back."
        return HeroCard(symbol: g.symbol, color: startingWindow ? .orange : .red, title: g.name,
                        detail: p.map { (startingWindow ? "Still starting: " : "") + MacGroup.human(g, $0) },
                        note: note, tintDetail: true) {
            if !startingWindow {
                if let fixPart {
                    Button { Task { await fix() } } label: { Text(MacGroup.fixLabel(fixPart.part)) }
                        .buttonStyle(.borderedProminent).tint(macBlue)
                } else if needsRestart(g) {
                    restartAction
                }
            }
        }
    }
    // The one way to a restart, in one look wherever it is: red, bordered.
    var restartAction: some View {
        Button(role: .destructive) { model.macPage = .restart } label: { Text("Restart the Mac…") }
            .buttonStyle(.bordered).tint(.red).controlSize(.regular)
    }
    // One line a part: its sign, its name, a small dot. Tapped, what it is and how it stands (folded and upright under it;
    // open flat in the right pane).
    func row(_ g: MacGroup, first: Bool, flat: Bool) -> some View {
        let open = flat ? picked?.id == g.id : expanded.contains(g.id)
        return Button {
            withAnimation(Motion.quick) {
                if flat { chosen = g.id } else if expanded.contains(g.id) { expanded.remove(g.id) } else { expanded.insert(g.id) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Image(systemName: g.symbol).font(.body).foregroundStyle(.secondary).frame(width: 26)
                    Text(g.name).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Circle().fill(dot(g)).frame(width: 8, height: 8)
                    if !flat {
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
                if open, !flat {
                    Text(stateLine(g)).font(.footnote).foregroundStyle(isBad(g) ? Color.red : Color.secondary)
                        .padding(.leading, 38).fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(down || report == nil ? "Waiting" : isBad(g) ? "Needs a look" : "Running")
        .modifier(OwnSeparator(first: first, ends: 9))
    }
    func stateLine(_ g: MacGroup) -> String {
        if down { return "Waiting for the Mac" }
        if report == nil { return "Checking…" }
        let ps = parts(g)
        if let b = ps.first(where: \.bad) { return MacGroup.human(g, b) }
        return ps.first.map { MacGroup.human(g, $0) } ?? "Running"
    }
    // Open flat: the part chosen on the left, said whole on the right.
    // Unchosen, the first part that is running: a part that's down is already said whole in its card on the left.
    var picked: MacGroup? { groups.first { $0.id == chosen } ?? groups.first { !isBad($0) } ?? groups.first }
    @ViewBuilder var detailCard: some View {
        if let g = picked {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: g.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 26)
                    Text(g.name).font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    Circle().fill(dot(g)).frame(width: 10, height: 10)
                }
                Text(stateLine(g)).foregroundStyle(isBad(g) && !down ? Color.red : Color.primary).fixedSize(horizontal: false, vertical: true)
                // What stands behind it, from Connections: each link's state in plain words and how long it has run,
                // and the way there for its buttons and the rest.
                let ls = (links.value?.links ?? []).filter { g.links.contains($0.id) }
                if !ls.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ls) { l in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(l.name).font(.subheadline)
                                    Spacer(minLength: 8)
                                    Text(l.up ? "Up" : l.down ? "Down" : l.state == "off" ? "Off" : "Starting").font(.footnote).foregroundStyle(.secondary)
                                }
                                let more = [l.plainDetail.flatMap { $0 == "Working" || $0 == "Answering" || $0 == "Running" ? nil : $0 }, l.uptime.map { "running \(Format.span($0))" }].compactMap { $0 }
                                if !more.isEmpty { Text(more.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                    }
                    .padding(.top, 6)
                    Button("Open Connections") { model.macPage = .links }.font(.subheadline).foregroundStyle(macBlue).padding(.top, 4)
                } else if g.id == "oclp" {
                    Button("Open the macOS tab") { model.tab = 4 }.font(.subheadline).foregroundStyle(macBlue).padding(.top, 4)
                }
            }
            .padding(.vertical, 6)
        }
    }

    func list(_ side: Side) -> some View {
        let flat = side != .all || roomy
        return ScrollViewReader { proxy in
            List {
                Section { PaneHeading(title: title, shown: side != .right, roomAbove: false, onMac: "everything") }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
                if side != .right {
                    Section { hero }
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                    if let fixNote { Section { FailText(fixNote) } }
                    Section {
                        let gs = groups
                        ForEach(gs) { g in
                            row(g, first: g.id == gs.first?.id, flat: flat).place(g.id).ownSeparatorRow()
                                // Open flat, the part shown on the right is lit on the left.
                                .listRowBackground(flat && picked?.id == g.id ? Color(white: 0.2) : nil)
                        }
                    }
                    if side == .all, roomy { Section { detailCard } }
                    if side == .all, !awaited, !down, !badGroups.contains(where: needsRestart) { restartButton }
                }
                if side == .right {
                    // No heading over it, so its card starts level with the hero beside it.
                    Section { detailCard }
                    if !awaited, !down, !badGroups.contains(where: needsRestart) { restartButton }
                }
            }
            .environment(\.defaultMinListRowHeight, 40)
            .onGeometryChange(for: Bool.self) { $0.size.height > 820 } action: { if side == .all { roomy = $0 } }
            .listSectionSpacing(16)
            .contentMargins(.top, 4 + PaneHeading.roomAbove(statusBarTop), for: .scrollContent)
            .scrollsUnder(side == .right ? 1 : 0)
            .keepsPlace("machealth", proxy)
            // The build's shot of the Memory row, the last part, wherever the posture puts it.
            .task { if model.pose == "healthmemory" { try? await Task.sleep(nanoseconds: 1_500_000_000); expanded.insert("memory"); chosen = "memory"; proxy.scrollTo("memory", anchor: .center) } }
        }
    }
    // An action, not a row: the way to a restart, under the parts.
    var restartButton: some View {
        Section {
            restartAction.frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
    }
    var body: some View {
        Group {
            if panes { FoldSplit { list(.left) } right: { list(.right) } } else { list(.all) }
        }
        .holdsWhileMoving("machealth")
        .modifier(TabBarFade())
        .background(groupedBackground.ignoresSafeArea())
        .topEdge()
        .pushedTitle()
        .animation(Motion.quick, value: report)
        .animation(Motion.quick, value: down)
        .task { await poll() }
        .task { await links.loop(model, every: 20) }
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000); now = Date() } }
    }

    // Every 3 s while the page is up (it stops when the page goes), fresher than the Mac's 5 s cache after a restart.
    func poll() async {
        if let posed = Self.posed(model.pose) {
            report = posed.report
            if posed.fixing { fixing = Date().addingTimeInterval(-23); fixingWhat = "TV" }
            // "healthstuck": gone twelve minutes and not back.
            // "didntconfirm": the restart was sent and its answer never came.
            if model.pose == "didntconfirm" { watch.asked(confirmed: false); watch.askedAt = Date().addingTimeInterval(-40) }
            if model.pose == "healthstuck" { watch.asked(); watch.askedAt = Date().addingTimeInterval(-720); watch.wentAway = true }
            if model.pose == "healthback" { watch.asked(); watch.askedAt = Date().addingTimeInterval(-200); watch.wentAway = true; watch.backAt = Date().addingTimeInterval(-20) }
            return
        }
        while !Task.isCancelled {
            // Not under the Mac's screen, which has the link to itself while it's open.
            if fixing == nil, !model.screenOpen {
                await read()
                // What the Mac's Console set going (Bring Everything Up, a restart) shows here as it runs.
                let a = await model.api.macActionNow()
                if a != macAction { withAnimation(Motion.quick) { macAction = a } }
                MacMirror.follow(a)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
    func read() async {
        do {
            let r = try await model.api.macHealth(fresh: watch.active)
            misses.hit(); away = false
            report = r
            HealthSummary.shared.set(r)
            if watch.active, let a = watch.askedAt {
                // Whether it restarted is the Mac's own uptime, asked now, never a guess from one missed answer: one
                // timeout on cellular read as a restart done ("Everything is up"), or hid a real one (audit, 2026-11-10).
                let up = (try? await model.api.live())?.uptime
                let since = Date().timeIntervalSince(a)
                if let up, up + 30 < since {
                    // Up for less time than since the restart was asked: it restarted, even if this page never saw it go.
                    if !watch.wentAway { watch.wentAway = true }
                    if watch.backAt == nil { watch.backAt = Date().addingTimeInterval(-up) }
                } else if let up, up >= since, watch.wentAway, watch.backAt == nil {
                    // It answers and has been up since before it was asked: that miss wasn't the restart. Still waiting for it.
                    watch.wentAway = false
                }
                // All up after coming back: the restart is over; the page keeps saying so until he leaves.
                if watch.backAt != nil, r.parts.allSatisfy({ !$0.bad }) { let b = watch.backAt; watch.done(); watch.backAt = b }
                // Asked long ago and never went down: over too, said once.
                else if !watch.wentAway, let a = watch.askedAt, Date().timeIntervalSince(a) > 600 { watch.done() }
            }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            // A restart was asked for: the first miss after it is the Mac going down. Otherwise only 8 s of misses count.
            if watch.active, let a = watch.askedAt, Date().timeIntervalSince(a) > 20 { watch.wentAway = true; watch.backAt = nil }
            watch.expire()
            if misses.miss() { away = true }
        }
    }
    func fix() async {
        fixNote = nil
        let names = badGroups.filter { g in parts(g).contains { $0.bad && MacParts.fixable.contains($0.part) } }.map(\.name)
        fixingWhat = names.count == 1 ? names[0] : names.isEmpty ? "what’s down" : names.dropLast().joined(separator: ", ") + " and " + names.last!
        withAnimation(Motion.quick) { fixing = Date() }
        do { report = try await model.api.macBringUp() }
        catch { fixNote = MacFiles.unreachable(error) ? "The Mac stopped answering while fixing. It may still be working; this page checks again by itself." : error.localizedDescription }
        withAnimation(Motion.quick) { fixing = nil }
    }

    // The build's shots: every part up, two red (one the Mac can fix, one that needs him), a fix under way, and the Mac
    // back from a restart with two parts still starting. Only with a pose; never on the phone.
    static func posed(_ pose: String) -> (report: MacReport, fixing: Bool)? {
        let says = ["tailscale": "Running", "serve": "https → bridge", "bridge": "Answering", "sessions": "6 of 6 kept running · 2 others", "tv": "Connected",
                    "letterboxd": "Sign-in relay running", "chumby": "Answering", "oclp": "HEALTHY: macOS 26.7.2, OCLP 3.0.0", "stuck": "Nothing stuck", "memory": "Normal pressure · 6.4 GB swap in use"]
        func r(_ bad: [String: String], fixed: [String: String] = [:]) -> MacReport {
            MacReport(ok: bad.isEmpty, at: Date().timeIntervalSince1970 * 1000, parts: MacParts.health.map {
                MacPart(part: $0, state: bad[$0] != nil ? "bad" : fixed[$0] != nil ? "fixed" : "ok", say: bad[$0] ?? fixed[$0] ?? says[$0]!)
            })
        }
        let two = ["tv": "Not connected", "chumby": "Not answering (asleep, off Wi-Fi, or chumby-remote down)"]
        switch pose {
        case "health", "healthmemory": return (r([:]), false)
        case "healthbad": return (r(two), false)
        // One part that needs his hands, as in Richard's screenshot of 2026-11-12: named in the card, first in the list.
        case "healthone": return (r(["stuck": "1 program stuck: Safari; a restart clears it"]), false)
        case "healthfixing": return (r(two), true)
        case "healthstuck", "didntconfirm": return (r([:]), false)
        case "healthback": return (r(["sessions": "3 of 6 kept running · 2 others"], fixed: ["letterboxd": "Sign-in relay started"]), false)
        default: return nil
        }
    }
}

// Restart the Mac: what it checked first, each green or red with what it means; refused while any is red, saying what to
// fix; one plain question; then the same page becomes "Getting everything up".
struct MacRestartView: View {
    @Environment(\.statusBarTop) private var statusBarTop
    let model: AppModel
    @Environment(\.paneLayout) private var panes
    @ObservedObject private var watch = RestartWatch.shared
    @State private var checks: MacReport?
    @State private var checking = false
    @State private var asking = false
    @State private var sending = false
    @State private var failure: String?
    @State private var refused: String?
    // Once asked from this page, it stays the bring-up page until he leaves it.
    @State private var restarted = false

    var red: [MacPart] { checks?.parts.filter { $0.bad && $0.part != "restart" } ?? [] }
    var ready: Bool { checks != nil && red.isEmpty && !checking }

    func list(_ side: Side) -> some View {
        ScrollViewReader { proxy in
            List {
                Section { PaneHeading(title: "Restart the Mac", shown: side != .right, roomAbove: false) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
                if side != .right {
                    Section {
                        ForEach(MacParts.checks, id: \.self) { id in
                            MacPartRow(id: id, part: checks?.parts.first { $0.part == id }, check: true, pending: checking || (checks == nil && failure == nil) ? "Checking…" : checks == nil ? "Not checked yet" : nil, first: id == MacParts.checks.first).place(id).ownSeparatorRow()
                        }
                    } header: { Text("Before it restarts") } footer: {
                        Text("It has to come back by itself, with no one at the Mac.")
                    }
                }
                if side != .left {
                    Section {
                        if !red.isEmpty || (checks == nil && failure != nil && !checking) {
                            if !red.isEmpty { Label(red.count == 1 ? "Restart waits until \(MacParts.name(red[0].part, check: true)) is green." : "Restart waits until the \(red.count) red checks are green.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red) }
                            Button { Task { await check() } } label: { Label("Check again", systemImage: "arrow.clockwise") }.disabled(checking)
                        }
                        Button(role: .destructive) { asking = true } label: {
                            HStack { Text("Restart the Mac"); Spacer(); if sending { ProgressView() } }
                        }
                        .disabled(!ready || sending)
                        .alert("Restart the Mac?", isPresented: $asking) {
                            Button("Restart", role: .destructive) { Task { await restart() } }
                            Button("Cancel", role: .cancel) {}
                        } message: { Text("The Mac restarts in a minute. The app reconnects by itself.") }
                        if let refused { FailText(refused) }
                        if let failure { FailText(failure) }
                    } footer: {
                        if checks == nil || checking { Text("Restart waits for the checks.") }
                        else if red.isEmpty { Text("Everything above is green. Open apps on the Mac close without saving.") }
                    }
                }
            }
            .contentMargins(.top, 4 + PaneHeading.roomAbove(statusBarTop), for: .scrollContent)
            .scrollsUnder(side == .right ? 1 : 0)
            .keepsPlace("macrestart", proxy)
        }
    }
    var body: some View {
        Group {
            if restarted || watch.active { MacHealthView(model: model) }
            else if panes { FoldSplit { list(.left) } right: { list(.right) } }
            else { list(.all) }
        }
        .holdsWhileMoving("macrestart")
        .modifier(TabBarFade())
        .background(groupedBackground.ignoresSafeArea())
        .topEdge()
        .pushedTitle()
        .animation(Motion.quick, value: checks)
        .task { if !watch.active { await check() } }
    }

    func check() async {
        if let posed = Self.posed(model.pose) { checks = posed; return }
        checking = true; failure = nil; refused = nil
        defer { checking = false }
        // A miss is asked again for a few seconds before it's said (no false "Can't reach").
        let started = Date()
        while !Task.isCancelled {
            do { checks = try await model.api.macChecks(); return }
            catch {
                if MacFiles.unreachable(error), Date().timeIntervalSince(started) < 10 { try? await Task.sleep(nanoseconds: 2_000_000_000); continue }
                failure = MacFiles.unreachable(error) ? Phrase.macAway : error.localizedDescription
                return
            }
        }
    }
    func restart() async {
        sending = true; failure = nil; refused = nil
        defer { sending = false }
        do {
            let (going, rep) = try await model.api.macRestart()
            if going {
                watch.asked()
                withAnimation(Motion.quick) { restarted = true }
            } else {
                checks = rep
                refused = rep.parts.first { $0.part == "restart" }?.say ?? "The Mac refused: something above turned red."
            }
        } catch {
            // The Mac answers only once its restart script has run, so an answer that never arrived (a timeout, the link
            // dropping mid-request) doesn't mean nothing happened: it may be restarting, and the page watches for it.
            // Only a request that never left says "nothing was restarted".
            if let u = error as? URLError, [.timedOut, .networkConnectionLost].contains(u.code) {
                watch.asked(confirmed: false)
                withAnimation(Motion.quick) { restarted = true }
            } else {
                failure = MacFiles.unreachable(error) ? "Can’t reach the Mac. Nothing was restarted." : error.localizedDescription
            }
        }
    }

    // The build's shots of the checks all green, and with one red (work still running). Never on the phone.
    static func posed(_ pose: String) -> MacReport? {
        let says = ["oclp": "Patches healthy", "updates": "No macOS update will install", "filevault": "Off; no password at boot",
                    "autologin": "Logs in by itself", "tailscale": "Starts at login", "work": "Nothing long-running",
                    "keep": "Scripts from /tmp kept in ~/.local/share/keep-after-reboot"]
        guard pose == "restart" || pose == "restartred" else { return nil }
        return MacReport(ok: pose == "restart", at: Date().timeIntervalSince1970 * 1000, parts: MacParts.checks.map {
            pose == "restartred" && $0 == "work" ? MacPart(part: $0, state: "bad", say: "Still running: buildonly.sh") : MacPart(part: $0, state: "ok", say: says[$0]!)
        })
    }
}
