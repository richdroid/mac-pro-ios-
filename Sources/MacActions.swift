import AppIntents
import SwiftUI

// mp's actions as buttons (Richard's Mac Pro toolkit, ~/code/Tools/mp/ACTIONS.md), through the bridge's POST /api/mp.
// Anything that needs an OK is first asked of the Mac as a dry run: its answer is the question ("This will …"), and the
// Mac's one-time nonce from that dry run is what lets the real run through, once. Each answer is mp's own, shown as it
// says: its line, then its rows, each with its state.

struct MPEnvelope: Decodable, Equatable {
    struct Row: Decodable, Equatable, Identifiable {
        var part: String?; var label: String?; var state: String?; var say: String?
        var id: String { (part ?? "") + (label ?? "") + (say ?? "") }
    }
    struct Job: Decodable, Equatable { var id: String?; var kind: String?; var title: String? }
    var ok: Bool?; var command: String?; var say: String?; var rows: [Row]?; var notes: [String]?
    var dryRun: Bool?; var needs: String?; var admin: Bool?; var adminCommand: String?; var job: Job?
}

extension API {
    // One call to mp through the bridge: its answer, and the nonce a dry run hands out for the real run.
    func mp(_ action: String, _ args: [String] = [], dryRun: Bool = false, confirm: Bool = false, nonce: String? = nil, protected: Bool = false, timeout: TimeInterval = 210) async throws -> (MPEnvelope, String?) {
        var r = URLRequest(url: URL(string: "/api/mp", relativeTo: base)!)
        r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue(MacFiles.origin(base), forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var b: [String: Any] = ["action": action, "args": args]
        if dryRun { b["dryRun"] = true }
        if confirm { b["confirm"] = true; b["nonce"] = nonce ?? "" }
        if protected { b["confirmProtected"] = true }
        r.httpBody = try JSONSerialization.data(withJSONObject: b)
        let (d, resp) = try await session.data(for: r)
        let h = resp as? HTTPURLResponse
        if let e = try? JSONDecoder().decode(MPEnvelope.self, from: d), e.ok != nil || e.say != nil { return (e, h?.value(forHTTPHeaderField: "X-MP-Nonce")) }
        if h?.statusCode == 404 { return (MPEnvelope(ok: false, say: "This Mac’s bridge can’t run Mac Pro actions yet."), nil) }
        throw APIError.badResponse
    }
    // Whether this Mac's bridge has /api/mp: its own refusal of a made-up action, without running anything.
    func mpAvailable() async -> Bool {
        guard let u = URL(string: "/api/mp?action=none", relativeTo: base) else { return false }
        var r = URLRequest(url: u); r.timeoutInterval = 10
        guard let (d, _) = try? await session.data(for: r), let e = try? JSONDecoder().decode(MPEnvelope.self, from: d) else { return false }
        return e.command != nil
    }
}

// The actions the app offers, by mp's names and its confirmation classes.
struct MPAction: Identifiable, Hashable {
    enum Kind { case read, tap, confirm }
    let id: String; let title: String; let action: String; let args: [String]; let kind: Kind; let symbol: String
    static let check = [
        MPAction(id: "status", title: "Everything at a glance", action: "status", args: [], kind: .read, symbol: "list.bullet.rectangle"),
        MPAction(id: "reboot-safe", title: "Safe to restart?", action: "reboot-safe", args: [], kind: .read, symbol: "checkmark.shield"),
        MPAction(id: "fix", title: "Fix what’s down", action: "fix", args: [], kind: .tap, symbol: "wrench.adjustable"),
    ]
    static let clean = [
        MPAction(id: "clean-trash", title: "Empty the Trash", action: "clean", args: ["trash"], kind: .confirm, symbol: "trash"),
        MPAction(id: "clean-caches", title: "Clear app caches", action: "clean", args: ["caches"], kind: .confirm, symbol: "archivebox"),
        MPAction(id: "clean-logs", title: "Remove old logs", action: "clean", args: ["old-logs"], kind: .confirm, symbol: "doc.text"),
    ]
    static let ship = [
        MPAction(id: "ship-status", title: "Your apps on TestFlight", action: "ship", args: ["status"], kind: .read, symbol: "airplane"),
        MPAction(id: "ship-macpro", title: "Ship Mac Pro", action: "ship", args: ["macpro"], kind: .confirm, symbol: "desktopcomputer"),
        MPAction(id: "ship-chumby", title: "Ship Chumby", action: "ship", args: ["chumby"], kind: .confirm, symbol: "alarm"),
        MPAction(id: "ship-tv", title: "Ship TV", action: "ship", args: ["tv"], kind: .confirm, symbol: "tv"),
    ]
    static let work = [
        MPAction(id: "test-quick", title: "Translator quick tests", action: "test", args: ["quick"], kind: .tap, symbol: "testtube.2"),
        MPAction(id: "test-results", title: "Latest test results", action: "test", args: ["results"], kind: .read, symbol: "list.clipboard"),
        MPAction(id: "jobs", title: "Long jobs", action: "jobs", args: [], kind: .read, symbol: "clock.arrow.circlepath"),
    ]
    static let chumby = [
        MPAction(id: "chumby-night-on", title: "Chumby night mode on", action: "chumby", args: ["night", "on"], kind: .tap, symbol: "moon"),
        MPAction(id: "chumby-night-off", title: "Chumby night mode off", action: "chumby", args: ["night", "off"], kind: .tap, symbol: "sun.max"),
    ]
}

// One action: its button, its question when it needs one, and what the Mac said it did.
struct MPActionRow: View {
    let model: AppModel
    let item: MPAction
    @State private var busy = false
    @State private var answer: MPEnvelope?
    @State private var answeredAt: Date?
    @State private var asking: (say: String, nonce: String)?
    @State private var failure: String?
    static func color(_ s: String?) -> Color {
        switch s { case "ok", "fixed": return .green; case "look", "busy": return .orange; case "bad": return .red; default: return .secondary }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { start() } label: {
                HStack {
                    Label(item.title, systemImage: item.symbol)
                    Spacer(minLength: 8)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .disabled(busy)
            if let a = answer {
                Label(a.say ?? (a.ok == true ? "Done" : "Not done"), systemImage: a.ok == true ? "checkmark.circle.fill" : a.needs == "yes" ? "hand.raised.fill" : "exclamationmark.circle.fill")
                    .font(.footnote).foregroundStyle(a.ok == true ? Color.green : a.needs == "yes" ? Color.orange : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach((a.rows ?? []).prefix(12)) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Self.color(r.state)).frame(width: 7, height: 7)
                        Text([r.label ?? r.part, r.say].compactMap { $0 }.joined(separator: ": ")).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(a.notes ?? [], id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                if let j = a.job { Text("Running on the Mac: \(j.title ?? j.kind ?? "a job"). Long jobs shows how it goes.").font(.footnote).foregroundStyle(.secondary) }
                if let t = answeredAt { Text("Answered \(t.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.tertiary) }
                if a.admin == true, let c = a.adminCommand { Text("Needs admin at the Mac:").font(.footnote).foregroundStyle(.secondary); CommandRow(command: c) }
            }
            if let failure { FailText(failure) }
        }
        .alert(item.title + "?", isPresented: .init(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            if let a = asking {
                Button(item.title, role: .destructive) { run(nonce: a.nonce) }
                Button("Cancel", role: .cancel) {}
            }
        } message: { Text(asking.map { "This will " + Self.lowerFirst($0.say) } ?? "") }
    }
    // A dry run that describes a change ("would remove …"), rather than saying there's nothing to do.
    static func wouldDo(_ s: String?) -> Bool { guard let s else { return false }; return s.lowercased().hasPrefix("would ") || s.lowercased().contains(" would ") }
    static func lowerFirst(_ s: String) -> String {
        // mp's dry run reads "Dry run: would remove 1.2 GB. Nothing was removed."; the question is "This will remove 1.2 GB."
        var t = s.hasPrefix("Dry run: ") ? String(s.dropFirst(9)) : s
        if t.lowercased().hasPrefix("would ") { t = String(t.dropFirst(6)) }
        t = t.replacingOccurrences(of: " Nothing was removed.", with: "").replacingOccurrences(of: " Nothing is pushed.", with: "")
        return t.prefix(1).lowercased() + t.dropFirst()
    }
    func start() {
        failure = nil
        if item.kind == .confirm {
            // The question is the Mac's own dry run; nothing changes until it's answered.
            busy = true
            Task {
                defer { busy = false }
                do {
                    let (e, n) = try await model.api.mp(item.action, item.args, dryRun: true)
                    // Nothing to ask about ("Nothing to clean."), or a refusal: that answer is the outcome.
                    if e.ok == false || n == nil || !Self.wouldDo(e.say) { withAnimation(Motion.quick) { answer = e }; return }
                    asking = (e.say ?? "go ahead", n!)
                } catch { failure = MacFiles.unreachable(error) ? Phrase.macAway : error.localizedDescription }
            }
        } else { run(nonce: nil) }
    }
    func run(nonce: String?) {
        busy = true; answer = nil
        Task {
            defer { busy = false }
            do {
                let (e, _) = try await model.api.mp(item.action, item.args, confirm: nonce != nil, nonce: nonce)
                withAnimation(Motion.quick) { answer = e; answeredAt = Date() }
            } catch {
                // No answer: whether it ran isn't known, and the row says so rather than "done".
                failure = MacFiles.unreachable(error) || (error as? URLError)?.code == .timedOut ? "The Mac didn’t answer, so it’s not known whether that ran. Check again in a moment." : error.localizedDescription
            }
        }
    }
}

struct MacActionsView: View {
    let model: AppModel
    var body: some View {
        ConsolePage(title: "Mac Pro actions", place: "macactions", away: false, lastRead: nil) {
            Section { ForEach(MPAction.check) { MPActionRow(model: model, item: $0) } } header: { Text("Check and fix") } footer: {
                Text("Fix what’s down starts only what isn’t running; parts that are up are left alone.")
            }
            Section { ForEach(MPAction.clean) { MPActionRow(model: model, item: $0) } } header: { Text("Free up space") } footer: {
                Text("Each asks first and says exactly what it will remove.")
            }
        } right: {
            Section { ForEach(MPAction.ship) { MPActionRow(model: model, item: $0) } } header: { Text("TestFlight") } footer: {
                Text("Shipping builds from the newest commit and uploads it; it asks first.")
            }
            Section { ForEach(MPAction.work) { MPActionRow(model: model, item: $0) } } header: { Text("Translator and jobs") }
            Section { ForEach(MPAction.chumby) { MPActionRow(model: model, item: $0) } } header: { Text("Chumby") }
        }
    }
}

// Shortcuts and Siri: "Run Mac Pro action", from a fixed list. The ones that need an OK ask for it in Shortcuts, with the
// Mac's own dry run as the question.
enum MacActionChoice: String, AppEnum {
    case status, health, fix, temps, updates, usage, rebootSafe, shipStatus, testQuick, chumbyNightOn, chumbyNightOff, emptyTrash, clearCaches
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mac Pro action"
    static var caseDisplayRepresentations: [MacActionChoice: DisplayRepresentation] = [
        .status: "Everything at a glance", .health: "Everything on the Mac", .fix: "Fix what’s down", .temps: "Temperatures",
        .updates: "Updates", .usage: "Claude usage", .rebootSafe: "Safe to restart?", .shipStatus: "TestFlight status",
        .testQuick: "Translator quick tests", .chumbyNightOn: "Chumby night mode on", .chumbyNightOff: "Chumby night mode off",
        .emptyTrash: "Empty the Trash", .clearCaches: "Clear app caches",
    ]
    var call: (action: String, args: [String], confirm: Bool) {
        switch self {
        case .status: return ("status", [], false)
        case .health: return ("health", [], false)
        case .fix: return ("fix", [], false)
        case .temps: return ("temps", [], false)
        case .updates: return ("updates", [], false)
        case .usage: return ("usage", [], false)
        case .rebootSafe: return ("reboot-safe", [], false)
        case .shipStatus: return ("ship", ["status"], false)
        case .testQuick: return ("test", ["quick"], false)
        case .chumbyNightOn: return ("chumby", ["night", "on"], false)
        case .chumbyNightOff: return ("chumby", ["night", "off"], false)
        case .emptyTrash: return ("clean", ["trash"], true)
        case .clearCaches: return ("clean", ["caches"], true)
        }
    }
}

struct MacRunActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Mac Pro Action"
    static var description = IntentDescription("Runs one of the Mac Pro’s actions and says what it did. Ones that change things ask first.")
    @Parameter(title: "Action") var choice: MacActionChoice
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let base = MacBridge.base else { throw MacIntentError.noAnswer }
        let api = API(base: base), c = choice.call
        var nonce: String?
        if c.confirm {
            let (dry, n) = try await api.mp(c.action, c.args, dryRun: true, timeout: 60)
            guard dry.ok != false, let n, MPActionRow.wouldDo(dry.say) else { let s = dry.say ?? "The Mac said no."; return .result(value: s, dialog: IntentDialog(stringLiteral: s)) }
            try await requestConfirmation(result: .result(dialog: IntentDialog(stringLiteral: "This will " + MPActionRow.lowerFirst(dry.say ?? "go ahead"))))
            nonce = n
        }
        let e: MPEnvelope
        do { e = try await api.mp(c.action, c.args, confirm: nonce != nil, nonce: nonce, timeout: c.action == "clean" ? 300 : c.action == "fix" ? 200 : 60).0 }
        catch {
            // No answer: whether it ran isn't known, and Siri says so.
            let s = "The Mac didn’t answer in time, so it’s not known whether that ran. Look in the Mac Pro app’s Actions."
            return .result(value: s, dialog: IntentDialog(stringLiteral: s))
        }
        let s = e.say ?? (e.ok == true ? "Done." : "Not done.")
        return .result(value: s, dialog: IntentDialog(stringLiteral: s))
    }
}
