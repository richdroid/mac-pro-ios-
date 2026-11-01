import AppIntents
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
    var reachable: Bool { status != nil }
    var music: TVStatus.Music? { status?.music }
    var asleep: Bool { status?.screen == "asleep" }
    var fraction: Double {
        guard let m = music, m.duration > 0 else { return 0 }
        let t = m.playing ? m.position + date.timeIntervalSince1970 * 1000 - m.sampledAt : m.position
        return min(max(t / m.duration, 0), 1)
    }
    var remaining: TimeInterval { music.map { ($0.duration * (1 - fraction)) / 1000 } ?? 0 }
    var caption: String {
        if !reachable { return "Tailscale off?" }
        if asleep { return "TV asleep" }
        return music?.artist ?? ""
    }
}

struct TVProvider: TimelineProvider {
    var mirror = false
    func placeholder(in context: Context) -> TVEntry { Self.sample }
    func getSnapshot(in context: Context, completion: @escaping (TVEntry) -> Void) {
        if context.isPreview { completion(Self.sample); return }
        Task { completion(await load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TVEntry>) -> Void) {
        Task {
            let e = await load()
            // Back when the song ends, if one is playing; otherwise at the usual pace.
            let wait = e.music?.playing == true ? max(e.remaining + 2, 60) : 15 * 60
            completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(wait))))
        }
    }
    func load() async -> TVEntry {
        var e = TVEntry()
        e.status = await TVBridge.status()
        if let art = e.music?.art, let d = await TVBridge.data(URL(string: art)), let i = TVImage(data: d) { e.cover = Self.shrunk(i, to: 320); e.wall = Self.shrunk(i, to: 16) }
        if mirror, e.status?.online == true, !e.asleep, let d = await TVBridge.data(TVBridge.url("/api/tv/shot")), let i = TVImage(data: d) { e.mirror = i }
        return e
    }
    static let favourites = ["com.codex.musicwebtv", "com.mint.letterboxd", "com.stremio.one", "com.google.android.youtube.tv", "com.netflix.ninja", "com.apple.atve.androidtv.appletv"]
    // Widgets get very little memory, so nothing bigger than it will be drawn is kept.
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
                            apps: favourites.map { .init(pkg: $0, name: $0.split(separator: ".").last.map(String.init) ?? $0, hasIcon: true, wide: true) })
        e.cover = sampleImage
        if let c = e.cover { e.wall = shrunk(c, to: 16); e.mirror = c; e.logos = Dictionary(uniqueKeysWithValues: favourites.map { ($0, c) }) }
        return e
    }
}

// The launcher's home screen behind a card: black, with the art as a soft wall of colour.
struct WidgetWall: View {
    let image: TVImage?
    var body: some View {
        ZStack {
            Color.black
            if let image {
                Color.clear.overlay { Image(tv: image).resizable().interpolation(.high).scaledToFill().opacity(0.42) }.clipped()
            }
        }
    }
}
// A flat key from the launcher: a glyph and nothing else.
struct WidgetKey: View {
    let icon: String, key: String, label: String
    var size: CGFloat = 34
    var body: some View {
        Button(intent: TVPress(key: key)) {
            Image(systemName: icon).font(.system(size: size * 0.46)).frame(width: size, height: size).contentShape(Rectangle()).widgetAccentable()
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
struct WidgetPower: View {
    var size: CGFloat = 34
    var body: some View {
        Button(intent: TVPower()) {
            Image(systemName: "power").font(.system(size: size * 0.46)).frame(width: size, height: size).contentShape(Rectangle()).widgetAccentable()
        }.buttonStyle(.plain).accessibilityLabel("Turn the TV on or off")
    }
}
// The launcher's progress line: leanback's cyan on grey, sitting where the art meets the band.
struct CardProgress: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Mint.band
                Rectangle().fill(Mint.progress).frame(width: g.size.width * fraction).widgetAccentable()
            }
        }.frame(height: 2)
    }
}
// Three bars when playing and a pause mark when not, at the corner of the art, as the launcher's now-playing card has them.
struct StatusMark: View {
    let playing: Bool
    var body: some View {
        Group {
            if playing {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach([0.55, 1.0, 0.72], id: \.self) { h in Rectangle().fill(Mint.text).frame(width: 3.5, height: 15 * h) }
                }
                .frame(height: 15, alignment: .bottom)
            } else {
                Image(systemName: "pause.fill").font(.system(size: 13)).foregroundStyle(Mint.text)
            }
        }
        .widgetAccentable()
    }
}
struct CardArt: View {
    let image: TVImage?
    let playing: Bool?
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Mint.plane
            if let image { Image(tv: image).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill() }
            else { Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(Mint.text.opacity(0.4)).frame(maxWidth: .infinity, maxHeight: .infinity).widgetAccentable() }
            if let playing {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .init(x: 0.5, y: 0.6), endPoint: .bottom)
                StatusMark(playing: playing).padding(.trailing, 8).padding(.bottom, 8)
            }
        }
        .contentShape(Rectangle())
        .clipped()
    }
}

// MARK: - Playing
struct NowBody: View {
    let family: WidgetFamily
    let entry: TVEntry
    var title: String { entry.music?.title ?? "Nothing playing" }
    var playing: Bool { entry.music?.playing == true }
    var body: some View {
        switch family {
        case .systemSmall:
            // The launcher's card, whole. Tapping it plays or pauses.
            Button(intent: TVPress(key: "play")) {
                VStack(spacing: 0) {
                    CardArt(image: entry.cover, playing: entry.music == nil ? nil : playing)
                    CardProgress(fraction: entry.fraction)
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(title).font(Mint.font(13.4)).lineLimit(1)
                            Text(entry.caption).font(Mint.font(10.8)).foregroundStyle(Mint.text.opacity(0.7)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(Mint.text.opacity(0.7)).widgetAccentable()
                    }
                    .padding(.horizontal, 11).frame(height: 44).background(Mint.band)
                }
            }.buttonStyle(.plain).accessibilityLabel(playing ? "Pause \(title)" : "Play \(title)")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                Text(entry.caption).font(.caption).lineLimit(1)
                ProgressView(value: entry.fraction).tint(.white)
            }
        default:
            HStack(spacing: 0) {
                CardArt(image: entry.cover, playing: entry.music == nil ? nil : playing).aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Mint.font(20, weight: 300)).lineLimit(1)
                    Text(entry.caption).font(Mint.font(12)).foregroundStyle(Mint.text.opacity(0.7)).lineLimit(1).padding(.top, 2)
                    Spacer(minLength: 4)
                    CardProgress(fraction: entry.fraction)
                    HStack {
                        WidgetKey(icon: "backward.end.fill", key: "previous", label: "Previous", size: 40)
                        Spacer(minLength: 0)
                        WidgetKey(icon: playing ? "pause.fill" : "play.fill", key: "play", label: playing ? "Pause" : "Play", size: 44)
                        Spacer(minLength: 0)
                        WidgetKey(icon: "forward.end.fill", key: "next", label: "Next", size: 40)
                    }.padding(.top, 6)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
    }
}
struct NowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TVEntry
    var body: some View {
        NowBody(family: family, entry: entry).foregroundStyle(Mint.text).containerBackground(for: .widget) { WidgetWall(image: entry.wall) }
    }
}
struct TVNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TVNow", provider: TVProvider()) { NowWidgetView(entry: $0) }
            .configurationDisplayName("Playing on TV")
            .description("The launcher’s now-playing card. Tap to play or pause.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
            .contentMarginsDisabled()
    }
}

// MARK: - Remote
// The Android TV remote's ring, flat in the launcher's card colours.
struct Pad: View {
    var side: CGFloat = 132
    var body: some View {
        let key = side / 3
        ZStack {
            Circle().fill(Mint.band)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { Color.clear.frame(width: key, height: key); WidgetKey(icon: "chevron.up", key: "up", label: "Up", size: key); Color.clear.frame(width: key, height: key) }
                GridRow {
                    WidgetKey(icon: "chevron.left", key: "left", label: "Left", size: key)
                    Button(intent: TVPress(key: "ok")) { Circle().fill(Mint.banner).padding(3).frame(width: key, height: key).contentShape(Circle()).widgetAccentable() }.buttonStyle(.plain).accessibilityLabel("Select")
                    WidgetKey(icon: "chevron.right", key: "right", label: "Right", size: key)
                }
                GridRow { Color.clear.frame(width: key, height: key); WidgetKey(icon: "chevron.down", key: "down", label: "Down", size: key); Color.clear.frame(width: key, height: key) }
            }
        }
        .frame(width: side, height: side)
    }
}
struct RemoteKeys: View {
    var key: CGFloat = 44
    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow { WidgetKey(icon: "arrow.left", key: "back", label: "Back", size: key); WidgetKey(icon: "house.fill", key: "home", label: "Home", size: key); WidgetPower(size: key) }
            GridRow { WidgetKey(icon: "speaker.minus.fill", key: "voldown", label: "Volume down", size: key); WidgetKey(icon: "playpause.fill", key: "play", label: "Play or pause", size: key); WidgetKey(icon: "speaker.plus.fill", key: "volup", label: "Volume up", size: key) }
        }
    }
}
struct RemoteBody: View {
    let family: WidgetFamily
    let entry: TVEntry
    var screenName: String {
        guard let s = entry.status else { return "Tailscale off?" }
        if s.screen == "asleep" { return "TV asleep" }
        return s.apps?.first { $0.pkg == s.app }?.name ?? "Home"
    }
    var body: some View {
        if family == .systemLarge {
            VStack(spacing: 10) {
                // A card of the TV's own picture. Every press refreshes it.
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        if let m = entry.mirror { Image(tv: m).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Text(screenName).font(Mint.font(13.4)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "tv").font(.system(size: 11)).foregroundStyle(Mint.text.opacity(0.7)).widgetAccentable()
                    }
                    .padding(.horizontal, 11).frame(height: 32).background(Mint.band)
                }
                .clipShape(RoundedRectangle(cornerRadius: Mint.radius))
                HStack { Pad(side: 123); Spacer(minLength: 0); RemoteKeys() }
            }
            .padding(14)
        } else {
            HStack { Pad(side: 132); Spacer(minLength: 0); RemoteKeys(key: 48) }.padding(.horizontal, 14).padding(.vertical, 12)
        }
    }
}
struct RemoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TVEntry
    var body: some View { RemoteBody(family: family, entry: entry).foregroundStyle(Mint.text).containerBackground(for: .widget) { Mint.plane } }
}
struct TVRemoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TVRemote", provider: TVProvider()) { RemoteWidgetView(entry: $0) }
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
        Timeline(entries: [await load(c)], policy: .after(Date().addingTimeInterval(6 * 3600)))
    }
    func load(_ c: TVAppsConfig) async -> TVEntry {
        var e = TVEntry()
        e.status = await TVBridge.status()
        if let art = e.music?.art, let d = await TVBridge.data(URL(string: art)), let i = TVImage(data: d) { e.wall = TVProvider.shrunk(i, to: 16) }
        for pkg in c.picks() {
            e.chosen.append(TVAppEntity(id: pkg, name: e.status?.apps?.first { $0.pkg == pkg }?.name ?? ""))
            if let d = await TVBridge.data(TVBridge.url("/api/tv/icon?pkg=\(pkg)"), timeout: 4), let i = TVImage(data: d) { e.logos[pkg] = i }
        }
        return e
    }
}
// Two rows of banners at the launcher's exact 142:80, so a logo is never cropped differently from the TV.
struct AppsBody: View {
    let entry: TVEntry
    var body: some View {
        GeometryReader { g in
            let gap: CGFloat = 8, w = (g.size.width - gap * 2) / 3, h = w * 80 / 142
            VStack(spacing: gap) {
                HStack(spacing: gap) { tile(0, w, h); tile(1, w, h); tile(2, w, h) }
                HStack(spacing: gap) { tile(3, w, h); tile(4, w, h); tile(5, w, h) }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .padding(.horizontal, 14)
    }
    func tile(_ i: Int, _ w: CGFloat, _ h: CGFloat) -> some View {
        let pkg = entry.chosen.indices.contains(i) ? entry.chosen[i].id : TVProvider.favourites[i]
        let app = entry.status?.apps?.first { $0.pkg == pkg }
        return Button(intent: TVOpenApp(pkg: pkg)) {
            ZStack {
                Mint.banner
                if let logo = entry.logos[pkg], app?.wide != false {
                    Image(tv: logo).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
                } else {
                    // The launcher's fallback for an app with no banner: its icon over its name.
                    VStack(spacing: 2) {
                        if let logo = entry.logos[pkg] { Image(tv: logo).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit().frame(width: h * 0.42, height: h * 0.42) }
                        Text(app?.name ?? "").font(Mint.font(10.5, condensed: true)).lineLimit(1).padding(.horizontal, 4).widgetAccentable()
                    }
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: Mint.radius))
        }.buttonStyle(.plain).accessibilityLabel(app?.name ?? "App")
    }
}
struct TVAppsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TVApps", intent: TVAppsConfig.self, provider: TVAppsProvider()) { e in
            AppsBody(entry: e).foregroundStyle(Mint.text).containerBackground(for: .widget) { WidgetWall(image: e.wall) }
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
struct TVVolumeUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TVVolumeUpControl") {
            ControlWidgetButton(action: TVPress(key: "volup")) { Label("TV Volume Up", systemImage: "speaker.plus.fill") }
        }.displayName("TV Volume Up")
    }
}
struct TVVolumeDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TVVolumeDownControl") {
            ControlWidgetButton(action: TVPress(key: "voldown")) { Label("TV Volume Down", systemImage: "speaker.minus.fill") }
        }.displayName("TV Volume Down")
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
        TVFlickControl()
        TVPlayControl()
        TVVolumeUpControl()
        TVVolumeDownControl()
        TVPowerControl()
        TVRemoteControl()
    }
}
#endif
