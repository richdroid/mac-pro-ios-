import SwiftUI
#if canImport(UIKit)
import UIKit
#endif




// One way to send anything to the TV: the thing's own page, its choices on it (an episode, then a stream), and the choice
// he makes is the flick. Picking a stream, by a tap or by holding it and flicking it up, is the send: the request leaves
// at once, and its picture goes straight into the Remote's own picture of the TV in one short move, the Remote coming up
// under it. No stage, no throw to watch, no catch to wait through (Richard, 2026-11-10: "flicking is still off and slow …
// i dont like what u have now at all and again too slow"; "streams should always be shown when choosing stremio titles").
struct FlickTarget: Identifiable {
    let id = UUID()
    let item: MediaItem
    let source: MediaSource
    // A song on this phone: its own cover, its own way to the TV, and what to do once it's there.
    var image: Image?
    var send: (String, [String: Any])?
    var sent: (() -> Void)?
    // The app a plain send puts in front (YouTube for a video from Continue watching); Mint when nil.
    var lands: String?
    // Kept by `again` (the target "Choose another" starts from), so a start stays this flick's own through its retries:
    // a fresh id there meant no flick ever owned its start, and the Mac's "playing" line never reached the Remote.
    var lineage = UUID()
    // Kept for the callers that set them (the next episode, a re-flick): neither skips the stream list any more. Every
    // Stremio title shows its streams and waits for his pick (Richard, 2026-11-10); the ones he'd most likely pick are
    // first, and already fetched.
    var ready = false
    var autoplay = false
    // The tile it was picked from, on the screen.
    var origin: CGRect? = nil
    // "Choose another" after a start that failed: straight to the streams, with the ones that didn't start set apart.
    var streamsFirst = false
    var avoid: Set<String> = []
    // Thrown from a card where it lives (a shelf, a search result, Continue watching), with the throw's speed: the flick
    // screen sends it at once rather than waiting for a pick, under the lift's own receipt id.
    var thrown: CGSize? = nil
    var receiptID: String? = nil
    // A link pasted or typed: a plain card naming the site and, once fetched, the page (the 2026-11-10 ruling: a link
    // flicks like anything else, never straight to the TV).
    static func link(_ text: String) -> FlickTarget {
        let yt = LinkPeek.isYouTube(text)
        return FlickTarget(item: MediaItem(title: LinkPeek.site(text), subtitle: "", art: "", id: text, kind: yt ? "youtube" : "link"),
                           source: .stremio, send: ("send", ["text": text]), lands: yt ? "com.google.android.youtube.tv" : nil)
    }
}
struct StremioEpisode: Decodable, Identifiable, Hashable {
    let id: String, season: Int, episode: Int, name: String, thumb: String
    // From the Mac when Stremio's meta has them; Cinemeta's (SeriesInfo) win where both exist.
    var runtime: Int?
    var overview: String?
    // "3. The One…", but never "2. Episode 2: …", which says the number twice (r26).
    var title: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Episode \(episode)" }
        if n.lowercased().hasPrefix("episode \(episode)") { return n }
        return "\(episode). \(n)"
    }
}
struct StremioStream: Decodable, Identifiable, Hashable {
    let token: String, addon: String, name: String, description: String
    var quality: String?
    var hdr: String?
    var gb: Double?
    var instant: Bool?
    var lang: String?
    // From the Mac: a file named as a dub of a title made in English, and one that was sent lately and never played.
    var dubbed: Bool?
    var stalled: Bool?
    var id: String { token }
    // "2.1 GB · Ready now". Where it came from is added only to tell apart two rows that would otherwise read the same.
    var size: String? { gb.flatMap { $0 > 0 ? ($0 < 1 ? "\(Int($0 * 1024)) MB" : String(format: "%.1f GB", $0)) : nil } }
    func details(withSource: Bool = false, size withSize: Bool = true) -> String {
        var parts: [String] = []
        if withSize, let size { parts.append(size) }
        if instant == true { parts.append("Ready now") }
        if let lang, !lang.isEmpty { parts.append(lang) }
        if withSource, !addon.isEmpty { parts.append(addon) }
        return parts.joined(separator: " · ")
    }
    // What the row reads as, without its source.
    var look: String { (name.isEmpty ? addon : name) + "\u{1}" + details() }
}
struct StremioMeta: Decodable {
    let about: String
    let episodes: [StremioEpisode]
}
extension MediaItem {
    // Cards hold either a plain title id or a whole link, and a link can already point at an episode.
    var stremioRef: (type: String, imdb: String, video: String?)? {
        if id.hasPrefix("stremio:///detail/") {
            let parts = id.dropFirst(18).split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            return (parts[0], parts[1], parts.count > 2 ? parts[2].removingPercentEncoding : nil)
        }
        return id.hasPrefix("tt") ? (kind == "series" ? "series" : "movie", id, nil) : nil
    }
}

// A pasted link's site and page name, fetched where that's cheap: YouTube's oEmbed answers with the title and a still;
// any other page is read for its og:title or <title>, up to 3 s. The card shows the site at once and the name as it comes.
enum LinkPeek {
    static func isYouTube(_ text: String) -> Bool {
        let h = host(text).lowercased()
        return h.hasSuffix("youtube.com") || h == "youtu.be"
    }
    static func url(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: t.contains("://") ? t : "https://" + t)
    }
    static func host(_ text: String) -> String { url(text)?.host ?? "" }
    // "youtube.com", "nytimes.com": the site, without the www.
    static func site(_ text: String) -> String {
        let h = host(text)
        return h.isEmpty ? "Link" : h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    static func peek(_ text: String) async -> (title: String?, art: String?) {
        guard let u = url(text) else { return (nil, nil) }
        // The build's link-with-art pose: what YouTube's oEmbed answers, from the stand-in Mac (CI has no network).
        if UserDefaults.standard.string(forKey: "pose") == "flick-link-art" { return ("A sample video that goes on a bit", TVBridge.url("/api/tv/shot")?.absoluteString) }
        if isYouTube(text) {
            let q = u.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            guard let o = URL(string: "https://www.youtube.com/oembed?url=\(q)&format=json"),
                  let d = try? await URLSession.shared.data(for: URLRequest(url: o, timeoutInterval: 3)).0,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (nil, nil) }
            return (j["title"] as? String, j["thumbnail_url"] as? String)
        }
        guard let d = try? await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 3)).0 else { return (nil, nil) }
        let html = String(decoding: d.prefix(96_000), as: UTF8.self)
        func match(_ pattern: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let m = r.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let g = Range(m.range(at: 1), in: html) else { return nil }
            let s = html[g].replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "’")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        let title = match(#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#) ?? match(#"<title[^>]*>([^<]+)</title>"#)
        let art = match(#"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#)
        return (title, art)
    }
}

// The flick's receipt on the TV (Richard, 2026-11-10: "a receipt of flick interface on tv", and "when i start to flick the
// tv starts the expected work in background and theres a receipt interface that makes sense with the flick"). The TV is
// told each step of the gesture, by the flick's own id: the lift (it begins what's likely coming where it can't be seen,
// and shows nothing), the throw (the card comes up from that edge there, leaning the way it was
// thrown and as fast, and says how the start goes), or the put-back (gone). The phone's picture leaves by its top edge
// and arrives at the TV's bottom edge: one motion. The Mac and the launcher do the rest (tv.js receiptSay, FlickReceipt.kt).
enum FlickReceipt {
    // What the TV's card shows. `kind`: film, episode, video, song, app, link. `shape`: poster, wide, square.
    // An app is named by its package, and the TV draws its own banner for it.
    static func body(id: String, title: String, line: String = "", art: String = "", kind: String, shape: String = "", pkg: String = "") -> [String: Any] {
        var b: [String: Any] = ["id": id, "title": title, "kind": kind]
        if !pkg.isEmpty { b["pkg"] = pkg }
        if !line.isEmpty, line != title { b["line"] = line }
        if art.hasPrefix("https://") { b["art"] = art }
        if !shape.isEmpty { b["shape"] = shape }
        return b
    }
    // The throw's own lean and speed, as the finger left it (points a second); a tap goes straight up.
    static func thrown(_ b: [String: Any], velocity v: CGSize) -> [String: Any] {
        var b = b
        let speed = (v.width * v.width + v.height * v.height).squareRoot()
        if speed > 50, v.height < 0 { b["vx"] = Double(v.width / speed); b["vy"] = Double(v.height / speed); b["speed"] = Double(speed) }
        else { b["vx"] = 0.0; b["vy"] = -1.0; b["speed"] = 0.0 }
        return b
    }
    // One lift at a time, and never the same one twice; the Mac keeps its own count too.
    @MainActor private static var lifted = ""
    @MainActor static func lift(_ b: [String: Any], lands: String?) {
        guard let id = b["id"] as? String, id != lifted else { return }
        lifted = id
        var body: [String: Any] = ["receipt": b]
        if let lands { body["lands"] = lands }
        Task { _ = try? await TVBridge.post("flick-lift", body, timeout: 8) }
    }
    // Put back, or let go anywhere but toward the TV.
    @MainActor static func cancel(_ id: String) {
        guard id == lifted else { return }
        lifted = ""
        Task { _ = try? await TVBridge.post("flick-cancel", ["id": id], timeout: 8) }
    }
    @MainActor static func thrown(_ id: String) { if id == lifted { lifted = "" } }
}
// Which file of a title was last started from this phone, by title and episode: so its row can say "Playing", and a pick
// of another row is known to be another stream.
@MainActor enum PlayedStream {
    private static var files: [String: String] = [:]
    static func file(_ key: String) -> String? { files[key] }
    static func set(_ key: String, _ file: String) { if files.count > 40 { files.removeAll() }; files[key] = file }
}
// Whether the Mac had begun to answer a send, kept by the send itself: it runs on after the flick screen has closed.
@MainActor final class HeardBox { var yes = false }

// The finger by the screen's own clock: every touch's timestamp and place (each coalesced sample too), from its
// touch-down, read off the window's own event delivery before any gesture sees it. Nothing is added to the gesture
// system: a recognizer on the window (ef52168) may have kept the lists from scrolling under a swipe in the films. The
// gestures' callbacks come when the main thread gets to them; these say when the finger really moved (FlickHand.real).
enum HandPhase { case moved, ended, cancelled }
#if os(iOS)
extension UIWindow {
    @objc dynamic func tvLedger_sendEvent(_ event: UIEvent) {
        if event.type == .touches { TouchLedger.see(event) }
        tvLedger_sendEvent(event)   // the system's own, after the exchange
    }
}
@MainActor enum TouchLedger {
    private static var follower: ((HandPhase, CGSize) -> Void)?
    private static var followFrom = CGPoint.zero
    // From now until it's lifted, the finger's every move (as its distance from where it is now), its lift and its
    // loss, straight from the window's events: what a thing in the hand follows once its hold is done. No gesture
    // follows it, so a list under it scrolls as freely as anywhere (a drag gesture after the hold, on every row, kept
    // the stream lists from scrolling under a swipe begun on a row: CI 2a45a88). False if the finger is already up.
    @discardableResult static func follow(_ f: @escaping (HandPhase, CGSize) -> Void) -> Bool {
        guard tracked != nil, let last = samples.last else { return false }
        followFrom = last.p
        follower = f
        return true
    }
    private static func offset(_ p: CGPoint) -> CGSize { CGSize(width: p.x - followFrom.x, height: p.y - followFrom.y) }
    private static var samples: [(t: Double, p: CGPoint)] = []
    private static var downAt = 0.0
    private static weak var tracked: UITouch?
    private static var installed = false
    static func install() {
        guard !installed, let a = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let b = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.tvLedger_sendEvent(_:))) else { return }
        installed = true
        method_exchangeImplementations(a, b)
    }
    static func see(_ event: UIEvent) {
        guard let all = event.allTouches else { return }
        if let t = tracked, all.contains(t) {
            switch t.phase {
            case .moved:
                for c in event.coalescedTouches(for: t) ?? [t] { samples.append((c.timestamp - downAt, c.location(in: nil))) }
                if samples.count > 240 { samples.removeSubrange(1..<(samples.count - 200)) }
                follower?(.moved, offset(t.location(in: nil)))
            case .ended, .cancelled:
                samples.append((t.timestamp - downAt, t.location(in: nil)))
                tracked = nil
                let f = follower; follower = nil
                f?(t.phase == .ended ? .ended : .cancelled, offset(t.location(in: nil)))
            default: break
            }
            return
        }
        // A new touch-down with none tracked: the one this ledger follows until it's lifted.
        guard tracked == nil || tracked?.phase == .ended || tracked?.phase == .cancelled,
              let t = all.first(where: { $0.phase == .began }) else { return }
        tracked = t
        follower = nil
        downAt = t.timestamp
        samples = [(0, t.location(in: nil))]
    }
    // A finger on the glass now.
    static var touching: Bool { tracked.map { $0.phase != .ended && $0.phase != .cancelled } ?? false }
    // The current (or last) touch, seconds from its touch-down; nil when there's none.
    static func feel() -> [(t: Double, p: CGPoint)]? { samples.count > 0 ? samples : nil }
    // Now, by the same clock: seconds since the current touch came down.
    static func sinceDown() -> Double? { samples.count > 0 ? ProcessInfo.processInfo.systemUptime - downAt : nil }
}
#else
enum TouchLedger {
    @MainActor @discardableResult static func follow(_ f: @escaping (HandPhase, CGSize) -> Void) -> Bool { false }
    @MainActor static func install() {}
    @MainActor static func feel() -> [(t: Double, p: CGPoint)]? { nil }
    @MainActor static func sinceDown() -> Double? { nil }
    @MainActor static var touching: Bool { false }
}
#endif

// A pasted link on the flick page: one rounded slab, its page's picture at the TV's 16:9 over its name. Until the page's
// picture comes, the site's own mark on the app's ground, and the site's name where the page's will be: nothing in it
// moves when the name arrives, and the name is said once (the shared poster card printed a link's address twice, once
// as a big serif "cover"). `tile` reports where the picture is, which is what flies.
struct LinkCard: View {
    static let corner: CGFloat = 16
    let title: String?
    let link: String
    let art: String?
    let width: CGFloat
    let tile: (CGRect) -> Void
    var body: some View {
        let site = LinkPeek.site(link)
        let yt = LinkPeek.isYouTube(link)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x3A3152), Color(hex: 0x1E1833)], startPoint: .top, endPoint: .bottom)
                Image(systemName: yt ? "play.rectangle.fill" : "safari.fill")
                    .font(.system(size: width * 0.12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                if let a = art, let u = URL(string: a) {
                    Art(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                }
            }
            .frame(width: width, height: (width * 9 / 16).rounded())
            .clipped()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { tile($0) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? site).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
                Text(title == nil ? link : site).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .frame(width: width, height: 70, alignment: .leading)
            .background(Color(white: 0.13))
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: title)
        .accessibilityElement(children: .combine)
    }
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
private func between(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
           width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

// A row of choices whose highlight slides to the one picked.
struct Chips<T: Hashable>: View {
    @Environment(TVModel.self) var model
    let options: [(T, String)]
    @Binding var selected: T
    // Space before the first chip and after the last, inside the row, so a row that runs to the edge scrolls to it.
    var inset: CGFloat = 0
    @Namespace private var pill
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { value, label in
                    Button { if selected != value { Haptic.fire(.tick) }; withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { selected = value } } label: {
                        Text(label).font(.footnote.weight(.semibold)).padding(.horizontal, 13).frame(height: 32)
                            .foregroundStyle(selected == value ? .black : .white)
                            .background {
                                if selected == value { Capsule().fill(TVLook.accent).matchedGeometryEffect(id: "pill", in: pill) }
                                else { Capsule().fill(.white.opacity(0.1)) }
                            }
                    }
                    .buttonStyle(PressCard())
                    .accessibilityAddTraits(selected == value ? .isSelected : [])
                }
            }
            .padding(.horizontal, inset)
        }
    }
}

// The shape of a row still on its way, breathing until it arrives.
struct PlaceholderRow: View {
    var delay = 0.0
    var thumb = false
    var body: some View {
        HStack(spacing: 11) {
            if thumb { RoundedRectangle(cornerRadius: 6, style: .continuous).frame(width: 82, height: 46) }
            VStack(alignment: .leading, spacing: 7) {
                Capsule().frame(width: 120, height: 11)
                Capsule().frame(width: 190, height: 8)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.12))
        .padding(.horizontal, 12).frame(height: thumb ? 66 : 64)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Its breathing is its opacity alone: as a phase animator, the 0.9 s ease also carried the row's own layout as the
        // page arrived, and the rows trailed in skewed past the left margin.
        // Read off the clock, with no animation in any transaction, so nothing else about the row can be carried by it.
        .modifier(Breathing(delay: delay))
        .accessibilityHidden(true)
    }
}
private struct Breathing: ViewModifier {
    let delay: Double
    @State private var from = Date()
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = max(0, ctx.date.timeIntervalSince(from) - delay)
            content.opacity(0.725 - 0.275 * cos(t / 0.9 * .pi))
        }
    }
}

// Cards give under the finger, as anything you can pick up should. Gently, and easing in, because every scroll starts
// with a touch on some card, and a sharp squeeze there makes the whole row twitch.
struct PressCard: ButtonStyle {
    // The moment a finger lands, before it's a tap: time enough to start asking for what the tap will need.
    var onPress: (() -> Void)? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(configuration.isPressed ? .easeOut(duration: 0.18).delay(0.06) : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in if down { onPress?() } }
    }
}

// A button inside a bar: only the icon gives, so the bar itself stays put.
struct PressIcon: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

// An app's own things, reached from its banner.
struct AppBrowse: View {
    @Environment(TVModel.self) var model
    @Environment(\.paneLayout) private var panes
    let source: MediaSource
    // A row opened from its heading on this page. This page is itself pushed by an item (model.browsing), and a row pushed
    // by value on the same stack re-pushed this page instead: "Continue watching" opened Stremio again (Richard,
    // 2026-11-06: "it shouldnt open the same menu as the one i first accessed"). So its rows open by an item too.
    @State private var row: RowRoute?
    var body: some View {
        Group {
            if panes {
                FoldSplit { BrowseColumn(store: .shared(source), part: .left) } right: { BrowseColumn(store: .shared(source), part: .right) }
            } else {
                BrowseColumn(store: .shared(source))
            }
        }
        .topShade().topFade()
        .environment(\.openRow, { row = $0 })
        .navigationDestination(item: $row) { $0.page.underFlick(barHidden: true) }
        .background { Ambience() }
        .onAppear { model.mood = source.mood }
        .onDisappear { if model.mood == source.mood { model.mood = nil } }
        // The build's shots: Stremio's first row opened from its heading ("-pose stremiorow"), its own list, not Stremio
        // again; and a title's details page ("-pose details"), pushed with the system's Back, edge to edge.
        .task {
            let pose = UserDefaults.standard.string(forKey: "pose")
            guard pose == "stremiorow" || pose == "details", row == nil else { return }
            let store = BrowseStore.shared(source)
            for _ in 0..<60 where store.rows.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if pose == "details" {
                if let item = store.rows.flatMap(\.items).first(where: { $0.stremioRef != nil && !$0.isYouTube }) { row = .info(item, source) }
            } else if let first = store.rows.first { row = .media(first, source) }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        // The app itself on the TV, in the page's bar; not offered when it's already the app on the TV.
        .barPage {
            if model.status?.app != source.pkg {
                PageBarAction(title: "Open on TV", icon: "tv") { model.post("open", ["pkg": source.pkg]) }
            }
        }
    }
}

// MARK: - The flick from where a thing lives
// Every card that can go to the TV (a shelf's, a search result, Continue watching, Watch's films, Mint's albums) is
// flicked the way a stream row is: held, it lifts off its shelf; thrown up, it goes; let go where it was, it's a tap
// (its page); anywhere else, it goes back. The same FlickHand reads it. A tap still opens its page. The card in the hand
// is drawn over everything (ShelfLiftOverlay), as a shelf clips whatever leaves it.
@MainActor @Observable final class ShelfHand {
    static let shared = ShelfHand()
    // The card that's in the hand or in the air: its own place on the shelf is empty meanwhile, its "i" with it.
    var item: MediaItem?
    var source = MediaSource.stremio
    // A tap iOS reports with the release of a held card is that release, not a second action.
    @ObservationIgnored var handledAt = Date.distantPast
}
// Something that leaves with a card while it's in the hand or in the air (its "i"): only this is redrawn when a card
// lifts, not every card on the page (each card read the hand itself, so a lift redrew them all).
struct HiddenInHand<Content: View>: View {
    let id: String
    @ViewBuilder var content: Content
    var body: some View { let l = Hand.shared.lifted?.id; content.opacity(!id.isEmpty && (l == id || l == id + "#w") ? 0 : 1) }
}
struct ShelfFlick: ViewModifier {
    let item: MediaItem
    let source: MediaSource
    let width: CGFloat
    // Where the picture is, as its button measures it.
    let rect: () -> CGRect
    // On a page that already holds the list (an episode on its show's page): the throw is the page's to make.
    var onThrow: (() -> Void)?
    // Held and let go where it was: the page's own choosing.
    var onTap: (() -> Void)?
    // A row whose own picture is a wide still (an episode's): that still is what lifts.
    var still: String? = nil
    // The pebble (TVHand): held still 0.15 s it lifts and is his finger's, point for point; moved first, the touch is the
    // scroll's and it never lifts (brief 8.2 and 8.3: one touch, one owner).
    func body(content: Content) -> some View {
        content.modifier(Liftable(item: item, source: source, wide: still != nil, art: still, onThrow: onThrow.map { f in { _ in f() } }, onTap: onTap, rect: rect, hides: still == nil))
    }
}


// MARK: - A throw that needs no page
// A Stremio film or episode thrown from its shelf goes straight to the TV: the stream he'd most likely pick (Best, as the
// page's throwPick has it) out of the list already in hand from the card's press, sent with its two nearest stand-ins and
// the lift's receipt, the card flying on into the Remote's picture. The flick page is built only when there's a choice to
// make: the list not in hand, nothing in it to send, or the card held over the TV until it says "Choose" (Richard,
// 2026-11-12: "flicking is everything"; one continuous motion, no page flashing up between).
@MainActor enum ShelfSend {
    // The one title (imdb/video) the next send starts over rather than resuming.
    static var restart: String?
    // Best: the top one that hasn't failed and isn't stalled or a dub; else the top one that hasn't failed.
    static func best(_ found: [StremioStream], avoid: Set<String> = []) -> StremioStream? {
        found.first { !avoid.contains($0.token) && $0.stalled != true && $0.dubbed != true } ?? found.first { !avoid.contains($0.token) }
    }
    // The film, or the episode the card names: what can be sent without a page. A show not at an episode needs its page.
    static func ref(_ item: MediaItem, _ source: MediaSource) -> (type: String, imdb: String, video: String)? {
        guard source == .stremio, !item.isYouTube, let r = item.stremioRef else { return nil }
        if r.type == "series" { guard let v = r.video else { return nil }; return (r.type, r.imdb, v) }
        return (r.type, r.imdb, r.imdb)
    }
    static func list(_ item: MediaItem, _ source: MediaSource) -> [StremioStream]? {
        guard let r = ref(item, source), let l = StreamCache.shared.inHand(type: r.type, imdb: r.imdb, video: r.video), !l.isEmpty else { return nil }
        return l
    }
    // "S1 E2", for a card on an episode.
    static func episodeLine(_ item: MediaItem) -> String? {
        guard let r = item.stremioRef, r.type == "series", let v = r.video else { return nil }
        let p = v.split(separator: ":")
        guard p.count == 3, let s = Int(p[1]), let e = Int(p[2]) else { return nil }
        return "S\(s) E\(e)"
    }
    // Where he is in it: the card's own, else Stremio's Continue watching (as the page's savedProgress).
    static func progress(_ item: MediaItem) -> Double? {
        if let p = item.progress { return p }
        guard let r = item.stremioRef else { return nil }
        let row = BrowseStore.shared(.stremio).rows.first { $0.title == "Continue watching" }
        for i in row?.items ?? [] {
            guard let ir = i.stremioRef, ir.imdb == r.imdb, let p = i.progress else { continue }
            if r.type != "series" || ir.video == r.video { return p }
        }
        return nil
    }
    // The page's order for the same pick: token, what it is, where he was, and the two nearest stand-ins.
    static func body(_ item: MediaItem, _ stream: StremioStream, _ list: [StremioStream], avoid: Set<String>) -> [String: Any] {
        guard let r = item.stremioRef else { return ["token": stream.token] }
        var b: [String: Any] = ["token": stream.token, "imdb": r.imdb]
        if r.type == "series", let v = r.video { b["video"] = v }
        // Start over chosen on the title page's card: from the top, whatever Continue watching says.
        if restart == r.imdb + "/" + (r.video ?? "") { restart = nil; b["restart"] = true }
        else
        // Near the end, it starts over (the page's default there); otherwise it carries on where he was.
        if let p = progress(item) {
            if p > 0.9, p < 0.99 { b["restart"] = true } else if p > 0.01, p < 0.97 { b["resume"] = (p * 1000).rounded() / 1000 }
        }
        let spare = list.filter { $0.token != stream.token && !avoid.contains($0.token) && $0.quality == stream.quality && $0.stalled != true
            && (stream.dubbed == true || $0.dubbed != true) }.prefix(2).map(\.token)
        if !spare.isEmpty { b["fallbacks"] = Array(spare) }
        return b
    }
}
extension TVModel {
    // The start, the model's from the throw: the Remote shows it (poster, ring, phase) and follows it to playing, or dims
    // it with "Choose another", which opens the page at its streams. The request goes now.
    func startStream(item: MediaItem, stream first: StremioStream, list: [StremioStream], receipt: [String: Any]?, velocity: CGSize) {
        guard let r = item.stremioRef else { return }
        let target = FlickTarget(item: item, source: .stremio)
        let lineage = target.lineage
        beginStart(.init(title: item.title, art: item.art, line: ShelfSend.episodeLine(item), token: first.token), target: target)
        standIn(item.art)
        // This flick's own clock (FlickClock.begin came just before), never a later flick's.
        let clock = FlickClock.current
        // Kept by the model: a newer start, or this one called off, ends it, so no retry of it is ever sent after something
        // newer (it stops at the same points as the page's own request does on its cancel).
        shelfStart = Task { @MainActor in
            let owns = { self.startingTarget?.lineage == lineage }
            var stream = first, list = list
            var avoid: Set<String> = [], resent = false, dropped = 0, plainOnce = false
            let heard = HeardBox()
            clock.mark("request")
            while true {
                if Task.isCancelled { return }
                var body = ShelfSend.body(item, stream, list, avoid: avoid)
                if let receipt { body["receipt"] = FlickReceipt.thrown(receipt, velocity: velocity) }
                // Every send after a dropped line asks how the first went (`again`): the Mac joins it if it's still
                // starting, or answers again if it ended; whether or not a byte came back first, nothing starts twice.
                if dropped > 0, !plainOnce { body["again"] = true }
                do {
                    let answer = try await TVBridge.playStream(body, opened: { _ in heard.yes = true; clock.mark("first-byte") }, phase: { p in
                        clock.mark("phase-" + p)
                        guard owns() else { return }
                        self.startPhase(p)
                        if p == "playing" { clock.mark("playing"); self.startPlayed() }
                    })
                    if Task.isCancelled { return }
                    if let j = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] {
                        if j["alreadyOn"] as? Bool == true { clock.mark("already-on") }
                        if j["joined"] as? Bool == true { clock.mark("joined") }
                        if let t = j["token"] as? String, t != stream.token, let played = list.first(where: { $0.token == t }) { stream = played }
                    }
                    PlayedStream.set(r.imdb + "/" + (r.type == "series" ? r.video ?? "" : ""), stream.description)
                    RecentFlicks.shared.add(RecentFlick(title: item.title, art: item.art, imdb: r.imdb, type: r.type, video: r.type == "series" ? r.video : nil,
                                                        episode: ShelfSend.episodeLine(item), at: Date()))
                    NextUp.shared.forget()
                    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "flicksDone") + 1, forKey: "flicksDone")
                    if owns() || startingTarget == nil { startPlayed() }
                    clock.mark("answer"); clock.finished()
                    return
                } catch {
                    // Ended from here (a newer start, or called off): nothing more of it, as the page's.
                    if Task.isCancelled { return }
                    // Asked `again` and told the Mac never saw it (the line dropped on the way out): it goes once as
                    // itself, while it's still the newest. Never on the Mac's say-so about a send it did see.
                    if error is TVBridge.Unseen, !plainOnce, owns() { plainOnce = true; continue }
                    if error is CancellationError || error is TVBridge.Unseen {
                        if owns() { clearStart() }; clock.mark("called-off"); clock.finished(); return
                    }
                    // Gone: the list fetched afresh and the same file (or the next best) sent once more, silently.
                    if error is TVBridge.Gone, !resent {
                        resent = true
                        let video = r.type == "series" ? r.video ?? r.imdb : r.imdb
                        StreamCache.shared.forget(type: r.type, imdb: r.imdb, video: video)
                        if let fresh = await StreamCache.shared.streams(type: r.type, imdb: r.imdb, video: video, again: true), !fresh.isEmpty,
                           let s = fresh.first(where: { $0.description == stream.description && !avoid.contains($0.token) }) ?? ShelfSend.best(fresh, avoid: avoid) {
                            list = fresh; stream = s; continue
                        }
                        if Task.isCancelled { return }
                    }
                    // The line dropped, not the start: twice more, a moment apart, before that's believed.
                    if error is URLError, dropped < 2 {
                        dropped += 1
                        clock.mark("line-lost")
                        try? await Task.sleep(nanoseconds: UInt64(dropped) * 700_000_000)
                        continue
                    }
                    clock.mark("failed"); clock.finished()
                    if error is TVBridge.DidNotStart, let stalled = TriedStreams.last { avoid.formUnion(stalled) } else { avoid.insert(stream.token) }
                    TriedStreams.last = nil
                    // On the Remote: the poster dims, with one way on (Choose another: the page, at its streams).
                    if owns() { startFailed(tokens: Array(avoid)) }
                    return
                }
            }
        }
    }
}

// MARK: - The flick's feel, in numbers
// The build's films only (under a pose), never on his phone. One line per flick, sent with the flick's own timing lines:
// how long the finger rested before the thing was in the hand; the frames the screen drew while he carried it (how many,
// how many came late, the longest); how the hand's picture and the flight's first frame compare (a change of size or
// place at the release is a jump); how fast the flight left against how fast the finger did; how long it stood still on
// the way; and when it landed. Read off the flight's own layer as the render server shows it, frame by frame.
#if os(iOS)
@MainActor final class FlickMeter: NSObject {
    static let shared = FlickMeter()
    static let on = UserDefaults.standard.string(forKey: "pose") != nil
    private enum Phase { case idle, drag, flight }
    private var phase = Phase.idle
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var kind = "", outcome = "", note = ""
    private var hold = 0.0, liftAt = 0.0, releaseAt = 0.0, finger = 0.0
    private var hand = CGRect.zero
    private var drag = (frames: 0, late: 0, longest: 0.0)
    private var air = (frames: 0, late: 0, longest: 0.0)
    private var trace: [(t: Double, r: CGRect)] = []
    private var serial = 0
    // In the hand. `hold`: seconds from the touch to the lift, by the finger's own clock.
    func lifted(_ kind: String, hold: Double?) {
        guard Self.on else { return }
        serial += 1
        self.kind = kind; self.hold = hold ?? -1
        phase = .drag; last = 0; liftAt = CACurrentMediaTime()
        drag = (0, 0, 0); air = (0, 0, 0); trace = []
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }
    // Let go. `hand`: the thing as it was drawn under the finger (window points); `speed`: the finger's, points a second.
    func released(_ outcome: String, speed: Double, hand: CGRect, note: String = "") {
        guard Self.on, phase == .drag else { return }
        self.outcome = outcome; self.hand = hand; finger = speed; self.note = note
        releaseAt = CACurrentMediaTime()
        guard outcome == "thrown" else { report(landed: false); return }
        phase = .flight
        let mine = serial
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if serial == mine, phase == .flight { report(landed: false) } }
    }
    func landed() {
        guard Self.on, phase == .flight else { return }
        report(landed: true)
    }
    @objc private func tick(_ l: CADisplayLink) {
        defer { last = l.timestamp }
        guard phase != .idle else { return }
        guard last > 0 else { return }
        let gap = (l.timestamp - last) * 1000, due = max(4, (l.targetTimestamp - l.timestamp) * 1000)
        if phase == .drag { drag.frames += 1; if gap > due * 1.5 { drag.late += 1 }; drag.longest = max(drag.longest, gap) }
        else { air.frames += 1; if gap > due * 1.5 { air.late += 1 }; air.longest = max(air.longest, gap) }
    }
    private func report(landed: Bool) {
        let now = CACurrentMediaTime()
        phase = .idle
        link?.invalidate(); link = nil
        var line = String(format: "feel %@ %@ hold=%.0f carry=%.0f frames=%d late=%d longest=%.0f finger=%.0f", kind, outcome, hold * 1000,
                          (releaseAt - liftAt) * 1000, drag.frames, drag.late, drag.longest, finger)
        if outcome == "thrown" {
            // The first frame of the flight against the hand's last: a change of size, or of place.
            var grow = -1.0, shift = -1.0, v0 = -1.0, first = -1.0, parked = 0.0
            if let a = trace.first, hand.height > 1 {
                first = a.t * 1000
                grow = Double(a.r.height / hand.height)
                shift = Double(hypot(a.r.midX - hand.midX, a.r.midY - hand.midY))
                // How fast it left: over its first twentieth of a second in the air.
                if let b = trace.first(where: { $0.t - a.t >= 0.045 }) { v0 = Double(hypot(b.r.midX - a.r.midX, b.r.midY - a.r.midY)) / (b.t - a.t) }
                // Stood still on the way: the longest stretch without moving while still well short of where it ended.
                if let end = trace.last {
                    var from: Double?
                    for i in 1..<max(1, trace.count) {
                        let p = trace[i - 1].r, q = trace[i].r
                        let still = hypot(q.midX - p.midX, q.midY - p.midY) < 0.5 && hypot(q.midX - end.r.midX, q.midY - end.r.midY) > 8
                        if still { if from == nil { from = trace[i - 1].t }; parked = max(parked, trace[i].t - (from ?? 0)) } else { from = nil }
                    }
                }
            }
            line += String(format: " first=%.0f grow=%.2f shift=%.0f v0=%.0f parked=%.0f air=%d airlate=%d airlongest=%.0f land=%.0f", first, grow, shift, v0,
                           parked * 1000, air.frames, air.late, air.longest, landed ? (now - releaseAt) * 1000 : -1)
        }
        if !note.isEmpty { line += " " + note }
        print("FEEL " + line)
        let e: [String: Any] = ["name": line, "at": Date().timeIntervalSince1970 * 1000]
        Task { _ = try? await TVBridge.post("timing", ["events": [e]], timeout: 5) }
    }
}
#else
@MainActor final class FlickMeter {
    static let shared = FlickMeter()
    func lifted(_ kind: String, hold: Double?) {}
    func released(_ outcome: String, speed: Double, hand: CGRect, note: String = "") {}
    func landed() {}
}
#endif
