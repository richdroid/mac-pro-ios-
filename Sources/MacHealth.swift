import SwiftUI

// Restart the Mac and get everything up (Richard, 2026-11-10: "build tools for restarting and getting everything up both
// from mac and mac pro app side"). Two pushed pages on the Control tab: "Everything on the Mac", each part by name with
// its state and a Fix only when something fixable is red; and "Restart the Mac", its checks first, refusing while any is
// red, then the same parts coming back one by one. Never one spinner that hides which part is stuck.

enum MacPage: String, Identifiable, Hashable { case health, restart; var id: String { rawValue } }

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
    static let health = ["tailscale", "serve", "bridge", "sessions", "tv", "letterboxd", "chumby", "oclp", "stuck"]
    static let checks = ["oclp", "updates", "filevault", "autologin", "tailscale", "work", "keep"]
    // The ones the Mac can bring back itself (mac-bringup.sh); the rest need a hand, and say what to do.
    static let fixable: Set<String> = ["tailscale", "bridge", "sessions", "tv", "letterboxd"]
    static func name(_ p: String, check: Bool = false) -> String {
        if check {
            switch p {
            case "oclp": return "OCLP patches"
            case "updates": return "macOS updates"
            case "filevault": return "FileVault"
            case "autologin": return "Auto-login"
            case "tailscale": return "Tailscale at login"
            case "work": return "Work in progress"
            case "keep": return "Files kept from /tmp"
            default: break
            }
        }
        switch p {
        case "tailscale": return "Tailscale"
        case "serve": return "Tailscale Serve"
        case "bridge": return "The bridge"
        case "sessions": return "Claude sessions"
        case "tv": return "TV link"
        case "letterboxd": return "Letterboxd relay"
        case "chumby": return "Chumby"
        case "oclp": return "OCLP"
        case "stuck": return "Stuck programs"
        default: return p.prefix(1).uppercased() + p.dropFirst()
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
            case ("serve", false): return "Points this app at the bridge"
            case ("serve", true): return "Not pointing at the bridge"
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
        case "serve": return "Ask a Claude session on the Mac to point Tailscale Serve back at the bridge."
        case "chumby": return "Check the Chumby is on and on Wi-Fi."
        case "oclp": return "Re-apply the root patches in OpenCore Legacy Patcher."
        case "stuck": return "A restart clears them."
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
        if let pose = d.string(forKey: "pose"), !pose.isEmpty, pose != "healthback", pose != "healthstuck" { askedAt = nil; wentAway = false }
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

// A part's row: its sign, its name, what it means, and what to do when it needs his hands.
struct MacPartRow: View {
    let id: String
    let part: MacPart?
    var check = false
    // Shown in place of the state: "Checking…", "Fixing…", "Waiting for the Mac".
    var pending: String?
    // Red, but only because the Mac is still coming up after a restart: amber, with a spinner, not a failure yet.
    var starting = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: MacParts.symbol(id)).font(.body).foregroundStyle(.secondary).frame(width: 26).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
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
            Spacer(minLength: 8)
            sign.frame(width: 24)
        }
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + 38 }
        .accessibilityElement(children: .combine)
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
    let model: AppModel
    @Environment(\.paneLayout) private var panes
    @ObservedObject private var watch = RestartWatch.shared
    @State private var report: MacReport?
    @State private var misses = MissClock()
    @State private var away = false
    @State private var fixing: Date?
    @State private var fixNote: String?
    @State private var now = Date()
    var title: String { watch.active ? "Getting everything up" : "Everything on the Mac" }
    var bad: [MacPart] { report?.parts.filter(\.bad) ?? [] }
    var canFix: [MacPart] { bad.filter { MacParts.fixable.contains($0.part) } }
    // While the Mac is down every part waits for it; nothing pretends to know.
    var down: Bool { away || (watch.active && watch.wentAway && watch.backAt == nil) }

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

    @ViewBuilder var banner: some View {
        if let line = bannerLine {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: line.symbol).font(.title3).foregroundStyle(line.color).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.title).font(.body.weight(.semibold))
                    Text(line.detail).font(.footnote).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            // A restart that never came back has an end: said in red after ten minutes, with a way to stop waiting.
            if watch.stuck(now) { Button("Stop waiting") { withAnimation(Motion.quick) { watch.done() } } }
        }
    }
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
                return Line(symbol: "arrow.triangle.2.circlepath", color: .orange, title: "The Mac is back", detail: "Back \(minutes(b.timeIntervalSince(a))) after the restart was asked. Parts still starting are below.")
            }
            return Line(symbol: "power.circle", color: .secondary, title: "The Mac is restarting", detail: "Asked \(clock(since)) ago. It usually takes three to five minutes; each part below fills in by itself as it comes back.")
        }
        if away { return Line(symbol: "wifi.exclamationmark", color: .red, title: Phrase.macAwayShort, detail: "It may be restarting, or Tailscale may be off on this iPhone.") }
        return nil
    }

    @ViewBuilder var fixSection: some View {
        if let f = fixing {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Fixing \(canFix.count == 1 ? MacParts.name(canFix[0].part) : "\(canFix.count) parts")… \(Int(now.timeIntervalSince(f)))s").monospacedDigit()
                }
            } footer: { Text("This can take up to two minutes. Each part says how it went.") }
        } else if !canFix.isEmpty, !down {
            Section {
                Button { Task { await fix() } } label: {
                    Label(canFix.count == 1 ? "Fix \(MacParts.name(canFix[0].part))" : "Fix \(canFix.count) parts", systemImage: "wrench.adjustable")
                }
                if let fixNote { FailText(fixNote) }
            } footer: { Text("Restarts what’s down on the Mac. Parts that need you say what to do.") }
        } else if let fixNote {
            Section { FailText(fixNote) }
        } else if panes, let r = report, !down {
            Section {
                Label(bad.isEmpty ? "Nothing needs you" : "\(bad.count) need\(bad.count == 1 ? "s" : "") your hands", systemImage: bad.isEmpty ? "checkmark.circle" : "hand.raised")
                Text("Checked \(Format.ago(ms: r.at)). It checks again every few seconds while this page is open.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    func partsSection(heading: Bool) -> some View {
        Section {
            ForEach(ids, id: \.self) { id in
                MacPartRow(id: id, part: report?.parts.first { $0.part == id }, pending: pending(id), starting: startingWindow).place(id)
            }
        } header: {
            // While the Mac is away nothing is known of its parts: the heading says so too, not what was last read.
            if heading, down { Text("Waiting for the Mac") }
            else if heading {
                Text(report.map { r in
                    let n = r.parts.filter(\.bad).count
                    return n == 0 ? "All running" : startingWindow ? "\(n) still starting" : "\(n) need\(n == 1 ? "s" : "") a look"
                } ?? "Checking")
            }
        }
    }
    func list(_ side: Side) -> some View {
        ScrollViewReader { proxy in
            List {
                Section { PaneHeading(title: title, shown: side != .right) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
                if side != .right, bannerLine != nil { Section { banner } }
                // Folded or upright, Fix comes before the parts, where he looks first; open flat it has the right pane.
                if side == .all { fixSection }
                // Open flat with the Mac away there's nothing to fix, so the parts take the right pane and the banner has the
                // left: the whole page sat in the left pane, cut off, beside an empty one (designer, 2026-11-10).
                if side == .all || (side == .left && !down) || (side == .right && down) { partsSection(heading: true) }
                if side == .right, !down { fixSection }
            }
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollsUnder(side == .right ? 1 : 0)
            .keepsPlace("machealth", proxy)
        }
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
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000); now = Date() } }
    }

    // Every 3 s while the page is up (it stops when the page goes), fresher than the Mac's 5 s cache after a restart.
    func poll() async {
        if let posed = Self.posed(model.pose) {
            report = posed.report
            if posed.fixing { fixing = Date().addingTimeInterval(-23) }
            // "healthstuck": gone twelve minutes and not back.
            if model.pose == "healthstuck" { watch.asked(); watch.askedAt = Date().addingTimeInterval(-720); watch.wentAway = true }
            if model.pose == "healthback" { watch.asked(); watch.askedAt = Date().addingTimeInterval(-200); watch.wentAway = true; watch.backAt = Date().addingTimeInterval(-20) }
            return
        }
        while !Task.isCancelled {
            // Not under the Mac's screen, which has the link to itself while it's open.
            if fixing == nil, !model.screenOpen { await read() }
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
        withAnimation(Motion.quick) { fixing = Date() }
        do { report = try await model.api.macBringUp() }
        catch { fixNote = MacFiles.unreachable(error) ? "The Mac stopped answering while fixing. It may still be working; this page checks again by itself." : error.localizedDescription }
        withAnimation(Motion.quick) { fixing = nil }
    }

    // The build's shots: every part up, two red (one the Mac can fix, one that needs him), a fix under way, and the Mac
    // back from a restart with two parts still starting. Only with a pose; never on the phone.
    static func posed(_ pose: String) -> (report: MacReport, fixing: Bool)? {
        let says = ["tailscale": "Running", "serve": "https → bridge", "bridge": "Answering", "sessions": "6 of 6 running", "tv": "Connected",
                    "letterboxd": "Sign-in relay running", "chumby": "Answering", "oclp": "HEALTHY: macOS 26.7.2, OCLP 3.0.0", "stuck": "Nothing stuck"]
        func r(_ bad: [String: String], fixed: [String: String] = [:]) -> MacReport {
            MacReport(ok: bad.isEmpty, at: Date().timeIntervalSince1970 * 1000, parts: MacParts.health.map {
                MacPart(part: $0, state: bad[$0] != nil ? "bad" : fixed[$0] != nil ? "fixed" : "ok", say: bad[$0] ?? fixed[$0] ?? says[$0]!)
            })
        }
        let two = ["tv": "Not connected", "chumby": "Not answering (asleep, off Wi-Fi, or chumby-remote down)"]
        switch pose {
        case "health": return (r([:]), false)
        case "healthbad": return (r(two), false)
        case "healthfixing": return (r(two), true)
        case "healthstuck": return (r([:]), false)
        case "healthback": return (r(["sessions": "3 of 6 running"], fixed: ["letterboxd": "Sign-in relay started"]), false)
        default: return nil
        }
    }
}

// Restart the Mac: what it checked first, each green or red with what it means; refused while any is red, saying what to
// fix; one plain question; then the same page becomes "Getting everything up".
struct MacRestartView: View {
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
                Section { PaneHeading(title: "Restart the Mac", shown: side != .right) }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
                if side != .right {
                    Section {
                        ForEach(MacParts.checks, id: \.self) { id in
                            MacPartRow(id: id, part: checks?.parts.first { $0.part == id }, check: true, pending: checking || (checks == nil && failure == nil) ? "Checking…" : checks == nil ? "Not checked yet" : nil).place(id)
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
            .contentMargins(.top, 4, for: .scrollContent)
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
