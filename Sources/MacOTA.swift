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

    // Changes when there's something new to offer or the Mac first answers.
    private var trigger: String {
        "\(model.gotFresh)|" + OTAInstaller.ready(model.status).map { "\($0.id)@\($0.build)" }.joined(separator: ",")
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
                Text("From the Mac, over the air. iOS asks you to confirm each one.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Divider().padding(.leading, 16) }
                    HStack {
                        Text(a.name).font(.body.weight(.medium))
                        Spacer(minLength: 8)
                        Text(a.phoneBuild.isEmpty ? "Build \(a.build)" : "\(a.phoneBuild) → \(a.build)")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: cardRadius - 6, style: .continuous))
            VStack(spacing: 6) {
                Button { install(apps) } label: {
                    Text(apps.count == 1 ? "Install" : "Install all").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                AppIcon(app: a, size: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.headline)
                    Text(Self.when(a)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    // Why its capsule is dimmed, on a line of its own so it's never cut off folded.
                    if Self.link(a) == nil && !seed.reachable && a.state != "installing" {
                        Text("Installs on home Wi-Fi").font(.footnote).foregroundStyle(.secondary)
                    }
                }
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
            Button { ota.install([a]) } label: {
                Text("Update").font(.subheadline.weight(.bold)).frame(minWidth: 62)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(macBlue)
            .disabled(ota.running)
            .accessibilityLabel("Update \(a.name) to build \(a.build)")
        } else if seed.reachable {
            // At home, before the Mac has a copy signed ahead: the Mac installs it over Wi-Fi.
            Button {
                fails[a.id] = nil
                Task { fails[a.id] = await model.run("ios-seed", ["file": a.file]) }
            } label: { Text("Update").font(.subheadline.weight(.bold)).frame(minWidth: 62) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(macBlue)
            .disabled(!seed.seeding.isEmpty)
        } else {
            // No copy signed ahead yet, away from home: the capsule is there, dimmed, and the row says when it goes.
            Text("Update").font(.subheadline.weight(.bold)).frame(minWidth: 62)
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

// What's new, three lines with "more" at the end of the third like the App Store's, only when there is more; opened,
// one line per change.
struct WhatsNew: View {
    let notes: [String]
    @State private var open = false
    @State private var shown: CGFloat = 0
    @State private var whole: CGFloat = 0
    private var more: Bool { whole > shown + 1 }
    var body: some View {
        Group {
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Text(n).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .transition(.opacity)
            } else {
                let text = notes.joined(separator: "\n")
                Text(text).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shown = $0 }
                    // The whole text, unclipped and unseen, to know whether three lines hold it.
                    .background(alignment: .topLeading) {
                        Text(text).fixedSize(horizontal: false, vertical: true).hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { whole = $0 }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if more {
                            Button { withAnimation(.snappy) { open = true } } label: {
                                Text("more").fontWeight(.semibold).foregroundStyle(macBlue)
                                    .padding(.leading, 40)
                                    .background(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Color(white: 0.11), location: 0.5)], startPoint: .leading, endPoint: .trailing))
                            }
                            .buttonStyle(.plain)
                        }
                    }
            }
        }
        .font(.subheadline)
    }
}

// An app's own icon, fetched once from the Mac; until then (or for an app the Mac has no package of) a plain tile.
struct AppIcon: View {
    @EnvironmentObject var model: AppModel
    let app: Status.SeedApp
    var size: CGFloat = 58
    @State private var image: Image?
    private var key: String { IconCache.key(app) }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        ZStack {
            // Until its icon is here, a plain square in the icon's place, never a stand-in picture; then it fades in.
            Color(white: 0.2)
            if let image { image.resizable().interpolation(.high).scaledToFill().transition(.opacity) }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: key) {
            if let known = IconCache.images[key] { image = known; return }
            guard let i = await IconCache.fetch(app, api: model.api) else { return }
            withAnimation(.easeOut(duration: 0.25)) { image = i }
        }
    }
}

@MainActor
enum IconCache {
    static var images: [String: Image] = [:]
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

// In Settings: whether the app offers waiting updates as it opens.
struct OTASettings: View {
    @AppStorage(OTAInstaller.offerKey) private var offer = false
    var body: some View {
        Section {
            Toggle("Also ask when I open the app", isOn: $offer)
        } header: { Text("App updates") } footer: {
            Text("New builds of your apps show as a number on the Apps tab and on the app’s icon, and install over the air from anywhere on Tailscale.")
        }
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
