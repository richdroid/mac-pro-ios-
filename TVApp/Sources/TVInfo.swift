import SwiftUI

// Everything about a film or a show before it's flicked: what it's about, the year, how long, who's in it, how it's rated,
// and a show's seasons (Richard, 2026-11-07: "there should be an info tab like an i to see full details of each before i
// flick"). Straight from Stremio's own catalogue, which the phone can reach from anywhere.
struct TitleInfo: Decodable {
    var name: String?
    var description: String?
    var releaseInfo: String?
    var runtime: String?
    var cast: [String]?
    var director: [String]?
    var genres: [String]?
    var imdbRating: String?
    var background: String?
    var poster: String?
    var videos: [Video]?
    struct Video: Decodable {
        var id: String?; var season: Int?; var episode: Int?; var number: Int?
        var name: String?; var title: String?; var thumbnail: String?; var overview: String?; var description: String?
    }
    // The show's episodes as the picker lists them (specials last), straight from the catalogue.
    var episodeList: [StremioEpisode] {
        (videos ?? []).compactMap { v in
            guard let id = v.id, let s = v.season, let e = v.episode ?? v.number else { return nil }
            return StremioEpisode(id: id, season: s, episode: e, name: v.name ?? v.title ?? "", thumb: v.thumbnail ?? "", runtime: nil, overview: v.overview ?? v.description)
        }.sorted { ($0.season == 0 ? Int.max : $0.season, $0.episode) < ($1.season == 0 ? Int.max : $1.season, $1.episode) }
    }
    // "1995 · 2 h 50 min · Crime, Drama"
    var facts: String {
        var parts: [String] = []
        if let y = releaseInfo, !y.isEmpty { parts.append(y.replacingOccurrences(of: "–", with: " – ")) }
        if let r = runtime, !r.isEmpty { parts.append(Self.readable(r)) }
        if let g = genres, !g.isEmpty { parts.append(g.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
    // "170 min" → "2 h 50 min"; anything else as it came.
    static func readable(_ r: String) -> String {
        guard let m = Int(r.prefix { $0.isNumber }), r.contains("min"), m >= 60 else { return r }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
    // Each season (specials left out) with how many episodes it has.
    var seasons: [(season: Int, episodes: Int)] {
        let counts = Dictionary(grouping: (videos ?? []).compactMap { $0.season }.filter { $0 > 0 }, by: { $0 }).mapValues(\.count)
        return counts.keys.sorted().map { ($0, counts[$0] ?? 0) }
    }
}

@MainActor
enum TitleInfoStore {
    private static var cache: [String: TitleInfo] = [:]
    static func cached(_ type: String, _ imdb: String) -> TitleInfo? { cache[type + imdb] }
    static func load(_ type: String, _ imdb: String) async -> TitleInfo? {
        if let c = cache[type + imdb] { return c }
        struct Wrap: Decodable { let meta: TitleInfo }
        guard let d = await TVBridge.data(URL(string: "https://v3-cinemeta.strem.io/meta/\(type)/\(imdb).json"), timeout: 12, cached: true),
              let w = try? JSONDecoder().decode(Wrap.self, from: d) else { return nil }
        cache[type + imdb] = w.meta
        return w.meta
    }
}

// The small "i" on a card's corner. Its own button, so it never also flicks the card.
struct InfoBadge: View {
    let action: () -> Void
    static var mark: some View {
        Image(systemName: "info").font(.system(size: 12, weight: .bold))
            .frame(width: 26, height: 26)
            .glassEffect(.regular.interactive(), in: Circle())
            // A finger's room around the small mark.
            .padding(6).contentShape(Rectangle())
    }
    var body: some View {
        Button(action: action) { Self.mark }
            .buttonStyle(.plain)
            .accessibilityLabel("Details")
    }
}

// The details, as a page pushed over whatever it was opened from, with the system's own Back at the top of the side strip
// (folded and open flat) or the top bar (open upright), the way the Duo lays it out (Richard, 2026-11-08: "looks fucked
// doesnt go edge to edge and no back button", on the sheet this was). The wide picture runs edge to edge under the clock
// and the strip, as the HIG lets a header span the full width while what scrolls stays inset. Its one big key sits in
// the page's foot inset, so nothing scrolls under it (the season chips sat under it before), and carries on to choosing
// and flicking, so reading about it is never a dead end.
struct TitleInfoPage: View {
    @Environment(TVModel.self) var model
    @Environment(\.dismiss) private var dismiss
    // Folded and turned sideways the display is about 400 pt tall: a banner up to 360 pt left the title under the key
    // (54832f8's folded-landscape shot). There it's a short strip, so the name and the first lines show above the key.
    @Environment(\.verticalSizeClass) private var vSize
    // And folded flat the display is 466 pt tall without being compact in height: the banner takes at most two fifths
    // of whatever height the page has, so the name clears the key in every posture (tv17's folded shot: "Toe Rings"
    // under the key).
    @State private var pageHeight: CGFloat = 0
    private var bannerMax: CGFloat { min(vSize == .compact ? 150 : 360, pageHeight > 0 ? pageHeight * 0.4 : 360) }
    let item: MediaItem
    let source: MediaSource
    // Opened from the flick's own page: there's nothing to carry on to, it's already there.
    var fromFlick = false
    @State private var info: TitleInfo?
    @State private var failed = false
    @State private var posterPlace = FrameBox()
    var ref: (type: String, imdb: String, video: String?)? { item.stremioRef }
    @State private var season = 1
    @State private var seriesInfo: SeriesInfo.Info?
    // Where he is in the show, from Stremio's Continue watching, if it knows.
    @State private var resumeFrom: MediaItem?
    var episodes: [StremioEpisode] { info?.episodeList ?? [] }
    // The episode to carry on with: the one he's on, or the one after it once that's all but done, else the first.
    var resume: StremioEpisode? {
        let all = episodes
        let from = resumeFrom?.stremioRef?.video ?? ref?.video
        if let id = from, let e = all.first(where: { $0.id == id }) {
            if (resumeFrom?.progress ?? 0) > 0.9, let n = NextUp.after(e, in: all) { return n }
            return e
        }
        return all.first { $0.season > 0 } ?? all.first
    }
    var resumeLabel: String { resumeFrom != nil && resume?.id == resumeFrom?.stremioRef?.video ? "Resume" : resumeFrom == nil ? "Play" : "Up next" }
    func episodeItem(_ e: StremioEpisode) -> MediaItem {
        NextUp.item(NextUp.Series(imdb: ref?.imdb ?? "", title: item.title, art: item.art, current: ""), e)
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(info?.name ?? item.title).font(.title.weight(.bold)).lineLimit(3)
                        HStack(spacing: 10) {
                            if let r = info?.imdbRating, !r.isEmpty {
                                Label(r, systemImage: "star.fill").labelStyle(.titleAndIcon).font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color(hex: 0xF5C518))
                            }
                            if let f = info?.facts, !f.isEmpty { Text(f).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    if let about = info?.description ?? item.about, !about.isEmpty {
                        Text(about).font(.body).fixedSize(horizontal: false, vertical: true)
                    } else if info == nil && !failed {
                        PlaceholderLines()
                    }
                    if let cast = info?.cast, !cast.isEmpty { fact("With", cast.prefix(6).joined(separator: ", ")) }
                    if let d = info?.director, !d.isEmpty { fact("Directed by", d.joined(separator: ", ")) }
                }
                .padding(.horizontal, 22)
                .settledAnimation(.easeOut(duration: 0.25), value: info == nil)
                // A show's page is its episode chooser: the seasons as the pivot, that season's episodes below, each one
                // tapped to choose its stream or held and flicked to the TV. Inset like the text, so nothing runs under the rail.
                if ref?.type == "series", !episodes.isEmpty {
                    EpisodePicker(episodes: episodes, season: $season, current: resume?.id, currentLabel: resumeLabel,
                                  progress: resume?.id == resumeFrom?.stremioRef?.video ? resumeFrom?.progress : nil, info: seriesInfo,
                                  choose: { e in model.tick(); FlickCardButton.tap(model, episodeItem(e), source); dismiss() },
                                  flickItem: { episodeItem($0) })
                        .padding(.horizontal, 22)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        // To the episode he'd carry on with, once the list and his place in it are known.
        .onChange(of: resume?.id) { _, id in
            guard let id else { return }
            Task { try? await Task.sleep(nanoseconds: 120_000_000); proxy.scrollTo(id, anchor: .center) }
        }
        }
        // The page runs under the bar to the top of the glass, so the picture is the first thing there and the system's
        // Back floats on it, as in Apple's own TV app. Inset, the page began under the bar instead, leaving a flat band
        // of the app's background between the glass edge and the picture in every posture (tv17's details shots: 23 pt
        // folded, the whole bar's height open upright), which read as a bar of its own colour with Back stuck in it
        // (Richard, 2026-11-09: "the back button looks off … not iphone duo").
        .ignoresSafeArea(edges: .top)
        // Measured on a layer under every inset: read inside the bars, the height changed as the bar came and went through
        // a push or the back swipe, and the banner shrank while the page slid (Richard, 2026-11-09: "the elements compact").
        .background { Color.clear.ignoresSafeArea().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if abs(pageHeight - $0) > 0.5 { pageHeight = $0 } } }
        // The key in the page's foot inset: the page scrolls above it, never under it.
        .safeAreaInset(edge: .bottom) {
            if !fromFlick && !(ref?.type == "series" && !episodes.isEmpty) {
                Button {
                    model.tick()
                    // The flick's screen opens over everything, so this page can go back under it at once.
                    FlickCardButton.tap(model, item, source)
                    dismiss()
                } label: {
                    Label(ref?.type == "series" ? "Choose an episode" : "Choose a stream", systemImage: "play.fill")
                        .font(.headline).foregroundStyle(.black.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(TVLook.accent, in: Capsule())
                }
                .buttonStyle(PressCard())
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 12)
                // What scrolls under the key fades out above it, never reads through beside it.
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .center)
                        .padding(.top, -28).ignoresSafeArea(edges: [.bottom, .horizontal]).allowsHitTesting(false)
                }
            }
        }
        .background { Ambience() }
        // No title in the bar: the name is set large in the page. The bar keeps its Back.
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            guard let ref else { failed = true; return }
            // Reading about it is the moment before choosing it: its streams are asked for now, so they're there.
            StreamCache.shared.prefetch(item)
            if ref.type == "series" {
                seriesInfo = SeriesInfo.cached(ref.imdb)
                Task { let i = await SeriesInfo.load(ref.imdb); withAnimation(.easeOut(duration: 0.2)) { seriesInfo = i } }
                // Where he is in it: Stremio's Continue watching, once in.
                let home = BrowseStore.shared(.stremio)
                if home.rows.isEmpty { await home.load() }
                resumeFrom = home.rows.first { $0.title == "Continue watching" }?.items.first { $0.stremioRef?.imdb == ref.imdb }
            }
            if let c = TitleInfoStore.cached(ref.type, ref.imdb) { info = c } else {
                let i = await TitleInfoStore.load(ref.type, ref.imdb)
                withAnimation(.easeOut(duration: 0.25)) { info = i; failed = i == nil }
            }
            if let r = resume { season = r.season }
        }
    }
    // The wide picture across the top, edge to edge under the clock and the side strip, no taller than 360 pt open; the
    // poster sat on it, both fading into the page.
    var header: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: bannerMax)
                .overlay {
                    Art(url: URL(string: info?.background ?? item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.06) }
                }
                .clipped()
                .mask(LinearGradient(colors: [.black, .black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: [.top, .horizontal])
            Art(url: URL(string: info?.poster ?? item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                .frame(width: 84, height: 126).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .measured(posterPlace)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                .padding(.leading, 22).offset(y: 30)
                // Held, the poster lifts off the page and goes to the TV like any card; the key at the foot stays the tap.
                .modifier(InfoPosterFlick(item: item, source: source, place: posterPlace, on: !fromFlick))
        }
        .padding(.bottom, 30)
    }
    func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline)
        }
    }
}
private struct InfoPosterFlick: ViewModifier {
    let item: MediaItem, source: MediaSource, place: FrameBox, on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.modifier(RowFlick(item: item, source: source, width: 84, place: place)) } else { content }
    }
}
private struct PlaceholderLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([1.0, 0.92, 0.6], id: \.self) { w in
                Capsule().fill(.white.opacity(0.09)).frame(height: 12).containerRelativeFrame(.horizontal) { x, _ in x * w * 0.85 }
            }
        }
    }
}
