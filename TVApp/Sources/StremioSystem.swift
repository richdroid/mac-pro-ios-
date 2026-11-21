import Foundation
import AppIntents
import CoreSpotlight
import Security
import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

// Play on iPhone in the rest of the system: what he played here findable in Spotlight, on the Continue watching widget,
// in Shortcuts and Siri, and handed to another of his devices with Handoff. The Dynamic Island and the Lock Screen show
// the system's own Now Playing for it (PhoneSession.nowPlaying), with its keys, as any video app's does.

@MainActor enum PhoneSystem {
    static weak var model: TVModel?
    static let activityType = "local.macpro.TV.watch"

    static func noted(_ r: PhoneRecent) {
        index(r)
        share()
    }

    // Spotlight: each title played here, found by its name, opening its picker (where Resume waits).
    static func index(_ r: PhoneRecent) {
        #if os(iOS)
        let a = CSSearchableItemAttributeSet(contentType: .movie)
        a.title = r.name
        a.contentDescription = [r.line, r.progress > 0.02 && r.progress < 0.95 ? "Resume at \(Self.time(r.at)) on iPhone" : "Play on iPhone"].filter { !$0.isEmpty }.joined(separator: " · ")
        let item = CSSearchableItem(uniqueIdentifier: "phone/\(r.type)/\(r.imdb)/\(r.video)", domainIdentifier: "phone", attributeSet: a)
        CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
        #endif
    }
    static func time(_ t: Double) -> String {
        let n = Int(max(0, t))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }

    // The widget's Continue watching: the last few, through the Keychain group the app and its widgets share
    // (PhoneShelf in the widget reads it). Names, posters and places only.
    static func share() {
        let list: [[String: Any]] = PhoneRecents.all.prefix(4).map { r in
            ["type": r.type, "imdb": r.imdb, "video": r.video, "name": r.name, "line": r.line, "poster": r.poster, "progress": r.progress, "left": max(0, r.length - r.at)]
        }
        guard let d = try? JSONSerialization.data(withJSONObject: list), let group = SavedAddress.sharedGroup else { return }
        // The same item the widget reads (TVWidget/PhoneWidget.swift): service and account must match.
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.macpro.TV.phoneShelf",
                                kSecAttrAccount as String: "recents", kSecAttrAccessGroup as String: group]
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
        WidgetCenter.shared.reloadTimelines(ofKind: "PhoneContinue")
    }

    // Handoff: what's playing, at where it is.
    static func activity(_ t: PhoneTitle, at: Double) -> NSUserActivity {
        let a = NSUserActivity(activityType: activityType)
        a.title = t.type == "series" && !t.line.isEmpty ? "\(t.name), \(t.line)" : t.name
        a.isEligibleForHandoff = true
        a.isEligibleForSearch = false
        a.userInfo = ["type": t.type, "imdb": t.imdb, "video": t.video, "name": t.name, "at": at]
        a.webpageURL = URL(string: "https://web.stremio.com/#/detail/\(t.type)/\(t.imdb)" + (t.type == "series" ? "/\(t.video)" : ""))
        return a
    }

    // Coming in from Handoff, Spotlight or a link: the title's picker on this phone.
    static func open(_ a: NSUserActivity) {
        if a.activityType == activityType, let u = a.userInfo, let imdb = u["imdb"] as? String {
            let type = u["type"] as? String ?? "movie"
            PhoneOpen.open(PhoneTitle(type: type, imdb: imdb, video: u["video"] as? String ?? imdb, name: u["name"] as? String ?? "", line: "", poster: "", background: ""), model: model)
            return
        }
        if a.activityType == CSSearchableItemActionType, let id = a.userInfo?[CSSearchableItemActivityIdentifier] as? String {
            let p = id.split(separator: "/").map(String.init)
            guard p.count == 4, p[0] == "phone" else { return }
            let r = PhoneRecents.all.first { $0.imdb == p[2] }
            PhoneOpen.open(r?.title ?? PhoneTitle(type: p[1], imdb: p[2], video: p[3], name: "", line: "", poster: "", background: ""), model: model)
        }
    }
}

#if os(iOS)
// The player's own Handoff, kept current while it plays.
@MainActor enum PhoneActivity {
    private static var current: NSUserActivity?
    static func began(_ s: PhoneSession) {
        let a = PhoneSystem.activity(s.title, at: s.position)
        a.becomeCurrent()
        current = a
    }
    static func update(_ s: PhoneSession) {
        current?.addUserInfoEntries(from: ["at": s.position])
        current?.needsSave = true
    }
    static func ended() { current?.invalidate(); current = nil }
}

// Handoff and Spotlight coming in, on the app's root (TVViews).
struct PhoneContinuation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onContinueUserActivity(PhoneSystem.activityType) { PhoneSystem.open($0) }
            .onContinueUserActivity(CSSearchableItemActionType) { PhoneSystem.open($0) }
    }
}
extension View { func phoneContinuation() -> some View { modifier(PhoneContinuation()) } }
#else
extension View { func phoneContinuation() -> some View { self } }
#endif

// MARK: Shortcuts and Siri

struct PhoneTitleEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Film or show"
    static var defaultQuery = PhoneTitleQuery()
    var id: String              // "movie/tt…/tt…" or "series/tt…/tt…:s:e" (the episode may be empty)
    var name: String
    var line: String
    var displayRepresentation: DisplayRepresentation {
        line.isEmpty ? DisplayRepresentation(title: "\(name)") : DisplayRepresentation(title: "\(name)", subtitle: "\(line)")
    }
    var title: PhoneTitle {
        let p = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let type = p.first ?? "movie", imdb = p.count > 1 ? p[1] : "", video = p.count > 2 ? p[2] : imdb
        return PhoneTitle(type: type, imdb: imdb, video: video, name: name, line: line, poster: "", background: "")
    }
}
struct PhoneTitleQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PhoneTitleEntity] {
        let recents = await MainActor.run { PhoneRecents.all }
        return identifiers.map { id in
            let r = recents.first { "\($0.type)/\($0.imdb)/\($0.video)" == id }
            return PhoneTitleEntity(id: id, name: r?.name ?? "", line: r?.line ?? "")
        }
    }
    func suggestedEntities() async throws -> [PhoneTitleEntity] {
        await MainActor.run { PhoneRecents.all }.map { PhoneTitleEntity(id: "\($0.type)/\($0.imdb)/\($0.video)", name: $0.name, line: $0.line) }
    }
    // Stremio's catalogue, films and shows found together.
    func entities(matching string: String) async throws -> [PhoneTitleEntity] {
        let q = string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? string
        var out: [PhoneTitleEntity] = []
        for type in ["movie", "series"] {
            guard let u = URL(string: "\(StremioAPI.metaBase)/catalog/\(type)/top/search=\(q).json"),
                  let d = try? await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 8)).0,
                  let metas = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["metas"] as? [[String: Any]] else { continue }
            out += metas.prefix(6).compactMap { m in
                guard let id = m["id"] as? String, id.hasPrefix("tt") else { return nil }
                return PhoneTitleEntity(id: "\(type)/\(id)/" + (type == "movie" ? id : ""), name: m["name"] as? String ?? "",
                                        line: [type == "series" ? "Show" : "Film", m["releaseInfo"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
            }
        }
        return out
    }
}
struct PlayOnIPhone: AppIntent {
    static var title: LocalizedStringResource = "Play on This Phone"
    static var description = IntentDescription("Finds a film or show in your Stremio add-ons and plays it on this phone.")
    static var openAppWhenRun = true
    @Parameter(title: "Film or show") var title: PhoneTitleEntity
    @MainActor func perform() async throws -> some IntentResult {
        PhoneOpen.open(title.title, model: PhoneSystem.model)
        return .result()
    }
}
struct ResumeOnIPhone: AppIntent {
    static var title: LocalizedStringResource = "Resume on This Phone"
    static var description = IntentDescription("Carries on with what you last watched on this phone, from where you were.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        guard let r = PhoneRecents.all.first else { throw StremioError(message: "Nothing has played on this iPhone yet.") }
        PhoneOpen.open(r.title, model: PhoneSystem.model)
        return .result()
    }
}
struct PlayTitleOnTV: AppIntent {
    static var title: LocalizedStringResource = "Play a Film or Show on the TV"
    static var description = IntentDescription("Opens its streams, to flick one to the TV.")
    static var openAppWhenRun = true
    @Parameter(title: "Film or show") var title: PhoneTitleEntity
    @MainActor func perform() async throws -> some IntentResult {
        guard let model = PhoneSystem.model else { return .result() }
        model.flick(FlickTarget(item: title.title.item, source: .stremio))
        return .result()
    }
}
