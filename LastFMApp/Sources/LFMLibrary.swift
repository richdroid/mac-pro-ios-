import SwiftUI

// Library: every artist, album and track he's played, and the songs he loves. One search box reaches all of them as he
// types (artists, albums and tracks together); the lists sort by plays, name, first listened or last listened. Every
// row opens its page.
enum LibSort: String, CaseIterable, Sendable {
    case plays = "Plays", name = "Name", first = "First listened", last = "Last listened"
}
enum LibShelf: Int, CaseIterable, Sendable {
    case artists, albums, tracks, loved
    var name: String { ["Artists", "Albums", "Tracks", "Loved"][rawValue] }
}

@MainActor @Observable final class LibraryModel {
    static let shared = LibraryModel()
    var shelf: LibShelf = .artists
    var sort: LibSort = .plays
    var query = ""
    private(set) var lists: [Kind: [Entry]] = [:]
    private(set) var loved: [Loved] = Loved.kept()
    private(set) var lovedPlays: [String: Int] = [:]
    @ObservationIgnored private var stamp: [Kind: Int] = [:]
    @ObservationIgnored private var loading: Set<Kind> = []
    @ObservationIgnored private var lovedAsked = false

    func appear() {
        for k in Kind.allCases { load(k) }
        if !lovedAsked {
            lovedAsked = true
            Task {
                if let l = await Loved.load() { withAnimation(.smooth) { loved = l } }
                lovedPlays = await HistoryDB.reader.lovedPlays(loved.map { ($0.artist, $0.title) })
            }
        }
    }
    // Worked out when first shown, and again when the history has grown since.
    func load(_ k: Kind) {
        let read = HistorySync.shared.read
        guard !loading.contains(k), lists[k] == nil || abs((stamp[k] ?? 0) - read) > 50 else { return }
        loading.insert(k)
        Task {
            let db = HistoryDB.reader
            var list = await db.library(k)
            if k == .artists {
                let covers = await db.artistCovers()
                for i in list.indices { if let c = covers[list[i].artist] { list[i] = list[i].with(album: c.0, image: c.1) } }
            }
            lists[k] = list
            stamp[k] = read
            loading.remove(k)
        }
    }
    // Sorted once per list and order, not on every redraw (sixteen thousand tracks by name is a noticeable sort).
    @ObservationIgnored private var sortedCache: [String: [Entry]] = [:]
    func sorted(_ k: Kind) -> [Entry] {
        let l = lists[k] ?? []
        if sort == .plays { return l }
        let key = "\(k.rawValue)|\(sort.rawValue)|\(l.count)|\(stamp[k] ?? 0)"
        if let hit = sortedCache[key] { return hit }
        let out: [Entry]
        switch sort {
        case .name: out = l.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .first: out = l.sorted { ($0.first ?? 0) > ($1.first ?? 0) }
        default: out = l.sorted { ($0.last ?? 0) > ($1.last ?? 0) }
        }
        sortedCache[key] = out
        return out
    }
    // Everything whose name (or artist) holds the words typed, most played first.
    func search(_ k: Kind) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return (lists[k] ?? []).filter { $0.title.localizedStandardContains(q) || (k != .artists && $0.artist.localizedStandardContains(q)) }
    }
}

extension HistoryDB {
    func lovedPlays(_ list: [(String, String)]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (a, t) in list { rows("SELECT COUNT(*) FROM plays WHERE artist = ? AND track = ?", [a, t]) { out["\(a)|\(t)"] = int($0, 0) } }
        return out
    }
}

struct LibraryTab: View {
    let top: Int
    @FocusState private var typing: Bool
    @State private var shown = 200
    @State private var grown: Set<Kind> = []
    private var m: LibraryModel { LibraryModel.shared }
    @Environment(\.paneLayout) private var pane
    var body: some View {
        Group {
            if pane {
                // Open flat: the search and the shelves on the left, the list on the right; nothing crosses the fold.
                FoldSplit {
                    Page(top: top) { VStack(alignment: .leading, spacing: S.section) { head; overview }.padding(.top, S.head) }
                } right: {
                    Page(top: top) { LazyVStack(alignment: .leading, spacing: 0) { if m.query.isEmpty { shelf } else { results } }.padding(.top, S.section) }
                }
            } else {
                Page(top: top) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        head.padding(.bottom, S.section)
                        if m.query.isEmpty { shelf } else { results }
                    }
                    .padding(.top, S.head)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .onAppear { m.appear() }
        // Leaving for a page puts the keyboard away; it never outlives the search it served.
        .onDisappear { typing = false }
        .task {
            guard Pose.name == "search" else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            m.query = LastFM.shared.mock ? "glass" : ""
        }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: S.head) {
            HubTitle(text: "library", size: 80)
            search.padding(.horizontal, S.margin)
            if m.query.isEmpty {
                Picker("Show", selection: Binding(get: { m.shelf }, set: { m.shelf = $0; shown = 200 })) {
                    ForEach(LibShelf.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, S.margin)
            }
        }
    }

    // Open flat, the left pane's room: how big his library is, and the shelf's nine most played, each opening its page.
    @ViewBuilder private var overview: some View {
        let kind = Kind(rawValue: m.shelf.rawValue) ?? .artists
        let top = m.shelf == .loved ? [] : Array((m.lists[kind] ?? []).prefix(9))
        VStack(alignment: .leading, spacing: S.section) {
            FigureGrid(items: [
                (number(m.lists[.artists]?.count ?? 0), "artists"),
                (number(m.lists[.albums]?.count ?? 0), "albums"),
                (number(m.lists[.tracks]?.count ?? 0), "tracks"),
                (number(m.loved.count), "loved"),
            ])
            if top.count == 9 {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "most played")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 3), spacing: 1) {
                        ForEach(top) { e in
                            Opens(route: e.route, zoom: "libtop|\(e.id)") { ArtView(e.art, px: 300, corner: 0).zoomSource("libtop|\(e.id)") }
                                .accessibilityLabel("\(e.rank). \(e.title)")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(.horizontal, S.margin)
    }

    private var search: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(S.soft)
            TextField("Artists, albums and tracks", text: Binding(get: { m.query }, set: { m.query = $0 }))
                .focused($typing)
                .submitLabel(.search)
                .onSubmit { typing = false }
                .autocorrectionDisabled()
                .foregroundStyle(.white)
            if !m.query.isEmpty {
                Button { m.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(S.soft).frame(width: 44, height: 44) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, 16).frame(height: 48)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    // One shelf, sorted as chosen, with how many there are and the sort beside it.
    @ViewBuilder private var shelf: some View {
        let isLoved = m.shelf == .loved
        let kind = Kind(rawValue: m.shelf.rawValue) ?? .artists
        let list = isLoved ? [] : m.sorted(kind)
        HStack(alignment: .firstTextBaseline) {
            Text(isLoved ? "\(number(m.loved.count)) loved" : "\(number(list.count)) \(kind.noun)").font(.system(.title2, weight: .bold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            if !isLoved {
                Menu {
                    Picker("Sort by", selection: Binding(get: { m.sort }, set: { m.sort = $0; shown = 200 })) {
                        ForEach(LibSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label(m.sort.rawValue, systemImage: "arrow.up.arrow.down").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 36)
                        .glassEffect(.regular, in: Capsule())
                }
            }
        }
        .padding(.horizontal, S.margin).padding(.bottom, S.head)
        if isLoved {
            ForEach(m.loved) { l in lovedRow(l).padding(.horizontal, S.margin) }
        } else {
            ForEach(list.prefix(shown)) { e in
                EntryRow(e: e, showRank: m.sort == .plays, context: "lib", trailing: trailing(e))
                    .padding(.horizontal, S.margin)
                    .onAppear { if e.id == list.prefix(shown).last?.id, shown < list.count { shown += 300 } }
            }
            if m.lists[kind] == nil { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, S.section) }
        }
    }
    private func trailing(_ e: Entry) -> String? {
        switch m.sort {
        case .first: return e.first.map(dateShort)
        case .last: return e.last.map(ago)
        default: return nil
        }
    }
    private func lovedRow(_ l: Loved) -> some View {
        let n = m.lovedPlays["\(l.artist)|\(l.title)"]
        let s = Scrobble.song(artist: l.artist, title: l.title, album: "", image: l.image)
        return Opens(route: .track(s), zoom: "loved|\(s.id)") {
            HStack(spacing: S.gap) {
                ArtView(s.art, px: 156, corner: 6).frame(width: S.art).zoomSource("loved|\(s.id)")
                VStack(alignment: .leading, spacing: S.pair / 2) {
                    Text(l.title).font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(l.artist).font(.subheadline).foregroundStyle(S.soft).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: S.pair / 2) {
                    Text(n.map(number) ?? "–").font(.body.weight(.medium)).monospacedDigit().foregroundStyle(.white)
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(S.accent)
                        if let w = l.when { Text(ago(Int(w.timeIntervalSince1970))) }
                    }
                    .font(.caption).foregroundStyle(S.soft)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(n.map { "\($0) plays, " } ?? "")loved\(l.when.map { " " + ago(Int($0.timeIntervalSince1970)).lowercased() } ?? "")")
            }
            .padding(.vertical, S.row / 2)
        }
        .accessibilityElement(children: .combine)
    }

    // As he types: artists, albums and tracks together, the most played first in each, more growing in place.
    @ViewBuilder private var results: some View {
        let groups = Kind.allCases.map { ($0, m.search($0)) }.filter { !$0.1.isEmpty }
        if groups.isEmpty {
            VStack(spacing: S.pair) {
                Image(systemName: "magnifyingglass").font(.largeTitle.weight(.light)).foregroundStyle(S.soft)
                Text("Nothing you've played matches").font(.body).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity).padding(.top, S.section)
        }
        ForEach(groups, id: \.0) { k, list in
            let open = grown.contains(k)
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: k.noun, trailing: number(list.count))
                VStack(spacing: 0) {
                    ForEach(list.prefix(open ? 200 : (k == .tracks ? 8 : 4))) { e in EntryRow(e: e, showRank: false, context: "find") }
                }
                if list.count > (k == .tracks ? 8 : 4) {
                    Button { withAnimation(.smooth) { if open { grown.remove(k) } else { grown.insert(k) } } } label: {
                        Text(open ? "Show fewer" : "Show all \(number(min(list.count, 200)))").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .glassEffect(.regular, in: Capsule())
                    }
                    .buttonStyle(Press())
                }
            }
            .padding(.horizontal, S.margin)
            .padding(.bottom, S.section)
        }
    }
}
