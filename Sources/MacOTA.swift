import SwiftUI
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
    @AppStorage(OTAInstaller.offerKey) private var offerOn = true

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
        guard offerOn, model.pose.isEmpty || model.pose == "otaoffer" else { return }
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

// At the top of the iPhone's apps when more than one update is waiting: all of them in one go.
struct OTAAllCard: View {
    @ObservedObject private var ota = OTAInstaller.shared
    let apps: [Status.SeedApp]
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 34)).foregroundStyle(.white, macBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ota.running ? "Installing updates" : "\(apps.count) updates ready").font(.headline)
                        Text(apps.map(\.name).formatted(.list(type: .and))).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button { if !ota.running { ota.install(apps) } } label: {
                    HStack(spacing: 8) {
                        if let c = ota.current {
                            ProgressView().tint(.white)
                            Text("\(c.name), \(ota.step + 1) of \(ota.queue.count)")
                        } else {
                            Text("Install all updates")
                        }
                    }
                    .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(macBlue)
                Text(ota.running ? "Tap Install each time iOS asks." : "Over the air from the Mac. iOS asks to install each one in turn.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(macBlue.opacity(0.16))
    }
}

// In Settings: whether the app offers waiting updates as it opens.
struct OTASettings: View {
    @AppStorage(OTAInstaller.offerKey) private var offer = true
    var body: some View {
        Section {
            Toggle("Offer updates when I open the app", isOn: $offer)
        } header: { Text("App updates") } footer: {
            Text("When the Mac has a new build of one of your apps, it’s offered as the app opens, and installs over the air from anywhere on Tailscale.")
        }
    }
}
