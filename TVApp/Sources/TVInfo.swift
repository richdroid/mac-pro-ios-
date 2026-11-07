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
    struct Video: Decodable { var season: Int?; var episode: Int?; var number: Int? }
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
    var body: some View {
        Button(action: action) {
            Image(systemName: "info").font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
                .glassEffect(.regular.interactive(), in: Circle())
                // A finger's room around the small mark.
                .padding(6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Details")
    }
}

// The details, in a sheet over whatever it was opened from. Its one big key carries on to choosing and flicking, so
// reading about it is never a dead end.
struct TitleInfoSheet: View {
    @Environment(TVModel.self) var model
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let source: MediaSource
    // Opened from the flick's own page: there's nothing to carry on to, it's already there.
    var fromFlick = false
    @State private var info: TitleInfo?
    @State private var failed = false
    var ref: (type: String, imdb: String, video: String?)? { item.stremioRef }
    var body: some View {
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
                    if let s = info?.seasons, !s.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(s.count == 1 ? "1 season" : "\(s.count) seasons").font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(s, id: \.season) { x in
                                        VStack(spacing: 2) {
                                            Text("Season \(x.season)").font(.subheadline.weight(.semibold))
                                            Text(x.episodes == 1 ? "1 episode" : "\(x.episodes) episodes").font(.caption).foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 14).padding(.vertical, 9)
                                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .animation(.easeOut(duration: 0.25), value: info == nil)
            }
            .padding(.bottom, fromFlick ? 24 : 96)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) {
            if !fromFlick {
                Button {
                    model.tick(); dismiss()
                    // Once the sheet is away, so the flick's screen opens over the page, not under a closing sheet.
                    Task { try? await Task.sleep(nanoseconds: 350_000_000); FlickCardButton.tap(model, item, source) }
                } label: {
                    Label(ref?.type == "series" ? "Choose an episode" : "Choose a stream", systemImage: "play.fill")
                        .font(.headline).foregroundStyle(.black.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(TVLook.accent, in: Capsule())
                }
                .buttonStyle(PressCard())
                .padding(.horizontal, 22).padding(.bottom, 18)
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(28)
        .task {
            guard let ref else { failed = true; return }
            if let c = TitleInfoStore.cached(ref.type, ref.imdb) { info = c; return }
            let i = await TitleInfoStore.load(ref.type, ref.imdb)
            withAnimation(.easeOut(duration: 0.25)) { info = i; failed = i == nil }
        }
    }
    // The wide picture across the top, the poster sat on it, both fading into the sheet.
    var header: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    Art(url: URL(string: info?.background ?? item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.06) }
                }
                .clipped()
                .mask(LinearGradient(colors: [.black, .black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
            Art(url: URL(string: info?.poster ?? item.art)) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                .frame(width: 84, height: 126).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                .padding(.leading, 22).offset(y: 30)
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
private struct PlaceholderLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([1.0, 0.92, 0.6], id: \.self) { w in
                Capsule().fill(.white.opacity(0.09)).frame(height: 12).containerRelativeFrame(.horizontal) { x, _ in x * w * 0.85 }
            }
        }
    }
}
