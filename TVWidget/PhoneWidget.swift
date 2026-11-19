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
    // The CI sheet's family (ci/gallery-tv/PhoneSheets.swift): WidgetKit's own can't be set outside a widget.
    var sheetFamily: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var widgetFamily
    private var family: WidgetFamily { sheetFamily ?? widgetFamily }
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
                    Text(family == .systemSmall ? "Nothing played yet" : "Nothing played on this iPhone yet").font(.subheadline.weight(.semibold)).lineLimit(3).minimumScaleFactor(0.85)
                    Text("Play on iPhone from any film or show.").font(.caption).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if family == .systemSmall, let i = entry.items.first {
                tile(i, big: true).widgetURL(Self.link(i))
            } else {
                if entry.items.count == 1, let i = entry.items.first {
                    // One film: its poster at a poster's shape on the left, its name and time beside it, not two empty places.
                    Link(destination: Self.link(i) ?? URL(string: "tvremoteapp://")!) {
                        HStack(alignment: .top, spacing: 12) {
                            poster(i).aspectRatio(Self.shape(i), contentMode: .fit)
                            VStack(alignment: .leading, spacing: 4) {
                                WholeWords(text: i.name, axis: .vertical).font(.headline)
                                WholeWords(text: Self.status(i), axis: .horizontal).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    // Two share the width in halves; three in thirds.
                    HStack(spacing: 10) {
                        ForEach(Array(entry.items.prefix(3).enumerated()), id: \.offset) { _, i in
                            Link(destination: Self.link(i) ?? URL(string: "tvremoteapp://")!) { tile(i, big: false) }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }
    // A poster's shape, or a still's when the picture is wider than tall.
    static func shape(_ i: PhoneShelfEntry.Item) -> CGFloat {
        guard let s = i.poster?.size, s.height > 0, s.width > s.height else { return 2 / 3 }
        return 16 / 9
    }
    static func status(_ i: PhoneShelfEntry.Item) -> String { i.left > 60 ? left(i.left) : (i.line.isEmpty ? "Play on iPhone" : i.line) }
    func tile(_ i: PhoneShelfEntry.Item, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            poster(i)
            // One block of fixed height in every tile (two lines of name, one of time), top-aligned so the posters stay
            // level: the time sits right under the name, and a short name leaves its spare line below both.
            VStack(alignment: .leading, spacing: WholeWords<EmptyView>.gap) {
                Text("X\nX").font(.caption.weight(.semibold))
                Text("X").font(.caption2)
            }
            .hidden().frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                WholeWords(text: i.name, axis: .vertical) {
                    WholeWords(text: Self.status(i), axis: .horizontal).font(.caption2).foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
            }
        }
    }
    func poster(_ i: PhoneShelfEntry.Item) -> some View {
        // The poster fills the room the tile is given, never more: loose in the ZStack, a poster filled to the tile's
        // width came out taller than the tile and pushed its name and time off the bottom (a still, wider, ran into
        // the tile beside it). Cropped from the top down, so a poster's title and faces stay in.
        ZStack(alignment: .bottom) {
            Color.white.opacity(0.1)
                .overlay(alignment: .top) { if let p = i.poster { Image(tv: p).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill() } }
                .overlay { if i.poster == nil { Image(systemName: "film").foregroundStyle(.white.opacity(0.5)) } }
                .clipped()
            GeometryReader { g in
                ZStack(alignment: .leading) { Color.white.opacity(0.3); TVLook.accent.frame(width: g.size.width * min(max(i.progress, 0), 1)) }
            }
            .frame(height: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// Words never cut and no ellipsis in a widget (the 11-12 ruling): the longest run of whole words, from the start, that fits.
// Horizontal: one line. Vertical: wrapped onto as many lines as the height allows. A run never ends on "of", "the",
// "by", "a" or "and", so no lone article; the first content word, if even that is too long, shrinks rather than being cut.
// Anything given as `below` (a tile's time) sits right under whichever run is chosen, and counts toward its fit.
struct WholeWords<Below: View>: View {
    let text: String
    let axis: Axis.Set
    let below: Below
    static var gap: CGFloat { 2 }
    init(text: String, axis: Axis.Set, @ViewBuilder below: () -> Below) { self.text = text; self.axis = axis; self.below = below() }
    static var joiners: Set<String> { ["of", "the", "by", "a", "and"] }
    static func runs(_ text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        var runs: [String] = []
        for n in (1...max(words.count, 1)).reversed() where !words.isEmpty {
            var w = Array(words.prefix(n))
            if n < words.count { while let l = w.last, joiners.contains(l.lowercased()) { w.removeLast() } }
            let r = w.joined(separator: " ")
            if !r.isEmpty, runs.last != r { runs.append(r) }
        }
        return runs.isEmpty ? [text] : runs
    }
    var body: some View {
        let runs = Self.runs(text)
        ViewThatFits(in: axis) {
            ForEach(Array(runs.dropLast().enumerated()), id: \.offset) { _, r in
                if axis == .horizontal { Text(r).lineLimit(1).fixedSize() } else {
                    VStack(alignment: .leading, spacing: Self.gap) { Text(r).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true); below }
                }
            }
            // The last resort: one line across, or two lines down at full size; it shrinks only when a single word is
            // wider than the room.
            if axis == .horizontal { Text(runs.last ?? text).lineLimit(1).minimumScaleFactor(0.5) } else {
                VStack(alignment: .leading, spacing: Self.gap) { Text(runs.last ?? text).multilineTextAlignment(.leading).lineLimit(2).minimumScaleFactor(0.5); below }
            }
        }
    }
}
extension WholeWords where Below == EmptyView {
    init(text: String, axis: Axis.Set) { self.init(text: text, axis: axis) { EmptyView() } }
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
