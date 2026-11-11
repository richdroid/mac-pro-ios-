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
struct FlickScreen: View {
    // Its entry in the side bar's Back, while choosing.
    @State private var showInfo = false
    @State private var openedAt = Date.distantPast
    // The stream whose full description is open under its row.
    @State private var streamOpen: String?
    @Environment(TVModel.self) var model
    // A series opens on its episodes, then the streams; a film on its streams; anything with nothing to choose (a video,
    // a song, a link) on its one card.
    enum Step: Int { case episodes, streams, card }
    let target: FlickTarget
    @State private var step: Step
    @State private var forward = true
    @State private var meta: StremioMeta?
    @State private var metaFailed = false
    @State private var lookups = 0
    @State private var season = 0
    @State private var episode: StremioEpisode?
    @State private var streams: [StremioStream] = []
    @State private var stream: StremioStream?
    @State private var findingStreams = false
    // The list came from the cache, within a blink of the page: it's simply there, with no arrival of its own.
    @State private var streamsQuick = false
    @State private var streamFilter = "All"
    @State private var noStreams = false
    @State private var arrived = false
    // The bar's buttons come a beat after the backdrop starts in, as the bar itself can't fade.
    @State private var barShown = false
    // Sent: the pick is on its way to the TV and its picture on its way to the Remote.
    @State private var flown = false
    @State private var releasedAt = Date.distantPast
    @StateObject private var pageBar = PageBarState()
    @State private var answered = false
    @State private var written = false
    // The picture going into the Remote, decoded, taken at the pick so it never waits on a fetch; and its 16 px version,
    // the Remote's own soft ground under it.
    @State private var heldImage: TVImage?
    @State private var softImage: TVImage?
    @State private var flight: Task<Void, Never>?
    @State private var cancelled = false
    // Streams the TV took but couldn't get going: kept apart in the list, and never picked again.
    @State private var failedTokens: Set<String> = []
    // What the TV is doing while it gets going, read off its status.
    @State private var phase: String?
    // The episode Stremio's Continue watching is on, and how far into it.
    @State private var upNext: String?
    @State private var upNextProgress: Double?
    // The episode he'll most likely carry on with: its streams asked for as soon as it's known, so choosing it finds them
    // waiting (Richard, 2026-11-07: "the stremio streams u flick take much much too long").
    func warmNext() {
        guard let ref = item.stremioRef, ref.type == "series", let v = upNext else { return }
        Task { _ = await StreamCache.shared.streams(type: "series", imdb: ref.imdb, video: v) }
    }
    // True once the episode he's on is known (what's playing, the card, or Continue watching), so nothing is prepared for a
    // guess like S1 E1 before then.
    @State private var resumeKnown = false
    // Each episode's own description and running time, from Stremio's catalogue.
    @State private var info: SeriesInfo.Info?
    // Start over or carry on, as chosen; unchosen, a nearly-finished one starts over and anything else carries on.
    @State private var startOverChoice: Bool?
    var startOver: Bool { startOverChoice ?? nearEnd }
    @State private var runtime: Double?
    @State private var choseOnTV = false
    @Environment(\.paneLayout) private var panes
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var priorMood: Color??
    // The Mac said the film is playing: the controls are his.
    @State private var playedAt: Date?
    // On the way out: nothing started now may change the app behind.
    @State private var leaving = false
    // Into the Remote: the picked thing's picture moves from where it was picked onto the Remote's own picture of the TV.
    // `moveT` is the move itself, 0 at the row (or the card) and 1 on the Remote's picture, on goRemote's spring.
    @State private var toRemote = false
    @State private var moveT: CGFloat = 0
    @State private var flyFrom = CGRect.zero
    @State private var remoteSlot = CGRect.zero
    @State private var screenOut = false
    // The last of it fading, so nothing over the Remote is gone in one frame when the screen closes.
    @State private var fadingOut = false
    // The tab he picked from, while the Remote comes up under this screen.
    @State private var tabBefore: Int?
    @State private var restoredTab: Int?
    // Where this screen sits on the display, to place things measured elsewhere.
    @State private var flickFrame = CGRect.zero
    // Held where it was as the Remote's tab comes up under it, so the tab changing can't lay it out again mid-move.
    @State private var held: CGRect?
    var flickOrigin: CGPoint { (held ?? flickFrame).origin }
    // The picked thing's own colour, which floods in a little behind the page.
    @State private var tint: Color?
    // Where each row and the card sit, in this screen's space, kept without redrawing anything.
    @State private var rects = RectBox()
    // The row (or the card) held and in the hand: it follows the finger, and let go upward it's the pick.
    @State private var liftedID: String?
    // Where the finger has it and how it leans, in a box only the lifted thing's own look reads (LiftedLook): as state of
    // this screen, every point the finger moved redrew the whole streams page under the row in the hand.
    @State private var lift = LiftBox()
    @State private var liftScale: CGFloat = 1
    // When a lifted row was last put down short of a throw, so the tap that iOS reports with the same release does nothing.
    @State private var settledAt = Date.distantPast
    // The finger on the row or the card, read by FlickHand; kept in a box so its every sample redraws nothing.
    @State private var hands = HandBox()
    // Whose gesture is under a finger now. iOS resets it however the touch ends, also when the system takes the touch
    // away and the gesture's own end never comes: a row left floating in the hand, the list unable to scroll and every
    // tap refused, was the flick "not working" until the page was closed.
    @GestureState private var touching: String?
    // The row or card just thrown: hidden where it was, as its picture is what flies.
    @State private var thrownID: String?
    // The list under a row in the hand holds still: its pan turned off in UIKit, never by redrawing the page (setting
    // scrollDisabled as a row lifted rebuilt the scroll view under the finger, and iOS took the touch away the moment it
    // moved: every real throw went back, CI 180efb2).
    @State private var pageLock = ScrollLockBox()
    // Another stream of what's already on, picked on purpose: sent, at the spot he's at.
    @State private var switching = false
    // A link's page name and picture, as fetched.
    @State private var linkTitle: String?
    @State private var linkArt: String?
    @State private var linkLooked = false
    // How the finger left the row or the card at the throw, for the TV's card to come in the same way.
    @State private var throwV = CGSize.zero
    // Each lift is its own flick on the TV, until it's thrown: the id the Mac and the TV follow it by.
    @State private var receiptID = UUID().uuidString
    // What the TV's receipt shows for this pick: the same title and line the Remote shows while it starts.
    var receipt: [String: Any] {
        let kind: String
        if video { kind = isSeries ? "episode" : "film" }
        else if item.kind == "youtube" { kind = "video" }
        else if isLink { kind = "link" }
        else if target.image != nil || source == .mint || target.send?.0 == "flick" { kind = "song" }
        else { kind = "film" }
        let line: String
        if let e = episode { line = "S\(e.season) E\(e.episode) · \(e.name)" }
        else if isLink { line = linkTitle == nil ? "" : item.title }
        else if kind == "film" { line = "" }
        else { line = shown.subtitle }
        let shape = kind == "song" ? "square" : kind == "film" || (kind == "episode" && episode?.thumb.isEmpty != false) ? "poster" : "wide"
        return FlickReceipt.body(id: receiptID, title: shown.title, line: line, art: startingArt, kind: kind, shape: shape)
    }
    // The card or a row is in his hand: the TV begins what it can where it can't be seen (the Mac's flick-lift: the
    // card's picture fetched, Mint's process up for a song), and for a stream row that exact stream's link is resolved
    // there now, ahead of the throw. Nothing shows on the TV until the release. Nothing for what's already on.
    func liftedUp() {
        guard !flown, !onTV else { return }
        let id = UUID().uuidString
        receiptID = id
        var r = receipt
        r["id"] = id
        if video, let row = liftedID, let s = streams.first(where: { $0.id == row }) {
            var b = prepareBody
            b["token"] = s.token
            // The link and nothing else: nothing is woken, opened or shown on the TV before he lets go (lifted and put
            // back, the TV must be exactly as it was).
            b["resolve"] = true
            Prepare.arm(b)
        }
        FlickReceipt.lift(r, lands: kindLands)
    }
    // Where a plain send lands, for the Mac to bring up out of sight: Mint for a song.
    var kindLands: String? { !video && (target.image != nil || source == .mint || target.send?.0 == "flick") ? "mint" : nil }
    static let pose = UserDefaults.standard.string(forKey: "pose")
    static let posed = ["flickdemo", "flickdemo-stream", "streams"].contains(pose) || pose?.hasPrefix("flick-") == true

    init(target: FlickTarget) {
        self.target = target
        let ref = target.source == .stremio && target.send == nil ? target.item.stremioRef : nil
        // Every Stremio title shows its streams and waits for the pick: a film, a card that already names its episode
        // (Continue watching, Recently flicked, the next episode, a re-flick) and "Choose another" open on the list;
        // only a show with no episode on its card opens on its episodes first. Nothing is picked for him and nothing
        // starts from a pick alone (Richard, 2026-11-10: "streams should always be shown when choosing stremio titles").
        if ref == nil { _step = State(initialValue: .card) }
        else if ref?.type == "movie" || ref?.video != nil || target.streamsFirst { _step = State(initialValue: .streams) }
        else { _step = State(initialValue: .episodes) }
        _failedTokens = State(initialValue: target.avoid)
        if let r = target.receiptID { _receiptID = State(initialValue: r) }
        if let v = target.thrown { _throwV = State(initialValue: v) }
    }
    var item: MediaItem { target.item }
    var source: MediaSource { target.source }
    var isSeries: Bool { item.stremioRef?.type == "series" }
    var isLink: Bool { item.kind == "link" || (item.kind == "youtube" && target.send != nil && item.art.isEmpty) }
    // Picking an episode or a stream, and through the move after the pick: the side bar stays beside this screen, so
    // another tab is a tap away, and the page under it steps out of sight. From the pick on, the Remote's tab is up
    // under this screen (UnderFlick lets it draw while flickHandoff is set); landed on it, this screen lets the pages go.
    var choosing: Bool { !closing && !landedOnRemote }
    @State private var closing = false
    @State private var landedOnRemote = false
    // Whether the pick has a picture to carry into the Remote: a plain send with none (a bare link, a song whose cover
    // has no address) crosses to the Remote through the page's own dissolve instead.
    var flies: Bool { !startingArt.isEmpty }
    // What the Mac is told is coming, so it can do more than wake the TV.
    var prepareBody: [String: Any] { prepareBody(for: nil) }
    func prepareBody(for video: String?) -> [String: Any] {
        guard let ref = item.stremioRef else { return [:] }
        var b: [String: Any] = ["type": ref.type, "imdb": ref.imdb]
        if let v = video ?? episode?.id ?? ref.video { b["video"] = v }
        if video == nil, let t = stream?.token { b["token"] = t }
        return b
    }
    // A Stremio stream or title: the kind of send the TV can be made ready for.
    var video: Bool { source == .stremio && target.send == nil && item.stremioRef != nil }
    var onTV: Bool { model.isOnTV(shown, source) || model.isOnTV(item, source) }
    // The card as it reads now: the show at the chosen episode, or a link at its fetched name.
    var shown: MediaItem {
        if isLink {
            return MediaItem(title: linkTitle ?? item.title, subtitle: linkTitle == nil ? "" : item.title, art: linkArt ?? item.art, id: item.id, kind: item.kind)
        }
        guard let e = episode else { return item }
        return MediaItem(title: item.title, subtitle: "S\(e.season) E\(e.episode) · \(e.name)", art: item.art, id: item.id, kind: item.kind)
    }
    var seasons: [Int] { Array(Set((meta?.episodes ?? []).map(\.season))).sorted() }
    var previous: Step? {
        switch step {
        case .episodes, .card: return nil
        case .streams: return isSeries ? .episodes : nil
        }
    }
    func go(_ to: Step) {
        model.tick()
        forward = to.rawValue > step.rawValue
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = to }
        if to == .streams && streams.isEmpty { Task { await findStreams() } }
    }

    var body: some View {
        screen
            .opacity(fadingOut ? 0 : 1)
            // The TV made ready, with what's coming, at each point he shows he means it: the show's page with its Resume,
            // and the streams opening. Nothing is prepared for what's already on the TV (r18).
            .onChange(of: step) { _, now in if now == .streams && video && !onTV { Prepare.arm(prepareBody) } }
            .onChange(of: resumeKnown && !onTVUnsettled ? resumeTarget?.episode.id : nil) { _, id in
                if let id, video, step == .episodes, let t = resumeTarget, !isOn(t.episode) { Prepare.arm(prepareBody(for: id)) }
            }
            .onChange(of: liftedID != nil) { _, up in
                ScrollLock.set(pageLock, up)
                if up { FlickHaptic.lift(); FlickClock.touched(); liftedUp() }
                // Down again without a throw: the TV lets its hint go. A throw clears the hand too, but it's `flown` by then.
                else if !flown { FlickReceipt.cancel(receiptID) }
            }
            // The touch is over, however it ended: anything still in the hand that its own end didn't settle goes back.
            .onChange(of: touching) { was, now in
                guard now == nil, let id = was else { return }
                Task { @MainActor in
                    guard liftedID == id, !flown else { return }
                    HandTrace.note("cancelled-by-system dy=\(Int(lift.drag.height))")
                    _ = hands.hand.cancel(); hands.id = nil
                    settle(quiet: true)
                }
            }
            .task { await opened() }
            // The picture the Remote shows while the TV starts (an episode's still, which the rows never showed), fetched
            // and shrunk while he's choosing, so at the pick it's in memory with its soft version.
            .task(id: screenURL) { if let u = screenURL { _ = await ImageStore.shared.load(u); if softImage == nil, let h = ImageStore.shared.cached(u) { softImage = await ImageStore.shrunk(h, 16) } } }
            .onAppear { FlickHaptic.warm() }
    }
    var screen: some View {
        // The system's own bar, so on the Duo back and close sit on the side like everywhere else.
        NavigationStack {
            GeometryReader { g in
                // Once held, laid out at the size it had and put back where it was, whatever the space around it does.
                let live = g.frame(in: .global)
                let box = held ?? live
                ZStack {
                    backdrop(box.size)
                    Group {
                        switch step {
                        case .episodes: episodesStep.transition(slide)
                        case .streams: streamsStep.transition(slide)
                        case .card: cardStep(g).transition(slide)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // In and out with the backdrop: it opens over the app, not as a sheet sliding up.
                    .opacity(arrived ? 1 : 0)
                    // The picked thing's picture on its way into the Remote, over the page as it dissolves.
                    if flown && !screenOut { flyer }
                }
                .frame(width: box.width, height: box.height)
                .coordinateSpace(name: "flick")
                .offset(x: box.minX - live.minX, y: box.minY - live.minY)
            }
            // On the reader, outside the hold's offset, so measuring it moves nothing.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { flickFrame = $0 }
            // Back and Close are the system's own navigation items, laid out by iOS the Duo's way (the top of the side
            // strip folded and open in landscape, the top bar open in portrait): Back a step through the choosing, X to
            // close (Apple's HIG for iPhone Duo, "Vertical controls"; Richard, 2026-11-08). The bar stays through the move
            // and fades with the rest of this screen: taken off as the move began, iOS kept its glass disc and dropped the
            // glyph, an empty circle until the Remote came.
            .toolbar { if barShown { bar } }
            .environment(\.pageBar, pageBar)
            // Open, the show's one big key sits at the left pane's foot, level with Back at the right's: the same height,
            // the same baseline.
            .overlay(alignment: .bottomLeading) {
                if panes && step == .episodes && !flown {
                    resumeButton(height: 50)
                        .padding(.horizontal, 20).padding(.bottom, 16)
                        .containerRelativeFrame(.horizontal) { w, _ in w / 2 }
                        .opacity(barShown ? 1 : 0)
                }
            }
            .onChange(of: choosing, initial: true) { _, c in model.flickChoosing = c }
            .onDisappear { model.flickChoosing = false; model.flickCovering = false }
            // Another tab, from the side bar while choosing, leaves the page for it.
            .onChange(of: model.tab) { _, t in
                // Its own putting back of the page he came from isn't him picking a tab, nor is the Remote being brought up
                // under this screen at the pick.
                if t == restoredTab { restoredTab = nil; return }
                if model.flickHandoff || flown { return }
                if !leaving { leave() }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .containerBackground(.clear, for: .navigation)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .preferredColorScheme(.dark)
        // The build's recording only: what the flick is doing, so a frame can be read against the code. Top left, clear of
        // the page's heading.
        .overlay(alignment: .topLeading) {
            // Only on the flick's own timing poses; the plain page shots stay clean so the page itself can be judged.
            if Self.pose?.hasPrefix("flick-") == true || Self.pose?.hasPrefix("flickdemo") == true {
                // Milliseconds since the pick, and since the card's press for the list, so a frame can be read against the
                // targets: streams within 150 ms of the press when cached, the Remote within 400 ms of the pick.
                // Ten times a second, not every frame: redrawn per frame it cost the hand-off its own frames (r27).
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    let t = releasedAt == .distantPast ? -1 : Int(ctx.date.timeIntervalSince(releasedAt) * 1000)
                    let l = streamsAt.map { Int($0.timeIntervalSince(StreamCache.pressedAt ?? openedAt) * 1000) } ?? -1
                    Text("t=\(t) list \(l) step \(step.rawValue) flown \(flown ? 1 : 0) move \(toRemote ? 1 : 0) phase \(phase ?? "-") answered \(answered ? 1 : 0)")
                        .font(.system(size: 11, design: .monospaced)).padding(6).background(.black.opacity(0.7)).foregroundStyle(.yellow)
                }
            }
        }
    }
    // When the stream list was first on screen, for the build's timing line.
    @State private var streamsAt: Date?
    // As the screen opens: in it comes, the colours change, and whatever the page needs is asked for.
    func opened() async {
        openedAt = Date()
        // Quick: the page is what he tapped for, so it's there as the tap lands, not on a half-second spring.
        withAnimation(.easeOut(duration: 0.18)) { arrived = true }
        Task { try? await Task.sleep(nanoseconds: 120_000_000); withAnimation(.easeOut(duration: 0.2)) { barShown = true } }
        // The app behind takes on the picked thing's colour too, and gets its own back after: never once this has
        // started to close, or the colour would stay behind it.
        if priorMood == nil { priorMood = .some(model.mood) }
        let art = item.art
        Task {
            guard let u = URL(string: art), let c = await ImageStore.shared.band(u) else { return }
            withAnimation(.easeOut(duration: 0.3)) { tint = c }
            if !leaving, !flown { model.mood = c }
        }
        if step == .streams && video && !onTV { Prepare.arm(prepareBody) }
        if Self.posed && Self.pose != "streams" { Task { await demo() } }
        // Thrown from its shelf: nothing to choose (a video, a song, a link) goes now; a show with no episode named opens
        // its page as a tap would, and the TV lets the lift's screen go.
        if target.thrown != nil {
            if step == .card { Task { try? await Task.sleep(nanoseconds: 34_000_000); FlickHaptic.caught(); send(from: shelfFrom) } }
            else if step == .episodes { FlickReceipt.cancel(receiptID) }
        }
        if isLink && !linkLooked {
            linkLooked = true
            Task {
                let p = await LinkPeek.peek(item.id)
                withAnimation(.easeOut(duration: 0.25)) { linkTitle = p.title; linkArt = p.art }
                if let a = p.art.flatMap(URL.init(string:)) { _ = await ImageStore.shared.load(a) }
            }
        }
        // Side by side, so a slow description doesn't hold up the streams.
        async let details: Void = loadMeta()
        if isSeries, let ref = item.stremioRef {
            info = SeriesInfo.cached(ref.imdb)
            if info == nil { Task { let i = await SeriesInfo.load(ref.imdb); withAnimation(.easeOut(duration: 0.2)) { info = i } } }
        }
        if step == .streams && streams.isEmpty { await findStreams() }
        await details
    }
    var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    // Black, as he asked: the page behind never shows through as shapes. The picked thing's art shows softly through the
    // dark.
    func backdrop(_ size: CGSize) -> some View {
        ZStack {
            // Opaque under everything: nothing of the page behind can read through, so that page needn't hide its own bar
            // to stay out of sight, which took the tab rail with it (r20–r26: no rail beside a show's page).
            Color.black
            Color.clear
                .overlay {
                    Group {
                        if let image = target.image { image.resizable().scaledToFill() }
                        else {
                            Art(url: URL(string: episode?.thumb.isEmpty == false ? episode!.thumb : shown.art)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                                .id(episode?.id ?? shown.art)
                                .transition(.opacity)
                        }
                    }
                    // A fixed blur: animating its radius redraws the whole screen's blur every frame.
                    .blur(radius: 32)
                    .scaleEffect(1.1)
                }
                .clipped()
                // Beside the side bar the strip under it is plain black, so the art's tint dies away before the page's
                // trailing edge rather than meeting the strip as a band of a different background (r30).
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .opacity(0.4)
            Color.black.opacity(0.6)
        }
        // Edge to edge, except past the page's trailing edge beside the side bar, where it would cover the rail.
        .ignoresSafeArea(edges: model.flickChoosing ? [.top, .bottom, .leading] : .all)
        .opacity(arrived ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: episode)
        .animation(.easeOut(duration: 0.3), value: step)
    }

    // One control at the top of the bar, as the Duo reserves it: Back while there's a step to go back to, else Close.
    @ToolbarContentBuilder var bar: some ToolbarContent {
        if let previous, !flown {
            ToolbarItem(placement: .navigation) { Button { go(previous) } label: { Label("Back", systemImage: "chevron.left") } }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button { if !flown { leave() } } label: { Label("Close", systemImage: "xmark") }
            }
        }
    }

    var poster: some View {
        Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
            .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
    }
    // The show's name leads; under it, once an episode's chosen, that episode, else how many seasons there are.
    func titles(big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(big ? .title.weight(.bold) : .title2.weight(.bold)).lineLimit(3)
            if step == .streams, let e = episode {
                Text("S\(e.season) E\(e.episode) · \(e.name)").font(.headline).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            } else if isSeries, case let n = seasons.filter({ $0 > 0 }).count, n > 0 {
                Text(n == 1 ? "1 season" : "\(n) seasons").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .contentTransition(.opacity)
    }
    // What it's about: on the streams, the episode's own words, else the show's or the film's (Richard, 2026-11-05: "make
    // the description an episode description unless not available").
    var blurbText: String? {
        if step == .streams, let e = episode, let o = info?.about[e.id], !o.isEmpty { return o }
        let a = meta?.about ?? item.about
        return a?.isEmpty == false ? a : nil
    }
    // Stremio's own words for it are on their way (the card's are in hand at once, the catalogue's a moment later).
    var blurbComing: Bool { source == .stremio && target.send == nil && item.stremioRef != nil && meta == nil && !metaFailed }
    func blurb(_ lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Its full height held from the start, whatever words are in it and while the catalogue's are on their way,
            // so the late description crossfades in place and nothing under it moves.
            if let t = blurbText ?? (blurbComing ? "" : nil) {
                Text(t).font(.subheadline).foregroundStyle(.secondary).lineLimit(lines, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
            }
            HStack(spacing: 18) {
                // Everything about it, before choosing (Richard, 2026-11-07: "an i to see full details of each before i flick").
                if item.stremioRef != nil {
                    Button { model.tick(); showInfo = true } label: { Label("Details", systemImage: "info.circle") }
                        .font(.footnote.weight(.semibold)).tint(TVLook.accent)
                }
                if let slug = item.slug, !slug.isEmpty {
                    Button { model.tick(); model.post("film", ["slug": slug]); leave() } label: {
                        Label("Letterboxd", systemImage: "film")
                    }.font(.footnote.weight(.medium)).tint(TVLook.accent)
                }
            }
        }
        .navigationDestination(isPresented: $showInfo) { TitleInfoPage(item: item, source: source, fromFlick: true) }
        .animation(.easeOut(duration: 0.2), value: blurbText)
    }
    var heading: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                poster.frame(width: 74, height: 111).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { rects.map["poster"] = $0 }
                VStack(alignment: .leading, spacing: 8) { titles(big: false); blurb(4) }
                Spacer(minLength: 0)
            }
            if step == .episodes { resumeButton() }
        }
    }
    // Unfolded, the show has the left side to itself: poster and name side by side, what it's about under them, and the
    // one big way to carry on, so the side reads full rather than a small poster over empty space.
    var bigHeading: some View {
        VStack(alignment: .leading, spacing: 16) {
            titles(big: true)
            poster.aspectRatio(2 / 3, contentMode: .fit)
                .containerRelativeFrame(.horizontal) { w, _ in min(w * 0.6, 300) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { rects.map["poster"] = $0 }
            blurb(6)
            // On the streams, the episode being chosen for: its number, name, length and what happens, so the side
            // under the poster is the episode's page, not half empty (r27).
            if step == .streams, let e = episode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Season \(e.season) · Episode \(e.episode)" + (e.runtime.map { " · \($0) min" } ?? ""))
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Text(e.title).font(.title3.weight(.semibold)).lineLimit(2)
                    if let o = e.overview, !o.isEmpty { Text(o).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Where to carry on: the episode he's on (or the one after it if that's all but done, or the first), as one big key.
    var resumeTarget: (episode: StremioEpisode, verb: String)? {
        guard let all = meta?.episodes, !all.isEmpty else { return nil }
        if let id = upNext, let e = all.first(where: { $0.id == id }) {
            let p = upNextProgress ?? 0
            if p > 0.9, let n = NextUp.after(e, in: all) { return (n, "Play next") }
            return (e, p > 0 ? "Resume" : "Play")
        }
        return (all.first { $0.season > 0 } ?? all[0], "Play")
    }
    // The episode the big key would play is already what's on the TV: the key says so, and takes him to the Remote.
    func isOn(_ e: StremioEpisode) -> Bool {
        guard let ref = item.stremioRef else { return false }
        return model.isOn(imdb: ref.imdb, title: item.title, episode: e.id)
    }
    // This show is what the TV's playing, but which episode isn't known yet: no key and no prepare until it is.
    var onTVUnsettled: Bool {
        guard item.stremioRef?.type == "series", model.videoIsCurrent, let s = model.status?.session, s.pkg == "com.stremio.one" else { return false }
        // Not settled until a fresh reading is in.
        if model.staleStatus { return true }
        if let on = NextUp.shared.series, on.imdb == item.stremioRef?.imdb { return false }
        return (s.isShow(item.title)) && s.seasonEpisode == nil
    }
    // Straight to the Remote with nothing sent; if it's paused there, asked to play (MEDIA_PLAY, never the toggle).
    func toRemoteNow() {
        model.tick()
        // Held as playing, as from a card, so the key shows the play it asked for at once.
        if model.status?.session?.playing == false { model.holdPlay(true); model.key("resume") }
        if let prior = priorMood { model.mood = prior }
        model.tab = 0
        leave(restoreMood: false)
    }
    @ViewBuilder func resumeButton(height: CGFloat = 58) -> some View {
        if let t = resumeTarget, isOn(t.episode) {
            Button(action: toRemoteNow) {
                HStack(spacing: 12) {
                    Circle().fill(TVLook.accent).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("On the TV").font(.headline)
                        Text("S\(t.episode.season) E\(t.episode.episode) · \(t.episode.name)").font(.caption.weight(.medium)).opacity(0.7).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "av.remote").font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 20).frame(height: height)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressCard())
            .transition(.opacity)
        } else if let t = resumeTarget, resumeKnown, !onTVUnsettled {
            // Only once it's known where he is: until then it said "Play S1 E1" for a show he's halfway through (r18).
            let p = t.episode.id == upNext ? (upNextProgress ?? 0) : 0
            let mins = info?.minutes[t.episode.id] ?? info?.show
            let left = t.verb == "Resume" ? mins.map { "\(max(1, Int(Double($0) * (1 - p)))) min left" } : mins.map { "\($0) min" }
            Button { choose(t.episode) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill").font(.system(size: 17, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(t.verb) S\(t.episode.season) E\(t.episode.episode)").font(.headline)
                        Text(([t.episode.name] + (left.map { [$0] } ?? [])).joined(separator: " · ")).font(.caption.weight(.medium)).opacity(0.7).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.black).padding(.horizontal, 20).frame(height: height)
                .background(TVLook.accent, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressCard())
            .transition(.opacity)
        }
    }
    // An episode picked, from its row or the big key: its streams, which were asked for as the page opened, so the list
    // is there as the step slides in.
    func choose(_ e: StremioEpisode) {
        if episode != e { episode = e; stream = nil; streams = []; noStreams = false; streamFilter = "All"; runtime = nil; startOverChoice = nil; choseOnTV = false }
        go(.streams)
    }
    func row<L: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                label()
                Spacer(minLength: 0)
                // The whole row is the button, so no arrow; only the one chosen says so.
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(TVLook.accent).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            // One row height for every plain choice on these pages, with the same corners as the episode rows.
            .frame(minHeight: 40)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(selected ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressCard())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    // The film at the top, then the choices. Unfolded, the film one side of the fold and the choices the other.
    @ViewBuilder func page<C: View>(@ViewBuilder content: () -> C) -> some View {
        // Both sides start at the same line, and fade under the top edge rather than run under the clock. Room at the
        // foot for the bar, so the last row can always be scrolled clear of it. Still while a row is in the hand.
        if panes {
            FoldSplit {
                ScrollView { bigHeading.padding(.horizontal, 20).padding(.top, 36).padding(.bottom, 84) }.topFade().summonsBar()
            } right: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { content() }
                        .padding(.horizontal, 20).padding(.top, 36).padding(.bottom, 84)
                        .background(ScrollLock(box: pageLock).allowsHitTesting(false))
                }
                .topFade().summonsBar()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { heading.padding(.bottom, 8); content() }
                    // Clear of the top edge and the clock, never jammed under it (r21).
                    .padding(.horizontal, 20).padding(.top, 32).padding(.bottom, 84)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(ScrollLock(box: pageLock).allowsHitTesting(false))
            }
            .topFade().summonsBar()
        }
    }

    // First step of a series: which episode. The same list as over the Remote and on Playing.
    var episodesStep: some View {
        page {
            if seasons.isEmpty && !metaFailed {
                ForEach(0..<4, id: \.self) { i in PlaceholderRow(delay: Double(i) * 0.12, thumb: true) }
            } else if seasons.isEmpty {
                // No episode list is no reason to be stuck: the TV can still open the series.
                Text("Couldn’t load the episodes.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                Button("Try again") { metaFailed = false; Task { await loadMeta() } }.font(.subheadline.weight(.medium)).tint(TVLook.accent)
                row(selected: false) { send(from: rects.map["poster"]) } label: {
                    Image(systemName: "tv").foregroundStyle(TVLook.accent).frame(width: 28)
                    Text("Open the series on the TV").font(.subheadline.weight(.semibold))
                }
            } else {
                ScrollViewReader { proxy in
                    let target = resumeTarget?.episode
                    EpisodePicker(episodes: meta?.episodes ?? [], season: $season, current: target?.id,
                                  // The episode that's on the TV says so, never "Up next" (r18).
                                  currentLabel: target.map(isOn) == true ? "Playing" : resumeTarget?.verb == "Resume" ? "Resume" : "Up next",
                                  progress: target?.id == upNext ? upNextProgress : nil, info: info) { choose($0) }
                    // To where he is, as soon as that's known, and again on coming back from the streams.
                    .onChange(of: target?.id, initial: true) { _, id in
                        guard let id else { return }
                        Task { try? await Task.sleep(nanoseconds: 60_000_000); withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onAppear { if let id = episode?.id ?? target?.id { Task { proxy.scrollTo(id, anchor: .center) } } }
                }
            }
        }
    }
    func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(TVLook.accent, in: Capsule()).foregroundStyle(.black)
    }
    // The page is wordless: Richard, choice screen 2026-11-10, "No hints" (tapping a stream is obvious enough). Kept as a
    // no-op so the call sites read as where a hint would have been.
    @AppStorage("flicksDone") private var flicksDone = 0
    @ViewBuilder func hint(_ words: String) -> some View { EmptyView() }
    // Next: which stream, or leave that to the TV. The pick is the flick: a tap sends it, and so does holding a row and
    // flicking it up.
    var streamsStep: some View {
        page {
            // The episode is named on the left, over its own description; here, the choice, under its heading.
            let qualities = ["1080p", "4K", "720p", "480p"].filter { q in streams.contains { $0.quality == q } }
            HStack(spacing: 12) {
                Text("Streams").font(.title3.weight(.bold))
                if qualities.count > 1 { Chips(options: (["All"] + qualities).map { ($0, $0) }, selected: $streamFilter).rowEdge() }
            }
            .frame(height: 36, alignment: .leading)
            .padding(.bottom, 2)
            hint("Tap a stream to play it on the TV, or hold it and flick it up.")
            // A row like the streams under it: a tap, or held and flicked up.
            row(selected: false) { if handFree { chooseOnTV() } } label: {
                Image(systemName: "tv").font(.system(size: 17, weight: .semibold)).foregroundStyle(TVLook.accent).frame(width: 28)
                Text("Choose on the TV").font(.subheadline.weight(.semibold))
            }
            .modifier(LiftedLook(lift: lift, up: liftedID == "tv", scale: liftScale, swell: 0.1, corner: 14, rest: (0, 0, 0), raised: (0.5, 24, 16), solid: true))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { rects.map["tv"] = $0 }
            .opacity(thrownID == "tv" ? 0 : 1)
            .zIndex(liftedID == "tv" ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: liftedID == "tv")
            .simultaneousGesture(holdAndThrow("tv") { chooseOnTV() })
            // Where it'll start, and the other way, whenever he's been in it before: from the card, else from Stremio's own
            // Continue watching (Richard, 2026-11-07: "obv when i flick it should start from where i was"). It applies to
            // whichever stream he picks.
            if hasResume && !choseOnTV {
                Chips(options: [(false, resumeLabel), (true, "Start over")], selected: Binding(get: { startOver }, set: { startOverChoice = $0 })).padding(.top, 6)
            }
            if findingStreams && streams.isEmpty {
                Text("Asking your addons…").font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(0..<4, id: \.self) { i in PlaceholderRow(delay: Double(i) * 0.12) }
            } else if noStreams {
                Button("No streams found. Try again") { Task { await findStreams(again: true) } }
                    .font(.subheadline.weight(.medium)).tint(TVLook.accent).frame(maxWidth: .infinity).padding(.top, 22)
            }
            let shown = streams.filter { streamFilter == "All" || $0.quality == streamFilter }
            // Best is the top one that hasn't already failed to start.
            let best = streamFilter == "All" ? streams.first { !failedTokens.contains($0.token) && $0.stalled != true && $0.dubbed != true } : nil
            // The stream that's on the TV now, when this is its own list: it says so, and a tap on it is the Remote.
            let onNow = alreadyOnTitle ? fileOnTV : nil
            // Rows that would read exactly the same say where each came from.
            let looks = Dictionary(shown.map { ($0.look, 1) }, uniquingKeysWith: +)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                streamRow(s, best: s == best, failed: failedTokens.contains(s.token), twin: (looks[s.look] ?? 0) > 1, playing: onNow != nil && onNow == s.description).transition(arriving(i))
            }
        }
        .task(id: episode?.id) { await loadRuntime() }
    }
    // Rows come in one after another, a beat apart; a list that was already in the cache is simply there.
    func arriving(_ i: Int) -> AnyTransition {
        if streamsQuick { return .opacity }
        let spring = Animation.spring(response: 0.45, dampingFraction: 0.85).delay(Double(min(i, 8)) * 0.035)
        return .asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(y: 14)).animation(spring), removal: .opacity)
    }
    // How far into it the card says he is, for the episode it's about.
    var savedProgress: Double? {
        guard let ref = item.stremioRef else { return nil }
        if ref.type == "series", let e = episode {
            if e.id == ref.video, let p = item.progress { return p }
            if e.id == upNext, let p = upNextProgress { return p }
            return continuing(ref.imdb, e.id)
        }
        return item.progress ?? continuing(ref.imdb, nil)
    }
    // Where Stremio's own Continue watching has him in this film, or this episode of this show.
    func continuing(_ imdb: String, _ video: String?) -> Double? {
        let row = BrowseStore.shared(.stremio).rows.first { $0.title == "Continue watching" }
        for i in row?.items ?? [] {
            guard let r = i.stremioRef, r.imdb == imdb, let p = i.progress else { continue }
            if video == nil || r.video == video { return p }
        }
        return nil
    }
    var hasResume: Bool { (savedProgress ?? 0) > 0.01 && (savedProgress ?? 0) < 0.99 }
    var nearEnd: Bool { (savedProgress ?? 0) > 0.9 }
    var resumeLabel: String {
        guard let runtime, let p = savedProgress else { return "Resume" }
        // Running time times progress: "Resumes at 42:10", "Resumes at 1:12:05".
        let s = Int(runtime * p / 1000)
        return "Resumes at " + (s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
    }
    // The running time, for the Resume chip's time: from Stremio's own catalogue, the episode's if it has one.
    func loadRuntime() async {
        guard runtime == nil, hasResume, let ref = item.stremioRef,
              let d = await TVBridge.data(URL(string: "https://v3-cinemeta.strem.io/meta/\(ref.type)/\(ref.imdb).json"), timeout: 10, cached: true),
              let meta = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["meta"] as? [String: Any] else { return }
        let video = episode?.id ?? ref.video
        let ep = (meta["videos"] as? [[String: Any]])?.first { ($0["id"] as? String) == video }
        func minutes(_ t: Any?) -> Double? {
            guard let t = t as? String else { return nil }
            // "2h 3min", "123 min" and the like: the number before each unit.
            func number(before unit: String) -> Double {
                guard let r = t.range(of: "\\d+\\s*" + unit, options: .regularExpression) else { return 0 }
                return Double(t[r].prefix { $0.isNumber }) ?? 0
            }
            let h = number(before: "h"), m = number(before: "min")
            return h + m > 0 ? (h * 60 + m) * 60000 : nil
        }
        if let ms = minutes(ep?["runtime"]) ?? minutes(meta["runtime"]) { withAnimation(.easeOut(duration: 0.2)) { runtime = ms } }
    }
    // A stream's row: the pick, by a tap, or lifted (held a moment) and flicked up. Lifted, it rises off the list, follows
    // the finger exactly and swells as it goes up; let go upward it's sent, let go short of that it settles back.
    func streamRow(_ s: StremioStream, best: Bool, failed: Bool, twin: Bool, playing: Bool = false) -> some View {
        let up = liftedID == s.id
        return row(selected: false) {
            guard handFree else { return }
            pick(s)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.name.isEmpty ? s.addon : s.name).font(.subheadline.weight(.bold)).lineLimit(1)
                    // The list comes best first, for this box and what's being watched.
                    if playing { badge("Playing") } else if best { badge("Best") }
                    // Tried, and the TV couldn't get it going: left in place so the list doesn't jump. One that failed in
                    // this very sitting is out of reach; one the Mac remembers from the last few days says so and can
                    // still be picked.
                    if failed || s.stalled == true {
                        Text("Didn’t start").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(.white.opacity(0.14), in: Capsule()).foregroundStyle(.secondary)
                    }
                }
                let details = s.details(withSource: twin, size: false)
                if !details.isEmpty { Text(details).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1) }
                // Everything the addon says about it (the file, the source, the size, the codec), when its "i" is open.
                if streamOpen == s.id {
                    Text([s.addon, s.name, s.description].filter { !$0.isEmpty }.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .multilineTextAlignment(.leading)
            // How big it is, at the row's end where the eye runs to, right-aligned so the sizes line up down the list.
            Text(s.size ?? "").font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                .frame(minWidth: 64, maxWidth: .infinity, alignment: .trailing).padding(.leading, 8)
            // Its details, opened in place: the row's own tap still picks it.
            Button { model.tick(); withAnimation(.snappy) { streamOpen = streamOpen == s.id ? nil : s.id } } label: {
                Image(systemName: streamOpen == s.id ? "info.circle.fill" : "info.circle").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TVLook.accent).frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Stream details")
        }
        .disabled(failed)
        .opacity(failed ? 0.45 : 1)
        // Lifted: up off the list on a bigger, lower shadow, on its own solid ground (nothing under it reads through),
        // lit round its edge more and more as it rises.
        .modifier(LiftedLook(lift: lift, up: up, scale: liftScale, swell: 0.1, corner: 14, rest: (0, 0, 0), raised: (0.5, 24, 16), solid: true))
        // Where it rests, measured outside everything that moves it (inside the drag's offset, the throw's picture
        // started twice the drag away, near the top of the page).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { rects.map[s.id] = $0 }
        // Thrown: it's the picture on its way to the Remote now, never also a row springing back into the list.
        .opacity(thrownID == s.id ? 0 : 1)
        .zIndex(up ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: up)
        // Held a moment, it's in the hand: from then the finger moves it, and the list under it holds still. The row's
        // own tap stays the quick way.
        .simultaneousGesture(holdAndThrow(s.id, failed: failed) { pick(s) })
        .accessibilityAction(named: "Flick to the TV") { pick(s) }
    }
    // The hold and the flick, on every row of the list: FlickHand reads the finger (lifted after the hold, moved with it,
    // let go upward as the pick, let go where it was as a tap, anywhere else back). The same hand reads the card.
    func holdAndThrow(_ id: String, failed: Bool = false, send: @escaping () -> Void) -> some Gesture {
        let rules = FlickHand.Rules.list
        return LongPressGesture(minimumDuration: rules.hold, maximumDistance: rules.slop)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("flick")))
            .updating($touching) { _, s, _ in s = id }
            .onChanged { v in
                guard !failed, !flown, case .second(true, let d) = v else { return }
                if hands.id != id {
                    // Lifted now: the hold's clock ran out with the finger still within the slop.
                    hands.id = id; hands.base = Date().addingTimeInterval(-rules.hold); hands.hand = FlickHand(rules)
                    _ = hands.hand.down(.zero, at: 0)
                    handle(hands.hand.held(at: rules.hold), id: id, scale: 1.04)
                }
                if let d { follow(d, id: id) }
            }
            .onEnded { v in
                guard hands.id == id else { return }
                var d: DragGesture.Value?
                if case .second(true, let dv) = v { d = dv }
                let t = d.map { $0.time.timeIntervalSince(hands.base) } ?? Date().timeIntervalSince(hands.base)
                let at = d.map { CGPoint(x: $0.translation.width, y: $0.translation.height) } ?? .zero
                finish(hands.hand.up(at, at: t), id: id, translation: d?.translation ?? .zero, send: send)
            }
    }
    // The card: nothing under it scrolls, so it's in the hand from the first touch; the throw, the put-back and the tap
    // are the list's own.
    func cardGesture(send: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("flick"))
            .updating($touching) { _, s, _ in s = "card" }
            .onChanged { d in
                guard !flown else { return }
                if hands.id != "card" {
                    hands.id = "card"; hands.base = d.time; hands.hand = FlickHand(.card)
                    handle(hands.hand.down(.zero, at: 0), id: "card", scale: 1.05)
                }
                follow(d, id: "card")
            }
            .onEnded { d in
                guard !flown, hands.id == "card" else { return }
                let at = CGPoint(x: d.translation.width, y: d.translation.height)
                finish(hands.hand.up(at, at: d.time.timeIntervalSince(hands.base)), id: "card", translation: d.translation, send: send)
            }
    }
    // The finger moved: the thing follows it exactly, leaning the way it goes, and says when letting go would send it.
    func follow(_ d: DragGesture.Value, id: String) {
        guard liftedID == id else { HandTrace.note("move-unlifted"); return }
        if lift.drag == .zero, d.translation != .zero { HandTrace.note("first-move") }
        handle(hands.hand.move(CGPoint(x: d.translation.width, y: d.translation.height), at: d.time.timeIntervalSince(hands.base)), id: id)
        lift.drag = d.translation
        let card = id == "card"
        lift.lean = max(card ? -8 : -6, min(card ? 8 : 6, Double(d.velocity.width) / (card ? 180 : 200) + Double(d.translation.width) / (card ? 50 : 60)))
    }
    func handle(_ events: [FlickHand.Event], id: String, scale: CGFloat = 1.04) {
        for e in events { HandTrace.note("\(e) \(id.prefix(6))") }
        for e in events {
            switch e {
            case .lifted:
                lift.drag = .zero; lift.lean = 0; lift.armed = false; liftedID = id
                withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { liftScale = scale }
            case .armed(let on):
                // Past the line: let go now and it goes. Felt once, as a detent, and seen as its edge lit all round.
                lift.armed = on
                if on { FlickHaptic.detent() }
            case .yielded: break
            }
        }
    }
    func finish(_ outcome: FlickHand.Outcome, id: String, translation: CGSize, send: () -> Void) {
        HandTrace.note(String(format: "end %@ dy=%.0f vy=%.0f", "\(outcome)", translation.height, hands.hand.velocity.dy))
        hands.id = nil
        switch outcome {
        case .thrown:
            // The pick, from where the thing is now, leaving the way the finger did.
            rects.map[id] = (rects.map[id] ?? .zero).offsetBy(dx: translation.width, dy: translation.height)
            let v = hands.hand.velocity
            throwV = CGSize(width: v.dx, height: v.dy)
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { thrownID = id }
            if id == "card" { FlickHaptic.caught() }
            send()
        case .longTap:
            // A press that ran long and was let go where it landed is a tap, and a tap is the pick, however long it was
            // held: lifted and put straight back, it did nothing, and a deliberate press read as a dead row.
            settledAt = Date()
            throwV = .zero
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { liftedID = nil; lift.drag = .zero; lift.lean = 0; lift.armed = false; liftScale = 1 }
            if id == "card" { FlickHaptic.caught() }
            send()
        case .putBack: settle()
        case .cancelled, .none, .quickTap: if liftedID == id { settle(quiet: true) }
        }
    }
    // Let go short of a throw: back to rest, with one soft touch (none when the system took the touch away).
    func settle(quiet: Bool = false) {
        settledAt = Date()
        if !quiet { FlickHaptic.settle() }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.6)) { liftedID = nil; lift.drag = .zero; lift.lean = 0; lift.armed = false; liftScale = 1 }
    }
    // The tap iOS reports with the release of a lifted row (put back, or already sent by the hand) is that release, not
    // a second pick.
    var handFree: Bool { liftedID == nil && Date().timeIntervalSince(settledAt) > 0.3 }
    func chooseOnTV() {
        guard !flown else { return }
        stream = nil; choseOnTV = true; FlickHaptic.caught(); send(from: rects.map["tv"])
    }
    // A stream picked: felt at once, and sent. What's already on the TV is never sent again; the pick goes straight to
    // the Remote (Richard, 2026-11-05: "the episode restarted i think because of the app").
    func pick(_ s: StremioStream) {
        guard !flown else { return }
        stream = s; choseOnTV = false
        FlickHaptic.caught()
        if alreadyOn {
            // The stream that's on, or which one is on isn't known: the Remote, nothing sent (ruling 11). Another row
            // of the same list is a different stream picked on purpose (the dub that was Best, a file that stutters):
            // that one is sent, and carries on where he is.
            guard let on = fileOnTV, on != s.description else { toRemoteNow(); return }
            switching = true
        }
        send(from: target.thrown != nil ? shelfFrom : rects.map[s.id] ?? rects.map["poster"])
    }
    // Where a card thrown from its shelf was let go, in this screen's space.
    var shelfFrom: CGRect? { target.origin.map { $0.offsetBy(dx: -flickOrigin.x, dy: -flickOrigin.y) } }
    func findStreams(again: Bool = false) async {
        guard let ref = item.stremioRef else { return }
        findingStreams = true; noStreams = false
        lookups += 1
        let mine = lookups
        // Only the newest lookup decides when the spinner stops.
        defer { if mine == lookups { findingStreams = false } }
        // The episode picked, else the one the card was already on, before its details have come. Usually already asked
        // for when the card was pressed.
        let video = episode?.id ?? ref.video ?? ref.imdb
        let asked = Date()
        let found = await StreamCache.shared.streams(type: ref.type, imdb: ref.imdb, video: video, again: again)
        // These tokens play the episode they were asked for, so an answer for another one is thrown away.
        guard (episode?.id ?? ref.video ?? ref.imdb) == video, mine == lookups else { return }
        guard let found, !found.isEmpty else { noStreams = true; return }
        // From the cache: there with the page, no arrival of its own. Fetched now: the rows come in a beat apart.
        let quick = Date().timeIntervalSince(asked) < 0.15
        streamsQuick = quick
        if quick { streams = found } else { withAnimation { streams = found } }
        streamsAt = Date()
        // Thrown from its shelf: the stream he'd most likely pick (Best: the top one that hasn't failed and isn't a dub),
        // sent as if he'd thrown its row. The tap still shows the list (Richard, 2026-11-10); the throw is the flick.
        if target.thrown != nil, !flown, !leaving, !again {
            if let best = found.first(where: { !failedTokens.contains($0.token) && $0.stalled != true && $0.dubbed != true }) ?? found.first(where: { !failedTokens.contains($0.token) }) {
                pick(best)
            }
        }
        // How long he waited for the list, from the card's press and from this page opening, into the Mac's timing log, so
        // the phone's own share of "the stremio streams take much too long" is measured on his phone (2026-11-07).
        if !again, openedAt != .distantPast, !leaving {
            let now = Date()
            // `sinceAsk` is his wait: from the moment this list was wanted (the page opening on it, or an episode picked).
            // `sinceOpen` counts from the page opening, so on a show it includes however long he read the episodes: the
            // "28.7 s" and "33.2 s" of 07:24Z on 11-11 were 0.53 s and 0.92 s lookups after 28 s of choosing an episode.
            var e: [String: Any] = ["name": "streams-shown", "at": now.timeIntervalSince1970 * 1000, "sinceOpen": Int(now.timeIntervalSince(openedAt) * 1000),
                                    "sinceAsk": Int(now.timeIntervalSince(asked) * 1000), "video": video, "count": found.count, "cached": quick]
            if let p = StreamCache.pressedAt, now.timeIntervalSince(p) < 30, now.timeIntervalSince(asked) >= now.timeIntervalSince(p) - 0.5 { e["sincePress"] = Int(now.timeIntervalSince(p) * 1000) }
            Task { _ = try? await TVBridge.post("timing", ["events": [e]], timeout: 10) }
        }
    }

    // Nothing to choose (a video, a song, a link): the one card, in the hand. A tap sends it, and so does flicking it up;
    // a pulled card follows the finger exactly.
    func cardStep(_ g: GeometryProxy) -> some View {
        let wide = g.size.width > g.size.height
        let width: CGFloat = wide ? 150 : 136
        let up = liftedID == "card"
        return VStack(spacing: 22) {
            Spacer(minLength: 0)
            hint("Tap it, or flick it up to the TV.")
                .opacity(up ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: up)
            MediaCard(item: shown, source: source, width: width, image: target.image)
                .modifier(LiftedLook(lift: lift, up: up, scale: liftScale, swell: 0.12, corner: 6, rest: (0.45, 18, 10), raised: (0.55, 30, 22)))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: up)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flick")) } action: { rects.map["card"] = $0 }
                .opacity(thrownID == "card" && flies ? 0 : 1)
                // In the hand from the first touch: nothing under it scrolls, so no hold is needed.
                .gesture(cardGesture { send(from: rects.map["card"]) })
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Sends this to the TV")
                .accessibilityAction { FlickHaptic.caught(); send(from: rects.map["card"]) }
            Text(shown.title).font(.headline).multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 40)
                .contentTransition(.opacity)
                .opacity(up ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: up)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: shown.title)
    }
    var screenURL: URL? { URL(string: episode?.thumb.isEmpty == false ? episode!.thumb : shown.art) }
    // The picked thing's picture going into the Remote: from the row (or the card) it was picked from to the Remote's own
    // picture of the TV, as one picture. It starts as the poster filling the row's shape, and opens into exactly what the
    // Remote shows while a start runs (the poster framed on its own soft ground, the light running round the edge), so the
    // landing swaps nothing in sight.
    var flyer: some View {
        FlyingPicture(t: moveT, from: flyFrom, to: remoteSlot, image: target.image ?? heldImage.map { Image(tv: $0) },
                      url: screenURL, soft: softImage, wide: heldImage.map(PosterOnBlur.isWide) ?? (shown.kind == "youtube"), tint: tint)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
    // For the build's recording: the moves a finger makes. flick-stage is the page at rest; flick-tap taps the first
    // stream; flick-putback lifts a row, pulls it down and lets go; flick-link throws a link's card; the rest hold the
    // first row and flick it up, and are judged on what the mock's scene answers (starting, slow, failed, offline,
    // already on).
    func demo() async {
        let pose = Self.pose ?? ""
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if pose == "flick-stage" {
            // The first row's centre, as a fraction of the display, for the build's real touch to land on.
            for _ in 0..<50 where streams.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            #if os(iOS)
            if let first = streams.first, let r = rects.map[first.id],
               let screen = (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen.bounds, screen.width > 0 {
                let x = (r.midX + flickOrigin.x) / screen.width, y = (r.midY + flickOrigin.y) / screen.height
                _ = await TVBridge.data(TVBridge.url(String(format: "/api/tv/applied?what=row&x=%.3f&y=%.3f", x, y)), timeout: 3)
            }
            #endif
            return
        }
        if step == .card {
            for _ in 0..<30 where linkTitle == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            liftedID = "card"; withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { liftScale = 1.05 }
            try? await Task.sleep(nanoseconds: 350_000_000)
            for i in 1...24 {
                lift.drag = CGSize(width: 10 * sin(CGFloat(i) / 24 * .pi), height: -9 * CGFloat(i))
                if !lift.armed, lift.drag.height <= -FlickHand.Rules.card.carry { lift.armed = true; FlickHaptic.detent() }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            rects.map["card"] = (rects.map["card"] ?? .zero).offsetBy(dx: lift.drag.width, dy: lift.drag.height)
            thrownID = "card"
            FlickHaptic.caught(); send(from: rects.map["card"])
            return
        }
        for _ in 0..<100 where streams.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let first = streams.first(where: { !failedTokens.contains($0.token) }) else { return }
        if pose == "flick-tap" { pick(first); return }
        liftedID = first.id; withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { liftScale = 1.04 }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if pose == "flick-putback" {
            for i in 1...30 { lift.drag = CGSize(width: 0, height: 3 * CGFloat(i)); try? await Task.sleep(nanoseconds: 16_000_000) }
            settle()
            return
        }
        for i in 1...24 {
            lift.drag = CGSize(width: 12 * sin(CGFloat(i) / 24 * .pi), height: -8 * CGFloat(i))
            lift.lean = Double(cos(CGFloat(i) / 24 * .pi)) * 3
            if !lift.armed, lift.drag.height <= -FlickHand.Rules.list.carry { lift.armed = true; FlickHaptic.detent() }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        rects.map[first.id] = (rects.map[first.id] ?? .zero).offsetBy(dx: lift.drag.width, dy: lift.drag.height)
        thrownID = first.id
        pick(first)
    }
    // The Remote's tab was brought up under this screen for a pick that didn't go on to it: the page he picked from comes
    // back under it.
    func backToThrownFrom() {
        guard let b = tabBefore else { return }
        restoredTab = b
        var quiet = Transaction(); quiet.disablesAnimations = true
        withTransaction(quiet) { model.flickHandoff = false; model.tab = b; model.moodArt = nil; if let prior = priorMood { model.mood = prior } }
        tabBefore = nil
    }
    // Everything fades back to the page underneath. From here on nothing started by this screen changes the app behind.
    func leave(restoreMood: Bool = true) {
        if !toRemote { backToThrownFrom() }
        leaving = true; closing = true
        if restoreMood, let prior = priorMood { model.mood = prior }
        // The whole screen, bar included, fades as one: its item taken off alone left its glass disc behind.
        withAnimation(.easeOut(duration: 0.2)) { arrived = false; fadingOut = true }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            model.closeFlick()
        }
    }
    // The send (the pick). t = 0 at the pick: the request leaves now; the start is the model's from now, so the Remote
    // comes up with it; the Remote's tab comes up under this opaque screen; and as soon as its picture's place is known the
    // picked thing's picture moves onto it while this page dissolves. On the Remote within 0.4 s, the TV starting in the
    // meantime, never waited for.
    func send(from: CGRect?) {
        guard !flown else { return }
        FlickClock.begin()
        releasedAt = Date()
        flown = true
        FlickReceipt.thrown(receiptID)
        liftedID = nil
        answered = false; written = false
        flyFrom = flies ? from ?? rects.map["poster"] ?? CGRect(x: flickFrame.width / 2 - 60, y: flickFrame.height * 0.6, width: 120, height: 60) : .zero
        if target.image == nil, let u = screenURL ?? URL(string: item.art) {
            heldImage = ImageStore.shared.cached(u)
            softImage = softImage ?? ImageStore.shared.small(u, 16)
            if softImage == nil, let h = heldImage { Task { softImage = await ImageStore.shrunk(h, 16) } }
        }
        // Held where it is first: the tab changing under it lays the space around it out again.
        if flickFrame.width > 0 { held = flickFrame }
        // The start is the model's from the pick: the Remote lays out under this screen with its poster, its bar's place
        // and its line already there, so nothing comes in late once it's in sight.
        if !alreadyOn, video || target.image != nil || flies {
            beginStarting()
            if flies { model.standIn(startingArt) }
        }
        // The Remote's tab up under this screen now, its picture kept hidden until this one lands on it.
        if model.tab != 0 || tabBefore == nil {
            tabBefore = tabBefore ?? model.tab
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { model.remoteArrival = Date(); model.flickHandoff = true; model.tab = 0; model.keepMood(until: item.art); model.mood = tint }
        }
        phase = nil
        flight = Task { await start() }
        goRemote()
    }
    // The picture the Remote shows while the TV starts it: the episode's still or the poster; a link's own picture, else
    // YouTube's banner for a YouTube link; nothing for a bare link, which has nothing to show.
    var startingArt: String {
        if video || target.image != nil { return screenURL?.absoluteString ?? item.art }
        if let a = linkArt, !a.isEmpty { return a }
        if !item.art.isEmpty { return item.art }
        if item.kind == "youtube" { return model.url("/api/tv/icon?pkg=com.google.android.youtube.tv&v=2")?.absoluteString ?? "" }
        return ""
    }
    func beginStarting() {
        model.beginStart(.init(title: shown.title, art: startingArt, line: episode.map { "S\($0.season) E\($0.episode) · \($0.name)" }, token: stream?.token), target: again)
    }
    // Into the Remote, in one move: the picked thing's picture goes from where it was picked onto the Remote's own picture
    // of the TV, which shows the same poster, as this page fades under it. The film's colour stays, as it's the same film.
    func goRemote() {
        #if os(iOS)
        if Self.pose?.hasPrefix("flick") == true, model.starting == nil, !alreadyOn, video { HitchLog.shared.assertFailed("model.starting was nil at the hand-over") }
        #endif
        model.tick()
        leaving = true
        // The stand-in was set at the pick; the live mirror waits until the start has cleared (startPlayed), so no stale
        // launcher capture shows behind a starting film (r24).
        if model.starting == nil, !model.mirrorLive { model.setMirror(true) }
        Task {
            // The same place on two reads in a row, so the move aims at where the picture settles, not at its first layout.
            // Known already from the last visit to the Remote, the move starts at once; the loop below follows any late change.
            var slot: CGRect? = model.mirrorSlot.flatMap { $0.width > 20 ? $0 : nil }, seen: CGRect?
            // The launch's first pick, the Remote not built yet: where a pick like this one last landed on this screen,
            // so the move starts as soon as any other, and follows the real place below once the Remote gives it. Only
            // with neither (the first pick ever in this posture) is the Remote waited for.
            let size = (held ?? flickFrame).size
            let slotKey = "\(Int(size.width))x\(Int(size.height))\(video ? "v" : "")"
            var remembered = false
            if slot == nil, let m = model.rememberedSlot(slotKey) { slot = m; remembered = true }
            for _ in 0..<(slot == nil ? 40 : 0) {
                if let s = model.mirrorSlot, s.width > 20 {
                    if let p = seen, abs(p.minX - s.minX) + abs(p.minY - s.minY) + abs(p.width - s.width) < 0.5 { slot = s; break }
                    seen = s
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            if slot == nil { slot = seen }
            guard let s = slot else {
                model.flickHandoff = false; model.keepMood(until: item.art); model.mood = tint; handOverArt()
                leave(restoreMood: false); Task { await model.load() }; return
            }
            remoteSlot = s.offsetBy(dx: -flickOrigin.x, dy: -flickOrigin.y)
            // A frame, so the Remote's first layout is done before anything moves.
            try? await Task.sleep(nanoseconds: 17_000_000)
            if remembered {
                // The Remote, built in that frame, may already say where its picture really is.
                if let live = model.mirrorSlot, live.width > 20 { remoteSlot = live.offsetBy(dx: -flickOrigin.x, dy: -flickOrigin.y) }
                FlickClock.current.mark("aim-remembered")
            }
            FlickClock.current.mark("move")
            model.remoteMoveAt = Date()
            // The page dissolves over the move's first half, the Remote's keys coming up through it; the picture travels on
            // its own spring. Two animations side by side, never one inside the other (the review of e59620e).
            // The bar stays (a tap on it does nothing once flown) and goes with the whole screen, disc and glyph together.
            withAnimation(.easeOut(duration: 0.2)) { arrived = false }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { toRemote = true; moveT = 1 }
            // The Remote's picture can still settle as its page lays out, so the move keeps aiming at where it is now,
            // place and size, until the spring has run its course and the picture has stopped moving. Every change of aim
            // is animated, never a jump mid-spring.
            let start = Date()
            let deadline = start.addingTimeInterval(0.4)
            var still = 0
            var aimedAt = start
            while Date() < deadline || Date().timeIntervalSince(aimedAt) < 0.3 && Date() < deadline.addingTimeInterval(0.3) {
                try? await Task.sleep(nanoseconds: 16_000_000)
                if let s = model.mirrorSlot, s.width > 20 {
                    let next = s.offsetBy(dx: -flickOrigin.x, dy: -flickOrigin.y)
                    let moved = abs(next.minX - remoteSlot.minX) + abs(next.minY - remoteSlot.minY)
                        + abs(next.width - remoteSlot.width) + abs(next.height - remoteSlot.height) > 0.5
                    if moved {
                        still = 0; aimedAt = Date()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { remoteSlot = next }
                    } else { still += 1 }
                }
                if Date().timeIntervalSince(start) > 0.36 && still >= 3 && Date().timeIntervalSince(aimedAt) >= 0.3 { break }
            }
            // Landed on it: the Remote's own picture, its bar and its episode line come up under this screen's picture
            // over 0.15 s while this one, opaque, still sits exactly on it; then this one goes in one frame, the Remote's
            // fully under it, so nothing is drawn twice and nothing fades in sight.
            FlickClock.current.remoteLanded()
            if let live = model.mirrorSlot, live.width > 20 { model.rememberSlot(live, slotKey) }
            // The pages he picked from may show again (this screen is about to go), and the Remote stays drawn.
            var landed = Transaction(); landed.disablesAnimations = true
            withTransaction(landed) { landedOnRemote = true }
            withAnimation(.easeOut(duration: 0.15)) { model.flickHandoff = false }
            try? await Task.sleep(nanoseconds: 150_000_000)
            var swap = Transaction(); swap.disablesAnimations = true
            withTransaction(swap) { screenOut = true }
            withAnimation(.easeOut(duration: 0.2)) { fadingOut = true }
            try? await Task.sleep(nanoseconds: 220_000_000)
            // Only now, with nothing moving: the picture he last threw, which redraws the app's pages (r26).
            handOverArt()
            // Hidden now, and taken down once the Remote has settled, not in the same moment as everything else.
            model.retireFlick()
            // Only once the move is over, so its fetch and redraw can't hitch it.
            await model.load()
        }
    }

    func loadMeta() async {
        guard source == .stremio, target.send == nil, let ref = item.stremioRef else { return }
        // A show opened from anywhere but Continue watching still starts where he is in it, if Stremio's row knows.
        let home = BrowseStore.shared(.stremio)
        let homeLoad = Task { if ref.type == "series" && ref.video == nil && home.rows.isEmpty { await home.load() } }
        // A show's episodes are NextUp's, asked for as its Continue watching tile came on screen, so mostly already here.
        let found: StremioMeta?
        if ref.type == "series" { found = await NextUp.meta(ref.imdb) } else {
            let d = await TVBridge.data(TVBridge.url("/api/tv/stremio-meta?type=\(ref.type)&id=\(ref.imdb)"), timeout: 15)
            found = d.flatMap { try? JSONDecoder().decode(StremioMeta.self, from: $0) }
        }
        guard let m = found else { metaFailed = true; return }
        defer {
            // The episode the big key would play, its streams fetched now, so tapping it never waits on them (§2.5a C7).
            if ref.type == "series", let e = resumeTarget?.episode, !isOn(e) { Task { _ = await StreamCache.shared.streams(type: "series", imdb: ref.imdb, video: e.id) } }
        }
        // The episode he's on, best source first: what the TV is playing now, the card's own episode, then "S2 E3" on the card.
        let on = upNext == nil ? onEpisode(in: m, ref: ref) : nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            meta = m
            // A card that's part way through a series starts on that episode, unless one's been picked meanwhile.
            if episode == nil { episode = m.episodes.first { $0.id == ref.video } }
            if let on { upNext = on.id; upNextProgress = on.progress; warmNext() }
            season = resumeTarget?.episode.season ?? episode?.season ?? m.episodes.first?.season ?? 0
        }
        if upNext != nil || ref.type != "series" { resumeKnown = true; return }
        // Otherwise Continue watching may know, once it's in.
        await homeLoad.value
        let rowItem = home.rows.first { $0.title == "Continue watching" }?.items.first { $0.stremioRef?.imdb == ref.imdb }
        let e = rowItem.flatMap { r in m.episodes.first { $0.id == r.stremioRef?.video } ?? Self.episode(named: r.subtitle, in: m.episodes) }
        if let e, upNext == nil {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { upNextProgress = rowItem?.progress; upNext = e.id; season = resumeTarget?.episode.season ?? e.season }
            warmNext()
        }
        resumeKnown = true
    }
    // The episode he's on for this show, without asking anyone: the TV's own session, then the card.
    func onEpisode(in m: StremioMeta, ref: (type: String, imdb: String, video: String?)) -> (id: String, progress: Double?)? {
        if let s = NextUp.shared.series, s.imdb == ref.imdb, m.episodes.contains(where: { $0.id == s.current }) {
            let sess = model.status?.session
            let p = sess.flatMap { x in x.duration.flatMap { d in d > 0 ? x.position.map { $0 / d } : nil } }
            return (s.current, p)
        }
        // The TV's session names the show and episode itself, before the series lookup has caught up.
        if let sess = model.status?.session, sess.pkg == "com.stremio.one", model.videoIsCurrent, sess.isShow(item.title),
           let se = sess.seasonEpisode, let e = m.episodes.first(where: { $0.season == se.season && $0.episode == se.episode }) {
            let p = sess.duration.flatMap { d in d > 0 ? sess.position.map { $0 / d } : nil }
            return (e.id, p)
        }
        if let v = ref.video, m.episodes.contains(where: { $0.id == v }) { return (v, item.progress) }
        if let e = Self.episode(named: item.subtitle, in: m.episodes) { return (e.id, item.progress) }
        return nil
    }
    // "S2 E3", "S02E03" or "S2 · E3" in a card's line, as the episode it names.
    static func episode(named text: String, in all: [StremioEpisode]) -> StremioEpisode? {
        guard let r = try? NSRegularExpression(pattern: #"S(\d+)\s*[·.]?\s*E(\d+)"#, options: .caseInsensitive),
              let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let sr = Range(m.range(at: 1), in: text), let er = Range(m.range(at: 2), in: text),
              let se = Int(text[sr]), let ep = Int(text[er]) else { return nil }
        return all.first { $0.season == se && $0.episode == ep }
    }
    var order: (String, [String: Any]) {
        if let send = target.send { return send }
        if let stream, let ref = item.stremioRef {
            // What it is, so the Mac can fetch its running time and poster while it starts, and the next two best streams,
            // so one that won't start is replaced on the Mac without coming back to the phone (§2.5a C8).
            var body: [String: Any] = ["token": stream.token, "imdb": ref.imdb]
            if ref.type == "series", let video = episode?.id ?? ref.video { body["video"] = video }
            // Another stream of what's on carries on where he is, unless he chose Start over on this very page.
            if switching { body["switch"] = true; if startOverChoice == true { body["restart"] = true } else if let at = livePosition, at > 30_000 { body["resumeMs"] = at.rounded() } }
            else if hasResume && startOver { body["restart"] = true }
            // Where he was in it, as a share of its length, so the Mac can make sure it opens there and not at 0:00 (r24:
            // "85 min left" opened at 0:08). Not for a start over.
            else {
                // From the card, else from Stremio's own Continue watching, so a pick from search, Recently flicked or a
                // rec carries on where he was too.
                if let p = savedProgress, p > 0.01, p < 0.97 { body["resume"] = (p * 1000).rounded() / 1000 }
            }
            // What stands in if this one won't start is the nearest thing to what he chose: the same quality, within the
            // filter he has on, never one that failed or a dub he didn't pick. A 1080p pick is never swapped for a 4K file.
            let spare = streams.filter { $0.token != stream.token && !failedTokens.contains($0.token) && $0.quality == stream.quality && $0.stalled != true
                && (stream.dubbed == true || $0.dubbed != true) }.prefix(2).map(\.token)
            if !spare.isEmpty { body["fallbacks"] = Array(spare) }
            return ("play-stream", body)
        }
        if let stream { return ("play-stream", ["token": stream.token]) }
        if source == .mint { return ("mint-open", ["link": item.id, "title": item.title, "subtitle": item.subtitle, "art": item.art, "kind": item.kind, "play": true]) }
        if let ref = item.stremioRef {
            if let e = episode { return ("stremio-open", ["id": "stremio:///detail/series/\(ref.imdb)/" + e.id.replacingOccurrences(of: ":", with: "%3A")]) }
            return ("stremio-open", item.id.hasPrefix("stremio:") ? ["id": item.id] : ["type": ref.type, "id": ref.imdb])
        }
        return ("film", ["slug": item.slug ?? ""])
    }
    // What's being started, for "Choose another" from the Remote: this title, at this episode.
    var again: FlickTarget {
        var item = self.item
        if let ref = item.stremioRef, ref.type == "series", let v = episode?.id ?? ref.video {
            item = MediaItem(title: item.title, subtitle: item.subtitle, art: item.art, id: "stremio:///detail/series/\(ref.imdb)/" + (v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v), kind: item.kind)
        }
        var t = FlickTarget(item: item, source: source, image: target.image, send: target.send, lands: target.lands)
        t.lineage = target.lineage
        return t
    }
    // The request, from the pick to the answer. It runs on after the flick screen has closed: the start is the model's,
    // and the Remote shows how it goes.
    func start() async {
        // What's already on the TV is never sent again; if it's paused there, it's asked to play, nothing else
        // (Richard, 2026-11-05: "the episode restarted i think because of the app").
        if alreadyOn {
            if model.status?.session?.playing == false { model.key("resume") }
            FlickClock.current.mark("already-on"); FlickClock.current.finished()
            answered = true
            return
        }
        let early = order.0 == "play-stream"
        if model.starting != nil { model.starting?.token = stream?.token }
        FlickClock.current.mark("request")
        written = true
        var resent = false
        // How many times the line to the Mac dropped under this send, and whether the Mac had begun to answer by then.
        var dropped = 0
        let heard = HeardBox()
        while true {
            // Made afresh each time round: after a list fetched again, the pick has a new token.
            var order = order
            // The TV's own card of this flick comes in as the send lands there (never for one asked about `again`).
            order.1["receipt"] = FlickReceipt.thrown(receipt, velocity: throwV)
            // The line dropped after the Mac had the send (the app put away, the tailnet blinking): asked how it went,
            // which joins that start or hears its answer again. Nothing is started twice.
            if dropped > 0, heard.yes { order.1["again"] = true }
            do {
                let answer: Data
                if early {
                    answer = try await TVBridge.playStream(order.1, opened: { _ in
                        answered = true; heard.yes = true; FlickClock.current.mark("first-byte")
                    }, phase: { p in took(p) })
                } else {
                    answer = try await TVBridge.post(order.0, order.1, timeout: 60)
                    answered = true
                }
                // The Mac found it already on, or joined a start of the same thing already under way: a success like any
                // other, with nothing more to do (real-TV test, 2026-11-05).
                if let j = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] {
                    if j["alreadyOn"] as? Bool == true { FlickClock.current.mark("already-on") }
                    if j["joined"] as? Bool == true { FlickClock.current.mark("joined") }
                    // A link the TV can't open: said, since then there's something else to do (AirPlay).
                    if order.0 == "send", let kind = j["kind"] as? String, !["apple", "words", "youtube", "film", "imdb"].contains(kind) {
                        model.say("That link can’t open on the TV. Try AirPlay."); if ownsStart { model.clearStart() }
                        FlickClock.current.mark("failed"); FlickClock.current.finished(); return
                    }
                }
                // The stream that really played (a fallback, when his pick wouldn't start) is the one this page holds from
                // here on, and the one remembered as what's on.
                if early, let j = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] {
                    if let t = j["token"] as? String, t != stream?.token, let played = streams.first(where: { $0.token == t }) { stream = played }
                    if let s = stream { PlayedStream.set(playedKey, s.description) }
                }
                target.sent?()
                remember()
                flicksDone += 1
                // An answer with no "playing" line (an old Mac, or a send that isn't a stream) is the yes.
                if ownsStart || model.startingTarget == nil { model.startPlayed() }
                FlickClock.current.mark("answer"); FlickClock.current.finished()
                return
            } catch {
                if Task.isCancelled || cancelled { return }
                // Called off on the TV's side (his own Home or another app, a newer send): not a failure, nothing to say.
                if error is CancellationError { if ownsStart { model.clearStart() }; FlickClock.current.mark("called-off"); FlickClock.current.finished(); return }
                // Gone: the list is fetched afresh and the same file (or the next best) sent once more, silently.
                if error is TVBridge.Gone, !resent, early, let ref = item.stremioRef {
                    resent = true
                    let was = stream
                    StreamCache.shared.forget(type: ref.type, imdb: ref.imdb, video: episode?.id ?? ref.video ?? ref.imdb)
                    await findStreams(again: true)
                    stream = streams.first { $0.description == was?.description && !failedTokens.contains($0.token) } ?? streams.first { !failedTokens.contains($0.token) }
                    if stream != nil { continue }
                }
                // The line itself dropped, not the start: the TV may well be playing it (2026-11-10: the Remote said
                // "didn't start" over an episode that was on). Twice more, a moment apart, before that's believed.
                if early, error is URLError, dropped < 2 {
                    dropped += 1
                    FlickClock.current.mark("line-lost")
                    try? await Task.sleep(nanoseconds: UInt64(dropped) * 700_000_000)
                    if Task.isCancelled || cancelled { return }
                    continue
                }
                FlickClock.current.mark("failed"); FlickClock.current.finished()
                // Out of reach from here on: every stream whose player came up and never played, his pick or a fallback, so
                // "Choose another" doesn't offer what stalled a moment ago. One that never got a player at all isn't
                // among them: that says nothing about the stream, and it stays his to pick. A Mac that doesn't say
                // which (an older one), or a failure of another kind: his pick, as before.
                if error is TVBridge.DidNotStart, let stalled = TriedStreams.last { failedTokens.formUnion(stalled) }
                else if let s = stream { failedTokens.insert(s.token) }
                TriedStreams.last = nil
                // On the Remote: the poster dims, with one way on (Choose another). A plain send that failed is said once.
                if ownsStart { if video { model.startFailed(tokens: Array(failedTokens)) } else { model.clearStart(); model.say("The TV didn’t get that") } }
                else if !video { model.say("The TV didn’t get that") }
                return
            }
        }
    }
    // A step of the start, as the Mac reports it: the model's, so the Remote follows it after this screen has closed. Only
    // while the start is still this flick's: a second flick (the next episode, one picked from the list) begins its own,
    // and the first's request runs on in the background (2026-11-08, "the remote is still fucked").
    var ownsStart: Bool { model.startingTarget?.lineage == target.lineage }
    func took(_ p: String) {
        FlickClock.current.mark("phase-" + p)
        phase = p
        guard ownsStart else { return }
        model.startPhase(p)
        if p == "playing" {
            FlickClock.current.mark("playing")
            playedAt = Date()
            model.startPlayed()
        }
    }
    // The very thing picked is what the TV is playing now: the same show and episode, or the same film, and not asked to
    // start over.
    var alreadyOn: Bool {
        guard source == .stremio, target.send == nil, let ref = item.stremioRef, model.videoIsCurrent,
              let s = model.status?.session, s.pkg == "com.stremio.one", !(nearEnd && startOver && stream != nil), !switching else { return false }
        if ref.type == "series" {
            guard let v = episode?.id ?? ref.video else { return false }
            return model.isOn(imdb: ref.imdb, title: item.title, episode: v)
        }
        return model.isOn(imdb: ref.imdb, title: item.title, episode: nil) && isThisFilm(s)
    }
    // This title (at this episode) is what the TV has on, whichever stream of it: for marking the row that's playing.
    var alreadyOnTitle: Bool {
        guard source == .stremio, target.send == nil, let ref = item.stremioRef, model.videoIsCurrent, let s = model.status?.session, s.pkg == "com.stremio.one" else { return false }
        if ref.type == "series" { guard let v = episode?.id ?? ref.video else { return false }; return model.isOn(imdb: ref.imdb, title: item.title, episode: v) }
        return model.isOn(imdb: ref.imdb, title: item.title, episode: nil) && isThisFilm(s)
    }
    var playedKey: String { (item.stremioRef?.imdb ?? "") + "/" + (episode?.id ?? item.stremioRef?.video ?? "") }
    // Which file of this title is on the TV: what this phone last started, else what the Mac says it started (so the row
    // says Playing after the app has been opened afresh, and another row is still known to be another stream).
    var fileOnTV: String? {
        if let f = PlayedStream.file(playedKey) { return f }
        guard let s = model.status?.session, let f = s.streamFile, !f.isEmpty, let ref = item.stremioRef else { return nil }
        let of = ref.type == "series" ? (episode?.id ?? ref.video) : ref.imdb
        return s.streamOf == of ? f : nil
    }
    // Where the TV is in what's on, in ms, carried on from its last reading while it plays.
    var livePosition: Double? {
        guard let s = model.status?.session, let p = s.position else { return nil }
        let since = s.playing ? (s.sampledAt.map { max(0, Date().timeIntervalSince1970 * 1000 - $0) } ?? 0) : 0
        return p + since
    }
    // Whether a Stremio player is the film just sent, by its title.
    func isThisFilm(_ p: TVStatus.Session) -> Bool {
        guard let now = p.description.first, !now.isEmpty else { return false }
        return TVStatus.Session.sameName(now, item.title)
    }
    // The picture he last threw, for the app's pages: set once the move is over (goRemote), never during it.
    func handOverArt() {
        if !item.art.isEmpty { model.lastArt = item.art; model.lastArtTitle = item.title; model.lastArtPkg = source == .mint ? "com.codex.musicwebtv" : "com.stremio.one" }
    }
    func remember() {
        let video = source == .stremio && target.send == nil
        // Kept on the phone for the Watch tab's Recently flicked, and for knowing the next episode.
        if video, let ref = item.stremioRef {
            RecentFlicks.shared.add(RecentFlick(title: item.title, art: item.art, imdb: ref.imdb, type: ref.type, video: ref.type == "series" ? episode?.id ?? ref.video : nil,
                                                episode: episode.map { "S\($0.season) E\($0.episode)" }, at: Date()))
            NextUp.shared.forget()
        }
    }
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
// Where the rows and the card sit, kept without redrawing anything while the list scrolls.
final class RectBox { var map: [String: CGRect] = [:] }

// Where the finger has the lifted row (or the card), and its lean. Observed, and read only in LiftedLook's own body and
// only by the one that's up, so a finger moving redraws that one row and nothing else on the page.
@Observable final class LiftBox {
    var drag = CGSize.zero
    var lean = 0.0
    // Past the line: let go now and it goes to the TV.
    var armed = false
}
// The hand on the row or the card, and when its clock started.
final class HandBox {
    var hand = FlickHand(.list)
    var id: String?
    var base = Date()
}
// A row or the card in the hand: its shadow, the light round its edge as it rises, its swell, its lean and its place
// under the finger. At rest it reads nothing from the box.
struct LiftedLook: ViewModifier {
    let lift: LiftBox
    let up: Bool
    let scale: CGFloat
    // How much more it grows on its way up, and its corner, for the lit edge.
    let swell: CGFloat, corner: CGFloat
    // The shadow at rest and lifted: opacity, radius, drop.
    let rest: (Double, CGFloat, CGFloat), raised: (Double, CGFloat, CGFloat)
    // A row's own ground is see-through; in the hand it's on a solid one, so the page under it never reads through.
    var solid = false
    func body(content: Content) -> some View {
        let drag = up ? lift.drag : .zero
        let rise = max(0, -drag.height)
        let shade = up ? raised : rest
        content
            .background { if solid && up { RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color(white: 0.14)) } }
            .shadow(color: .black.opacity(shade.0), radius: shade.1, y: shade.2)
            // Lit as it rises, and all the way round once letting go would send it, so the line is seen as well as felt.
            .overlay { RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(TVLook.accent.opacity(up ? (lift.armed ? 1 : 0.45 * min(1, rise / 80)) : 0), lineWidth: up && lift.armed ? 2 : 1.5) }
            .scaleEffect(up ? scale + swell * min(1, rise / 260) : 1)
            .rotationEffect(.degrees(up ? lift.lean : 0))
            .offset(drag)
    }
}

// The picked thing's picture on its way into the Remote's picture of the TV, from one number: 0 at the row (or card) it
// was picked from, 1 on the Remote. The poster fills the row's shape at the start and opens into the Remote's own look
// (the poster framed on its soft ground, 14 pt in, with the light round the edge), so what lands is exactly what the
// Remote draws next. A wide picture (a video's still) fills the Remote's picture, as it does there. Interpolated here so
// the move is this view's whatever transaction the state changed in; the target rect is animatable too, so a late re-aim
// eases rather than steps.
private struct FlyingPicture: View, Animatable {
    var t: CGFloat
    let from: CGRect
    var to: CGRect
    let image: Image?
    let url: URL?
    let soft: TVImage?
    let wide: Bool
    let tint: Color?
    var animatableData: AnimatablePair<CGFloat, CGRect.AnimatableData> {
        get { AnimatablePair(t, to.animatableData) }
        set { t = newValue.first; to.animatableData = newValue.second }
    }
    var body: some View {
        let p = min(max(t, 0), 1)
        let box = between(from, to, p)
        // The framed poster's place on the Remote: its height less 14 pt each side, 2:3 wide, centred.
        let innerEnd: CGRect = {
            if wide { return to }
            let h = max(0, to.height - 28), w = (h * 2 / 3).rounded()
            return CGRect(x: to.midX - w / 2, y: to.minY + 14, width: w, height: h)
        }()
        let inner = between(from, innerEnd, p)
        let groundRadius = lerp(14, TVLook.card, p)
        ZStack(alignment: .topLeading) {
            // The Remote's ground under the poster: black, the picture at 16 px over it at 0.7, coming in with the move.
            ZStack {
                Color.black
                if let soft { Color.clear.overlay { Image(tv: soft).resizable().interpolation(.high).scaledToFill() }.clipped().opacity(0.7) }
                else { (tint ?? Color(white: 0.15)).opacity(0.7) }
            }
            .frame(width: max(0, box.width), height: max(0, box.height))
            .clipShape(RoundedRectangle(cornerRadius: groundRadius, style: .continuous))
            .overlay { LoadingRing(radius: groundRadius).opacity(Double(p)) }
            .opacity(Double(p))
            .offset(x: box.minX, y: box.minY)
            // The picture itself, filling its shape all the way.
            Group {
                if let image { image.resizable().scaledToFill() }
                else { Art(url: url) { $0.resizable().scaledToFill() } placeholder: { (tint ?? Color(white: 0.15)) } }
            }
            .frame(width: max(0, inner.width), height: max(0, inner.height))
            .clipShape(RoundedRectangle(cornerRadius: wide ? groundRadius : lerp(14, 8, p), style: .continuous))
            .shadow(color: .black.opacity(wide ? 0 : 0.5 * Double(p)), radius: 14, y: 6)
            .offset(x: inner.minX, y: inner.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Laid out at each frame's own values, at once: the move's spring is this view's.
        .transaction { $0.animation = nil }
        // Nothing until its place is known, so it never starts from a corner.
        .opacity(from == .zero || to == .zero ? 0 : 1)
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
                    Button { model.tick(); withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { selected = value } } label: {
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
        .phaseAnimator([0.45, 1.0]) { c, o in c.opacity(o) } animation: { _ in .easeInOut(duration: 0.9).delay(delay) }
        .accessibilityHidden(true)
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

// The build's own record of what the hand made of a real finger (the films' touches), next to what was sent. Never on
// his phone: only under a pose.
@MainActor enum HandTrace {
    static let on = UserDefaults.standard.string(forKey: "pose") != nil
    static func note(_ what: String) {
        guard on else { return }
        let e: [String: Any] = ["name": "hand-" + what, "at": Date().timeIntervalSince1970 * 1000]
        Task { _ = try? await TVBridge.post("timing", ["events": [e]], timeout: 5) }
    }
}
// MARK: - The flick from where a thing lives
// Every card that can go to the TV (a shelf's, a search result, Continue watching, Watch's films, Mint's albums) is
// flicked the way a stream row is: held, it lifts off its shelf; thrown up, it goes; let go where it was, it's a tap
// (its page); anywhere else, it goes back. The same FlickHand reads it. A tap still opens its page. The card in the hand
// is drawn over everything (ShelfLiftOverlay), as a shelf clips whatever leaves it.
@MainActor @Observable final class ShelfHand {
    static let shared = ShelfHand()
    var item: MediaItem?
    var source = MediaSource.stremio
    var width: CGFloat = 0
    var rect = CGRect.zero
    var drag = CGSize.zero
    var lean = 0.0
    var armed = false
    // A tap iOS reports with the release of a held card is that release, not a second action.
    @ObservationIgnored var handledAt = Date.distantPast
}
// The card in the hand, over the whole window, where the finger has it.
struct ShelfLiftOverlay: View {
    @State private var hand = ShelfHand.shared
    var body: some View {
        GeometryReader { g in
            if let item = hand.item {
                let o = g.frame(in: .global).origin
                let rise = max(0, -hand.drag.height)
                MediaCard(item: item, source: hand.source, width: hand.width)
                    .shadow(color: .black.opacity(0.55), radius: 26, y: 18)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(TVLook.accent.opacity(hand.armed ? 1 : 0.45 * min(1, rise / 80)), lineWidth: hand.armed ? 2 : 1.5)
                            .frame(width: hand.width, height: hand.rect.height > 0 ? min(hand.rect.height, hand.width * 1.5) : hand.width * 1.5)
                    }
                    .scaleEffect(1.06 + 0.06 * min(1, rise / 240), anchor: .center)
                    .rotationEffect(.degrees(hand.lean))
                    .position(x: hand.rect.midX - o.x + hand.drag.width, y: hand.rect.midY - o.y + hand.drag.height)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
// The scroll views a held card sits in hold still while it's in the hand, as the streams page's list does.
#if canImport(UIKit)
final class ScrollLockBox { weak var view: UIView?; var locked: [UIScrollView] = [] }
struct ScrollLock: UIViewRepresentable {
    let box: ScrollLockBox
    func makeUIView(context: Context) -> UIView { let v = UIView(); v.isUserInteractionEnabled = false; box.view = v; return v }
    func updateUIView(_ uiView: UIView, context: Context) { box.view = uiView }
    @MainActor static func set(_ box: ScrollLockBox, _ on: Bool) {
        if on {
            var v = box.view?.superview
            while let s = v { if let sv = s as? UIScrollView, sv.panGestureRecognizer.isEnabled { sv.panGestureRecognizer.isEnabled = false; box.locked.append(sv) }; v = s.superview }
        } else { box.locked.forEach { $0.panGestureRecognizer.isEnabled = true }; box.locked = [] }
    }
}
#else
final class ScrollLockBox {}
struct ScrollLock: View {
    let box: ScrollLockBox
    var body: some View { Color.clear }
    @MainActor static func set(_ box: ScrollLockBox, _ on: Bool) {}
}
#endif
struct ShelfFlick: ViewModifier {
    @Environment(TVModel.self) var model
    let item: MediaItem
    let source: MediaSource
    let width: CGFloat
    // Where the card is, as its button measures it.
    let rect: () -> CGRect
    @State private var hands = HandBox()
    @State private var lock = ScrollLockBox()
    @State private var up = false
    @State private var receipt = ""
    @GestureState private var touching = false
    func body(content: Content) -> some View {
        content
            .opacity(up ? 0 : 1)
            .background(ScrollLock(box: lock).allowsHitTesting(false))
            .simultaneousGesture(gesture)
            .onChange(of: touching) { _, t in
                guard !t else { return }
                Task { @MainActor in if up { _ = hands.hand.cancel(); end(.cancelled, translation: .zero) } }
            }
            .accessibilityAction(named: "Flick to the TV") { hands.hand = FlickHand(.list); throwIt(velocity: CGSize(width: 0, height: -800), translation: .zero) }
    }
    var gesture: some Gesture {
        let rules = FlickHand.Rules.list
        return LongPressGesture(minimumDuration: rules.hold, maximumDistance: rules.slop)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($touching) { _, s, _ in s = true }
            .onChanged { v in
                guard case .second(true, let d) = v, model.flicking == nil || model.flickRetired else { return }
                if !up {
                    hands.base = Date().addingTimeInterval(-rules.hold); hands.hand = FlickHand(rules)
                    _ = hands.hand.down(.zero, at: 0)
                    _ = hands.hand.held(at: rules.hold)
                    lifted()
                }
                guard let d else { return }
                for e in hands.hand.move(CGPoint(x: d.translation.width, y: d.translation.height), at: d.time.timeIntervalSince(hands.base)) {
                    if case .armed(let on) = e { ShelfHand.shared.armed = on; if on { FlickHaptic.detent() } }
                }
                ShelfHand.shared.drag = d.translation
                ShelfHand.shared.lean = max(-6, min(6, Double(d.velocity.width) / 200 + Double(d.translation.width) / 60))
            }
            .onEnded { v in
                guard up else { return }
                var d: DragGesture.Value?
                if case .second(true, let dv) = v { d = dv }
                let t = d.map { $0.time.timeIntervalSince(hands.base) } ?? Date().timeIntervalSince(hands.base)
                let at = d.map { CGPoint(x: $0.translation.width, y: $0.translation.height) } ?? .zero
                end(hands.hand.up(at, at: t), translation: d?.translation ?? .zero)
            }
    }
    // In the hand: felt, drawn over everything, the shelf held still, and the TV told what's coming.
    func lifted() {
        HandTrace.note("shelf-lifted")
        up = true
        FlickHaptic.lift(); FlickClock.touched()
        ScrollLock.set(lock, true)
        let h = ShelfHand.shared
        h.item = item; h.source = source; h.width = width; h.rect = rect(); h.drag = .zero; h.lean = 0; h.armed = false
        if source == .stremio, !item.isYouTube { StreamCache.shared.prefetch(item) }
        guard !model.isOnTV(item, source) else { receipt = ""; return }
        receipt = UUID().uuidString
        FlickReceipt.lift(Self.receipt(item, source, id: receipt), lands: source == .mint ? "mint" : nil)
    }
    // What the TV's receiving screen shows for this card.
    static func receipt(_ item: MediaItem, _ source: MediaSource, id: String) -> [String: Any] {
        let kind: String
        if item.isYouTube { kind = "video" }
        else if source == .mint { kind = "song" }
        else if item.stremioRef?.type == "series" { kind = "episode" }
        else { kind = "film" }
        return FlickReceipt.body(id: id, title: item.title, line: item.shownSubtitle, art: item.art, kind: kind,
                                 shape: kind == "song" ? "square" : kind == "video" ? "wide" : "poster")
    }
    func end(_ outcome: FlickHand.Outcome, translation: CGSize) {
        HandTrace.note(String(format: "shelf-end %@ dy=%.0f", "\(outcome)", translation.height))
        ShelfHand.shared.handledAt = Date()
        ScrollLock.set(lock, false)
        switch outcome {
        case .thrown:
            let v = hands.hand.velocity
            throwIt(velocity: CGSize(width: v.dx, height: v.dy), translation: translation)
        case .longTap:
            // Held and let go where it was: a tap, its page, as on any button.
            put(back: false)
            if !receipt.isEmpty { FlickReceipt.cancel(receipt) }
            FlickCardButton.tap(model, item, source, origin: rect())
        default:
            FlickHaptic.settle()
            if !receipt.isEmpty { FlickReceipt.cancel(receipt) }
            put(back: true)
        }
    }
    func put(back: Bool) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.75)) { ShelfHand.shared.drag = .zero; ShelfHand.shared.lean = 0; ShelfHand.shared.armed = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: back ? 300_000_000 : 0)
            ShelfHand.shared.item = nil; up = false
        }
    }
    func throwIt(velocity: CGSize, translation: CGSize) {
        FlickHaptic.caught()
        let from = rect().offsetBy(dx: translation.width, dy: translation.height)
        // What's on already: the Remote, nothing sent (as a tap on it does).
        if model.isOnTV(item, source) { ShelfHand.shared.item = nil; up = false; model.showOnRemote(); return }
        var t: FlickTarget
        if item.isYouTube {
            let at = item.resume ?? 0
            let link = "https://www.youtube.com/watch?v=\(item.id)" + (at >= 30 ? "&t=\(at)" : "")
            t = FlickTarget(item: item, source: source, send: ("send", ["text": link]), lands: "com.google.android.youtube.tv", origin: from)
        } else { t = FlickTarget(item: item, source: source, origin: from) }
        t.thrown = velocity
        t.receiptID = receipt.isEmpty ? nil : receipt
        model.flick(t)
        // The flick screen's own picture takes over from here, from where it was let go.
        Task { @MainActor in try? await Task.sleep(nanoseconds: 60_000_000); ShelfHand.shared.item = nil; up = false }
    }
}
