import SwiftUI
import WidgetKit
import Security

// Continue watching, from what he played on this iPhone with Play on iPhone: the last title (or, wider, the last few),
// how far through it he is, and a tap that opens its picker in the app with Resume ready. The app writes the list to
// the Keychain group the two share (PhoneSystem.share in StremioSystem.swift); names, posters and places only.

struct PhoneShelfEntry: TimelineEntry {
    struct Item { var type, imdb, video, name, line: String; var progress, left: Double; var poster: TVImage? }
    var date = Date()
    var items: [Item] = []
}

struct PhoneShelfProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhoneShelfEntry { Self.sample }
    func getSnapshot(in context: Context, completion: @escaping (PhoneShelfEntry) -> Void) {
        if context.isPreview { completion(Self.sample); return }
        Task { completion(await load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PhoneShelfEntry>) -> Void) {
        Task { completion(Timeline(entries: [await load()], policy: .after(Date().addingTimeInterval(3600)))) }
    }
    static let sample = PhoneShelfEntry(items: [.init(type: "movie", imdb: "tt0000001", video: "tt0000001", name: "A Film", line: "", progress: 0.4, left: 3600, poster: nil)])
    static func read() -> [[String: Any]] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.macpro.TV.phoneShelf",
                                kSecAttrAccount as String: "recents", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if let g = SavedAddress.sharedGroup { q[kSecAttrAccessGroup as String] = g }
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let l = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return l
    }
    func load() async -> PhoneShelfEntry {
        var items: [PhoneShelfEntry.Item] = []
        for r in Self.read().prefix(3) {
            var poster: TVImage?
            if let s = r["poster"] as? String, let u = URL(string: s), s.hasPrefix("http"),
               let d = try? await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 6)).0 { poster = ImageStore.decode(d, maxPixels: 240) }
            items.append(.init(type: r["type"] as? String ?? "movie", imdb: r["imdb"] as? String ?? "", video: r["video"] as? String ?? "",
                               name: r["name"] as? String ?? "", line: r["line"] as? String ?? "", progress: r["progress"] as? Double ?? 0,
                               left: r["left"] as? Double ?? 0, poster: poster))
        }
        return PhoneShelfEntry(items: items)
    }
}

struct PhoneShelfView: View {
    let entry: PhoneShelfEntry
    @Environment(\.widgetFamily) private var family
    static func link(_ i: PhoneShelfEntry.Item) -> URL? {
        var c = URLComponents(); c.scheme = "tvremoteapp"; c.host = "phone"
        c.queryItems = [.init(name: "type", value: i.type), .init(name: "id", value: i.imdb), .init(name: "video", value: i.video), .init(name: "name", value: i.name)]
        return c.url
    }
    static func left(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min left" : "\(max(m, 1)) min left"
    }
    var body: some View {
        Group {
            if entry.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "play.rectangle").font(.title2).foregroundStyle(TVLook.accent)
                    Text("Nothing played on this iPhone yet").font(.subheadline.weight(.semibold))
                    Text("Play on iPhone from any film or show.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if family == .systemSmall, let i = entry.items.first {
                tile(i, big: true).widgetURL(Self.link(i))
            } else {
                HStack(spacing: 10) {
                    ForEach(Array(entry.items.prefix(family == .systemSmall ? 1 : 3).enumerated()), id: \.offset) { _, i in
                        Link(destination: Self.link(i) ?? URL(string: "tvremoteapp://")!) { tile(i, big: false) }
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }
    func tile(_ i: PhoneShelfEntry.Item, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottom) {
                Color.white.opacity(0.1)
                if let p = i.poster { Image(tv: p).resizable().scaledToFill() } else { Image(systemName: "film").foregroundStyle(.white.opacity(0.5)) }
                GeometryReader { g in
                    ZStack(alignment: .leading) { Color.white.opacity(0.3); TVLook.accent.frame(width: g.size.width * min(max(i.progress, 0), 1)) }
                }
                .frame(height: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(i.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(i.left > 60 ? Self.left(i.left) : (i.line.isEmpty ? "Play on iPhone" : i.line)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct PhoneContinueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PhoneContinue", provider: PhoneShelfProvider()) { e in
            PhoneShelfView(entry: e).containerBackground(for: .widget) { TVGlass() }
        }
        .configurationDisplayName("Continue on iPhone")
        .description("What you were watching with Play on iPhone, from where you were.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
