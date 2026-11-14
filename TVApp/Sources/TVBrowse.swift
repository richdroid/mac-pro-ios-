import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Mint and Stremio, pared down: what they already show, on the phone, ready to flick to the TV.
struct MediaItem: Codable, Identifiable, Hashable {
    let title: String, subtitle: String, art: String, id: String, kind: String
    var about: String?
    var progress: Double?
    var slug: String?
    // A YouTube video (kind "youtube", id its video id): the second to start it from, where he left off on the TV.
    var resume: Int?
    var isYouTube: Bool { kind == "youtube" }
}
struct MediaRow: Codable, Identifiable, Hashable {
    let title: String, items: [MediaItem]
    var id: String { title }
}
enum MediaSource: String, CaseIterable, Identifiable {
    case mint, stremio
    var id: String { rawValue }
    var name: String { self == .mint ? "Mint Music" : "Stremio" }
    var pkg: String { self == .mint ? "com.codex.musicwebtv" : "com.stremio.one" }
    static func of(pkg: String) -> MediaSource? { allCases.first { $0.pkg == pkg } }
    var coverAspect: CGFloat { self == .mint ? 1 : 2.0 / 3 }
    // Each app's own colour, for the page behind it.
    var mood: Color { self == .mint ? Color(hex: 0x1F9E78) : Color(hex: 0x6A3FD0) }
    var cardWidth: CGFloat { self == .mint ? 150 : 124 }
    func endpoint(_ q: String) -> String {
        let term = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        // Stremio's home is asked for with YouTube's unfinished videos in Continue watching: only a build that can open
        // a YouTube card asks (yt=1), so the Mac never hands an older one a card it would throw at Stremio.
        return "/api/tv/\(rawValue)" + (q.isEmpty ? (self == .stremio ? "?yt=1" : "") : "?q=\(term)")
    }
}

// What a list request answers.
private struct BrowseAnswer: Decodable { let rows: [MediaRow] }

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
        let s = BrowseStore(source, kept: "home-" + source.rawValue); stores[source] = s; return s
    }
    // The Watch tab's films and shows, kept for the app's life, so its search and genre are still there when he's back.
    private static var discovering: [String: BrowseStore] = [:]
    static func discover(_ type: String) -> BrowseStore {
        if let s = discovering[type] { return s }
        let s = BrowseStore(.stremio, base: "/api/tv/discover?type=\(type)", kept: "discover-" + type); discovering[type] = s; return s
    }
    private var searching: Task<Void, Never>?
    // The rows only if they're the answer to what's asked now: a search never shows the last search's rows, or the
    // recently played it started from (r17: "I typed Heat and it showed me albums").
    var answerRows: [MediaRow] {
        loadedFor == query.trimmingCharacters(in: .whitespaces) + (genre.isEmpty ? "" : "\u{1}" + genre) ? rows : []
    }
    // Whether this text has had its answer, rows or none, rather than merely not loading at this instant (a search waits
    // a moment before it starts, and read as answered in that gap).
    func answered(_ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespaces) + (genre.isEmpty ? "" : "\u{1}" + genre)
        return loadedFor == q || (failed && !loading && query.trimmingCharacters(in: .whitespaces) == text.trimmingCharacters(in: .whitespaces))
    }
    // What a search's one list is called here ("Films", "Shows"), where the Mac's own name for it ("Results") says
    // nothing beside another kind's.
    let found: String?
    // The list as it last came (no search, no genre), kept on the phone under this name: a launch shows it at once and
    // the Mac's fresh answer replaces it when it comes, so Watch, Continue watching and Mint's rows never open empty or
    // wait on the Mac (its first answer of a session took 6.3 s on 2026-11-10; the rows sat as grey shapes for all of it).
    let kept: String?
    private var fromDisk = false
    // When the kept list was last fresh, once the Mac has failed to give a newer one: the pages dim it and say so.
    @Published private(set) var keptSince: Date?
    private var keptDate: Date?
    // Since when asking has failed. The kept list dims and says when it was last seen only once that has gone on about
    // 25 s, as the app's other reach words do: until then it stays at full strength (a blip leaves no trace).
    // A miss long after the last one starts the clock again: two blips minutes apart are not 25 s of failure.
    private var missSince: Date?, lastMiss: Date?
    private func stillMissing() -> Bool {
        let now = Date()
        if missSince == nil || now.timeIntervalSince(lastMiss ?? now) > 60 { missSince = now }
        lastMiss = now
        return now.timeIntervalSince(missSince!) >= TVModel.unreachableAfter
    }
    private static func keptFile(_ name: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tv-rows-\(name).json")
    }
    init(_ source: MediaSource, base: String? = nil, found: String? = nil, kept: String? = nil) {
        self.source = source; self.base = base; self.found = found; self.kept = kept
        // Not for the build's sample Mac, whose scenes each expect to start from nothing.
        guard let kept, let file = Self.keptFile(kept), !["127.0.0.1", "localhost"].contains(where: { TVBridge.address.contains($0) }) else { return }
        let folds = base != nil
        Task { [weak self] in
            let disk: (rows: [MediaRow], at: Date?)? = await Task.detached(priority: .userInitiated) {
                guard let d = try? Data(contentsOf: file), let a = try? JSONDecoder().decode(BrowseAnswer.self, from: d) else { return nil }
                let at = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
                return (folds ? Self.fold(Self.once(a.rows)) : a.rows, at)
            }.value
            // Only if nothing has come meanwhile, and nothing is being searched.
            guard let self, let rows = disk?.rows, !rows.isEmpty, self.rows.isEmpty, self.loadedFor == nil, self.query.isEmpty, self.genre.isEmpty else { return }
            self.fromDisk = true
            self.keptDate = disk?.at
            if self.failed { self.failed = false }
            self.rows = rows
        }
    }
    private func keep(_ data: Data?) {
        guard let kept, let data, let file = Self.keptFile(kept), !["127.0.0.1", "localhost"].contains(where: { TVBridge.address.contains($0) }) else { return }
        Task.detached(priority: .utility) { try? data.write(to: file, options: .atomic) }
    }
    func endpoint(_ q: String) -> String {
        guard let base else { return source.endpoint(q) }
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        return base + "&yt=1" + (q.isEmpty ? "" : "&q=" + enc(q)) + (genre.isEmpty ? "" : "&genre=" + enc(genre))
    }
    func load(force: Bool = false) async {
        let q = query.trimmingCharacters(in: .whitespaces) + (genre.isEmpty ? "" : "\u{1}" + genre)
        // Recent enough to skip, though what's on the TV moves on, so never for long.
        if !force && loadedFor == q && !rows.isEmpty && Date().timeIntervalSince(loadedAt) < 60 { return }
        // Unfolded, both sides ask at once.
        if inFlight == q && !force { return }
        inFlight = q
        generation += 1
        let mine = generation
        // Set only when they change: every assignment redraws every shelf that watches this store.
        if !loading { loading = true }
        if failed { failed = false }
        // Only the newest request gets to say it has finished.
        defer { if mine == generation { if loading { loading = false }; inFlight = nil } }
        // Its own task, so unfolding, which replaces the view that asked, doesn't cancel it for the view that's waiting.
        let address = TVBridge.url(endpoint(query.trimmingCharacters(in: .whitespaces)))
        let data = await Task { await TVBridge.data(address, timeout: 20) }.value
        // A slower, older search must not replace a newer one.
        guard q == query.trimmingCharacters(in: .whitespaces) + (genre.isEmpty ? "" : "\u{1}" + genre) else { return }
        // Decoded and folded off the main thread: a big list took a noticeable bite out of scrolling.
        // A search's answer is shown as it came: folding is for the catalogue's shelves.
        let folds = base != nil && query.trimmingCharacters(in: .whitespaces).isEmpty, name = found
        let decoded: [MediaRow]? = await Task.detached(priority: .userInitiated) {
            guard let data, let a = try? JSONDecoder().decode(BrowseAnswer.self, from: data) else { return nil }
            if let name, a.rows.count == 1 { return a.rows[0].items.isEmpty ? [] : [MediaRow(title: name, items: a.rows[0].items)] }
            return folds ? Self.fold(Self.once(a.rows)) : a.rows.filter { !$0.items.isEmpty }
        }.value
        guard q == query.trimmingCharacters(in: .whitespaces) + (genre.isEmpty ? "" : "\u{1}" + genre) else { return }
        guard let decoded else {
            // Results for some other search aren't an answer to this one.
            // (The list kept from last time stays while the Mac can't be asked for a fresh one.)
            if loadedFor != q, !(fromDisk && q.isEmpty) { if !rows.isEmpty { rows = [] }; loadedFor = nil }
            if fromDisk, q.isEmpty, stillMissing(), keptSince != keptDate { keptSince = keptDate }
            if failed != rows.isEmpty { failed = rows.isEmpty }
            return
        }
        // The same list again (a revisit after a minute) changes nothing on screen, so it isn't set again.
        if decoded != rows { rows = decoded }
        loadedFor = q; loadedAt = Date(); fromDisk = false; missSince = nil
        if keptSince != nil { keptSince = nil }
        if q.isEmpty, !decoded.isEmpty { keep(data) }
    }
    // Stremio's home for Continue watching: one request that every asker waits on, rather than two panes' loads cancelling
    // each other's bookkeeping through the search guards (r27, open: the row stayed four grey boxes). Applied whenever no
    // search or genre is up. The mock is told by the row itself once it's on screen (DiscoverColumn), not from here.
    private var homeTask: Task<[MediaRow]?, Never>?
    func loadHome() async {
        if !rows.isEmpty && loadedFor == "" && Date().timeIntervalSince(loadedAt) < 60 { return }
        let task = homeTask ?? Task {
            let data = await TVBridge.data(TVBridge.url(source.endpoint("")), timeout: 20)
            let rows = await Task.detached(priority: .userInitiated) { () -> [MediaRow]? in
                guard let data, let a = try? JSONDecoder().decode(BrowseAnswer.self, from: data) else { return nil }
                return a.rows
            }.value
            if rows?.isEmpty == false { self.keep(data) }
            return rows
        }
        homeTask = task
        let decoded = await task.value
        if homeTask == task { homeTask = nil }
        guard query.trimmingCharacters(in: .whitespaces).isEmpty && genre.isEmpty else { return }
        guard let decoded else {
            if failed != rows.isEmpty { failed = rows.isEmpty }
            if fromDisk, stillMissing(), keptSince != keptDate { keptSince = keptDate }
            return
        }
        if failed { failed = false }
        if decoded != rows { rows = decoded }
        loadedFor = ""; loadedAt = Date(); fromDisk = false; missSince = nil
        if keptSince != nil { keptSince = nil }
    }
    // Each title once on the page, in the first row it comes in. Continue watching is his own and is kept whole, but what
    // it holds isn't repeated further down.
    nonisolated static func once(_ rows: [MediaRow]) -> [MediaRow] {
        var seen = Set<String>()
        return rows.compactMap { r in
            if r.title == "Continue watching" { r.items.forEach { seen.insert($0.stremioRef?.imdb ?? $0.id) }; return r }
            let items = r.items.filter { seen.insert($0.stremioRef?.imdb ?? $0.id).inserted }
            return items.isEmpty ? nil : MediaRow(title: r.title, items: items)
        }
    }
    // A shelf of only a few is never shown on its own: its cards go to the front of the full row before it (else the
    // one after), with nothing twice. Continue watching is his own, however short.
    nonisolated static func fold(_ rows: [MediaRow]) -> [MediaRow] {
        func full(_ r: MediaRow) -> Bool { r.items.count >= 8 }
        func key(_ i: MediaItem) -> String { i.stremioRef?.imdb ?? i.id }
        var out: [MediaRow] = [], waiting: [MediaItem] = [], waitingTitle = ""
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
            } else { if waiting.isEmpty { waitingTitle = r.title }; waiting += r.items }
        }
        // Short rows with no full row to join are still the answer: dropped, a genre with six films, or a search that
        // found one show, came out as an empty page (2026-11-10: "Arrested Development" searched under Shows said "No
        // results", with the show found). They stand under the first one's own name.
        if !waiting.isEmpty {
            var seen = Set(out.flatMap { $0.items.map(key) })
            let rest = waiting.filter { seen.insert(key($0)).inserted }
            if !rest.isEmpty { out.append(MediaRow(title: waitingTitle, items: rest)) }
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
    // A YouTube still is wide, so its card is: a 16:9 tile the row's cover height, the still filling it (YouTube's own stills
    // are 16:9, so nothing is cut off), rather than a wide picture shrunk into a poster's shape.
    var coverHeight: CGFloat { width / source.coverAspect }
    var cardWidth: CGFloat { item.isYouTube ? (coverHeight * 16 / 9).rounded() : width }
    @State private var band: Color?
    // No cover to be had (none given, or it wouldn't load): the card draws its own, never a blank tile.
    @State private var noArt = false
    // A cover seen before has its colour ready, so the card arrives already tinted rather than fading in.
    var shownBand: Color { band ?? ImageStore.shared.cachedBand(URL(string: item.art)) ?? CoverWait.band }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image { image.resizable().scaledToFill() }
                else if noArt { CoverFallback(title: item.title, tint: shownBand) }
                else { Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { CoverWait().overlay { LoadingRing(radius: 0) } } }
            }
                .frame(width: cardWidth, height: coverHeight)
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
            .frame(width: cardWidth, height: Self.band(width), alignment: .topLeading)
            .background(shownBand)
        }
        .clipShape(RoundedRectangle(cornerRadius: width > 200 ? 8 : 6, style: .continuous))
        .task(id: item.art) {
            guard image == nil else { return }
            guard let u = URL(string: item.art), !item.art.isEmpty else { noArt = true; return }
            if ImageStore.shared.cached(u) == nil, await ImageStore.shared.load(u) == nil { withAnimation(.easeOut(duration: 0.25)) { noArt = true }; return }
            ArtCheck.arrived()
            if ImageStore.shared.cachedBand(u) == nil, let c = await ImageStore.shared.band(u) { band = c }
        }
        .animation(.easeOut(duration: 0.25), value: band)
    }
}

// For the build's check that covers really arrive, not just rows (r29: open Watch, rows in, every cover grey): the first
// few covers drawn tell the sample Mac. Never sent to a real one.
@MainActor enum ArtCheck {
    static var told = 0
    static func arrived() {
        guard ["127.0.0.1", "localhost"].contains(where: { TVBridge.address.contains($0) }), told < 4 else { return }
        told += 1
        Task { _ = await TVBridge.data(TVBridge.url("/api/tv/applied?what=art&n=\(told)"), timeout: 3) }
    }
}

// A cover that can't be had: its title set large on a gradient of the card's own tint, like a poster, so the row never
// shows a blank tile.
struct CoverFallback: View {
    let title: String
    let tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [tint.opacity(0.65), Color(hex: 0x1B1530)], startPoint: .topTrailing, endPoint: .bottomLeading)
                RadialGradient(colors: [TVLook.accent.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: g.size.width)
                Text(title).font(.system(size: max(13, g.size.width * 0.15), weight: .bold, design: .serif))
                    .foregroundStyle(.white.opacity(0.92)).lineLimit(4).minimumScaleFactor(0.6)
                    .padding(g.size.width * 0.09)
            }
        }
        .accessibilityHidden(true)
    }
}

// A cover on its way: the app's own purple, with a soft light passing over it, so the row reads as loading rather than
// as flat tiles. The title is already in the band under it.
struct CoverWait: View {
    static let band = Color(hex: 0x3A3152)
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        Color(hex: 0x352B4E)
            .overlay {
                if !still {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.8)
                            .phaseAnimator([false, true]) { c, on in c.offset(x: on ? g.size.width : -g.size.width * 0.8) } animation: { _ in .linear(duration: 1.3) }
                    }
                }
            }
            .clipped()
    }
}

// A whole row as a list. Tapping an item opens the same flick sheet as its card.
struct MediaList: View {
    @Environment(TVModel.self) var model
    let row: MediaRow
    let source: MediaSource
    var body: some View {
        RowList(title: row.title) {
            ForEach(row.items) { item in
                Button { FlickCardButton.tap(model, item, source) } label: {
                    HStack(spacing: 12) {
                        Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                            // One picture column for every row, so every title starts at the same place and the lines between
                            // rows start together (r35: a YouTube still at its full 16:9 width pushed its text 80 pt right of
                            // the posters', a ragged column). In a list the title says what it is; the still fills the poster's
                            // place, its middle kept.
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
                .contextMenu { QueueMenu(item: item, source: source) }
                .accessibilityLabel(item.shownSubtitle.isEmpty ? item.title : "\(item.title), \(item.shownSubtitle)")
            }
        }
    }
}

struct BrowseColumn: View {
    enum Part { case all, left, right }
    @Environment(TVModel.self) var model
    @ObservedObject var store: BrowseStore
    var part = Part.all
    @FocusState private var searchFocused: Bool
    // Unfolded, the rows take turns on each side of the fold.
    var shown: [MediaRow] {
        part == .all ? store.rows : store.rows.enumerated().filter { ($0.offset % 2 == 0) == (part == .left) }.map(\.element)
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // The app's name leads the page. Unfolded, the other side keeps its room empty, so both sides' rows start level.
                PageHeading(store.source.name).padding(.horizontal, 20).padding(.bottom, -10).opacity(part == .right ? 0 : 1).accessibilityHidden(part == .right)
                // The one search (the Search tab), which finds this app's things among everything else.
                if part != .right { OpensSearchField().padding(.horizontal, 20) }
                if store.rows.isEmpty && part != .right {
                    Group {
                        if store.loading { VStack(spacing: 22) { ForEach(0..<3, id: \.self) { _ in PlaceholderShelf() } } }
                        else if store.failed { ContentUnavailableView("Can’t reach \(store.source.name)", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again.")) }
                        else { ContentUnavailableView.search }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
                // The Mac can't be asked: the rows are the ones kept from last time, said so and dimmed.
                if part != .right, store.query.isEmpty, let since = store.keptSince { KeptNote(since: since) }
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
                    .opacity(store.keptSince != nil ? 0.55 : 1)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 12)
            // The rows arrive, and give way to what a search finds, with a fade: the lists are set outside any animation,
            // so they cut in and out (the 2026-11-10 motion pass).
            .settledAnimation(.easeOut(duration: 0.25), value: shown.map(\.title))
            .settledAnimation(.easeOut(duration: 0.25), value: store.keptSince != nil)
            .animation(.easeOut(duration: 0.25), value: store.query.isEmpty)
        }
        .restsOnRows()
        // Scrolling the results puts the keyboard away, as does opening one.
        .scrollDismissesKeyboard(.immediately)
        .summonsBar()
        .refreshable { await store.load(force: true) }
        .task { await store.load() }
    }
}

// Every card in a row, wherever it is: a press already asks for its streams, and the flick knows the tile it came
// from, so a card put back lands on it.
struct FlickCardButton: View {
    @Environment(TVModel.self) var model
    let item: MediaItem
    let source: MediaSource
    let width: CGFloat
    var ready = false
    // Where the tile is, kept without redrawing anything while the row scrolls.
    @State private var place = FrameBox()
    @Environment(\.openRow) private var openRow
    // A film or show from Stremio's catalogue has its details a tap away, on the "i" at the picture's corner.
    var hasInfo: Bool { source == .stremio && !item.isYouTube && item.stremioRef != nil }
    // What a tap on a card does; the build's real-data flows tap through here too.
    @MainActor static func tap(_ model: TVModel, _ item: MediaItem, _ source: MediaSource, ready: Bool = false, origin: CGRect? = nil, held: Bool = false) {
        // A card picked from anywhere (a search result, Return on the field) takes the keyboard down with it (gate of 0472bce).
        SearchStore.shared.putKeyboardAway()
        // The tap iOS reports with the release of a card that was held (thrown, put back, or let go as a tap) is that.
        // The held card's own release (`held`) is the one that counts.
        if !held, Date().timeIntervalSince(ShelfHand.shared.handledAt) < 0.35 { return }
        if model.isOnTV(item, source) { model.showOnRemote(); return }
        if item.isYouTube {
            // A YouTube video from Continue watching: thrown like anything else, and on the TV it opens in YouTube where
            // he left it, the way a pasted link does. Under half a minute in isn't worth resuming: it starts from the top.
            let at = item.resume ?? 0
            let link = "https://www.youtube.com/watch?v=\(item.id)" + (at >= 30 ? "&t=\(at)" : "")
            model.flick(FlickTarget(item: item, source: source, send: ("send", ["text": link]), lands: "com.google.android.youtube.tv", origin: origin))
            return
        }
        model.flick(FlickTarget(item: item, source: source, ready: ready, origin: origin))
    }
    var body: some View {
        Button { Self.tap(model, item, source, ready: ready, origin: place.rect) } label: { MediaCard(item: item, source: source, width: width) }
            // A sleeping box takes seconds to bring Stremio up, so it's told the moment a finger lands, not at the throw.
            // Whether it's what's on is asked at the press, not while drawing: read here, every card on every page was
            // redrawn each time the TV's status changed (once a second with something playing).
            .buttonStyle(PressCard(onPress: source == .stremio && !item.isYouTube ? { [model] in if !model.isOnTV(item, source) { StreamCache.shared.prefetch(item); Prepare.arm() } } : nil))
            // Outside the press's own squeeze, so the measure never moves with what it measures.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { place.rect = $0 }
            // Held, it lifts off the shelf; thrown up, it goes to the TV (ShelfFlick, the streams page's own hand).
            .modifier(ShelfFlick(item: item, source: source, width: width, rect: { [place] in place.rect ?? .zero }))
            .accessibilityLabel(item.shownSubtitle.isEmpty ? item.title : "\(item.title), \(item.shownSubtitle)")
            // The details are a pushed page with the system's Back, never a sheet (2026-11-08: the sheet sat inset with a
            // rounded corner and no Back, folded). On a page pushed by an item (an app's page) it opens through that
            // page's own route, as its rows do; elsewhere by value on the tab's path.
            .overlay(alignment: .topTrailing) {
                Group {
                    if hasInfo {
                        if let openRow { InfoBadge { model.tick(); openRow(.info(item, source)) } }
                        else { NavigationLink(value: RowRoute.info(item, source)) { InfoBadge.mark }.buttonStyle(.plain).accessibilityLabel("Details").simultaneousGesture(TapGesture().onEnded { model.tick() }) }
                    }
                }
                // Lifts with the card: never left floating over its empty place while the card is in the hand or in the air.
                .opacity(ShelfHand.shared.item?.id == item.id ? 0 : 1)
            }
            // A show he's part way through (Continue watching's tiles carry how far): its episodes asked for as the tile
            // comes on screen, so its page opens on them rather than on grey rows.
            .onAppear { if source == .stremio, item.progress != nil { NextUp.prefetch(item) } }
            // Held: the same title on this phone instead, from his own add-ons.
            .contextMenu {
                if hasInfo { Button("Play on iPhone", systemImage: "iphone") { model.tick(); PhoneOpen.open(item, model: model) } }
                QueueMenu(item: item, source: source)
            }
    }
}
final class FrameBox { var rect: CGRect? }

// A row of cards that scrolls sideways. It stops where the page's other content stops, fading out there rather than cut
// square, and fading in at the start too once it's been scrolled. Folded or open, nothing runs on under the clock or the
// glass side bar.
private struct RowEdge: ViewModifier {
    @State private var scrolled = false
    // Something still past the trailing edge: only then does that edge fade (a row of chips that fits, the streams' "720p"
    // open flat, was cut by a fade with nothing beyond it).
    @State private var more = true
    func body(content: Content) -> some View {
        content
            .scrollTargetBehavior(FreeScroll())
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x > 4 } action: { _, s in scrolled = s }
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.width - $0.contentOffset.x - $0.containerSize.width > 4 } action: { _, m in more = m }
            // The row's own frame already ends where the page's content does (level with the search field), so the fade
            // ends at that edge and nothing of the row is drawn past it. No reader here: measuring the safe area took it
            // off twice, and laid the page out a frame late on first visit.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(scrolled ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(more ? 0 : 1)], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                }
                // Only the fade eases, so nothing in the row animates with it.
                .animation(.easeOut(duration: 0.2), value: scrolled)
                .animation(.easeOut(duration: 0.2), value: more)
            }
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
