import SwiftUI

// Discover: artists like the ones he plays most (the last three months, and his canon), that he's played little or never,
// each with why ("Because you play X and Y"); and a song of each to try. Asked of Last.fm once a day and kept, so it
// opens at once; every artist and song opens its page, and Apple Music is one tap away.
struct Rec: Codable, Hashable, Identifiable, Sendable {
    var id: String { name.lowercased() }
    let name: String
    let because: [String]
    let score: Double
    var plays: Int
    var album: String = ""
    var image: String?
    var track: String?
    var trackListeners: Int?
}

@MainActor @Observable final class DiscoverModel {
    static let shared = DiscoverModel()
    private(set) var recs: [Rec] = []
    private(set) var day = 0
    private(set) var working = false
    private var file: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(LastFM.shared.mock ? "discover-mock.json" : "discover.json") }
    private init() {
        if !UserDefaults.standard.bool(forKey: "fresh"), let d = try? Data(contentsOf: file), let o = try? JSONDecoder().decode([Rec].self, from: d) {
            recs = o
            day = UserDefaults.standard.integer(forKey: LastFM.shared.mock ? "discover.day.mock" : "discover.day")
        }
    }
    func appear() {
        guard !working, day != LocalDay.today || recs.isEmpty else { return }
        guard HistorySync.shared.complete || HistorySync.shared.coveredFrom < Int(Clock.now.timeIntervalSince1970) - 90 * 86400 else { return }
        working = true
        Task { await work(); working = false }
    }
    private func work() async {
        let db = HistoryDB.shared
        let now = Int(Clock.now.timeIntervalSince1970) + 1
        // Seeds: the twelve he's played most in three months, weighted by how much.
        let seeds = await db.top(.artists, from: now - 90 * 86400, to: now, limit: 12, median: 215)
        guard !seeds.isEmpty else { return }
        var score: [String: (name: String, s: Double, because: [(String, Double)])] = [:]
        let seedNames = Set(seeds.map { $0.artist.lowercased() })
        for seed in seeds {
            guard let j = try? await LastFM.shared.call("artist.getsimilar", ["artist": seed.artist, "limit": "30", "autocorrect": "1"], fresh: 86400) else { continue }
            let w = sqrt(Double(seed.plays))
            for a in j["similarartists"]["artist"].array {
                let name = a["name"].text, m = Double(a["match"].text) ?? 0
                guard !name.isEmpty, !seedNames.contains(name.lowercased()) else { continue }
                var cur = score[name.lowercased()] ?? (name, 0, [])
                cur.s += m * w
                cur.because.append((seed.artist, m * w))
                score[name.lowercased()] = cur
            }
        }
        let ranked = score.values.sorted { $0.s > $1.s }.prefix(60)
        let counts = await db.playsOf(artists: ranked.map(\.name))
        // Played little or never: ten plays at most.
        var list: [Rec] = ranked.compactMap { c in
            let n = counts[c.name.lowercased()] ?? 0
            guard n <= 10 else { return nil }
            return Rec(name: c.name, because: c.because.sorted { $0.1 > $1.1 }.prefix(2).map(\.0), score: c.s, plays: n)
        }
        list = Array(list.prefix(16))
        withAnimation(.smooth) { recs = list }
        // Then their covers and a song of each to try, as they come.
        for i in list.indices {
            let r = await ArtistArt.ref(list[i].name)
            list[i].album = r.album; list[i].image = r.url
            if let j = try? await LastFM.shared.call("artist.gettoptracks", ["artist": list[i].name, "limit": "3", "autocorrect": "1"], fresh: 86400) {
                let tracks = j["toptracks"]["track"].array
                let mine = await db.playsOf(artist: list[i].name, tracks: tracks.map { $0["name"].text })
                if let t = tracks.first(where: { (mine[$0["name"].text.lowercased()] ?? 0) == 0 }) ?? tracks.first {
                    list[i].track = t["name"].text; list[i].trackListeners = t["listeners"].int
                }
            }
            recs = list
        }
        day = LocalDay.today
        UserDefaults.standard.set(day, forKey: LastFM.shared.mock ? "discover.day.mock" : "discover.day")
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: file, options: .atomic) }
    }
}

struct DiscoverTab: View {
    let top: Int
    @Environment(\.paneLayout) private var pane
    private var m: DiscoverModel { DiscoverModel.shared }
    var body: some View {
        Group {
            if pane {
                FoldSplit {
                    Page(top: top) { VStack(alignment: .leading, spacing: S.section) { HubTitle(text: "discover", size: 80); artists }.padding(.top, S.head) }
                } right: {
                    Page(top: top) { VStack(alignment: .leading, spacing: S.section) { tracks }.padding(.top, S.section) }
                }
            } else {
                Page(top: top) {
                    VStack(alignment: .leading, spacing: S.section) { HubTitle(text: "discover", size: 80); artists; tracks }.padding(.top, S.head)
                }
            }
        }
        .onAppear { m.appear() }
    }

    @ViewBuilder private var artists: some View {
        if m.recs.isEmpty {
            // The first time only: a record turning on glass while the first list is found.
            VStack(spacing: S.inner) {
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    Image(systemName: "opticaldisc").resizable().scaledToFit().foregroundStyle(.white.opacity(0.4))
                        .frame(width: 72).rotationEffect(.degrees(tl.date.timeIntervalSinceReferenceDate * 40))
                }
                Text(HistorySync.shared.complete || m.working ? "Finding artists like yours" : "Ready once your history is read")
                    .font(.body).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity).padding(.vertical, S.section)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: S.corner, style: .continuous))
            .padding(.horizontal, S.margin)
        } else {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "artists for you")
                VStack(spacing: S.gap) { ForEach(m.recs) { r in ArtistRec(r: r) } }
            }
            .padding(.horizontal, S.margin)
        }
    }

    @ViewBuilder private var tracks: some View {
        let list = m.recs.filter { $0.track != nil }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "songs to try")
                VStack(spacing: 0) { ForEach(list) { r in TrackRec(r: r) } }
            }
            .padding(.horizontal, S.margin)
        }
    }
}

struct ArtistRec: View {
    let r: Rec
    var body: some View {
        HStack(spacing: S.gap) {
            Opens(route: .artist(r.name), zoom: "rec|\(r.id)") {
                HStack(spacing: S.inner) {
                    ArtView(ArtRef(artist: r.name, album: r.album, url: r.image), px: 300, corner: 10).frame(width: 84).zoomSource("rec|\(r.id)")
                    VStack(alignment: .leading, spacing: S.pair) {
                        Text(r.name).font(.title3.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        Text("Because you play \(r.because.joined(separator: " and "))").font(.subheadline).foregroundStyle(S.soft).fixedSize(horizontal: false, vertical: true)
                        Text(r.plays == 0 ? "New to you" : "You: \(plays(r.plays))").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                }
            }
            AppleMusicButton(what: .artist, artist: r.name)
        }
        .card()
        .accessibilityElement(children: .contain)
    }
}

struct TrackRec: View {
    let r: Rec
    var body: some View {
        let s = Scrobble.song(artist: r.name, title: r.track ?? "", album: r.album, image: r.image)
        HStack(spacing: S.gap) {
            Opens(route: .track(s), zoom: "try|\(s.id)") {
                HStack(spacing: S.gap) {
                    ArtView(s.art, px: 156, corner: 6).frame(width: S.art).zoomSource("try|\(s.id)")
                    VStack(alignment: .leading, spacing: S.pair / 2) {
                        Text(s.title).font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(s.artist).font(.subheadline).foregroundStyle(S.soft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            AppleMusicButton(what: .song, artist: r.name, title: r.track ?? "")
        }
        .padding(.vertical, S.row / 2)
    }
}

// Straight to Apple Music: the artist or song itself when Apple's store has it, else a search there.
struct AppleMusicButton: View {
    let what: AppleMusic.What
    let artist: String
    var title = ""
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { Task { openURL(await AppleMusic.shared.link(what, artist: artist, title: title)) } } label: {
            Image(systemName: "music.note").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(Press())
        .accessibilityLabel("Open in Apple Music")
    }
}
