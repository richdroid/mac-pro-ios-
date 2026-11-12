import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// His own apps installed over the air, Apple's own way: the Mac serves each copy signed for this iPhone behind an
// itms-services link, the app opens it and iOS asks "Install", then downloads and installs it by itself, from anywhere on
// Tailscale (Richard, 2026-11-07: "build this into the mac pro app in a nice way ... or even does it automatically").
// iOS always asks, so the most it can do by itself is offer them as the app opens, one tap to start.
@MainActor
final class OTAInstaller: ObservableObject {
    static let shared = OTAInstaller()
    static let offerKey = "offerUpdates"
    // The Mac's alert, and its notification's category, for updates waiting while the phone is away from home.
    nonisolated static let alertID = "ios:waiting"
    private static let openedKey = "otaOpened", offeredKey = "otaOffered", offeredAtKey = "otaOfferedAt"
    // Builds offered and turned down aren't offered again for this long, unless a newer one arrives.
    private static let quietFor: TimeInterval = 6 * 3600

    struct Item: Equatable { let file: String; let name: String; let build: String; let link: URL }
    // The run in progress, in order, and which one iOS is asking about.
    @Published private(set) var queue: [Item] = []
    @Published private(set) var step = 0
    @Published var offering = false
    // Asked for from the notification or the alert on Status: starts as soon as the Mac has answered.
    @Published var wanted = false
    // Whether the app is in front, from the scene: iOS's "Install" question makes it inactive while it's up.
    var away = false
    // Offered once each time the app comes to the front, never again while the installs come and go.
    var offeredThisVisit = false

    var running: Bool { !queue.isEmpty }
    var current: Item? { queue.indices.contains(step) ? queue[step] : nil }

    // What can go now: his own apps with a newer build the Mac has signed for this iPhone. This app itself, once already
    // at that build, is done whatever the Mac (which can't see the phone away from home) still says.
    static func ready(_ s: Status?) -> [Status.SeedApp] {
        (s?.iosApps?.apps ?? []).filter { a in
            guard a.own, !(a.ota ?? "").isEmpty, ["waiting", "update"].contains(a.state) else { return false }
            return !(isThisApp(a) && thisBuild == a.build)
        }
    }
    static func isThisApp(_ a: Status.SeedApp) -> Bool {
        a.file == "MacPro.ipa" || a.name == (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Mac Pro")
    }
    static var thisBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    // Builds whose install this phone has already opened. Away from home the Mac can't see what the phone has, so this
    // is how an update tapped once stops being offered.
    func wasOpened(_ a: Status.SeedApp) -> Bool {
        (UserDefaults.standard.dictionary(forKey: Self.openedKey) as? [String: String])?[a.id] == a.build
    }
    private func markOpened(_ i: Item) {
        var d = UserDefaults.standard.dictionary(forKey: Self.openedKey) as? [String: String] ?? [:]
        d[i.file] = i.build
        UserDefaults.standard.set(d, forKey: Self.openedKey)
        objectWillChange.send()
    }
    // Not yet opened on this phone: what the offer and the Install all card count.
    func pending(_ s: Status?) -> [Status.SeedApp] { Self.ready(s).filter { !wasOpened($0) } }

    private static func key(_ apps: [Status.SeedApp]) -> String { apps.map { "\($0.id)@\($0.build)" }.sorted().joined(separator: ",") }
    func offerDue(_ apps: [Status.SeedApp]) -> Bool {
        let d = UserDefaults.standard
        return d.string(forKey: Self.offeredKey) != Self.key(apps) || Date().timeIntervalSince1970 - d.double(forKey: Self.offeredAtKey) > Self.quietFor
    }
    func markOffered(_ apps: [Status.SeedApp]) {
        UserDefaults.standard.set(Self.key(apps), forKey: Self.offeredKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.offeredAtKey)
    }

    // One link at a time: iOS shows one "Install" question and drops a second opened while it's up. Each next link opens
    // once the app is back in front after the question was answered. This app goes last: installing it ends it.
    func install(_ apps: [Status.SeedApp]) {
        guard !running else { return }
        let items = apps.sorted { !Self.isThisApp($0) && Self.isThisApp($1) }
            .compactMap { a in URL(string: a.ota ?? "").map { Item(file: a.id, name: a.name, build: a.build, link: $0) } }
        guard !items.isEmpty else { return }
        queue = items; step = 0
        Task {
            for (i, item) in items.enumerated() {
                step = i
                Self.open(item.link)
                markOpened(item)
                if i < items.count - 1, !(await answered()) { break }
            }
            // The last question stays marked a moment, so the card doesn't snap back the instant it's asked.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            queue = []; step = 0
        }
    }

    // Up to 3 s for iOS's question to come up, then as long as it's up (a couple of minutes at most), then a second for
    // it to go. False when he left the app instead: the rest keep their own Install buttons.
    private func answered() async -> Bool {
        var t = 0.0
        while !away, t < 3 { try? await Task.sleep(nanoseconds: 100_000_000); t += 0.1 }
        t = 0
        while away, t < 120 { try? await Task.sleep(nanoseconds: 200_000_000); t += 0.2 }
        if away { return false }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return !away
    }

    private static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

// On the whole app: the offer as it comes to the front, and the install asked for from the notification.
struct OTAOffer: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject private var ota = OTAInstaller.shared
    @Environment(\.scenePhase) private var phase
    @AppStorage(OTAInstaller.offerKey) private var offerOn = false

    // Changes when there's something new to offer or the Mac first answers. Worked out as a status lands (StatusStore), so
    // the whole app isn't watching every reading for it.
    @State private var trigger = ""
    private func retrigger(_ s: Status?) {
        let t = "\(model.gotFresh)|" + OTAInstaller.ready(s).map { "\($0.id)@\($0.build)" }.joined(separator: ",")
        if t != trigger { trigger = t }
    }
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $ota.offering) {
                OTAOfferSheet(apps: ota.pending(model.status)) { apps in
                    ota.offering = false
                    model.tab = 1
                    // Once the sheet has gone, so iOS's question isn't asked over it.
                    Task { try? await Task.sleep(nanoseconds: 500_000_000); ota.install(apps) }
                }
            }
            .onChange(of: phase) { _, p in
                ota.away = p != .active
                if p == .background { ota.offeredThisVisit = false }
                if p == .active { consider() }
            }
            .onReceive(model.statusStore.$status) { retrigger($0) }
            .onChange(of: model.gotFresh) { retrigger(model.status) }
            .onChange(of: trigger) { consider() }
            .onChange(of: ota.wanted) { consider() }
            .onAppear { consider() }
    }
    private func consider() {
        guard phase == .active, !ota.running, model.gotFresh, model.problem == nil else { return }
        if ota.wanted {
            ota.wanted = false
            let ready = OTAInstaller.ready(model.status)
            if !ready.isEmpty { model.tab = 1; ota.install(ready) }
            return
        }
        // The build's shots show the offer only in its own pose, so it isn't over the others.
        guard offerOn || model.pose == "otaoffer", model.pose.isEmpty || model.pose == "otaoffer" else { return }
        let apps = ota.pending(model.status)
        // Its pose is shot in several postures one after another, each a fresh launch that must show it.
        guard !apps.isEmpty, !ota.offering, !ota.offeredThisVisit, ota.offerDue(apps) || model.pose == "otaoffer",
              !model.signInSheet, !model.screenOpen, !model.apiSetup else { return }
        ota.offeredThisVisit = true
        ota.markOffered(apps)
        ota.offering = true
    }
}
extension View {
    func otaOffer(_ model: AppModel) -> some View { modifier(OTAOffer(model: model)) }
}

// What's ready, build by build, and one tap to start. iOS still asks once for each.
struct OTAOfferSheet: View {
    let apps: [Status.SeedApp]
    let install: ([Status.SeedApp]) -> Void
    @Environment(\.dismiss) private var dismiss
    // As tall as what's in it, measured, so it sits low over the page whatever the posture.
    @State private var height: CGFloat = 430
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 52)).foregroundStyle(.white, macBlue)
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text(apps.count == 1 ? "Update ready" : "\(apps.count) updates ready").font(.title2.weight(.bold))
                // Only what he needs to know before tapping: iOS will ask once per app. Where it comes from is plumbing.
                Text("iOS asks you to confirm each one.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Divider().padding(.leading, 16) }
                    // The same app as on the Apps tab's row: its icon, its name, its build in the same words.
                    HStack(spacing: 12) {
                        AppIcon(app: a, size: 32)
                        Text(a.name).font(.headline)
                        Spacer(minLength: 8)
                        Text(a.phoneBuild.isEmpty ? "Build \(a.build)" : "Build \(a.phoneBuild) → \(a.build)")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: cardRadius - 6, style: .continuous))
            VStack(spacing: 6) {
                Button { install(apps) } label: {
                    // The Apps tab's words for the same thing: Update, Update All.
                    Text(apps.count == 1 ? "Update" : "Update All").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(macBlue)
                Button("Not now") { dismiss() }
                    .font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 8)
        .frame(maxWidth: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
    }
}

// The top of the Apps tab, the App Store's way: each app with a newer build, its icon, when it was built, an Update
// capsule, and what's new in it; Update All above when there's more than one (Richard, 2026-11-07: "the updates should
// be in the apps tab ... redesign that around it", the count a badge on the tab "exactly like app store").
struct UpdatesSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var ota = OTAInstaller.shared
    let seed: Status.SeedStatus
    @State private var fails: [String: String] = [:]

    // Everything of his with a newer build than the phone's, whether it can go over the air now or only on home Wi-Fi.
    // One already sent to this iPhone over the air is done as far as he's concerned: away from home the Mac can't see the
    // phone to know, and "Update" on it all shift would ask him to do again what he did (designer HOLD, 2026-11-07).
    @MainActor static func updates(_ seed: Status.SeedStatus) -> [Status.SeedApp] {
        seed.apps.filter { a in
            guard a.own, ["waiting", "update", "installing"].contains(a.state) else { return false }
            if a.state != "installing", link(a) != nil, OTAInstaller.shared.wasOpened(a) { return false }
            return !(OTAInstaller.isThisApp(a) && a.build == OTAInstaller.thisBuild)
        }
    }
    static func link(_ a: Status.SeedApp) -> URL? { (a.ota ?? "").isEmpty ? nil : URL(string: a.ota!) }

    var body: some View {
        let ups = Self.updates(seed)
        let ready = ups.filter { Self.link($0) != nil }
        Section {
            if ups.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    Text("All your apps are up to date").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(ups) { a in row(a) }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(ups.count > 1 ? "\(ups.count) Updates" : "Updates").font(.title3.weight(.bold)).foregroundStyle(.primary)
                Spacer()
                if ready.count > 1 {
                    Button(ota.running ? "Updating…" : "Update All") { ota.install(ready) }
                        .font(.body.weight(.semibold)).tint(macBlue)
                        .disabled(ota.running)
                }
            }
            .textCase(nil)
            .padding(.bottom, 2)
        }
    }

    func row(_ a: Status.SeedApp) -> some View {
        // The app's row opens its Version History, as on the App Store; Update and "more" keep their own taps. The
        // system's button style in the list, so the press is the row's own highlight inside the card's corners.
        // Color.primary, the label colour itself: .primary resolved to the style's tint and turned every line blue.
        Button { model.appHistory = a.file } label: { rowBody(a).foregroundStyle(Color.primary) }
            .accessibilityHint(a.isOurs ? "Opens its version history" : "Opens its details")
            .place("update-\(a.id)")
    }
    func rowBody(_ a: Status.SeedApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                AppIcon(app: a, size: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.headline)
                    // Folded, the column between the icon and the capsule is about 150 pt: each line fits whole, shrinking a
                    // little rather than being cut off.
                    Text(Self.when(a)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                    // Why its capsule is dimmed, on a line of its own.
                    if Self.link(a) == nil && !seed.reachable && a.state != "installing" {
                        Text("On home Wi-Fi").font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                // As tall as its lines, so a third line never shrinks the others; only a narrow column scales them.
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                button(a)
            }
            if let f = fails[a.id] { Text(f).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let notes = a.notes, !notes.isEmpty { WhatsNew(notes: notes) }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder func button(_ a: Status.SeedApp) -> some View {
        if a.state == "installing" || ota.current?.file == a.id {
            ProgressView().controlSize(.regular).frame(width: 84)
        } else if Self.link(a) != nil {
            Button("Update") { ota.install([a]) }
            .rowCapsule()
            .disabled(ota.running)
            .accessibilityLabel("Update \(a.name) to build \(a.build)")
        } else if seed.reachable {
            // At home, before the Mac has a copy signed ahead: the Mac installs it over Wi-Fi.
            Button {
                fails[a.id] = nil
                Task { fails[a.id] = await model.run("ios-seed", ["file": a.file]) }
            } label: { Text("Update") }
            .rowCapsule()
            .disabled(!seed.seeding.isEmpty)
        } else {
            // No copy signed ahead yet, away from home: the capsule is there, dimmed, and the row says when it goes.
            Text("Update").font(.subheadline.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.08), in: Capsule()).foregroundStyle(.secondary)
                .accessibilityLabel("\(a.name) updates on home Wi-Fi")
        }
    }

    // "Build 178 · Today", as the App Store dates each update.
    static func when(_ a: Status.SeedApp) -> String {
        var parts = ["Build \(a.build)"]
        if let ms = a.builtAt, ms > 0 {
            let d = Date(timeIntervalSince1970: ms / 1000), cal = Calendar.current
            parts.append(cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.month(.abbreviated).day()))
        }
        return parts.joined(separator: " · ")
    }
}

// What's new, three lines with "more" at the end of the third like the App Store's, only when there is more. The same
// bullet lines as Version History, collapsed and opened: "more" lets the rest of the list show under the lines already
// there, never a second layout (it was a run-on paragraph cut mid-word, then bullets once opened).
struct WhatsNew: View {
    let notes: [String]
    @State private var open = false
    @State private var whole: CGFloat = 0
    // One line of the notes' type; until measured, the system's own figure for it.
    @State private var line: CGFloat = NoteLines.lineHeight
    private var cut: CGFloat { line * 3 }
    private var more: Bool { whole > cut + 1 }
    var body: some View {
        NoteLines(notes: notes)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { whole = $0 }
            .frame(height: open || !more ? nil : cut, alignment: .top)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if more && !open {
                    Button { withAnimation(.snappy) { open = true } } label: {
                        Text("more").fontWeight(.semibold).foregroundStyle(macBlue)
                            .padding(.leading, 40)
                            .background(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: cardFill, location: 0.5)], startPoint: .leading, endPoint: .trailing))
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(alignment: .topLeading) {
                Text("A").hidden().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { line = $0 }
            }
            .font(.subheadline)
    }
}

// An update's notes, one bullet per change with its wrap hung under the text: on an Updates row, opened by "more", and in
// Version History alike. No gap between them, so three lines are always exactly three lines' height.
struct NoteLines: View {
    let notes: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(notes.enumerated()), id: \.offset) { i, n in
                // "# " starts a heading over the lines under it, as an App Store or GitHub release groups its notes.
                if n.hasPrefix("# ") {
                    Text(n.dropFirst(2)).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, i == 0 ? 0 : 6)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(n).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    @MainActor static var lineHeight: CGFloat {
        #if canImport(UIKit)
        return UIFont.preferredFont(forTextStyle: .subheadline).lineHeight.rounded(.up)
        #else
        return 18
        #endif
    }
}

extension View {
    // The one capsule on every row of his apps, as the App Store's Update and Open: bold, filled for the thing to do now
    // (Update, Install), tinted glass for the rest (Renew, Quit). Before, Update was bold and small, Install larger and
    // semibold, Renew and Quit plain body in a rounded rectangle: four buttons for one job.
    @ViewBuilder func rowCapsule(prominent: Bool = true) -> some View {
        if prominent {
            self.font(.subheadline.weight(.bold)).buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(macBlue)
        } else {
            self.font(.subheadline.weight(.bold)).buttonStyle(.bordered).buttonBorderShape(.capsule).tint(macBlue)
        }
    }
}

// An app's own icon, fetched once from the Mac; until then (or for an app the Mac has no package of) a plain tile.
struct AppIcon: View {
    let app: Status.SeedApp
    var size: CGFloat = 58
    @State private var image: Image?
    // No icon to fetch (an app he added that carries none), or the fetch failed: the app's initial on a quiet tile,
    // never a blank square (gate 3, Delta).
    @State private var none = false
    private var key: String { IconCache.key(app) }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        ZStack {
            // Until its icon is here, a plain square in the icon's place, never a stand-in picture; then it fades in.
            Color(white: 0.2)
            if none, image == nil {
                LinearGradient(colors: [Color(white: 0.36), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
                Text(app.name.prefix(1).uppercased()).font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.92))
            }
            if let image { image.resizable().interpolation(.high).scaledToFill().transition(.opacity) }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: key) {
            if let known = IconCache.images[key] { image = known; return }
            guard let api = IconCache.api, let i = await IconCache.fetch(app, api: api) else { none = true; return }
            withAnimation(.easeOut(duration: 0.25)) { image = i }
        }
    }
}

@MainActor
enum IconCache {
    static var images: [String: Image] = [:]
    // The Mac to ask, set by the model, so an icon never watches the model (it redrew with every reading).
    static var api: API?
    static func key(_ a: Status.SeedApp) -> String { (a.icon ?? "") + "@" + a.build }
    static func fetch(_ a: Status.SeedApp, api: API) async -> Image? {
        guard let path = a.icon, !path.isEmpty, let d = try? await api.data(path), let i = make(d) else { return nil }
        images[key(a)] = i
        return i
    }
    // As soon as a status names his apps, so the Apps tab opens with their icons already there over a slow link.
    static func prefetch(_ s: Status?, api: API) {
        for a in s?.iosApps?.apps ?? [] where a.own && images[key(a)] == nil { Task { _ = await fetch(a, api: api) } }
    }
    static func make(_ d: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: d).map { Image(uiImage: $0) }
        #else
        return nil
        #endif
    }
}

// The count on the app's home-screen icon: the updates waiting, nothing else.
enum AppBadge {
    static func set(_ n: Int) {
        #if canImport(UIKit)
        // The icon's number needs leave to badge, asked once, the first time there's one to show; never in the build's
        // shots, which launch with an address and shouldn't have a prompt over them.
        let shots = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["address"] != nil
        Task {
            let c = UNUserNotificationCenter.current()
            if n > 0, !shots, await c.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await c.requestAuthorization(options: [.badge, .alert, .sound])
            }
            try? await c.setBadgeCount(n)
        }
        #endif
    }
}

// One finished build of an app and what changed in it, from the Mac's copy of the code.
struct BuildNotes: Codable, Identifiable, Equatable {
    let build: String; let at: Double; let notes: [String]
    var id: String { build }
}

// Every finished build that changed the app, newest first: its number, when, and what changed, the one on this iPhone
// marked. Pushed on the Apps tab's stack, with the system's own Back (the Duo's way, 2026-11-08 ruling).
struct VersionHistoryView: View {
    // Held, not watched: the page redraws for its own app's entry (seeds) and the installer, never for a reading.
    let model: AppModel
    @ObservedObject private var seeds: SeedStore
    @ObservedObject private var ota = OTAInstaller.shared
    let file: String
    @State private var builds: [BuildNotes]?
    @State private var failed: String?
    @State private var misses = MissClock()
    // Kept on the phone, so opening it again (or after a relaunch) shows the list from its first frame while the Mac is
    // asked again; never a "Loading…" row that swaps out in front of him.
    @MainActor static var known: [String: [BuildNotes]] = {
        guard let d = try? Data(contentsOf: knownFile) else { return [:] }
        return (try? JSONDecoder().decode([String: [BuildNotes]].self, from: d)) ?? [:]
    }()
    private static var knownFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("version-history.json") }

    init(file: String, model: AppModel) {
        self.file = file
        self.model = model
        _seeds = ObservedObject(wrappedValue: model.seedStore)
        _builds = State(initialValue: Self.known[file])
    }

    private var app: Status.SeedApp? { seeds.seed?.apps.first { $0.file == file } }

    // The build on this iPhone: this app knows its own; for the others, what the Mac last saw on the phone.
    // What the Mac sees on the phone first, so the page says what the On this iPhone row says; away from home this app
    // still knows its own.
    static func phoneBuild(_ a: Status.SeedApp) -> String {
        if !a.phoneBuild.isEmpty { return a.phoneBuild }
        if OTAInstaller.isThisApp(a) { return OTAInstaller.thisBuild }
        return a.state == "current" ? a.build : ""
    }
    // The entry marked "On this iPhone": the phone's own build, or, when that build changed nothing in this app (so it
    // isn't listed), the newest listed build before it, whose changes are the ones he has.
    static func hereBuild(_ phone: String, in builds: [BuildNotes]) -> String? {
        if builds.contains(where: { $0.build == phone }) { return phone }
        guard let p = Int(phone) else { return nil }
        return builds.compactMap { Int($0.build) }.filter { $0 <= p }.max().map(String.init)
    }
    // Under the name, what the build marked "On this iPhone" below doesn't already say: how long it has left, or that a
    // newer one waits (it said "Build 204 on this iPhone" right above "Build 204  On this iPhone").
    static func onPhoneLine(_ a: Status.SeedApp) -> (String, Color) {
        let b = phoneBuild(a)
        if b.isEmpty { return ("Not on this iPhone", .orange) }
        if let tf = a.tfNewer { return ("Build \(tf) in TestFlight", .secondary) }
        if b != a.build, ["waiting", "update", "installing"].contains(a.state) { return ("Build \(a.build) is ready", .secondary) }
        if a.state == "failed" { return ("Install failed", .red) }
        guard let days = SeedSection.daysLeft(a), let l = SeedSection.left(days) else { return ("On this iPhone", .secondary) }
        return (l.0 + " on this iPhone", l.1)
    }
    // "Today, 10:16 AM", "Yesterday, 9:50 PM", "Nov 6": several builds can land in a day.
    static func when(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000), cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Today, \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday, \(time)" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    @Environment(\.paneLayout) private var panes
    var body: some View {
        Group {
            // Open flat, the App Store's app page across the two panes: the app and what's new in its newest build on the
            // left, every build on the right, so no line runs across the fold (designer HOLD, CI ac93e14).
            // The right pane goes on from the build after it, so the newest never shows twice side by side.
            if panes { FoldSplit { pane(header: true, showBuilds: false) } right: { pane(header: false, showBuilds: true, afterNewest: true) } }
            else { pane(header: true, showBuilds: true) }
        }
        .holdsWhileMoving("versions")
        .background(groupedBackground.ignoresSafeArea())
        .topEdge()
        // The page's name as large as every tab's, never the small bar title it was (17 pt, under the 20 pt app name in the
        // card below it, beside a 34 pt "Apps" one Back away), and placed as every pushed page's is (pushedTitle).
        .pushedTitle()
        .task { await load() }
    }
    private func pane(header: Bool, showBuilds: Bool, afterNewest: Bool = false) -> some View {
        ScrollViewReader { proxy in
        List {
            // As a tab's paneTitle: at the cards' edge, the same height in both panes so their first cards start level.
            Section { PaneHeading(title: "Version History", shown: header) }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
            if header, let app {
                Section {
                    // Beside the name when the line fits whole; folded, "Build 11 on this iPhone" wrapped to two lines
                    // beside Update (CI ac93e14), so there Update goes under the name, as on the App Store's app page.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            AppIcon(app: app, size: 58)
                            names(app).fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
                            update(app)
                        }
                        HStack(alignment: .top, spacing: 14) {
                            AppIcon(app: app, size: 58)
                            VStack(alignment: .leading, spacing: 10) { names(app); update(app) }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.vertical, 4)
                    .place("header")
                }
            }
            if header, !showBuilds, let builds, let newest = builds.first {
                let here = app.flatMap { Self.hereBuild(Self.phoneBuild($0), in: builds) }
                Section("What’s New") { entry(newest, here: newest.build == here).place(newest.id) }
            }
            // The page already says Version History; the builds follow the app without a heading saying it again.
            if showBuilds {
            Section {
                if let builds {
                    if builds.isEmpty { Text("No builds yet").foregroundStyle(.secondary) }
                    let here = app.flatMap { Self.hereBuild(Self.phoneBuild($0), in: builds) }
                    ForEach(afterNewest ? Array(builds.dropFirst()) : builds) { entry($0, here: $0.build == here).place($0.id) }
                } else if let failed {
                    // Something he can do about it: ask again.
                    Button { self.failed = nil; Task { await load() } } label: {
                        HStack {
                            Text(failed).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text("Try Again").fontWeight(.semibold).foregroundStyle(macBlue)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                }
            }
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
        // At the end of the list the card's foot rests clear of the fade above the tab bar, ending on its rounded corners
        // as Apps does, not dissolving into it (CI ac93e14's film, open upright).
        .contentMargins(.bottom, 24, for: .scrollContent)
        .scrollsUnder()
        // Opened, turned or closed, the page comes back at the build he was reading.
        .keepsPlace("versions-\(file)", proxy)
        // Open upright the tab bar floats over the page's foot; the notes fade out above it, as on Apps itself, instead of
        // reading on either side of it (Richard, 2026-11-05: "fade page content out under the tab bar").
        .modifier(TabBarFade())
        }
    }

    func names(_ app: Status.SeedApp) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let line = Self.onPhoneLine(app)
            Text(app.name).font(.title3.weight(.bold))
            Text(line.0).font(.subheadline).foregroundStyle(line.1).monospacedDigit()
        }
    }
    // A newer build ready for this iPhone: Update, as on the app's App Store page.
    @ViewBuilder func update(_ app: Status.SeedApp) -> some View {
        if let seed = seeds.seed, UpdatesSection.updates(seed).contains(where: { $0.id == app.id }), UpdatesSection.link(app) != nil {
            if ota.current?.file == app.id { ProgressView().frame(width: 84) }
            else {
                Button("Update") { ota.install([app]) }
                    .rowCapsule()
                    .disabled(ota.running)
                    .accessibilityLabel("Update \(app.name) to build \(app.build)")
            }
        }
    }

    func entry(_ b: BuildNotes, here: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Build \(b.build)").font(.headline).monospacedDigit()
                if here {
                    // The capsule's height is drawn, not laid out: its padding in the row's height made that one row a
                    // fraction of a pixel taller, and the list showed a black hairline across the card under it (open
                    // portrait, CI 09a29be).
                    Text("On this iPhone").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(.green.opacity(0.15)).padding(.vertical, -2))
                }
                Spacer(minLength: 8)
                Text(Self.when(b.at)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            // The same lines as the Updates row's what's new.
            NoteLines(notes: b.notes).font(.subheadline)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // A Mac that doesn't answer is asked again every 2 s, and only said to be unreachable after 8 s of it (MissClock).
    func load() async {
        while !Task.isCancelled, !(await loadOnce()) { try? await Task.sleep(nanoseconds: 2_000_000_000) }
    }
    // True once there's nothing more to ask: the list came, or the Mac has been away long enough to say so.
    func loadOnce() async -> Bool {
        do {
            let got = try await model.api.history(file)
            misses.hit()
            failed = nil
            if got != builds { builds = got }
            if got != Self.known[file] {
                Self.known[file] = got
                let all = Self.known, to = Self.knownFile
                Task.detached(priority: .utility) { try? JSONEncoder().encode(all).write(to: to, options: .atomic) }
            }
        }
        catch is CancellationError { return true }
        catch let e as URLError where e.code == .cancelled { return true }
        catch {
            // A list already here stays; with none, say why: no answer at all is the Mac, an answer that isn't the list
            // is the Mac not having it right now.
            guard builds == nil else { return true }
            if error is URLError {
                guard misses.miss() else { return false }
                failed = "Can’t reach the Mac"
            } else { failed = "The Mac couldn’t read the history" }
            return true
        }
        return true
    }
}
