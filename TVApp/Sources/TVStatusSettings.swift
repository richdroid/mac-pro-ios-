import SwiftUI

// Settings, behind a gear on Status rather than a tab of its own (Richard's answers, 2026-11-11: six tabs, "Settings sits
// behind a gear on Status"). The gear is the system's own toolbar item, laid out by iOS the Duo's way (at the top of the
// side strip folded and open in landscape, in the top bar open in portrait), and Settings is pushed with the system's Back,
// as every other page opened from a tab is (Apple's HIG for iPhone Duo; Richard, 2026-11-08).

// The page Settings is pushed as, on Status' own stack.
enum SettingsRoute: Hashable { case root }

// A tab's page pushing onto its own stack when asked from outside a link (Settings asked for as tab 9). An existential, so
// NavigationPath.append opens it to the concrete type its destination is registered for (never AnyHashable).
struct PagePush { var push: (any Hashable) -> Void = { _ in }; var pop: () -> Void = {} }
private struct PagePushKey: EnvironmentKey { static let defaultValue = PagePush() }
extension EnvironmentValues { var pagePush: PagePush { get { self[PagePushKey.self] } set { self[PagePushKey.self] = newValue } } }

struct StatusTab: View {
    @Environment(TVModel.self) var model
    @Environment(\.pagePush) private var pagePush
    @StateObject private var store = ManageStore()
    // The last ask for Settings acted on, so coming back to the tab doesn't push it again.
    @State private var seen = 0
    @MainActor static var scripted = false
    var body: some View {
        DeviceTab()
            // The bar carries the gear only: the page draws its own large heading.
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.tick(); pagePush.push(SettingsRoute.root) } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .shotSpot("gear", pose: "settingsnav")
                }
            }
            .navigationDestination(for: SettingsRoute.self) { _ in TVSettingsPage() }
            .navigationDestination(for: StremioRoute.self) { _ in StremioAccountPage() }
            .navigationDestination(for: ManagePage.self) { page in
                switch page {
                case .apps: ManageAppsView(store: store)
                case .settings: ManageSettingsView(store: store)
                case .connection: ConnectionView()
                }
            }
            // For the build's film where touches can't reach (the cover display): Settings pushed and popped, then TV
            // settings pushed and popped, at a finger's pace.
            // Once per launch, and not tied to this view's life: the root steps off screen at each push, which cancelled and
            // restarted a view task (37416ae: pushes and pops piling up).
            .onAppear {
                guard UserDefaults.standard.string(forKey: "pose") == "settingsscript", !Self.scripted else { return }
                Self.scripted = true
                let nav = pagePush
                Task { @MainActor in
                    func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
                    await wait(5); nav.push(SettingsRoute.root)
                    await wait(3); nav.pop()
                    await wait(3); nav.push(SettingsRoute.root)
                    await wait(3); nav.push(ManagePage.settings)
                    await wait(3); nav.pop()
                    await wait(3); nav.pop()
                }
            }
            .onChange(of: model.settingsAsked, initial: true) { _, n in
                guard n > seen else { return }
                seen = n
                openSettings()
            }
    }
    // Settings, and for the build's shots the page opened from it ("-pose connection", "-pose tvsettings", "-pose tvapps").
    func openSettings() {
        pagePush.push(SettingsRoute.root)
        switch UserDefaults.standard.string(forKey: "pose") {
        case "connection": pagePush.push(ManagePage.connection)
        case "tvsettings": pagePush.push(ManagePage.settings)
        case "tvapps": pagePush.push(ManagePage.apps)
        default: break
        }
    }
}

// The TV's own settings and this app's connection, pushed from Status. Its heading is drawn in the page, as the pages
// pushed from it draw theirs; the bar carries only the system's Back.
struct TVSettingsPage: View {
    @Environment(\.paneLayout) private var panes
    func page(_ content: some View) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 26) { content }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24) }
    }
    var body: some View {
        Group {
            // Unfolded, one list each side of the fold rather than one list across it, the two cards level.
            if panes {
                FoldSplit {
                    page(Group { PageHeading("Settings").padding(.horizontal, 4); TVManageSections(level: true).shotSpot("tvrow", pose: "settingsnav") })
                } right: {
                    page(Group { PageHeading(" ").padding(.horizontal, 4).hidden(); TVActionSections(); StremioSettingsSection() })
                }
            } else {
                page(Group { PageHeading("Settings").padding(.horizontal, 4); TVManageSections().shotSpot("tvrow", pose: "settingsnav"); TVActionSections(); StremioSettingsSection() })
            }
        }
        .summonsBar()
        .topShade().topFade()
        // The same wall as the pages opened from here, outside the fade's mask so its top isn't a black band.
        .background { Ambience() }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .barPage()
    }
}

// For the build's films only: where a control is, as fractions of the screen, told to the stand-in Mac's log
// (what=NAME&x=&y=) so a real touch through Device Hub can land on it. Nothing happens without the matching pose.
private struct ShotSpot: ViewModifier {
    let what: String, pose: String
    func body(content: Content) -> some View {
        if !what.isEmpty, UserDefaults.standard.string(forKey: "pose") == pose {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
                #if os(iOS)
                guard let screen = (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen.bounds,
                      screen.width > 0, r.width > 0 else { return }
                let x = r.midX / screen.width, y = r.midY / screen.height
                Task { _ = await TVBridge.data(TVBridge.url(String(format: "/api/tv/applied?what=%@&x=%.3f&y=%.3f", what, x, y)), timeout: 3) }
                // The system's Back for a page pushed from here: in the side strip, where this item sits; in the top bar
                // (open upright), at its leading end on this item's line.
                if what == "gear" {
                    let bx = r.minY < screen.height * 0.12 && r.midX > screen.width / 2 ? 43 / screen.width : x
                    Task { _ = await TVBridge.data(TVBridge.url(String(format: "/api/tv/applied?what=back&x=%.3f&y=%.3f", bx, y)), timeout: 3) }
                }
                #endif
            }
        } else { content }
    }
}
extension View { func shotSpot(_ what: String, pose: String) -> some View { modifier(ShotSpot(what: what, pose: pose)) } }
