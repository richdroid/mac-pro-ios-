import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Mint and Stremio, pared down: what they already show, on the phone, ready to flick to the TV.
struct MediaItem: Decodable, Identifiable, Hashable {
    let title: String, subtitle: String, art: String, id: String, kind: String
    var about: String?
    var progress: Double?
    var slug: String?
}
struct MediaRow: Decodable, Identifiable, Hashable {
    let title: String, items: [MediaItem]
    var id: String { title }
}
enum MediaSource: String, CaseIterable, Identifiable {
    case mint, stremio
    var id: String { rawValue }
    var name: String { self == .mint ? "Mint Music" : "Stremio" }
    var pkg: String { self == .mint ? "com.codex.musicwebtv" : "com.stremio.one" }
    static func of(pkg: String) -> MediaSource? { allCases.first { $0.pkg == pkg } }
    var prompt: String { self == .mint ? "Search music" : "Search films and series" }
    var coverAspect: CGFloat { self == .mint ? 1 : 2.0 / 3 }
    // Each app's own colour, for the page behind it.
    var mood: Color { self == .mint ? Color(hex: 0x1F9E78) : Color(hex: 0x6A3FD0) }
    var cardWidth: CGFloat { self == .mint ? 150 : 124 }
    func endpoint(_ q: String) -> String {
        let term = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "/api/tv/\(rawValue)" + (q.isEmpty ? "" : "?q=\(term)")
    }
}

@MainActor
final class BrowseStore: ObservableObject {
    let source: MediaSource
    // A different list to ask for than the app's own, like films or shows to pick from, and a genre to narrow it.
    let base: String?
    @Published var genre = ""
    @Published var rows: [MediaRow] = []
    @Published var query = ""
    @Published var loading = false
    @Published var failed = false
    private var loadedFor: String?
    private var inFlight: String?
    private var generation = 0
    private var loadedAt = Date.distantPast
    private static var stores: [MediaSource: BrowseStore] = [:]
    // One for each app, so going back in shows what was there straight away.
    static func shared(_ source: MediaSource) -> BrowseStore {
        if let s = stores[source] { return s }
        let s = BrowseStore(source); stores[source] = s; return s
    }
    // The Watch tab's films and shows, kept for the app's life, so its search and genre are still there when he's back.
    private static var discovering: [String: BrowseStore] = [:]
    static func discover(_ type: String) -> BrowseStore {
        if let s = discovering[type] { return s }
        let s = BrowseStore(.stremio, base: "/api/tv/discover?type=\(type)"); discovering[type] = s; return s
    }
    private var searching: Task<Void, Never>?
    init(_ source: MediaSource, base: String? = nil) { self.source = source; self.base = base }
    func endpoint(_ q: String) -> String {
        guard let base else { return source.endpoint(q) }
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        return base + (q.isEmpty ? "" : "&q=" + enc(q)) + (genre.isEmpty ? "" : "&genre=" + enc(genre))
    }
    func load(force: Bool = false) async {
        let q = query.trimmingCharacters(in: .whitespaces) + (genre.isEmpty ? "" : "\u{1}" + genre)
        // Recent enough to skip, though what's on the TV moves on, so never for long.
        if !force && loadedFor == q && !rows.isEmpty && Date().timeIntervalSince(loadedAt) < 60 { return }
        struct Answer: Decodable { let rows: [MediaRow] }
        // Unfolded, both sides ask at once.
        if inFlight == q && !force { return }
        inFlight = q
        generation += 1
        let mine = generation
        loading = true; failed = false
        // Only the newest request gets to say it has finished.
        defer { if mine == generation { loading = false; inFlight = nil } }
        // Its own task, so unfolding, which replaces the view that asked, doesn't cancel it for the view that's waiting.
        let address = TVBridge.url(endpoint(query.trimmingCharacters(in: .whitespaces)))
        let data = await Task { await TVBridge.data(address, timeout: 20) }.value
        // A slower, older search must not replace a newer one.
        guard q == query.trimmingCharacters(in: .whitespaces) + (genre.isEmpty ? "" : "\u{1}" + genre) else { return }
        guard let data, let a = try? JSONDecoder().decode(Answer.self, from: data) else {
            // Results for some other search aren't an answer to this one.
            if loadedFor != q { rows = []; loadedFor = nil }
            failed = rows.isEmpty
            return
        }
        rows = base == nil ? a.rows : Self.fold(a.rows); loadedFor = q; loadedAt = Date()
    }
    // A shelf of only a few is never shown on its own: its cards go to the front of the full row before it (else the
    // one after), with nothing twice. Continue watching is his own, however short.
    static func fold(_ rows: [MediaRow]) -> [MediaRow] {
        func full(_ r: MediaRow) -> Bool { r.items.count >= 8 }
        func key(_ i: MediaItem) -> String { i.stremioRef?.imdb ?? i.id }
        var out: [MediaRow] = [], waiting: [MediaItem] = []
        func merge(_ few: [MediaItem], into r: MediaRow) -> MediaRow {
            var seen = Set<String>()
            return MediaRow(title: r.title, items: (few + r.items).filter { seen.insert(key($0)).inserted })
        }
        for r in rows {
            if r.title == "Continue watching" || full(r) {
                out.append(waiting.isEmpty || r.title == "Continue watching" ? r : merge(waiting, into: r))
                if r.title != "Continue watching" { waiting = [] }
            } else if let i = out.lastIndex(where: { $0.title != "Continue watching" && full($0) }) {
                out[i] = merge(r.items, into: out[i])
            } else { waiting += r.items }
        }
        return out
    }
    func searchSoon() {
        searching?.cancel()
        searching = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { await self?.load() }
        }
    }
}

extension MediaItem {
    // What's worth reading under the title: no service, no kind, no "Continue".
    var shownSubtitle: String { Wording.subtitle(subtitle) }
}

// The item as Mint draws it: a cover over a solid band tinted from that cover.
struct MediaCard: View {
    let item: MediaItem
    let source: MediaSource
    var width: CGFloat
    var image: Image?   // for a song on this phone, whose cover has no address
    // Room for a title on two lines and the line under it, the same on every card, so a row's cards stay even.
    static func band(_ width: CGFloat) -> CGFloat { width > 200 ? 82 : 62 }
    static func height(_ width: CGFloat, _ source: MediaSource) -> CGFloat { width / source.coverAspect + band(width) }
    @State private var band: Color?
    // A cover seen before has its colour ready, so the card arrives already tinted rather than fading in.
    var shownBand: Color { band ?? ImageStore.shared.cachedBand(URL(string: item.art)) ?? Color(hex: 0x37474F) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image { image.resizable().scaledToFill() }
                else { Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color(hex: 0x37474F) } }
            }
                .frame(width: width, height: width / source.coverAspect)
                .clipped()
                .overlay(alignment: .bottom) {
                    // How far through it you are, as on the TV's own cards.
                    if let p = item.progress, p > 0 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Color.white.opacity(0.25)
                                TVLook.accent.frame(width: g.size.width * min(p, 1))
                            }
                        }.frame(height: 3)
                    }
                }
            // The whole title, on two lines if it needs them, rather than cut short.
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: width > 200 ? 18 : 14)).lineLimit(2).multilineTextAlignment(.leading)
                let under = item.shownSubtitle
                if !under.isEmpty { Text(under).font(.system(size: width > 200 ? 14 : 11.5)).foregroundStyle(.white.opacity(0.72)).lineLimit(1) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, width > 200 ? 14 : 10)
            .padding(.top, width > 200 ? 10 : 7)
            .frame(width: width, height: Self.band(width), alignment: .topLeading)
            .background(shownBand)
        }
        .clipShape(RoundedRectangle(cornerRadius: width > 200 ? 8 : 6, style: .continuous))
        .task(id: item.art) {
            if let u = URL(string: item.art), ImageStore.shared.cachedBand(u) == nil, let c = await ImageStore.shared.band(u) { band = c }
        }
        .animation(.easeOut(duration: 0.25), value: band)
    }
}

// A whole row as a list. Tapping an item opens the same flick sheet as its card.
struct MediaList: View {
    @EnvironmentObject var model: TVModel
    let row: MediaRow
    let source: MediaSource
    var body: some View {
        RowList(title: row.title) {
            ForEach(row.items) { item in
                Button { model.flick(FlickTarget(item: item, source: source)) } label: {
                    HStack(spacing: 12) {
                        Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                            .frame(width: 50, height: 50 / source.coverAspect).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body.weight(.semibold)).lineLimit(2)
                            if !item.shownSubtitle.isEmpty { Text(item.shownSubtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.shownSubtitle.isEmpty ? item.title : "\(item.title), \(item.shownSubtitle)")
            }
        }
    }
}

struct BrowseColumn: View {
    enum Part { case all, left, right }
    @EnvironmentObject var model: TVModel
    @ObservedObject var store: BrowseStore
    var part = Part.all
    // Unfolded, the rows take turns on each side of the fold.
    var shown: [MediaRow] {
        part == .all ? store.rows : store.rows.enumerated().filter { ($0.offset % 2 == 0) == (part == .left) }.map(\.element)
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if part != .right { HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(store.source.prompt, text: $store.query).autocorrectionDisabled().submitLabel(.search)
                        .onChange(of: store.query) { _, _ in store.searchSoon() }
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 16).frame(height: 46)
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 20) }
                if store.rows.isEmpty && part != .right {
                    Group {
                        if store.loading { VStack(spacing: 22) { ForEach(0..<3, id: \.self) { _ in PlaceholderShelf() } } }
                        else if store.failed { ContentUnavailableView("Can’t reach \(store.source.name)", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again.")) }
                        else { ContentUnavailableView.search }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(shown) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        RowHeader(title: row.title, route: .media(row, store.source)).padding(.leading, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 10) {
                                ForEach(row.items) { item in FlickCardButton(item: item, source: store.source, width: store.source.cardWidth) }
                            }
                            .padding(.horizontal, 20)
                        }
                        .rowEdge()
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 12)
        }
        .restsOnRows()
        .refreshable { await store.load(force: true) }
        .task { await store.load() }
    }
}

// Every card in a row, wherever it is: a press already asks for its streams, and the flick knows the tile it came
// from, so a card put back lands on it.
struct FlickCardButton: View {
    @EnvironmentObject var model: TVModel
    let item: MediaItem
    let source: MediaSource
    let width: CGFloat
    var ready = false
    // Where the tile is, kept without redrawing anything while the row scrolls.
    @State private var place = FrameBox()
    var body: some View {
        Button { model.flick(FlickTarget(item: item, source: source, ready: ready, origin: place.rect)) } label: { MediaCard(item: item, source: source, width: width) }
            // A sleeping box takes seconds to bring Stremio up, so it's told the moment a finger lands, not at the throw.
            .buttonStyle(PressCard(onPress: source == .stremio ? { StreamCache.shared.prefetch(item); Prepare.arm() } : nil))
            // Outside the press's own squeeze, so the measure never moves with what it measures.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { place.rect = $0 }
            .accessibilityLabel(item.shownSubtitle.isEmpty ? item.title : "\(item.title), \(item.shownSubtitle)")
    }
}
final class FrameBox { var rect: CGRect? }

// A row of cards that scrolls sideways. On the outer screen it runs on under the glass side bar to the screen's edge,
// as every row does there; unfolded, it stops at its own pane, fading out at the pane's edge rather than cut square,
// and fading in at the start too once it's been scrolled.
private struct RowEdge: ViewModifier {
    @Environment(\.paneLayout) private var panes
    @State private var scrolled = false
    func body(content: Content) -> some View {
        if panes {
            content
                .scrollTargetBehavior(FreeScroll())
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x > 4 } action: { _, s in scrolled = s }
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(scrolled ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                    }
                    // Only the fade eases, so nothing in the row animates with it.
                    .animation(.easeOut(duration: 0.2), value: scrolled)
                }
        } else { content.scrollTargetBehavior(FreeScroll()) }
    }
}
extension View { func rowEdge() -> some View { modifier(RowEdge()) } }
// Sideways rows glide and stop where the finger leaves them, whatever the page around them snaps to.
struct FreeScroll: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {}
}
// Up and down, a page of rows comes to rest with a row's heading at the top, never half under the bar.
extension View {
    func restsOnRows() -> some View { scrollTargetBehavior(.viewAligned(limitBehavior: .never)) }
}

// Stremio and Mint searched together, from the bar on the Apps page. Every result flicks like a card on its own page.
struct EverywhereSearch: View {
    @EnvironmentObject var model: TVModel
    let text: String
    @StateObject private var films = BrowseStore(.stremio)
    @StateObject private var music = BrowseStore(.mint)
    var stores: [BrowseStore] { [films, music] }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(stores, id: \.source) { store in
                ForEach(store.rows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(row.title).font(.title3.weight(.bold))
                            Text(store.source.name).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 10) {
                                ForEach(row.items) { item in FlickCardButton(item: item, source: store.source, width: store.source.cardWidth) }
                            }
                            .padding(.horizontal, 20)
                        }
                        .rowEdge()
                    }
                    .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            if films.rows.isEmpty && music.rows.isEmpty {
                Group {
                    if films.loading || music.loading { ProgressView() }
                    else { ContentUnavailableView.search(text: text) }
                }
                .frame(maxWidth: .infinity).padding(.top, 30)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: films.rows.map(\.id) + music.rows.map(\.id))
        .onChange(of: text, initial: true) { _, t in
            for s in stores { s.query = t; s.searchSoon() }
        }
    }
}
