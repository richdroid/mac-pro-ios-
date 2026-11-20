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
    struct Entry: Codable, Equatable, Identifiable { let version: String; let at: Double; let notes: [String]; var mine: Bool?; var id: String { version } }
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
    // The Mac answered that it doesn't know this request (one from before it): the page shows what the Apps tab knows.
    @State private var oldMac = false
    // Kept on the phone, so the page opens drawn, as Version History does, while the Mac is asked again.
    @MainActor static var known: [String: IPAAnswer] = {
        // The build's film of a first-ever open starts with nothing kept.
        if UserDefaults.standard.bool(forKey: "noInfoCache") { return [:] }
        guard let d = try? Data(contentsOf: knownFile) else { return [:] }
        return (try? JSONDecoder().decode([String: IPAAnswer].self, from: d)) ?? [:]
    }()
    private static var knownFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app-info.json") }
    @MainActor static func keep(_ file: String, _ got: IPAAnswer) {
        guard got != known[file] else { return }
        known[file] = got
        let all = known, to = knownFile
        Task.detached(priority: .utility) { try? JSONEncoder().encode(all).write(to: to, options: .atomic) }
    }
    // Asked as soon as a status names an added app, so its page opens whole the first time, never filling in as he looks.
    @MainActor private static var asked: Set<String> = []
    @MainActor static func prefetch(_ s: Status?, api: API) {
        for a in s?.iosApps?.apps ?? [] where a.own && !a.isOurs && !a.file.isEmpty && !asked.contains(a.file + "@" + a.build) {
            asked.insert(a.file + "@" + a.build)
            Task { if let got = try? await api.ipaInfo(a.file) { keep(a.file, got) } }
        }
    }

    init(file: String, model: AppModel) {
        self.file = file
        self.model = model
        _seeds = ObservedObject(wrappedValue: model.seedStore)
        _answer = State(initialValue: Self.known[file])
    }

    private var app: Status.SeedApp? { seeds.seed?.apps.first { $0.file == file } }
    private var info: IPADetails? { answer?.info }
    private var history: OutsideHistory? { answer?.history.flatMap { $0.entries.isEmpty ? nil : $0 } }
    // The version on this iPhone, only when the Mac knows the phone has the copy it holds; otherwise nothing is claimed.
    private var phoneVersion: String? {
        guard let app, app.state == "current" else { return nil }
        return app.version.isEmpty ? info?.version : app.version
    }

    @Environment(\.paneLayout) private var panes
    var body: some View {
        Group {
            // Open flat: the app and what's known of its versions on the left, the facts on the right; with no history,
            // the package's facts under the app on the left and its copies on the right, so neither pane is mostly
            // empty and nothing runs across the fold.
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
        let g = groups()
        return ScrollViewReader { proxy in
        List {
            Section { PaneHeading(title: "App Info", shown: side != .right) }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
            if side != .right, let app { Section { header(app).place("header") } }
            if let history, side != .right {
                whatsNew(history)
                if history.entries.count > 1 { olderVersions(history) }
            }
            ForEach(Array(g.enumerated()), id: \.offset) { i, group in
                // Without history the first group (Information) is the left pane's; the rest the right's.
                let left = history == nil && i == 0 && info != nil
                if side == .whole || (side == .left && left) || (side == .right && !left) {
                    Section(group.title) {
                        ForEach(group.facts, id: \.label) { f in
                            LabeledContent(f.label) {
                                Text(f.value).foregroundStyle(f.color).multilineTextAlignment(.trailing)
                                    .lineLimit(f.label == "Bundle ID" ? 1 : nil).truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
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
                Text(Self.versionLine(app.version.isEmpty ? info?.version ?? "" : app.version, app.build.isEmpty ? info?.build ?? "" : app.build)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
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
            // Where it was read, so a newer version than his copy isn't taken for his.
            Text(sourceNote(h))
        }
    }
    func isMine(_ e: OutsideHistory.Entry) -> Bool {
        guard let v = phoneVersion else { return false }
        return e.mine ?? (e.version == v)
    }
    func sourceNote(_ h: OutsideHistory) -> String {
        let place = h.from == "GitHub" ? "its GitHub releases" : "the App Store"
        guard let have = phoneVersion, !isMine(h.entries[0]) else { return "From \(place)." }
        if h.entries.contains(where: isMine) { return "From \(place). This iPhone has \(have), listed below." }
        return "From \(place). This iPhone has \(have)."
    }
    func versionTitle(_ e: OutsideHistory.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Version \(e.version)").font(.headline).monospacedDigit().lineLimit(1)
            if isMine(e) {
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

    // The App Store's Information list, in groups: the package, what it uses, the copy on this iPhone, the one on the
    // Mac. A group of one row joins Information (never a lone capsule beside rounded cards). From a Mac too old to read
    // the package, the little the Apps tab knows, in one card. While the first answer is on its way, nothing yet.
    struct Fact { let label: String; let value: String; var color: Color = .secondary }
    struct FactGroup { let title: String; var facts: [Fact] }
    func groups() -> [FactGroup] {
        // Before the Mac's answer (or from a Mac too old to give one), what the Apps list already knows about the copy on
        // this iPhone, at once and in its final place (the right pane open flat), so the page never opens on its header
        // alone; the package's facts join it when they come.
        guard let i = info else {
            guard let app else { return [] }
            var f: [Fact] = []
            if app.installedAt > 1_000_000_000, app.state != "missing" { f.append(Fact(label: "Installed", value: Self.day(app.installedAt))) }
            if app.expires > 0, app.state != "missing" { f.append(expiry(app.expires)) }
            return f.isEmpty ? [] : [FactGroup(title: "On this iPhone", facts: f)]
        }
        var main = FactGroup(title: "Information", facts: [])
        if let by = history?.by, !by.isEmpty { main.facts.append(Fact(label: "Developer", value: by)) }
        if let s = i.size, s > 0 { main.facts.append(Fact(label: "Size", value: Self.bytes(s))) }
        if let c = i.category, !c.isEmpty { main.facts.append(Fact(label: "Category", value: c)) }
        if let m = i.minimumOS, !m.isEmpty { main.facts.append(Fact(label: "Requires", value: "iOS \(m) or later")) }
        if let d = i.devices, !d.isEmpty { main.facts.append(Fact(label: "Runs on", value: d)) }
        if let n = i.languages, n > 1 { main.facts.append(Fact(label: "Languages", value: "\(n)")) }
        if let c = i.copyright, !c.isEmpty { main.facts.append(Fact(label: "Copyright", value: c)) }
        var uses = FactGroup(title: "What It Uses", facts: [])
        if let x = i.extensions, !x.isEmpty { uses.facts.append(Fact(label: "Includes", value: x.joined(separator: ", "))) }
        if let x = i.asks, !x.isEmpty { uses.facts.append(Fact(label: "Can ask for", value: x.joined(separator: ", "))) }
        if let x = i.capabilities, !x.isEmpty { uses.facts.append(Fact(label: "Uses", value: x.joined(separator: ", "))) }
        // The copy on this iPhone: when it went on, when its signature ends (the phone's copy, as the header counts it).
        var phone = FactGroup(title: "On this iPhone", facts: [])
        let team = i.signed?.team ?? ""
        if let app, app.installedAt > 1_000_000_000, app.state != "missing" {
            phone.facts.append(Fact(label: "Installed", value: Self.day(app.installedAt)))
            if app.expires > 0 { phone.facts.append(expiry(app.expires)) }
            if !team.isEmpty { phone.facts.append(Fact(label: "Signed by", value: team)) }
        }
        // The package the Mac keeps: where it came from, when, and how it came.
        var mac = FactGroup(title: "On the Mac", facts: [])
        if let src = i.source {
            if src.kind == "files" { mac.facts.append(Fact(label: "Added from", value: "Files")) }
            else if let h = src.host, !h.isEmpty { mac.facts.append(Fact(label: "Downloaded from", value: h)) }
        }
        if let a = i.addedAt, a > 0 { mac.facts.append(Fact(label: "Added", value: Self.day(a))) }
        if phone.facts.isEmpty, !team.isEmpty { mac.facts.append(Fact(label: "Signed by", value: team)) }
        if let t = i.cameSigned?.team, !t.isEmpty { mac.facts.append(Fact(label: "Originally", value: "Signed by \(t)")) }
        else { mac.facts.append(Fact(label: "Originally", value: "Unsigned")) }
        var out: [FactGroup] = []
        for g in [uses, phone, mac] where !g.facts.isEmpty {
            if g.facts.count == 1 { main.facts.append(contentsOf: g.facts) } else { out.append(g) }
        }
        if let b = i.bundle, !b.isEmpty { main.facts.append(Fact(label: "Bundle ID", value: b)) }
        return [main] + out
    }
    // The header's own rule for colour: grey until the last day, orange on it, red once it's passed.
    func expiry(_ ends: Double) -> Fact {
        let days = Int(ceil((ends / 1000 - Date().timeIntervalSince1970) / 86400))
        return Fact(label: "Expires", value: Self.day(ends), color: days <= 0 ? .red : days == 1 ? .orange : .secondary)
    }

    static func bytes(_ n: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
    // "Nov 5" this year, "Jul 11, 2024" before.
    static func day(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        if Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) { return d.formatted(.dateTime.month(.abbreviated).day()) }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    // Asked as the page opens; asked again while the Mac is still looking in public (it answers its facts at once and
    // what it found when it has it). A Mac too old to know the request answers "not found": the page keeps what the Apps
    // tab already knows, and says nothing about it. One that doesn't answer is asked again every 3 s while the page is up.
    func load() async {
        var tries = 0
        while !Task.isCancelled {
            do {
                let got = try await model.api.ipaInfo(file)
                if got != answer { withAnimation(Motion.quick) { answer = got } }
                Self.keep(file, got)
                tries += 1
                guard got.historyPending == true, tries < 8 else { return }
            } catch is CancellationError { return }
            catch let e as URLError where e.code == .cancelled { return }
            catch is URLError {}
            catch { if answer == nil { oldMac = true }; return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
