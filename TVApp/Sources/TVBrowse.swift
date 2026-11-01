import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Mint and Stremio, pared down: what they already show, on the phone, ready to flick to the TV.
struct MediaItem: Decodable, Identifiable, Hashable {
    let title: String, subtitle: String, art: String, id: String, kind: String
    var about: String?
    var progress: Double?
}
struct MediaRow: Decodable, Identifiable {
    let title: String, items: [MediaItem]
    var id: String { title }
}
enum MediaSource: String, CaseIterable, Identifiable {
    case mint, stremio
    var id: String { rawValue }
    var name: String { self == .mint ? "Mint Music" : "Stremio" }
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
    @Published var picked: MediaItem?   // kept here so unfolding doesn't close the sheet
    private var loadedFor: String?
    private var searching: Task<Void, Never>?
    init(_ source: MediaSource) { self.source = source }
    func load(force: Bool = false) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !force && loadedFor == q && !rows.isEmpty { return }
        struct Answer: Decodable { let rows: [MediaRow] }
        loading = true; failed = false
        defer { loading = false }
        let data = await TVBridge.data(TVBridge.url(source.endpoint(q)), timeout: 20)
        // A slower, older search must not replace a newer one.
        guard q == query.trimmingCharacters(in: .whitespaces) else { return }
        guard let data, let a = try? JSONDecoder().decode(Answer.self, from: data) else { failed = rows.isEmpty; return }
        rows = a.rows; loadedFor = q
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

// Flick the cover up and it goes to the TV. The button does the same, for anyone not flicking.
struct MediaSheet: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let source: MediaSource
    @State private var flown: CGFloat = 0
    @State private var sending = false
    // Goes back by itself if the system takes the touch away, so the cover can't get stuck raised.
    @GestureState private var dragged: CGFloat = 0
    var offset: CGFloat { flown + dragged }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                MediaCard(item: item, source: source, width: source == .mint ? 250 : 200)
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    .offset(y: offset)
                    .opacity(sending ? 0 : 1)
                    // Ahead of the page's own scrolling, which would otherwise take every upward drag.
                    .highPriorityGesture(DragGesture(minimumDistance: 8)
                        .updating($dragged, body: { v, state, t in
                            state = min(0, v.translation.height) * 0.8
                            t.animation = .spring(duration: 0.3, bounce: 0.3)
                        })
                        .onEnded { v in if v.translation.height < -60 || v.predictedEndTranslation.height < -160 { send() } })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Send to TV") { send() }
                Label("Flick up to send to the TV", systemImage: "chevron.up").font(.footnote).foregroundStyle(.secondary)
                Button(action: send) {
                    Label("Send to TV", systemImage: "tv").font(.body.weight(.semibold)).frame(maxWidth: 280, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                if let about = item.about, !about.isEmpty {
                    Text(about).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: 420, alignment: .leading).padding(.top, 2)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }
    func send() {
        guard !sending else { return }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        withAnimation(.easeIn(duration: 0.22)) { flown = -700; sending = true }
        let body: (String, [String: Any]) = source == .mint
            ? ("mint-open", ["link": item.id, "title": item.title, "subtitle": item.subtitle, "art": item.art, "kind": item.kind, "play": true])
            : ("stremio-open", ["type": item.kind, "id": item.id])
        // Gone with the flick; the message reports how it went, however long the TV takes.
        Task { try? await Task.sleep(nanoseconds: 220_000_000); dismiss() }
        Task {
            // Stremio stops at its list of streams, and which one to play is a choice for the remote.
            do { try await TVBridge.post(body.0, body.1); model.say(source == .mint ? "On the TV" : "On the TV. Pick a stream with the remote.") }
            catch { model.say("The TV didn’t get that") }
        }
    }
}

// A whole row as a list. Tapping an item opens the same flick sheet as its card.
struct MediaList: View {
    let row: MediaRow
    let source: MediaSource
    @State private var picked: MediaItem?
    var body: some View {
        RowList(title: row.title) {
            ForEach(row.items) { item in
                Button { picked = item } label: {
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
        .sheet(item: $picked) { MediaSheet(item: $0, source: source) }
    }
}

struct BrowseColumn: View {
    @ObservedObject var store: BrowseStore
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(store.source.prompt, text: $store.query).autocorrectionDisabled().submitLabel(.search)
                        .onChange(of: store.query) { _, _ in store.searchSoon() }
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 16).frame(height: 46)
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 20)
                if store.rows.isEmpty {
                    Group {
                        if store.loading { ProgressView() }
                        else if store.failed { ContentUnavailableView("Can’t reach \(store.source.name)", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again.")) }
                        else { ContentUnavailableView.search }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(store.rows) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        RowHeader(title: row.title) { MediaList(row: row, source: store.source) }.padding(.leading, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 10) {
                                ForEach(row.items) { item in
                                    Button { store.picked = item } label: { MediaCard(item: item, source: store.source, width: store.source.cardWidth) }
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

struct BrowseTab: View {
    @Environment(\.paneLayout) private var panes
    @StateObject private var mint = BrowseStore(.mint)
    @StateObject private var stremio = BrowseStore(.stremio)
    @AppStorage("browseSource") private var source = MediaSource.mint.rawValue
    var body: some View {
        Group {
            if panes {
                FoldSplit { BrowseColumn(store: mint) } right: { BrowseColumn(store: stremio) }
            } else {
                VStack(spacing: 8) {
                    Picker("Source", selection: $source) {
                        ForEach(MediaSource.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20)
                    BrowseColumn(store: source == MediaSource.mint.rawValue ? mint : stremio).id(source)
                }
            }
        }
        .sheet(item: $mint.picked) { MediaSheet(item: $0, source: .mint) }
        .sheet(item: $stremio.picked) { MediaSheet(item: $0, source: .stremio) }
    }
}
