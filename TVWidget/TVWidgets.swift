import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

struct TVEntry: TimelineEntry {
    var date = Date()
    var status: TVStatus?
    var cover: TVImage?
    var wall: TVImage?
    var mirror: TVImage?
    var logos: [String: TVImage] = [:]
    var chosen: [TVAppEntity] = []
    var reachable = true    // false when `status` is the last one known
    // When `status` was read, if it's the last one known rather than this moment's.
    var readAt: Date?
    // The banner of the app in front, for the resting Playing widget.
    var front: TVImage?
    var liveStatus: Bool { status != nil && reachable }
    var asleep: Bool { status?.screen == "asleep" }
    // What's on, by the same rules as the Now Playing card: Mint's song, the film, show or video in Stremio or YouTube, or
    // the music AirPlayed to Mint. A play or pause just pressed wins over a reading from before it took. The last known is
    // shown only until it would have ended (ten minutes when it can't be timed); after that, nothing is claimed.
    var now: TVNowItem? {
        guard let s = status, var n = TVNowItem(s) else { return nil }
        if let w = TVPlayWanted.read(), w.until > date { n.hold(playing: w.playing, at: date) }
        if n.playing, let end = n.end, end < date { return nil }
        if !reachable, !n.playing || n.end == nil, (readAt ?? date).addingTimeInterval(600) < date { return nil }
        return n
    }
    var fraction: Double { now?.fraction(at: date) ?? 0 }
    var remaining: TimeInterval { now?.end.map { max(0, $0.timeIntervalSince(date)) } ?? 0 }
    // The app in front, by name ("Home" for the launcher).
    var frontName: String? {
        guard let s = status, let pkg = s.app else { return nil }
        return s.apps?.first { $0.pkg == pkg }?.name ?? (pkg.contains("launcher") ? "Home" : nil)
    }
    // The name over the line: what's playing; resting, the TV asleep or the app in front.
    var title: String {
        if let n = now { return n.title }
        if status == nil { return "TV" }
        if asleep { return "TV asleep" }
        return frontName ?? "Home"
    }
    // The line under the name: the artist, the episode or the channel; resting, nothing more unless it's waiting.
    var caption: String {
        if let n = now { return n.subtitle }
        if status == nil { return reachable ? "" : "Waiting for the TV" }
        // Just ended (the reading still says it plays): claim nothing until the next reading says what's on.
        if let s = status, TVNowItem(s) != nil { return "" }
        return asleep || !liveStatus ? "" : "Nothing playing"
    }
    // Said small, in place of the progress line, when what's shown is the last known rather than live.
    var lastSeen: String? {
        guard !reachable, status != nil else { return nil }
        return "Last seen " + tvWidgetTime(readAt ?? date)
    }
}
// "3:42 PM" today, "Tue 3:42 PM" before: the one way every widget says when it last heard.
func tvWidgetTime(_ d: Date) -> String {
    Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}
// Play or pause just pressed on the widget, held for six seconds against readings from before the TV took it, as the
// Now Playing card does (a reading three seconds on still said playing, and the glyph flipped back under his thumb).
enum TVPlayWanted {
    static func read() -> (playing: Bool, until: Date)? {
        let d = UserDefaults.standard
        guard let until = d.object(forKey: "tvWantedUntil") as? Date else { return nil }
        return (d.bool(forKey: "tvWantedPlaying"), until)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: "tvWantedUntil") }
    static func set(_ playing: Bool) {
        UserDefaults.standard.set(playing, forKey: "tvWantedPlaying")
        UserDefaults.standard.set(Date().addingTimeInterval(6), forKey: "tvWantedUntil")
    }
}
// What's playing, as the Now Playing card says it (TVIsland.state): its name, the line under it, which player, and
// where it is in it.
struct TVNowItem {
    var title: String, subtitle: String, app: String, playing: Bool
    var progress: Double?, start: Date?, end: Date?
    // How long it runs, kept while paused (start and end are only set while it plays).
    var duration: TimeInterval?
    var timed: Bool { start != nil || progress != nil }
    // Sent from this phone: iOS already has its controls for it, so the widget shows it without its own keys.
    var airplay: Bool { app == "AirPlay" }
    func fraction(at d: Date) -> Double {
        if playing, let a = start, let b = end, b > a { return min(max(d.timeIntervalSince(a) / b.timeIntervalSince(a), 0), 1) }
        return min(max(progress ?? 0, 0), 1)
    }
    var length: TimeInterval? {
        if let a = start, let b = end { return b.timeIntervalSince(a) }
        return duration
    }
    // Held paused or playing from a press: the bar stops where it is, or runs on from there.
    mutating func hold(playing p: Bool, at d: Date) {
        guard p != playing else { return }
        let len = length
        let at = fraction(at: d)
        playing = p; progress = at
        if p, let len { start = d.addingTimeInterval(-at * len); end = start!.addingTimeInterval(len) } else if !p { start = nil; end = nil }
    }
    init?(_ s: TVStatus) {
        // Music AirPlayed from this phone to Mint, his most common case: the island leaves it to iOS, the widget names it.
        if let a = s.airplay, a.active, a.kind == nil || a.kind == "music", let t = a.title, !t.isEmpty {
            self.init(title: t, subtitle: a.artist ?? "", app: "AirPlay", playing: a.playing ?? true)
            return
        }
        #if os(iOS)
        guard let st = TVIsland.state(s) else { return nil }
        self.init(title: st.title, subtitle: st.subtitle, app: st.app, playing: st.playing, progress: st.progress, start: st.start, end: st.end)
        duration = st.length
        #else
        guard let m = s.music else { return nil }
        self.init(title: m.title, subtitle: m.artist, app: "Mint", playing: m.playing)
        #endif
    }
    init(title: String, subtitle: String, app: String, playing: Bool, progress: Double? = nil, start: Date? = nil, end: Date? = nil) {
        self.title = title; self.subtitle = subtitle; self.app = app; self.playing = playing; self.progress = progress; self.start = start; self.end = end
    }
}

struct TVProvider: TimelineProvider {
    var art = false
    var mirror = false
    var needsStatus = true  // the plain remote shows nothing live, so it never fetches
    func placeholder(in context: Context) -> TVEntry { Self.sample }
    func getSnapshot(in context: Context, completion: @escaping (TVEntry) -> Void) {
        if context.isPreview { completion(Self.sample); return }
        Task { completion(await load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TVEntry>) -> Void) {
        Task {
            guard needsStatus else { completion(Timeline(entries: [TVEntry()], policy: .never)); return }
            let e = await load()
            // The progress line moves on its own between reloads, which iOS only allows now and then.
            var entries = [e]
            if art, e.now?.playing == true {
                let steps = Int(min(e.remaining, 600) / 30)
                if steps > 0 { for i in 1...steps { var n = e; n.date = e.date.addingTimeInterval(Double(i) * 30); entries.append(n) } }
                // And the moment it ends, so a finished song or film doesn't sit there with a full bar.
                if e.remaining < 600 { var n = e; n.date = e.date.addingTimeInterval(e.remaining + 1); entries.append(n) }
            }
            // Read again just after it ends (the next song or episode has usually started), else in ten minutes.
            let next: TimeInterval = e.now?.playing == true ? (art && e.remaining < 600 && e.now?.end != nil ? e.remaining + 2 : 600) : 1800
            completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(next))))
        }
    }
    // The reload after a press reads what the press left (WidgetFresh) and asks the network for nothing; a timed reload
    // asks, with short waits, and keeps the last status rather than wiping it when the Mac can't be reached.
    func load() async -> TVEntry {
        var e = TVEntry()
        let cache = WidgetFresh.statusFile
        if let d = WidgetFresh.fresh(cache), let s = try? JSONDecoder().decode(TVStatus.self, from: d), s.online {
            e.status = s
        } else if let d = await TVBridge.data(TVBridge.url("/api/tv/status"), timeout: 5), let s = try? JSONDecoder().decode(TVStatus.self, from: d), s.online {
            e.status = s
            try? d.write(to: cache, options: .atomic)
        } else {
            e.reachable = false
            if let d = try? Data(contentsOf: cache) {
                e.status = try? JSONDecoder().decode(TVStatus.self, from: d)
                e.readAt = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        }
        // The cover is the same picture for the whole song or film, so it comes from the cache after the first time.
        if art, e.now != nil, let url = Self.coverAddress(e.status), let d = await TVBridge.data(URL(string: url), timeout: 6, cached: true), let i = Self.thumbnail(d, 320) { e.cover = i; e.wall = Self.shrunk(i, to: 16) }
        // Resting with the TV on: the banner of the app in front stands where the cover would.
        // Also while something plays, for the moment it ends; from disk only while the Mac isn't answering.
        if art, !e.asleep, let pkg = e.status?.app { e.front = await Self.logo(pkg, fetch: e.reachable) }
        // Not answering: the last picture, shown dimmed with when it was.
        if mirror, !e.reachable, let d = try? Data(contentsOf: WidgetFresh.shotFile) { e.mirror = Self.thumbnail(d, 640) }
        if mirror, e.reachable, !e.asleep {
            // Never decoded at the Mac's full size: widgets get very little memory.
            if let d = WidgetFresh.fresh(WidgetFresh.shotFile), let i = Self.thumbnail(d, 640) { e.mirror = i }
            else if let d = await TVBridge.data(TVBridge.url("/api/tv/shot"), timeout: 6), let i = Self.thumbnail(d, 640) {
                e.mirror = i
                // So the next press knows to fetch a picture of its own.
                try? d.write(to: WidgetFresh.shotFile, options: .atomic)
            }
        }
        return e
    }
    // The poster of the film or show, else the song's album; never an app's icon.
    static func coverAddress(_ s: TVStatus?) -> String? {
        guard let s else { return nil }
        let a = s.session.flatMap { $0.pkg == "com.codex.musicwebtv" ? nil : $0.art } ?? s.music?.art
        guard let a, !a.isEmpty, !a.contains("/api/tv/icon") else { return nil }
        return a.hasPrefix("/") ? TVBridge.url(a)?.absoluteString : a
    }
    // An app's banner, from disk once it's been fetched: a launch button never needs the Mac to draw (it left six blank
    // tiles for a quarter of an hour whenever the Mac didn't answer). `fetch` false reads the disk only.
    static func logo(_ pkg: String, fetch: Bool = true) async -> TVImage? {
        let file = WidgetFresh.dir.appendingPathComponent("widget-logo-\(pkg).png")
        if let d = try? Data(contentsOf: file) { return thumbnail(d, 320).flatMap { flatPicture($0) ? nil : $0 } }
        guard fetch, let d = await TVBridge.data(TVBridge.url("/api/tv/icon?pkg=\(pkg)&v=2"), timeout: 6, cached: true), let i = thumbnail(d, 320) else { return nil }
        try? d.write(to: file, options: .atomic)
        return flatPicture(i) ? nil : i
    }
    static let favourites = ["com.codex.musicwebtv", "com.mint.letterboxd", "com.stremio.one", "com.google.android.youtube.tv", "com.netflix.ninja", "com.apple.atve.androidtv.appletv"]
    // Widgets get very little memory, so a picture is never decoded at full size.
    static func thumbnail(_ d: Data, _ side: Int) -> TVImage? {
        #if canImport(UIKit)
        guard let source = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
        #else
        return TVImage(data: d)
        #endif
    }
    static func shrunk(_ i: TVImage, to side: CGFloat) -> TVImage {
        #if canImport(UIKit)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { _ in i.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
        #else
        return i
        #endif
    }
    static var sampleImage: TVImage? {
        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { c in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor(red: 0.75, green: 0.16, blue: 0.47, alpha: 1).cgColor, UIColor(red: 0.12, green: 0.35, blue: 0.78, alpha: 1).cgColor] as CFArray, locations: nil)!
            c.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 120, y: 120), options: [])
        }
        #else
        return nil
        #endif
    }
    static var sample: TVEntry {
        var e = TVEntry()
        e.status = TVStatus(online: true, screen: "on", app: "com.codex.musicwebtv", volume: 12, volumeMax: 25,
                            music: .init(title: "Sample Song", artist: "Sample Artist", album: "Sample Album", art: "", playing: true, position: 60000, duration: 144000, sampledAt: Date().timeIntervalSince1970 * 1000), session: nil,
                            apps: zip(favourites, ["Mint Music", "Letterboxd", "Stremio", "YouTube", "Netflix", "Apple TV"]).map { .init(pkg: $0, name: $1, hasIcon: false, wide: false) })
        e.cover = sampleImage
        if let c = e.cover { e.wall = shrunk(c, to: 16); e.mirror = c }
        return e
    }
}

// Behind every widget: the album art as a soft wall of colour, as on the TV's home screen; with none, the TVs' own dark
// with a faint cyan light from the top, as the Mac Pro's graphite has its glow.
struct WidgetWall: View {
    let image: TVImage?
    var body: some View {
        ZStack {
            TVGlass()
            if let image {
                Color.clear.overlay { Image(tv: image).resizable().interpolation(.high).scaledToFill().blur(radius: 12).opacity(0.8) }.clipped()
                // Dark enough for white text, even over a white cover.
                LinearGradient(colors: [.black.opacity(0.32), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}
struct TVGlass: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1C2228), Color(hex: 0x0E1114)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [TVLook.accent.opacity(0.10), .clear], center: .top, startRadius: 4, endRadius: 220)
        }
    }
}
struct WidgetKey: View {
    let icon: String, key: String, label: String
    var size: CGFloat = 44
    var body: some View {
        Button(intent: TVPress(key: key)) { KeyFace(icon: icon, size: size) }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
// Ten seconds back or on in Stremio, as the Now Playing card sends it (exact jumps, not the TV's own rewind key).
struct TVSeek: AppIntent {
    static var title: LocalizedStringResource = "Skip ten seconds on the TV"
    static var isDiscoverable = false
    @Parameter(title: "Forward") var forward: Bool
    init() {}
    init(forward: Bool) { self.forward = forward }
    func perform() async throws -> some IntentResult {
        let pressed = Date()
        try await TVBridge.post("player-seek", ["steps": forward ? 1 : -1], timeout: 12)
        await WidgetFresh.refresh(after: pressed)
        return .result()
    }
}
// Pause or play, as the glyph says, and held so the next reading can't flip it back (TVPlayWanted).
struct TVPlayPause: AppIntent {
    static var title: LocalizedStringResource = "Play or pause the TV"
    static var isDiscoverable = false
    @Parameter(title: "Play") var play: Bool
    init() {}
    init(play: Bool) { self.play = play }
    func perform() async throws -> some IntentResult {
        let pressed = Date()
        TVPlayWanted.set(play)
        do { try await TVBridge.post("key", ["key": play ? "resume" : "pause"], timeout: 6) }
        catch { TVPlayWanted.clear(); throw error }
        await WidgetFresh.refresh(after: pressed)
        return .result()
    }
}
// The keys either side of play: the song before and after for Mint, ten seconds back and on for a film or a show, the
// TV's own back and forward for a video.
struct SkipKey: View {
    let item: TVNowItem
    let forward: Bool
    var size: CGFloat = 44
    var body: some View {
        if item.app == "Stremio" {
            Button(intent: TVSeek(forward: forward)) { KeyFace(icon: forward ? "goforward.10" : "gobackward.10", size: size) }.buttonStyle(.plain)
                .accessibilityLabel(forward ? "Forward 10 seconds" : "Back 10 seconds")
        } else if item.app == "Mint" {
            WidgetKey(icon: forward ? "forward.end.fill" : "backward.end.fill", key: forward ? "next" : "previous", label: forward ? "Next song" : "Previous song", size: size)
        } else {
            WidgetKey(icon: forward ? "forward.fill" : "backward.fill", key: forward ? "forward" : "rewind", label: forward ? "Forward" : "Back", size: size)
        }
    }
}
struct WidgetPower: View {
    var size: CGFloat = 44
    var body: some View {
        Button(intent: TVPower()) { KeyFace(icon: "power", size: size) }.buttonStyle(.plain).accessibilityLabel("Turn the TV on or off")
    }
}
struct KeyFace: View {
    let icon: String
    let size: CGFloat
    var body: some View {
        Image(systemName: icon).font(.system(size: size * 0.38, weight: .medium))
            .widgetAccentable()
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.14), in: Circle())
            .contentShape(Circle())
    }
}
struct RoundPlay: View {
    @Environment(\.widgetRenderingMode) private var mode
    let playing: Bool
    var size: CGFloat = 44
    var body: some View {
        // The key that does what the glyph says, as the Now Playing card sends it: a toggle pressed on a widget that's a
        // reading behind the TV did the opposite.
        Button(intent: TVPlayPause(play: !playing)) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(mode == .fullColor ? Color.black.opacity(0.85) : Color.white)
                .widgetAccentable()
                .frame(width: size, height: size)
                // Cyan, as play is everywhere in the app; a faint glass under the glyph on a tinted or clear screen.
                .background(mode == .fullColor ? TVLook.accent : Color.white.opacity(0.2), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(playing ? "Pause" : "Play")
    }
}
struct ProgressLine: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(width: max(4, g.size.width * fraction)).widgetAccentable()
            }
        }.frame(height: 4)
    }
}
// The cover in its own shape: a poster upright, an album square, a still wide (to 4:3 at most), at the height given. Real
// art stays real on a tinted or clear Home Screen. With none, the app in front's banner, or a quiet tile with a glyph.
struct CoverView: View {
    let image: TVImage?
    var glyph = "music.note"
    var height: CGFloat
    var maxWidth: CGFloat = .infinity
    // Up to a banner's or a still's 16:9; when that's wider than the room, the picture keeps its shape and gets shorter.
    var shape: CGFloat {
        guard let image else { return 1 }
        return min(max(image.size.width / max(image.size.height, 1), 0.66), 1.78)
    }
    var body: some View {
        let w = min(height * shape, maxWidth)
        let height = image == nil ? self.height : min(self.height, w / shape)
        ZStack {
            Color.white.opacity(0.1)
            if let image { Image(tv: image).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill().frame(width: w, height: height).clipped() }
            else { Image(systemName: glyph).font(.system(size: height * 0.3, weight: .medium)).foregroundStyle(.white.opacity(0.55)).widgetAccentable() }
        }
        .frame(width: w, height: height)
        .clipShape(RoundedRectangle(cornerRadius: height > 70 ? 12 : 9, style: .continuous))
    }
}

// MARK: - Playing
struct NowBody: View {
    let family: WidgetFamily
    let entry: TVEntry
    var playing: Bool { entry.now?.playing == true }
    // Transport only when it can do something: the TV is on and something's playing on it that the TV controls.
    var canPlay: Bool { entry.liveStatus && !entry.asleep && entry.now != nil && entry.now?.airplay != true }
    var glyph: String {
        guard let n = entry.now else { return entry.asleep ? "moon.zzz" : "tv" }
        return n.airplay ? "airplayaudio" : n.app == "Stremio" ? "film" : n.app == "YouTube" ? "play.rectangle" : "music.note"
    }
    // What stands where the cover goes: the cover, else the app in front's banner.
    var picture: TVImage? { entry.now != nil ? entry.cover : entry.front }
    // The last known, shown dimmed.
    var dim: Double { entry.reachable ? 1 : 0.6 }
    var under: some View {
        Group {
            if canPlay, entry.now?.timed == true { ProgressLine(fraction: entry.fraction) }
            else if let seen = entry.lastSeen { Text(seen).font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
            else if entry.now?.airplay == true { Label("From this iPhone", systemImage: "airplayaudio").font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
        }
    }
    var body: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    CoverView(image: picture, glyph: glyph, height: 64, maxWidth: 74).shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    Spacer(minLength: 0)
                    if canPlay { RoundPlay(playing: playing) }
                    else if entry.liveStatus && entry.asleep { WidgetPower() }
                }
                Spacer(minLength: 4)
                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1).invalidatableContent()
                if !entry.caption.isEmpty { Text(entry.caption).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                under.padding(.top, 7)
            }
            .opacity(dim)
            .padding(14)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.headline).lineLimit(1)
                if let line = entry.lastSeen ?? (entry.caption.isEmpty ? nil : entry.caption) { Text(line).font(.caption).lineLimit(1) }
                if canPlay, entry.now?.timed == true { ProgressView(value: entry.fraction).tint(.white) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            HStack(alignment: .top, spacing: 14) {
                // A quiet tile half the size when there's no picture and nothing playing (asleep, never reached).
                CoverView(image: picture, glyph: glyph, height: picture == nil && entry.now == nil ? 64 : 130, maxWidth: 140).shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title).font(.headline).lineLimit(2).minimumScaleFactor(0.9).invalidatableContent()
                    if !entry.caption.isEmpty { Text(entry.caption).font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(1).padding(.top, 1) }
                    under.padding(.top, 9)
                    if canPlay, let n = entry.now, n.timed, let len = n.length ?? nil {
                        HStack {
                            Text(clock(n.fraction(at: entry.date) * len)); Spacer(); Text("-" + clock((1 - n.fraction(at: entry.date)) * len))
                        }
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.6)).padding(.top, 3)
                    }
                    Spacer(minLength: 4)
                    if canPlay, let n = entry.now {
                        HStack {
                            SkipKey(item: n, forward: false)
                            Spacer(minLength: 0)
                            RoundPlay(playing: playing, size: 48)
                            Spacer(minLength: 0)
                            SkipKey(item: n, forward: true)
                        }
                    } else if entry.liveStatus && entry.asleep {
                        // Asleep: the one useful thing to do is wake it.
                        HStack { Spacer(minLength: 0); WidgetPower(size: 48) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .opacity(dim)
            .padding(14)
        }
    }
    func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
struct NowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TVEntry
    var body: some View {
        NowBody(family: family, entry: entry).foregroundStyle(.white).containerBackground(for: .widget) { WidgetWall(image: entry.wall) }
    }
}
struct TVNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TVNow", provider: TVProvider(art: true)) { NowWidgetView(entry: $0).widgetURL(URL(string: "tvremoteapp://tab/2")) }
            .configurationDisplayName("Playing on TV")
            .description("What’s on, with its controls.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
            .contentMarginsDisabled()
    }
}

// MARK: - Remote
struct Pad: View {
    var side: CGFloat = 132
    var body: some View {
        let key = side / 3
        ZStack {
            Circle().fill(Color.white.opacity(0.1))
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { Color.clear.frame(width: key, height: key); arrow("chevron.up", "up", "Up", key); Color.clear.frame(width: key, height: key) }
                GridRow {
                    arrow("chevron.left", "left", "Left", key)
                    // Glass, as the keys around it: a lit disc with a ring, never a flat white blob.
                    Button(intent: TVPress(key: "ok")) {
                        Circle().fill(Color.white.opacity(0.22)).overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1).widgetAccentable())
                            .padding(6).frame(width: key, height: key).contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Select")
                    arrow("chevron.right", "right", "Right", key)
                }
                GridRow { Color.clear.frame(width: key, height: key); arrow("chevron.down", "down", "Down", key); Color.clear.frame(width: key, height: key) }
            }
        }
        .frame(width: side, height: side)
    }
    func arrow(_ icon: String, _ k: String, _ label: String, _ size: CGFloat) -> some View {
        Button(intent: TVPress(key: k)) { Image(systemName: icon).font(.system(size: size * 0.36, weight: .semibold)).frame(width: size, height: size).contentShape(Rectangle()).widgetAccentable() }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
struct RemoteKeys: View {
    var key: CGFloat = 44
    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow { WidgetKey(icon: "arrow.uturn.backward", key: "back", label: "Back", size: key); WidgetKey(icon: "house.fill", key: "home", label: "Home", size: key); WidgetPower(size: key) }
            // The TV's own rewind and forward, whatever's playing: not "10", which only Stremio's exact jumps are.
            GridRow { WidgetKey(icon: "backward.fill", key: "rewind", label: "Rewind", size: key); WidgetKey(icon: "playpause.fill", key: "play", label: "Play or pause", size: key); WidgetKey(icon: "forward.fill", key: "forward", label: "Fast forward", size: key) }
        }
    }
}
struct RemoteBody: View {
    let family: WidgetFamily
    let entry: TVEntry
    @Environment(\.widgetRenderingMode) private var mode
    var screenName: String {
        guard entry.liveStatus, let s = entry.status else { return entry.lastSeen ?? "Waiting for the TV" }
        if s.screen == "asleep" { return "TV asleep" }
        let name = s.apps?.first { $0.pkg == s.app }?.name ?? "Home"
        // The picture is from the last refresh, so say when that was.
        return entry.mirror == nil ? name : "\(name) · \(tvWidgetTime(entry.date))"
    }
    var body: some View {
        if family == .systemLarge {
            VStack(spacing: 10) {
                // The TV's own picture, whole in its 16:9 (every press refreshes it); the last one, dimmed, while the TV
                // isn't answering.
                ZStack {
                    (mode == .fullColor ? Color.black : Color.white.opacity(0.1))
                    if let m = entry.mirror, !entry.asleep {
                        Image(tv: m).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill().opacity(entry.liveStatus ? 1 : 0.5)
                    } else {
                        Image(systemName: entry.asleep ? "moon.zzz" : "tv").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.45)).widgetAccentable()
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(screenName).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        RemoteKeys(key: 44)
                    }
                    Spacer(minLength: 0)
                    Pad(side: 132)
                }
            }
            .padding(14)
        } else {
            HStack { RemoteKeys(key: 48); Spacer(minLength: 0); Pad(side: 132) }.padding(.horizontal, 14).padding(.vertical, 12)
        }
    }
}
struct RemoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TVEntry
    var body: some View { RemoteBody(family: family, entry: entry).foregroundStyle(.white).containerBackground(for: .widget) { TVGlass() }.widgetURL(URL(string: "tvremoteapp://tab/0")) }
}
// MARK: - Box status
struct TVBoxInfo: Codable {
    var model = "", android = ""
    var uptime = 0.0, cpu = 0.0, memUsed = 0.0, memTotal = 0.0, diskUsed = 0.0, diskTotal = 0.0, tempC = 0.0
}
struct TVBoxEntry: TimelineEntry {
    var date = Date()
    var info: TVBoxInfo?
    var photo: TVImage?
    var screen = ""
    var reachable = false
    // When the figures shown were read, when they're the last known rather than this moment's.
    var readAt: Date?
    var uptime: String {
        let u = Int(info?.uptime ?? 0), d = u / 86400, h = u / 3600 % 24, m = u / 60 % 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    // Not live, the last figures are shown with when they were read: never an alarm for a reading missed.
    // Not live: the time it was last seen, by a grey dot (the full phrase didn't fit beside the photo).
    var state: String { !reachable ? tvWidgetTime(readAt ?? date) : screen == "asleep" ? "Asleep" : screen == "screensaver" ? "Screensaver" : screen == "on" ? "Awake" : "Online" }
    var dot: Color { !reachable ? .gray : screen == "on" || screen == "screensaver" ? .green : .gray }
    var memory: Double { (info?.memTotal ?? 0) > 0 ? info!.memUsed / info!.memTotal : 0 }
    var storage: Double { (info?.diskTotal ?? 0) > 0 ? info!.diskUsed / info!.diskTotal : 0 }
    var fahrenheit: Int { Int(((info?.tempC ?? 0) * 9 / 5 + 32).rounded()) }
}
struct TVBoxProvider: TimelineProvider {
    static var sample: TVBoxEntry {
        TVBoxEntry(info: TVBoxInfo(model: "onn. 4K Streaming Box", android: "14", uptime: 118800, cpu: 18, memUsed: 1.4e9, memTotal: 2e9, diskUsed: 3.3e9, diskTotal: 4.7e9, tempC: 46), screen: "on", reachable: true)
    }
    func placeholder(in context: Context) -> TVBoxEntry { Self.sample }
    func getSnapshot(in context: Context, completion: @escaping (TVBoxEntry) -> Void) {
        if context.isPreview { completion(Self.sample); return }
        Task { completion(await load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TVBoxEntry>) -> Void) {
        // Without a fresh reading, sooner (5 minutes) rather than a quarter of an hour of the last one.
        Task { let e = await load(); completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(e.reachable ? 15 * 60 : 5 * 60)))) }
    }
    func load() async -> TVBoxEntry {
        var e = TVBoxEntry()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let infoFile = caches.appendingPathComponent("widget-box.json"), photoFile = caches.appendingPathComponent("widget-box.png")
        // All three at once, eight seconds at most: one after the other they took up to half a minute.
        let needPhoto = !FileManager.default.fileExists(atPath: photoFile.path)
        async let device = TVBridge.data(TVBridge.url("/api/tv/device"), timeout: 8)
        async let status = TVBridge.data(TVBridge.url("/api/tv/status"), timeout: 8)
        async let photo: Data? = needPhoto ? TVBridge.data(TVBridge.url("/api/tv/device-image"), timeout: 8) : nil
        if let d = await device, let i = try? JSONDecoder().decode(TVBoxInfo.self, from: d) {
            e.info = i; e.reachable = true
            try? JSONEncoder().encode(i).write(to: infoFile, options: .atomic)
        } else if let d = try? Data(contentsOf: infoFile) {
            e.info = try? JSONDecoder().decode(TVBoxInfo.self, from: d)
            e.readAt = (try? infoFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        if let d = await status, let s = try? JSONDecoder().decode(TVStatus.self, from: d) { e.screen = s.screen ?? "" }
        if let d = await photo, d.count > 100 { try? d.write(to: photoFile, options: .atomic) }
        if let d = try? Data(contentsOf: photoFile) { e.photo = TVImage(data: d) }
        return e
    }
}
struct BoxBar: View {
    let value: Double
    var color: Color { value > 0.9 ? .red : value > 0.75 ? .orange : TVLook.accent }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(color).frame(width: max(5, g.size.width * min(max(value, 0), 1))).widgetAccentable()
            }
        }
        .frame(height: 6)
    }
}
// The Mac Pro widget's meter, in the TV's cyan: the same sizes for the same job.
struct BoxRow: View {
    let label: String, text: String
    var value: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer(minLength: 4)
                Text(text).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            }
            if let value { BoxBar(value: value) }
        }
    }
}
struct TVBoxBody: View {
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.showsWidgetContainerBackground) private var background
    let family: WidgetFamily
    let entry: TVBoxEntry
    // The box's photo, drawn as a photo on a tinted or clear screen (not a flat block), on a soft light where the dark
    // box would vanish into a dark ground (StandBy, tinted). Before its first fetch, the system's media box.
    var photo: some View {
        Group {
            if let p = entry.photo { Image(tv: p).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit() }
            else { Image(systemName: "tv.and.mediabox").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.7)).widgetAccentable() }
        }
        // The soft light only where the dark box would vanish: none in full colour on its own background.
        .background { if mode != .fullColor || !background { Ellipse().fill(RadialGradient(colors: [.white.opacity(0.28), .clear], center: .center, startRadius: 2, endRadius: 44)).scaleEffect(1.4) } }
    }
    var state: some View {
        HStack(spacing: 5) {
            Circle().fill(entry.dot).frame(width: 8, height: 8)
            // The state leads its line at its full size.
            Text(entry.state).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
        }
    }
    // Not answering: said as "Last seen" over the time, so it never reads as a clock.
    var seen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Last seen").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Text(entry.state).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
    var dim: Double { entry.reachable ? 1 : 0.55 }
    var body: some View {
        if entry.info == nil {
            VStack(alignment: .leading, spacing: 6) {
                photo.frame(width: 56, height: 44)
                Spacer(minLength: 0)
                Text("TV box").font(.system(size: 15, weight: .semibold))
                Text("Waiting for the box").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if family == .systemSmall {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    photo.frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        if entry.reachable {
                            state
                            Text("Up \(entry.uptime)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        } else { seen }
                    }
                }
                // CPU and temperature across the full width (beside the photo the temperature was cut).
                Text("CPU \(Int(entry.info?.cpu ?? 0))% · \(entry.fahrenheit)°F").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75)).monospacedDigit().lineLimit(1)
                    .opacity(dim)
                Spacer(minLength: 0)
                Group {
                    BoxRow(label: "Memory", text: "\(Int((entry.memory * 100).rounded()))%", value: entry.memory)
                    BoxRow(label: "Storage", text: "\(Int((entry.storage * 100).rounded()))%", value: entry.storage)
                }
                .opacity(dim)
            }
            .padding(16)
        } else {
            HStack(spacing: 14) {
                VStack(spacing: 4) {
                    photo.frame(width: 88, height: 70)
                    if entry.reachable {
                        state
                        Text("Up \(entry.uptime)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    } else {
                        Text("Last seen " + entry.state).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).lineLimit(2)
                    }
                }
                .frame(width: 100)
                VStack(alignment: .leading, spacing: 0) {
                    BoxRow(label: "CPU", text: "\(Int(entry.info?.cpu ?? 0))%", value: (entry.info?.cpu ?? 0) / 100)
                    Spacer(minLength: 4)
                    BoxRow(label: "Memory", text: "\(Int((entry.memory * 100).rounded()))%", value: entry.memory)
                    Spacer(minLength: 4)
                    BoxRow(label: "Storage", text: "\(Int((entry.storage * 100).rounded()))%", value: entry.storage)
                    Spacer(minLength: 4)
                    BoxRow(label: "Temperature", text: "\(entry.fahrenheit)°F")
                }
                .opacity(dim)
            }
            .padding(16)
        }
    }
}
struct TVBoxWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TVBoxEntry
    var body: some View {
        TVBoxBody(family: family, entry: entry).foregroundStyle(.white).containerBackground(for: .widget) { TVGlass() }.widgetURL(URL(string: "tvremoteapp://tab/5"))
    }
}
struct TVBoxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TVBoxStatus", provider: TVBoxProvider()) { TVBoxWidgetView(entry: $0) }
            .configurationDisplayName("TV Box Status")
            .description("Whether the TV box is awake, how long it's been up, and its CPU, memory, storage and temperature.")
            .contentMarginsDisabled()
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct TVRemoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TVRemote", provider: TVProvider(needsStatus: false)) { RemoteWidgetView(entry: $0) }
            .configurationDisplayName("TV Remote")
            .description("Move and select on the TV without opening the app.")
            .supportedFamilies([.systemMedium])
            .contentMarginsDisabled()
    }
}
struct TVScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TVScreen", provider: TVProvider(mirror: true)) { RemoteWidgetView(entry: $0) }
            .configurationDisplayName("TV Screen and Remote")
            .description("The TV’s picture above its remote.")
            .supportedFamilies([.systemLarge])
            .contentMarginsDisabled()
    }
}

// MARK: - Apps
struct TVAppsConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "TV Apps"
    static var description = IntentDescription("Choose the six apps.")
    @Parameter(title: "First app") var first: TVAppEntity?
    @Parameter(title: "Second app") var second: TVAppEntity?
    @Parameter(title: "Third app") var third: TVAppEntity?
    @Parameter(title: "Fourth app") var fourth: TVAppEntity?
    @Parameter(title: "Fifth app") var fifth: TVAppEntity?
    @Parameter(title: "Sixth app") var sixth: TVAppEntity?
    func picks() -> [String] {
        [first?.id, second?.id, third?.id, fourth?.id, fifth?.id, sixth?.id].enumerated().map { $1 ?? TVProvider.favourites[$0] }
    }
}
struct TVAppsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TVEntry { TVProvider.sample }
    func snapshot(for c: TVAppsConfig, in context: Context) async -> TVEntry { context.isPreview ? TVProvider.sample : await load(c) }
    func timeline(for c: TVAppsConfig, in context: Context) async -> Timeline<TVEntry> {
        let e = await load(c)
        // Soon if it failed, so blank tiles don't stay all day.
        return Timeline(entries: [e], policy: .after(Date().addingTimeInterval(e.reachable || e.logos.count >= 6 ? 6 * 3600 : 900)))
    }
    func load(_ c: TVAppsConfig) async -> TVEntry {
        var e = TVEntry()
        e.status = await TVBridge.status()
        e.reachable = e.status != nil
        // The apps' names, kept on disk from the last answer, so the tiles are named with no answer at all.
        let namesFile = WidgetFresh.dir.appendingPathComponent("widget-app-names.json")
        var names = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: namesFile))) ?? [:]
        if let apps = e.status?.apps {
            for a in apps { names[a.pkg] = a.name }
            try? JSONEncoder().encode(names).write(to: namesFile, options: .atomic)
        }
        e.chosen = c.picks().map { pkg in TVAppEntity(id: pkg, name: names[pkg] ?? "") }
        // All at once, from disk when they've been fetched before: logos almost never change.
        let fetch = e.reachable
        e.logos = await withTaskGroup(of: (String, TVImage?).self) { group -> [String: TVImage] in
            for pkg in c.picks() { group.addTask { (pkg, await TVProvider.logo(pkg, fetch: fetch)) } }
            var out: [String: TVImage] = [:]
            for await (pkg, i) in group { if let i { out[pkg] = i } }
            return out
        }
        return e
    }
}
// Two rows of real banners in the TV's own 142:80 shape, so a logo is never cropped differently.
struct AppsBody: View {
    let entry: TVEntry
    @Environment(\.widgetRenderingMode) private var mode
    var body: some View {
        GeometryReader { g in
            let gap: CGFloat = 10, w = (g.size.width - gap * 2) / 3, h = w * 80 / 142
            VStack(spacing: gap) {
                HStack(spacing: gap) { tile(0, w, h); tile(1, w, h); tile(2, w, h) }
                HStack(spacing: gap) { tile(3, w, h); tile(4, w, h); tile(5, w, h) }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .padding(.horizontal, 14)
    }
    func name(_ pkg: String, _ app: TVStatus.App?) -> String { app?.name ?? entry.chosen.first { $0.id == pkg }?.name ?? "" }
    func tile(_ i: Int, _ w: CGFloat, _ h: CGFloat) -> some View {
        let pkg = entry.chosen.indices.contains(i) ? entry.chosen[i].id : TVProvider.favourites[i]
        let app = entry.status?.apps?.first { $0.pkg == pkg }
        return Button(intent: TVOpenApp(pkg: pkg)) {
            ZStack {
                (mode == .fullColor ? TVLook.bannerTile : Color.white.opacity(0.14))
                if let logo = entry.logos[pkg], app?.wide != false {
                    Image(tv: logo).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
                } else {
                    VStack(spacing: 2) {
                        if let logo = entry.logos[pkg] { Image(tv: logo).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFit().frame(width: h * 0.42, height: h * 0.42) }
                        Text(name(pkg, app)).font(.caption2.weight(.medium)).lineLimit(1).padding(.horizontal, 4).widgetAccentable()
                    }
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }.buttonStyle(.plain).accessibilityLabel(app?.name ?? "App")
    }
}
struct TVAppsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TVApps", intent: TVAppsConfig.self, provider: TVAppsProvider()) { e in
            AppsBody(entry: e).foregroundStyle(.white).containerBackground(for: .widget) { TVGlass() }.widgetURL(URL(string: "tvremoteapp://tab/1"))
        }
        .configurationDisplayName("TV Apps")
        .description("Six apps of your choice, opened on the TV with one tap.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Control Center
struct TVPlayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TVPlayControl") {
            ControlWidgetButton(action: TVPress(key: "play")) { Label("TV Play or Pause", systemImage: "playpause.fill") }
        }.displayName("TV Play or Pause")
    }
}
struct TVFlickControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TVFlickControl") {
            ControlWidgetButton(action: FlickToTV()) { Label("Flick to TV", systemImage: "airplayaudio") }
        }.displayName("Flick to TV").description("Sends what’s playing on this iPhone to the TV.")
    }
}
struct TVPowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TVPowerControl") {
            ControlWidgetButton(action: TVPower()) { Label("TV On or Off", systemImage: "power") }
        }.displayName("TV On or Off")
    }
}
struct TVRemoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TVRemoteControl") {
            ControlWidgetButton(action: TVOpenRemote()) { Label("TV Remote", systemImage: "av.remote.fill") }
        }.displayName("TV Remote")
    }
}

#if !GALLERY
@main
struct TVWidgets: WidgetBundle {
    var body: some Widget {
        TVNowWidget()
        TVRemoteWidget()
        TVScreenWidget()
        TVAppsWidget()
        TVBoxWidget()
        TVIslandWidget()
        TVFlickControl()
        TVPlayControl()
        TVPowerControl()
        TVRemoteControl()
    }
}
#endif
