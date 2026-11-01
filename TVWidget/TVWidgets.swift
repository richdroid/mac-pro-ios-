import AppIntents
import SwiftUI
import WidgetKit

struct TVEntry: TimelineEntry {
    var date = Date()
    var status: TVStatus?
    var cover: TVImage?
    var tint = Mint.band
    var mirror: TVImage?
    var logos: [String: TVImage] = [:]
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
    var logos = false
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
        if let art = e.music?.art, let d = await TVBridge.data(URL(string: art)), let i = TVImage(data: d) { e.cover = i; e.tint = CoverTint.of(i) }
        if mirror, e.status?.online == true, !e.asleep, let d = await TVBridge.data(TVBridge.url("/api/tv/shot")), let i = TVImage(data: d) { e.mirror = i }
        if logos {
            for pkg in Self.favourites {
                if let d = await TVBridge.data(TVBridge.url("/api/tv/icon?pkg=\(pkg)"), timeout: 4), let i = TVImage(data: d) { e.logos[pkg] = i }
            }
        }
        return e
    }
    static let favourites = ["com.codex.musicwebtv", "com.mint.letterboxd", "com.stremio.one", "com.google.android.youtube.tv"]
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
        if let c = e.cover { e.tint = CoverTint.of(c); e.mirror = c; e.logos = Dictionary(uniqueKeysWithValues: favourites.map { ($0, c) }) }
        return e
    }
}

// A flat key from the launcher. Clear Home Screens flatten it along with everything else.
struct WidgetKey: View {
    let icon: String, key: String, label: String
    var size: CGFloat = 34
    var body: some View {
        Button(intent: TVPress(key: key)) {
            Image(systemName: icon).font(.system(size: size * 0.5)).frame(width: size, height: size).contentShape(Rectangle()).widgetAccentable()
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
struct WidgetPower: View {
    var size: CGFloat = 34
    var body: some View {
        Button(intent: TVPower()) {
            Image(systemName: "power").font(.system(size: size * 0.5)).frame(width: size, height: size).contentShape(Rectangle()).widgetAccentable()
        }.buttonStyle(.plain).accessibilityLabel("Turn the TV on or off")
    }
}
struct RoundPlay: View {
    @Environment(\.widgetRenderingMode) private var mode
    let playing: Bool
    var size: CGFloat = 42
    var body: some View {
        Button(intent: TVPress(key: "play")) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size * 0.42))
                .foregroundStyle(mode == .fullColor ? Color.black.opacity(0.85) : Color.white)
                .frame(width: size, height: size)
                .background(Color.white.opacity(mode == .fullColor ? 0.68 : 0.2), in: Circle())
                .widgetAccentable()
        }.buttonStyle(.plain).accessibilityLabel(playing ? "Pause" : "Play")
    }
}
struct Hairline: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.25))
                Rectangle().fill(Color.white).frame(width: g.size.width * fraction).widgetAccentable()
            }
        }.frame(height: 2)
    }
}
struct CoverView: View {
    let image: TVImage?
    var body: some View {
        ZStack {
            Mint.band
            if let image { Image(tv: image).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill() }
            else { Image(systemName: "music.note").font(.title2).opacity(0.5).widgetAccentable() }
        }
        .clipShape(RoundedRectangle(cornerRadius: Mint.radius))
    }
}

// MARK: - Playing
struct NowBody: View {
    let family: WidgetFamily
    let entry: TVEntry
    var title: String { entry.music?.title ?? "Nothing playing" }
    var body: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    CoverView(image: entry.cover).frame(width: 64, height: 64)
                    Spacer(minLength: 0)
                    RoundPlay(playing: entry.music?.playing == true)
                }
                Spacer(minLength: 6)
                Text(title).font(Mint.font(15.4)).lineLimit(2)
                Text(entry.caption).font(Mint.font(11.8)).opacity(0.75).lineLimit(1)
                Hairline(fraction: entry.fraction).padding(.top, 6)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                Text(entry.caption).font(.caption).lineLimit(1)
                ProgressView(value: entry.fraction).tint(.white)
            }
        default:
            HStack(spacing: 14) {
                CoverView(image: entry.cover).aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Mint.font(19, weight: 300)).lineLimit(1)
                    Text(entry.caption).font(Mint.font(12.5)).opacity(0.75).lineLimit(1)
                    Spacer(minLength: 4)
                    Hairline(fraction: entry.fraction)
                    HStack {
                        WidgetKey(icon: "backward.end.fill", key: "previous", label: "Previous")
                        Spacer(minLength: 0)
                        RoundPlay(playing: entry.music?.playing == true)
                        Spacer(minLength: 0)
                        WidgetKey(icon: "forward.end.fill", key: "next", label: "Next")
                    }.padding(.top, 4)
                }
            }
        }
    }
}
struct NowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TVEntry
    var body: some View {
        NowBody(family: family, entry: entry).foregroundStyle(Mint.text).containerBackground(for: .widget) { entry.tint }
    }
}
struct TVNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TVNow", provider: TVProvider()) { NowWidgetView(entry: $0) }
            .configurationDisplayName("Playing on TV")
            .description("What’s on, with its colour and controls.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - Remote
struct Pad: View {
    var key: CGFloat = 42
    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { Color.clear.frame(width: key, height: key); WidgetKey(icon: "chevron.up", key: "up", label: "Up", size: key); Color.clear.frame(width: key, height: key) }
            GridRow {
                WidgetKey(icon: "chevron.left", key: "left", label: "Left", size: key)
                Button(intent: TVPress(key: "ok")) { Circle().fill(Mint.text.opacity(0.16)).overlay { Circle().strokeBorder(Mint.text.opacity(0.4)) }.padding(4).frame(width: key, height: key).widgetAccentable() }.buttonStyle(.plain).accessibilityLabel("Select")
                WidgetKey(icon: "chevron.right", key: "right", label: "Right", size: key)
            }
            GridRow { Color.clear.frame(width: key, height: key); WidgetKey(icon: "chevron.down", key: "down", label: "Down", size: key); Color.clear.frame(width: key, height: key) }
        }
    }
}
struct RemoteKeys: View {
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow { WidgetKey(icon: "arrow.uturn.backward", key: "back", label: "Back", size: 40); WidgetKey(icon: "house", key: "home", label: "Home", size: 40); WidgetPower(size: 40) }
            GridRow { WidgetKey(icon: "speaker.minus", key: "voldown", label: "Volume down", size: 40); WidgetKey(icon: "playpause", key: "play", label: "Play or pause", size: 40); WidgetKey(icon: "speaker.plus", key: "volup", label: "Volume up", size: 40) }
        }
    }
}
struct RemoteBody: View {
    let family: WidgetFamily
    let entry: TVEntry
    var body: some View {
        if family == .systemLarge {
            VStack(spacing: 10) {
                // Every press refreshes the widget, so the picture is the TV a moment ago.
                ZStack {
                    Color.black
                    if let m = entry.mirror { Image(tv: m).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit() }
                    else { Text(entry.reachable ? (entry.asleep ? "TV asleep" : "") : "Tailscale off?").font(Mint.font(15)).opacity(0.7) }
                }
                .aspectRatio(16.0 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Mint.radius))
                HStack { Pad(key: 44); Spacer(minLength: 0); RemoteKeys() }
            }
        } else {
            HStack { Pad(key: 42); Spacer(minLength: 0); RemoteKeys() }
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
    }
}
struct TVScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TVScreen", provider: TVProvider(mirror: true)) { RemoteWidgetView(entry: $0) }
            .configurationDisplayName("TV Screen and Remote")
            .description("The TV’s picture above its remote.")
            .supportedFamilies([.systemLarge])
    }
}

// MARK: - Apps
struct AppsBody: View {
    let entry: TVEntry
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { tile(0); tile(1) }
            GridRow { tile(2); tile(3) }
        }
    }
    func tile(_ i: Int) -> some View {
        let pkg = TVProvider.favourites[i]
        let app = entry.status?.apps?.first { $0.pkg == pkg }
        return Button(intent: TVOpenApp(pkg: pkg)) {
            ZStack {
                Mint.banner
                if let logo = entry.logos[pkg] {
                    if app?.wide == true { Image(tv: logo).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill() }
                    else { Image(tv: logo).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit().padding(6) }
                } else { Text(app?.name ?? "").font(Mint.font(14, condensed: true)).widgetAccentable() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Mint.radius))
        }.buttonStyle(.plain).accessibilityLabel(app?.name ?? "App")
    }
}
struct TVAppsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TVApps", provider: TVProvider(logos: true)) { e in
            AppsBody(entry: e).foregroundStyle(Mint.text).containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("TV Apps")
        .description("Your four apps, opened on the TV with one tap.")
        .supportedFamilies([.systemMedium])
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
        TVPlayControl()
        TVPowerControl()
        TVRemoteControl()
    }
}
#endif
