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
struct MediaRow: Decodable, Identifiable {
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
    var cardWidth: CGFloat { self == .mint ? 150 : 124 }
    func endpoint(_ q: String) -> String {
        let term = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "/api/tv/\(rawValue)" + (q.isEmpty ? "" : "?q=\(term)")
    }
}

@MainActor
final class BrowseStore: ObservableObject {
    let source: MediaSource
    @Published var rows: [MediaRow] = []
    @Published var query = ""
    @Published var loading = false
    @Published var failed = false
    private var loadedFor: String?
    private var inFlight: String?
    private var loadedAt = Date.distantPast
    private static var stores: [MediaSource: BrowseStore] = [:]
    // One for each app, so going back in shows what was there straight away.
    static func shared(_ source: MediaSource) -> BrowseStore {
        if let s = stores[source] { return s }
        let s = BrowseStore(source); stores[source] = s; return s
    }
    private var searching: Task<Void, Never>?
    init(_ source: MediaSource) { self.source = source }
    func load(force: Bool = false) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Recent enough to skip, though what's on the TV moves on, so never for long.
        if !force && loadedFor == q && !rows.isEmpty && Date().timeIntervalSince(loadedAt) < 60 { return }
        struct Answer: Decodable { let rows: [MediaRow] }
        // Unfolded, both sides ask at once.
        if inFlight == q && !force { return }
        inFlight = q
        loading = true; failed = false
        defer { loading = false; inFlight = nil }
        let data = await TVBridge.data(TVBridge.url(source.endpoint(q)), timeout: 20)
        // A slower, older search must not replace a newer one.
        guard q == query.trimmingCharacters(in: .whitespaces) else { return }
        guard let data, let a = try? JSONDecoder().decode(Answer.self, from: data) else { failed = rows.isEmpty; return }
        rows = a.rows; loadedFor = q; loadedAt = Date()
    }
    func searchSoon() {
        searching?.cancel()
        searching = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { await self?.load() }
        }
    }
}

// The item as Mint draws it: a cover over a solid band tinted from that cover.
struct MediaCard: View {
    let item: MediaItem
    let source: MediaSource
    var width: CGFloat
    @State private var band = Color(hex: 0x37474F)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color(hex: 0x37474F) }
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
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: width > 200 ? 18 : 14)).lineLimit(1)
                Text(item.subtitle).font(.system(size: width > 200 ? 14 : 11.5)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, width > 200 ? 14 : 10)
            .frame(width: width, height: width > 200 ? 66 : 50, alignment: .leading)
            .background(band)
        }
        .clipShape(RoundedRectangle(cornerRadius: width > 200 ? 8 : 6, style: .continuous))
        .task(id: item.art) {
            if let u = URL(string: item.art), let c = await ImageStore.shared.band(u) { band = c }
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
                Button { model.flicking = FlickTarget(item: item, source: source) } label: {
                    HStack(spacing: 12) {
                        Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                            .frame(width: 50, height: 50 / source.coverAspect).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body.weight(.semibold)).lineLimit(2)
                            Text(item.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(item.subtitle)")
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
                        if store.loading { ProgressView() }
                        else if store.failed { ContentUnavailableView("Can’t reach \(store.source.name)", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again.")) }
                        else { ContentUnavailableView.search }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(shown) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        RowHeader(title: row.title) { MediaList(row: row, source: store.source) }.padding(.leading, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 10) {
                                ForEach(row.items) { item in
                                    Button { model.flicking = FlickTarget(item: item, source: store.source) } label: { MediaCard(item: item, source: store.source, width: store.source.cardWidth) }
                                        .buttonStyle(.plain).accessibilityLabel("\(item.title), \(item.subtitle)")
                                }
                            }
                            .padding(.horizontal, 20).scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned).clipped()
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await store.load(force: true) }
        .task { await store.load() }
    }
}
