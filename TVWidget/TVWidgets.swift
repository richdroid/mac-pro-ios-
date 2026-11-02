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
    var liveStatus: Bool { status != nil && reachable }
    var music: TVStatus.Music? { status?.music }
    var asleep: Bool { status?.screen == "asleep" }
    var fraction: Double {
        guard let m = music, m.duration > 0 else { return 0 }
        let t = m.playing ? m.position + date.timeIntervalSince1970 * 1000 - m.sampledAt : m.position
        return min(max(t / m.duration, 0), 1)
    }
    var remaining: TimeInterval { music.map { ($0.duration * (1 - fraction)) / 1000 } ?? 0 }
    var caption: String {
        if !liveStatus { return "Tailscale off?" }
        if asleep { return "TV asleep" }
        return music?.artist ?? ""
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
            if art, e.music?.playing == true {
                let steps = Int(min(e.remaining, 600) / 30)
                if steps > 0 { for i in 1...steps { var n = e; n.date = e.date.addingTimeInterval(Double(i) * 30); entries.append(n) } }
            }
            completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(e.music?.playing == true ? 600 : 1800))))
        }
    }
    func load() async -> TVEntry {
        var e = TVEntry()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-tv.json")
        if let d = await TVBridge.data(TVBridge.url("/api/tv/status")), let s = try? JSONDecoder().decode(TVStatus.self, from: d), s.online {
            e.status = s
            try? d.write(to: cache, options: .atomic)
        } else {
            e.reachable = false
            // Keep the last song on show rather than wiping it.
            if let d = try? Data(contentsOf: cache) { e.status = try? JSONDecoder().decode(TVStatus.self, from: d) }
        }
        if art, let url = e.music?.art, let d = await TVBridge.data(URL(string: url)), let i = Self.thumbnail(d, 320) { e.cover = i; e.wall = Self.shrunk(i, to: 16) }
        if mirror, e.reachable, !e.asleep, let d = await TVBridge.data(TVBridge.url("/api/tv/shot"), timeout: 15), let i = TVImage(data: d) { e.mirror = i }
        return e
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

// Behind every widget: the album art as a soft wall of colour, as on the TV's home screen.
struct WidgetWall: View {
    let image: TVImage?
    var body: some View {
        ZStack {
            Color(hex: 0x14181C)
            if let image {
                Color.clear.overlay { Image(tv: image).resizable().interpolation(.high).scaledToFill().blur(radius: 12).opacity(0.8) }.clipped()
                // Dark enough for white text, even over a white cover.
                LinearGradient(colors: [.black.opacity(0.32), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
            }
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
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.14), in: Circle())
            .contentShape(Circle())
            .widgetAccentable()
    }
}
struct RoundPlay: View {
    @Environment(\.widgetRenderingMode) private var mode
    let playing: Bool
    var size: CGFloat = 44
    var body: some View {
        Button(intent: TVPress(key: "play")) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(mode == .fullColor ? Color.black.opacity(0.85) : Color.white)
                .frame(width: size, height: size)
                .background(Color.white.opacity(mode == .fullColor ? 0.92 : 0.2), in: Circle())
                .widgetAccentable()
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
struct CoverView: View {
    let image: TVImage?
    var body: some View {
        ZStack {
            Color.white.opacity(0.1)
            if let image { Color.clear.overlay { Image(tv: image).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill() }.clipped() }
            else { Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary).widgetAccentable() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Playing
struct NowBody: View {
    let family: WidgetFamily
    let entry: TVEntry
    var title: String { entry.music?.title ?? "Nothing playing" }
    var playing: Bool { entry.music?.playing == true }
    // Transport only when it can do something: the TV is on and there's a song.
    var canPlay: Bool { entry.liveStatus && !entry.asleep && entry.music != nil }
    var body: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    CoverView(image: entry.cover).frame(width: 62, height: 62).shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    Spacer(minLength: 0)
                    if canPlay { RoundPlay(playing: playing) }
                    else if entry.liveStatus { WidgetPower() }
                }
                Spacer(minLength: 4)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).invalidatableContent()
                Text(entry.caption).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                if canPlay { ProgressLine(fraction: entry.fraction).padding(.top, 7) }
            }
            .padding(14)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                Text(entry.caption).font(.caption).lineLimit(1)
                ProgressView(value: entry.fraction).tint(.white)
            }
        default:
            HStack(spacing: 14) {
                CoverView(image: entry.cover).aspectRatio(1, contentMode: .fit).shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline).lineLimit(1).invalidatableContent()
                    Text(entry.caption).font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(1).padding(.top, 1)
                    if canPlay { ProgressLine(fraction: entry.fraction).padding(.top, 9) }
                    Spacer(minLength: 4)
                    if canPlay {
                        HStack {
                            WidgetKey(icon: "backward.fill", key: "previous", label: "Previous")
                            Spacer(minLength: 0)
                            RoundPlay(playing: playing, size: 48)
                            Spacer(minLength: 0)
                            WidgetKey(icon: "forward.fill", key: "next", label: "Next")
                        }
                    } else if entry.liveStatus {
                        // Asleep: the one useful thing to do is wake it.
                        HStack { Spacer(minLength: 0); WidgetPower(size: 48) }
                    }
                }
            }
            .padding(14)
        }
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
                    Button(intent: TVPress(key: "ok")) { Circle().fill(Color.white.opacity(0.9)).padding(5).frame(width: key, height: key).contentShape(Circle()).widgetAccentable() }.buttonStyle(.plain).accessibilityLabel("Select")
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
            GridRow { WidgetKey(icon: "gobackward.10", key: "rewind", label: "Rewind", size: key); WidgetKey(icon: "playpause.fill", key: "play", label: "Play or pause", size: key); WidgetKey(icon: "goforward.10", key: "forward", label: "Fast forward", size: key) }
        }
    }
}
struct RemoteBody: View {
    let family: WidgetFamily
    let entry: TVEntry
    @Environment(\.widgetRenderingMode) private var mode
    var screenName: String {
        guard entry.liveStatus, let s = entry.status else { return "Tailscale off?" }
        if s.screen == "asleep" { return "TV asleep" }
        let name = s.apps?.first { $0.pkg == s.app }?.name ?? "Home"
        // The picture is from the last refresh, so say when that was.
        return entry.mirror == nil ? name : "\(name) · \(entry.date.formatted(date: .omitted, time: .shortened))"
    }
    var body: some View {
        if family == .systemLarge {
            VStack(spacing: 12) {
                // The TV's own picture. Every press refreshes it.
                ZStack(alignment: .bottomLeading) {
                    (mode == .fullColor ? Color.black : Color.white.opacity(0.1))
                    if let m = entry.mirror {
                        Image(tv: m).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(systemName: entry.asleep ? "moon.zzz" : "tv").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.45)).frame(maxWidth: .infinity, maxHeight: .infinity).widgetAccentable()
                    }
                    Text(screenName).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(mode == .fullColor ? Color.black.opacity(0.55) : Color.white.opacity(0.14), in: Capsule()).padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack { RemoteKeys(); Spacer(minLength: 0); Pad(side: 132) }
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
    var body: some View { RemoteBody(family: family, entry: entry).foregroundStyle(.white).containerBackground(for: .widget) { Color(hex: 0x14181C) }.widgetURL(URL(string: "tvremoteapp://tab/0")) }
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
    var uptime: String {
        let u = Int(info?.uptime ?? 0), d = u / 86400, h = u / 3600 % 24, m = u / 60 % 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    var state: String { !reachable ? "Can’t reach it" : screen == "asleep" ? "Asleep" : screen == "screensaver" ? "Screensaver" : screen == "on" ? "Awake" : "Online" }
    var dot: Color { !reachable ? .orange : screen == "on" || screen == "screensaver" ? .green : .gray }
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
        Task { completion(Timeline(entries: [await load()], policy: .after(Date().addingTimeInterval(15 * 60)))) }
    }
    func load() async -> TVBoxEntry {
        var e = TVBoxEntry()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let infoFile = caches.appendingPathComponent("widget-box.json"), photoFile = caches.appendingPathComponent("widget-box.png")
        if let d = await TVBridge.data(TVBridge.url("/api/tv/device"), timeout: 12), let i = try? JSONDecoder().decode(TVBoxInfo.self, from: d) {
            e.info = i; e.reachable = true
            try? JSONEncoder().encode(i).write(to: infoFile, options: .atomic)
        } else if let d = try? Data(contentsOf: infoFile) {
            e.info = try? JSONDecoder().decode(TVBoxInfo.self, from: d)
        }
        if let d = await TVBridge.data(TVBridge.url("/api/tv/status"), timeout: 8), let s = try? JSONDecoder().decode(TVStatus.self, from: d) { e.screen = s.screen ?? "" }
        if !FileManager.default.fileExists(atPath: photoFile.path), let d = await TVBridge.data(TVBridge.url("/api/tv/device-image"), timeout: 12) { try? d.write(to: photoFile, options: .atomic) }
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
        .frame(height: 5)
    }
}
struct BoxRow: View {
    let label: String, text: String
    var value: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                Spacer(minLength: 4)
                Text(text).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            }
            if let value { BoxBar(value: value) }
        }
    }
}
struct TVBoxBody: View {
    let family: WidgetFamily
    let entry: TVBoxEntry
    var photo: some View {
        Group {
            if let p = entry.photo { Image(tv: p).resizable().scaledToFit() }
            else { Image(systemName: "av.remote").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.7)) }
        }
    }
    var state: some View {
        HStack(spacing: 5) {
            Circle().fill(entry.dot).frame(width: 8, height: 8)
            Text(entry.state).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
    var body: some View {
        if entry.info == nil {
            VStack(alignment: .leading, spacing: 6) {
                photo.frame(height: 44)
                Text("TV box").font(.system(size: 14, weight: .semibold))
                Text("Tailscale off?").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if family == .systemSmall {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    photo.frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        state
                        Text("Up \(entry.uptime)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    }
                }
                Spacer(minLength: 0)
                BoxRow(label: "Memory", text: "\(Int((entry.memory * 100).rounded()))%", value: entry.memory)
                BoxRow(label: "Storage", text: "\(Int((entry.storage * 100).rounded()))%", value: entry.storage)
            }
            .padding(16)
        } else {
            HStack(spacing: 14) {
                VStack(spacing: 4) {
                    photo.frame(width: 88, height: 74)
                    state
                    Text("Up \(entry.uptime)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
                .frame(width: 96)
                VStack(alignment: .leading, spacing: 6) {
                    BoxRow(label: "CPU", text: "\(Int(entry.info?.cpu ?? 0))%", value: (entry.info?.cpu ?? 0) / 100)
                    BoxRow(label: "Memory", text: "\(Int((entry.memory * 100).rounded()))%", value: entry.memory)
                    BoxRow(label: "Storage", text: "\(Int((entry.storage * 100).rounded()))%", value: entry.storage)
                    BoxRow(label: "Temperature", text: "\(entry.fahrenheit)°F")
                }
            }
            .padding(16)
        }
    }
}
struct TVBoxWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TVBoxEntry
    var body: some View {
        TVBoxBody(family: family, entry: entry).foregroundStyle(.white).containerBackground(for: .widget) { Color(hex: 0x14181C) }.widgetURL(URL(string: "tvremoteapp://tab/5"))
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
        return Timeline(entries: [e], policy: .after(Date().addingTimeInterval(e.reachable && !e.logos.isEmpty ? 6 * 3600 : 900)))
    }
    func load(_ c: TVAppsConfig) async -> TVEntry {
        var e = TVEntry()
        e.status = await TVBridge.status()
        e.reachable = e.status != nil
        let names = e.status?.apps
        e.chosen = c.picks().map { pkg in TVAppEntity(id: pkg, name: names?.first { $0.pkg == pkg }?.name ?? "") }
        guard e.reachable else { return e }
        // All at once, and from the cache when possible: logos almost never change.
        let logos = await withTaskGroup(of: (String, TVImage?).self) { group -> [String: TVImage] in
            for pkg in c.picks() {
                group.addTask {
                    let d = await TVBridge.data(TVBridge.url("/api/tv/icon?pkg=\(pkg)&v=2"), timeout: 6, cached: true)
                    return (pkg, d.flatMap { TVProvider.thumbnail($0, 320) })
                }
            }
            var out: [String: TVImage] = [:]
            for await (pkg, i) in group { if let i { out[pkg] = i } }
            return out
        }
        e.logos = logos
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
                    Image(tv: logo).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
                } else {
                    VStack(spacing: 2) {
                        if let logo = entry.logos[pkg] { Image(tv: logo).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFit().frame(width: h * 0.42, height: h * 0.42) }
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
            AppsBody(entry: e).foregroundStyle(.white).containerBackground(for: .widget) { Color(hex: 0x14181C) }.widgetURL(URL(string: "tvremoteapp://tab/1"))
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
