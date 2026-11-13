import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Screen and MacPro Console built around each other (Richard, 2026-11-13: "integrated with the app… help with the handoff
// and optimization; build the iPhone app and dashboard around each other"). The phone tells the bridge when Screen opens,
// changes shape and closes, and where it was (POST /api/mac/screen/session), so the Console on the Mac lays itself out
// for the phone and opens on the same thing; the Console can hand a place back (a macproapp:// link), which the phone
// lands on as Screen closes. A bridge without the route (an older one) answers 404 and nothing changes here.

// The app's places as links, the same names the Console uses (API.md 4.4):
//   macproapp://tab/<n>                     a tab by number (as before)
//   macproapp://status[/temps[/<sensor>]]   Status; a sensor's day
//   macproapp://disk                        the disk's day
//   macproapp://health[/<part>]             Everything on the Mac
//   macproapp://control[/<section>]         Control; links, fans, updates, storage, startup, restart
//   macproapp://macos                       the macOS tab
enum MacDeepLink {
    @MainActor static func open(_ url: URL, _ model: AppModel) -> Bool {
        guard url.scheme == "macproapp", let host = url.host else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        model.screenOpen = false
        switch host {
        case "tab":
            guard let t = parts.first.flatMap(Int.init) else { return false }
            model.show(tab: t)
        case "status":
            model.tab = 0; model.macPage = nil
            if parts.first == "temps", parts.count > 1 { model.history = .temperature(parts[1]) }
            else if let k = parts.first, let m = HistoryMetric.named(k == "memory" ? "mem" : k == "network" ? "rx" : k) { model.history = m }
        case "temps":
            model.tab = 0
            if let s = parts.first { model.history = .temperature(s) }
        case "disk":
            model.tab = 0; model.history = .disk
        case "health", "everything":
            model.tab = 5; model.macPage = .health
        case "control":
            model.tab = 5
            switch parts.first ?? "" {
            case "links", "connections": model.macPage = .links
            case "fans", "temps": model.macPage = .fans
            case "updates": model.macPage = .updates
            case "storage": model.macPage = .storage
            case "startup": model.macPage = .startup
            case "health": model.macPage = .health
            case "restart": model.macPage = .restart
            default: model.macPage = nil
            }
        case "macos", "updates":
            model.tab = 4
        default:
            return false
        }
        return true
    }
}

@MainActor
final class ScreenHandoff {
    static let shared = ScreenHandoff()
    private(set) var sid: String?
    private var lastViewport: [String: Any]?
    private var sent = ""
    // Where the phone was as Screen opened, in the links' words.
    static func context(_ model: AppModel) -> [String: String] {
        let names = [0: "status", 1: "apps", 2: "claude", 4: "macos", 5: "control", 9: "settings"]
        var c: [String: String] = ["tab": names[model.tab] ?? "status"]
        if let p = model.macPage { c["item"] = p.rawValue }
        else if let h = model.history { c["item"] = h.key }
        else if let s = model.sessionScreen { c["item"] = s.name }
        return c
    }
    static func viewport(_ size: CGSize, panes: Bool) -> [String: Any] {
        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        #else
        let scale: CGFloat = 2
        #endif
        let posture = panes ? "open-flat" : size.width >= 500 || size.height >= 500 && size.width >= 380 ? "open-upright" : "folded"
        return ["w": Int(size.width), "h": Int(size.height), "scale": Double(scale), "posture": posture]
    }
    func opened(_ model: AppModel, size: CGSize, panes: Bool) {
        let id = UUID().uuidString.lowercased()
        sid = id
        lastViewport = Self.viewport(size, panes: panes)
        send(model, ["state": "start", "sid": id, "viewport": lastViewport!, "context": Self.context(model)])
    }
    func reshaped(_ model: AppModel, size: CGSize, panes: Bool) {
        guard let id = sid else { return }
        let v = Self.viewport(size, panes: panes)
        let key = "\(v["w"]!)x\(v["h"]!)\(v["posture"]!)"
        guard key != sent else { return }
        sent = key; lastViewport = v
        send(model, ["state": "context", "sid": id, "viewport": v])
    }
    // Screen closed: the session ends, and a place the Console handed back for this session is where the phone lands.
    func closed(_ model: AppModel) {
        guard let id = sid else { return }
        sid = nil; sent = ""
        let api = model.api
        Task { @MainActor in
            _ = try? await api.macDo("/api/mac/screen/session", ["state": "end", "sid": id], timeout: 8)
            struct Answer: Decodable { struct Back: Decodable { let sid: String; let link: String; var t: Double? }; var handback: Back? }
            guard let a: Answer = try? await api.macFeed("/api/mac/screen", timeout: 8), let b = a.handback, b.sid == id, let u = URL(string: b.link) else { return }
            _ = MacDeepLink.open(u, model)
        }
    }
    private func send(_ model: AppModel, _ body: [String: Any]) {
        let api = model.api
        Task { _ = try? await api.macDo("/api/mac/screen/session", body, timeout: 8) }
    }
}

// On the Screen's cover: says when it opens, each change of size or posture, and when it closes.
struct ReportsScreen: ViewModifier {
    let model: AppModel
    @Environment(\.paneLayout) private var panes
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { ScreenHandoff.shared.opened(model, size: g.size, panes: panes) }
                .onDisappear { ScreenHandoff.shared.closed(model) }
                .onChange(of: g.size) { _, s in ScreenHandoff.shared.reshaped(model, size: s, panes: panes) }
                .onChange(of: panes) { _, p in ScreenHandoff.shared.reshaped(model, size: g.size, panes: p) }
        })
    }
}
