import SwiftUI

// An app he added himself (not Mac Pro, TV Remote or Chumby) has no builds of ours to list, so its page is what the
// package itself says, grouped the App Store's way, and any history the Mac found in public: the App Store's current
// version and its notes, or an open-source app's GitHub releases (Richard, 2026-11-12: "when i load an ipa and its like
// no update history yeah that makes sense so show other details but ofc for my own apps show that update history or
// maybe look into finding that update history on ur own"). Never an empty "no history" state.

// What the Mac read out of the package. Every field optional: a Mac that knows less leaves it out, and the row goes.
struct IPADetails: Codable, Equatable {
    struct Signature: Codable, Equatable { var team: String?; var created: Double?; var expires: Double?; var development: Bool? }
    struct Source: Codable, Equatable { var kind: String?; var host: String?; var url: String? }
    var name: String?; var bundle: String?; var version: String?; var build: String?
    var size: Double?; var unpacked: Double?; var minimumOS: String?; var devices: String?; var category: String?
    var languages: Int?; var sdk: String?; var copyright: String?
    var extensions: [String]?; var asks: [String]?; var capabilities: [String]?
    var cameSigned: Signature?; var signed: Signature?
    var addedAt: Double?; var installedAt: Double?; var source: Source?
}
// Versions found in public, newest first, from one place.
struct OutsideHistory: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable { let version: String; let at: Double; let notes: [String]; var id: String { version } }
    let from: String; var link: String?; var by: String?; let entries: [Entry]
}
struct IPAAnswer: Codable, Equatable { var info: IPADetails?; var history: OutsideHistory?; var historyPending: Bool? }

extension Status.SeedApp {
    // His own three apps, whose builds the Mac lists from their code; everything else he added himself.
    static let ourFiles: Set<String> = ["MacPro.ipa", "TV.ipa", "Chumby.ipa"]
    var isOurs: Bool { Self.ourFiles.contains(file) || testFlight }
}

// The Apps tab's page for one app: his own apps' Version History, or an added app's details.
struct AppPage: View {
    let file: String
    let model: AppModel
    var body: some View {
        if Status.SeedApp.ourFiles.contains(file) { VersionHistoryView(file: file, model: model) }
        else { AppInfoView(file: file, model: model) }
    }
}

struct AppInfoView: View {
    let model: AppModel
    @ObservedObject private var seeds: SeedStore
    let file: String
    @State private var answer: IPAAnswer?
    // Kept on the phone, so the page opens drawn, as Version History does, while the Mac is asked again.
    @MainActor static var known: [String: IPAAnswer] = {
        guard let d = try? Data(contentsOf: knownFile) else { return [:] }
        return (try? JSONDecoder().decode([String: IPAAnswer].self, from: d)) ?? [:]
    }()
    private static var knownFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app-info.json") }

    init(file: String, model: AppModel) {
        self.file = file
        self.model = model
        _seeds = ObservedObject(wrappedValue: model.seedStore)
        _answer = State(initialValue: Self.known[file])
    }

    private var app: Status.SeedApp? { seeds.seed?.apps.first { $0.file == file } }
    private var info: IPADetails? { answer?.info }
    private var history: OutsideHistory? { answer?.history.flatMap { $0.entries.isEmpty ? nil : $0 } }

    @Environment(\.paneLayout) private var panes
    var body: some View {
        Group {
            // Open flat: the app and what's known of its versions on the left, the facts on the right; with no history,
            // the facts split across both, so neither pane is mostly empty and nothing runs across the fold.
            if panes { FoldSplit { pane(.left) } right: { pane(.right) } }
            else { pane(.whole) }
        }
        .holdsWhileMoving("appinfo")
        .background(groupedBackground.ignoresSafeArea())
        .topEdge()
        .pushedTitle()
        .task { await load() }
    }

    enum Side { case left, right, whole }
    private func pane(_ side: Side) -> some View {
        ScrollViewReader { proxy in
        List {
            Section { PaneHeading(title: "App Info", shown: side != .right) }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
            if side != .right, let app { Section { header(app).place("header") } }
            if let history, side != .right {
                whatsNew(history)
                if history.entries.count > 1 { olderVersions(history) }
            }
            // With history the facts are the right pane's. Without it, the package's facts sit under the app on the left,
            // and what it uses, its signature and where it came from on the right.
            if side == .whole || (side == .right && history != nil) || (side == .left && history == nil && info != nil) || (side == .right && info == nil) {
                general()
            }
            if side == .whole || side == .right {
                uses()
                signature()
                origin()
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .scrollsUnder()
        .keepsPlace("appinfo-\(file)-\(side)", proxy)
        .modifier(TabBarFade())
        }
    }

    // The app as its row shows it: icon, name, version, and how it stands on this iPhone; Update when a newer copy is ready.
    func header(_ app: Status.SeedApp) -> some View {
        let line = Self.standing(app)
        return HStack(spacing: 14) {
            AppIcon(app: app, size: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.title3.weight(.bold)).lineLimit(2)
                Text(Self.versionLine(info?.version ?? app.version, info?.build ?? app.build)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                if let line { Text(line.0).font(.subheadline).foregroundStyle(line.1).monospacedDigit() }
            }
            Spacer(minLength: 8)
            if let seed = seeds.seed, UpdatesSection.updates(seed).contains(where: { $0.id == app.id }), UpdatesSection.link(app) != nil {
                Button("Update") { OTAInstaller.shared.install([app]) }.rowCapsule()
            }
        }
        .padding(.vertical, 4)
    }
    // How the app stands on this iPhone, in the On this iPhone row's own words. Nothing when the Mac can't tell (the
    // phone out of its sight before it ever installed it): "Not on this iPhone" there would be a guess.
    static func standing(_ a: Status.SeedApp) -> (String, Color)? {
        switch a.state {
        case "installing": return ("Installing…", .secondary)
        case "failed": return ("Install failed", .red)
        case "missing": return ("Not on this iPhone", .orange)
        case "waiting", "update": return ("Build \(a.build) is ready", .secondary)
        case "unknown": return nil
        default:
            guard let days = SeedSection.daysLeft(a), let l = SeedSection.left(days) else { return ("On this iPhone", .secondary) }
            return (days > 0 ? l.0 + " on this iPhone" : "Expired on this iPhone", l.1)
        }
    }
    // "Version 2.1.0 (24)", the App Store's own way of writing it; a build that repeats the version once.
    static func versionLine(_ v: String, _ b: String) -> String {
        if v.isEmpty { return b.isEmpty ? "" : "Build \(b)" }
        return b.isEmpty || b == v ? "Version \(v)" : "Version \(v) (\(b))"
    }

    // The newest version found, as the App Store's What's New: its number, date and notes, three lines and "more".
    @ViewBuilder func whatsNew(_ h: OutsideHistory) -> some View {
        let newest = h.entries[0]
        Section {
            VStack(alignment: .leading, spacing: 8) {
                versionTitle(newest)
                if !newest.notes.isEmpty { WhatsNew(notes: newest.notes) }
            }
            .padding(.vertical, 6)
            .place("whatsnew")
            if let s = h.link, let url = URL(string: s) {
                Link(destination: url) {
                    HStack { Text(h.from == "GitHub" ? "Releases on GitHub" : "View on the App Store"); Spacer(); Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)) }
                }
            }
        } header: { Text("What’s New") } footer: {
            // Where it was read, so a newer App Store version than his copy isn't taken for his.
            Text(Self.sourceNote(h, have: info?.version ?? app?.version ?? ""))
        }
    }
    static func sourceNote(_ h: OutsideHistory, have: String) -> String {
        let place = h.from == "GitHub" ? "its GitHub releases" : "the App Store"
        let newest = h.entries[0].version
        if !have.isEmpty, newest != have, !h.entries.contains(where: { $0.version == have }) { return "From \(place). The copy on this iPhone is \(have)." }
        if !have.isEmpty, newest != have { return "From \(place). This iPhone has \(have), listed below." }
        return "From \(place)."
    }
    func versionTitle(_ e: OutsideHistory.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Version \(e.version)").font(.headline).monospacedDigit().lineLimit(1)
            if e.version == (info?.version ?? app?.version) {
                Text("On this iPhone").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(.green.opacity(0.15)).padding(.vertical, -2))
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if e.at > 0 { Text(Self.day(e.at)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
        }
    }
    func olderVersions(_ h: OutsideHistory) -> some View {
        Section("Version History") {
            ForEach(h.entries.dropFirst()) { e in
                VStack(alignment: .leading, spacing: 8) {
                    versionTitle(e)
                    if !e.notes.isEmpty { WhatsNew(notes: e.notes) }
                }
                .padding(.vertical, 6)
                .place("v-\(e.version)")
            }
        }
    }

    // The App Store's Information list, in groups: the package and what it runs on, what it uses, its signature, its
    // origin. From a Mac too old to read the package, the little the Apps tab knows, in one card.
    @ViewBuilder func general() -> some View {
        if let i = info {
            Section("Information") {
                if let by = history?.by, !by.isEmpty { row("Developer", by) }
                if let s = i.size, s > 0 { row("Size", Self.bytes(s)) }
                if let c = i.category, !c.isEmpty { row("Category", c) }
                if let m = i.minimumOS, !m.isEmpty { row("Requires", "iOS \(m) or later") }
                if let d = i.devices, !d.isEmpty { row("Runs on", d) }
                if let n = i.languages, n > 1 { row("Languages", "\(n)") }
                if let s = i.sdk, !s.isEmpty { row("Built for", s) }
                if let c = i.copyright, !c.isEmpty { row("Copyright", c) }
            }
        } else if let app, app.installedAt > 1_000_000_000 || app.expires > 0 {
            Section("Information") {
                if app.installedAt > 1_000_000_000 { row("Installed", Self.day(app.installedAt)) }
                if app.expires > 0 { expiry(app.expires) }
            }
        }
    }
    @ViewBuilder func uses() -> some View {
        let inc = info?.extensions ?? [], asks = info?.asks ?? [], caps = info?.capabilities ?? []
        if !inc.isEmpty || !asks.isEmpty || !caps.isEmpty {
            Section("What It Uses") {
                if !inc.isEmpty { row("Includes", inc.joined(separator: ", ")) }
                if !asks.isEmpty { row("Can ask for", asks.joined(separator: ", ")) }
                if !caps.isEmpty { row("Uses", caps.joined(separator: ", ")) }
            }
        }
    }
    // The copy on this iPhone is signed on the Mac; the package as it came may have had a signature of its own, or none.
    @ViewBuilder func signature() -> some View {
        if let i = info {
            let s = i.signed
            let ends = (s?.expires).flatMap { $0 > 0 ? $0 : nil } ?? app.flatMap { $0.expires > 0 ? $0.expires : nil }
            Section("Signature") {
                if let t = s?.team, !t.isEmpty { row("Signed by", t) }
                if let c = s?.created, c > 0 { row("Signed", Self.day(c)) }
                if let ends { expiry(ends) }
                if let t = i.cameSigned?.team, !t.isEmpty { row("As it came", "Signed by \(t)") }
                else { row("As it came", "Unsigned") }
            }
        }
    }
    func expiry(_ ends: Double) -> some View {
        let days = Int(ceil((ends / 1000 - Date().timeIntervalSince1970) / 86400))
        return LabeledContent("Expires") {
            Text(Self.day(ends)).foregroundStyle(days <= 1 ? Color.red : days <= 30 ? Color.orange : Color.secondary)
        }
    }
    @ViewBuilder func origin() -> some View {
        if let i = info {
            let installed = i.installedAt ?? app?.installedAt ?? 0
            Section("On the Mac") {
                if let src = i.source {
                    if src.kind == "files" { row("Added from", "Files") }
                    else if let h = src.host, !h.isEmpty { row("Downloaded from", h) }
                }
                if let a = i.addedAt, a > 0 { row("Added", Self.day(a)) }
                if installed > 1_000_000_000 { row("Installed", Self.day(installed)) }
                if let b = i.bundle, !b.isEmpty {
                    LabeledContent("Bundle ID") { Text(b).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                }
            }
        }
    }
    func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).multilineTextAlignment(.trailing) }
    }

    static func bytes(_ n: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
    // "Nov 5" this year, "Jul 11, 2024" before.
    static func day(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        if Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) { return d.formatted(.dateTime.month(.abbreviated).day()) }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    // Asked as the page opens; asked again while the Mac is still looking in public (it answers what it has after 6 s).
    // A Mac too old to know the page's details answers "not found": the page keeps what the Apps tab already knows, and
    // says nothing about it. One that doesn't answer is asked again every 3 s while the page is up.
    func load() async {
        var tries = 0
        while !Task.isCancelled {
            do {
                let got = try await model.api.ipaInfo(file)
                if got != answer { withAnimation(Motion.quick) { answer = got } }
                if got != Self.known[file] {
                    Self.known[file] = got
                    let all = Self.known, to = Self.knownFile
                    Task.detached(priority: .utility) { try? JSONEncoder().encode(all).write(to: to, options: .atomic) }
                }
                tries += 1
                guard got.historyPending == true, tries < 6 else { return }
            } catch is CancellationError { return }
            catch let e as URLError where e.code == .cancelled { return }
            catch is URLError {}
            catch { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
