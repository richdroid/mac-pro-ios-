import SwiftUI

// Now playing, as its own hub (Richard, 2026-11-24: "I really want stats from, like, for example, how many listeners and
// stuff … the song I'm listening to and everything"). Zune HD's Now Playing is the first page: the cover over his own
// covers' wall, the artist's name drifting, the song in light type, and the numbers. Then the song, its artist and its
// album, each a page of big numbers with labels: everyone's listeners and scrobbles, his plays, his first and last
// scrobble, his rank among everything he plays and his share of his whole history, then the tags and what's like it.
// Everything worked out on the phone from his plays where it can be; Last.fm's numbers asked once an hour.

// One song's numbers, from Last.fm and from his history, kept for the song shown.
@MainActor @Observable final class NowStats {
    static let shared = NowStats()
    private(set) var key = ""
    private(set) var track: TrackInfo?
    private(set) var artist: ArtistInfo?
    private(set) var album: AlbumInfo?
    private(set) var trackStory: Story?
    private(set) var artistStory: Story?
    private(set) var albumStory: Story?
    private(set) var similarTracks: [Entry] = []
    private(set) var similarArtists: [Entry] = []
    // The leading tag and how many people use it on Last.fm.
    private(set) var tagReach: (tag: String, reach: Int)?
    @ObservationIgnored private var task: Task<Void, Never>?

    @ObservationIgnored private var full = false
    // `full: false` (home's tile): only the song's own numbers, two quiet calls, so a launch never queues twenty
    // requests ahead of the history read and the poll. The hub asks for everything.
    func load(_ s: Scrobble, full want: Bool = true) {
        let k = "\(s.artist)|\(s.title)|\(s.album)".lowercased()
        if k == key, full || !want { return }
        key = k
        full = want
        task?.cancel()
        if !want {
            task = Task {
                async let ts = HistoryDB.reader.story(artist: s.artist, track: s.title, median: LengthFill.shared.median)
                async let ti = TrackInfo.load(s)
                let (t0, t1) = await (ts, ti)
                guard !Task.isCancelled else { return }
                trackStory = t0; track = t1
            }
            return
        }
        // The last song's numbers stay until the next one's are in, then swap together (no blank line between songs).
        task = Task {
            let median = LengthFill.shared.median
            async let ts = HistoryDB.reader.story(artist: s.artist, track: s.title, median: median)
            async let ars = HistoryDB.reader.story(artist: s.artist, median: median)
            async let als = s.album.isEmpty ? Story() : HistoryDB.reader.story(artist: s.artist, album: s.album, median: median)
            async let ti = TrackInfo.load(s)
            async let ai = ArtistInfo.load(s.artist)
            async let li = s.album.isEmpty ? AlbumInfo() : AlbumInfo.load(artist: s.artist, album: s.album)
            let (t0, a0, l0, t1, a1, l1) = await (ts, ars, als, ti, ai, li)
            guard !Task.isCancelled else { return }
            trackStory = t0; artistStory = a0; albumStory = s.album.isEmpty ? nil : l0
            track = t1; artist = a1; album = s.album.isEmpty ? nil : l1
            // Then what's like it, and the leading tag's reach.
            var sims = await TrackInfo.similar(s)
            for k in sims.indices {
                let n = await HistoryDB.reader.playsOf(artist: sims[k].artist, tracks: [sims[k].track])[sims[k].track.lowercased()] ?? 0
                var e = Entry(kind: .tracks, artist: sims[k].artist, album: "", track: sims[k].track, plays: n, image: sims[k].image)
                if e.image == nil, let c = await HistoryDB.reader.cover(of: e.artist) { e = e.with(album: c.album, image: c.url) }
                sims[k] = e
            }
            let names = a1.similar.prefix(10).map(\.name)
            let counts = await HistoryDB.reader.playsOf(artists: names)
            var arts: [Entry] = []
            for n in names {
                let r = await ArtistArt.ref(n)
                arts.append(Entry(kind: .artists, artist: n, album: r.album, track: "", plays: counts[n.lowercased()] ?? 0, image: r.url))
            }
            var reach: (String, Int)?
            if let tag = t1?.tags.first ?? a1.tags.first,
               let j = try? await LastFM.shared.call("tag.getinfo", ["tag": tag], fresh: 7 * 86400), let r = j["tag"]["reach"].int {
                reach = (tag, r)
            }
            guard !Task.isCancelled else { return }
            similarTracks = Array(sims.prefix(8))
            similarArtists = arts
            tagReach = reach
        }
    }
}

// A page's worth of big numbers, Zune's way: the figure large and light, what it counts in small capitals under it.
struct BigFigures: View {
    let items: [(String, String)]
    var body: some View {
        if !items.isEmpty { FigureGrid(items: items, size: 40) }
    }
}

// His share of everything he's played, as a percentage that reads at a glance.
func share(_ part: Int, of whole: Int) -> String? {
    guard whole > 0, part > 0 else { return nil }
    let p = Double(part) / Double(whole) * 100
    return p >= 10 ? "\(Int(p.rounded()))%" : p >= 0.1 ? String(format: "%.1f%%", p) : "<0.1%"
}

struct NowPlayingHub: View {
    @Environment(\.paneLayout) private var pane
    @Environment(\.horizontalSizeClass) private var size
    @State private var page: Int
    init(start: Int = 0) { _page = State(initialValue: min(max(start, 0), 3)) }
    private var store: Store { Store.shared }
    private var stats: NowStats { NowStats.shared }
    var body: some View {
        // "now playing" only while it's live (Last.fm answering, the song on): else what was last heard (gate 1, item 6).
        GeometryReader { g in
            // Read here, inside the reader that lays out the pivot: read outside it, the title missed Last.fm going away
            // upright (gate 2a, item 6: NOW PLAYING over LAST HEARD).
            let playing = (store.shown?.nowPlaying ?? false) && !store.trouble
            let sideways = g.size.width > g.size.height * 1.15
            Group {
                if pane {
                    FoldSplit {
                        Page {
                            VStack(alignment: .leading, spacing: S.section) {
                                AppTitle(text: playing ? "now playing" : "last played").turnstile(0)
                                hero(.column).turnstile(1)
                            }.padding(.top, S.head)
                        }
                        .background(alignment: .top) { wall }
                    } right: {
                        Pager(.pivot, title: " ", page: Binding(get: { max(page, 1) }, set: { page = $0 }), top: 0, panels: Array(panels(.column, playing: playing).dropFirst()))
                    }
                } else {
                    Pager(.pivot, title: playing ? "now playing" : "last played", page: $page, top: 0,
                          panels: panels(sideways ? .short : size == .regular ? .wide : .column, playing: playing))
                }
            }
        }
        .task(id: store.shown?.id) { if let s = store.shown { stats.load(s) } }
    }

    private func panels(_ layout: NowHero.Layout, playing: Bool) -> [Panel] {
        var out = [Panel(0, playing ? "playing" : "played") {
            VStack(alignment: .leading, spacing: S.section) { hero(layout) }
                .background(alignment: .top) { wall }
        }]
        out.append(Panel(1, "song") { SongStats() })
        out.append(Panel(2, "artist") { ArtistStats() })
        if !(store.shown?.album.isEmpty ?? true) { out.append(Panel(3, "album") { AlbumStats() }) }
        return out
    }

    @ViewBuilder private func hero(_ layout: NowHero.Layout) -> some View {
        if store.trouble { TroubleNote().padding(.horizontal, S.margin) }
        if store.shown != nil {
            NowHero(layout: layout, titled: false)
            NowFigures().padding(.horizontal, S.margin)
            if let s = store.shown { Later { MixView(artist: s.artist, center: s.art).padding(.horizontal, S.margin) } }
        } else {
            Text("Nothing played yet").font(.zune(.title3, .light)).foregroundStyle(Z.subtle).padding(.horizontal, S.margin)
        }
    }

    // Zune's Now Playing wall: his own covers behind what's on, in the playing cover's colour.
    @ViewBuilder private var wall: some View {
        if let s = store.shown, s.nowPlaying {
            // Half a second after the page: the cover, the song and the head are the first frame, the wall comes behind.
            Later { ArtWall(tint: (ArtStore.shared.palette(s.art) ?? Palette.from(name: s.artist + s.album)).vivid.color).transition(.opacity) }
        }
    }
}

// Under the hero: the song's numbers at a glance (everyone's listeners and scrobbles, his plays of it and of the artist).
struct NowFigures: View {
    private var stats: NowStats { NowStats.shared }
    var body: some View {
        BigFigures(items: [
            stats.track?.listeners.map { (compact($0), "listeners") },
            stats.track?.plays.map { (compact($0), "scrobbles") },
            // His plays of it and of the artist are the hero's own line; here his place and his first time with it.
            stats.trackStory.flatMap { st in st.rank.map { ("#\(number($0))", "of your \(number(st.of)) songs") } },
            stats.trackStory?.last.map { (ago($0), "last scrobble") },
        ].compactMap { $0 })
        .animation(.easeOut(duration: 0.2), value: stats.key)
    }
}

// A stats page under the pivot: head, figures, then what's below.
private struct StatsPage<C: View>: View {
    let title: String
    let byline: String?
    let open: Route?
    @ViewBuilder let rest: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: S.section) {
            VStack(alignment: .leading, spacing: S.pair) {
                if let open {
                    Opens(route: open) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(title).font(.zune(.title, .medium)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                            Image(systemName: "chevron.right").font(.zune(.subheadline, .semibold)).foregroundStyle(Z.subtle)
                        }
                    }
                    .accessibilityHint("Opens its page")
                } else {
                    Text(title).font(.zune(.title, .medium)).foregroundStyle(.white).lineLimit(2)
                }
                if let byline { Text(byline).font(.zune(.body)).foregroundStyle(Z.subtle).lineLimit(1) }
            }
            .padding(.horizontal, S.margin)
            rest()
        }
    }
}

private struct WhenFigures {
    static func items(_ st: Story?, noun: String) -> [(String, String)] {
        guard let st, st.plays > 0 else { return [] }
        return [
            st.rank.map { ("#\(number($0))", "of your \(number(st.of)) \(noun)") },
            st.first.map { (dateShort($0), "first scrobble") },
            st.last.map { (ago($0), "last scrobble") },
            st.secs.map { (duration($0), "listening") },
        ].compactMap { $0 }
    }
}

struct SongStats: View {
    private var stats: NowStats { NowStats.shared }
    private var store: Store { Store.shared }
    var body: some View {
        if let s = store.shown {
            StatsPage(title: s.title, byline: s.artist, open: .track(s)) {
                BigFigures(items: [
                    stats.track?.listeners.map { (compact($0), "listeners") },
                    stats.track?.plays.map { (compact($0), "scrobbles") },
                    (stats.track?.userPlays ?? stats.trackStory?.plays).map { (number($0), $0 == 1 ? "your play" : "your plays") },
                    stats.track?.duration.map { (String(format: "%d:%02d", $0 / 60, $0 % 60), "length") },
                ].compactMap { $0 }).padding(.horizontal, S.margin)
                let when = WhenFigures.items(stats.trackStory, noun: "tracks")
                if !when.isEmpty { BigFigures(items: when).padding(.horizontal, S.margin) }
                if let t = stats.track, t.listeners.map({ $0 > 0 }) == true, let mine = t.userPlays, mine > 0, let all = t.plays, all > 0 {
                    // How much of the world's listening to it is his.
                    let per = Double(all) / Double(max(t.listeners ?? 1, 1))
                    Text("Everyone who plays it averages \(String(format: "%.1f", per)) plays; you've played it \(number(mine)) times.")
                        .font(.zune(.body)).foregroundStyle(Z.subtle).padding(.horizontal, S.margin).fixedSize(horizontal: false, vertical: true)
                }
                TagsBlock(tags: stats.track?.tags ?? [], reach: stats.tagReach)
                if let w = stats.track?.summary { VStack(alignment: .leading, spacing: S.head) { SectionHead(text: "about"); MoreText(text: w) }.padding(.horizontal, S.margin) }
                if !stats.similarTracks.isEmpty {
                    VStack(alignment: .leading, spacing: S.head) {
                        SectionHead(text: "like this")
                        VStack(spacing: 0) { ForEach(stats.similarTracks) { e in EntryRow(e: e, showRank: false, context: "nowlike", trailing: e.plays > 0 ? nil : "new") } }
                    }
                    .padding(.horizontal, S.margin)
                }
            }
        }
    }
}

struct ArtistStats: View {
    private var stats: NowStats { NowStats.shared }
    private var store: Store { Store.shared }
    var body: some View {
        if let s = store.shown {
            let mine = stats.artist?.userPlays ?? stats.artistStory?.plays
            StatsPage(title: s.artist, byline: stats.artist?.tags.prefix(3).joined(separator: " · "), open: .artist(s.artist)) {
                BigFigures(items: [
                    stats.artist?.listeners.map { (compact($0), "listeners") },
                    stats.artist?.plays.map { (compact($0), "scrobbles") },
                    mine.map { (number($0), "your plays") },
                    mine.flatMap { m in share(m, of: store.profile?.playcount ?? 0).map { ($0, "of your scrobbles") } },
                ].compactMap { $0 }).padding(.horizontal, S.margin)
                let when = WhenFigures.items(stats.artistStory, noun: "artists")
                if !when.isEmpty { BigFigures(items: when).padding(.horizontal, S.margin) }
                if let st = stats.artistStory, st.plays > 0 { YourTide(story: st, tint: ArtStore.shared.palette(s.art)?.vivid.color ?? Z.magenta) }
                if let st = stats.artistStory, !st.top.isEmpty {
                    VStack(alignment: .leading, spacing: S.head) {
                        SectionHead(text: "your top songs")
                        VStack(spacing: 0) { ForEach(st.top.prefix(5)) { e in EntryRow(e: e, context: "nowtop") } }
                    }
                    .padding(.horizontal, S.margin)
                }
                if !stats.similarArtists.isEmpty {
                    Panorama(title: "similar", items: stats.similarArtists, tiles: true) { e in e.plays > 0 ? "\(number(e.plays)) plays" : "New to you" }
                }
                if let b = stats.artist?.bio { VStack(alignment: .leading, spacing: S.head) { SectionHead(text: "about"); MoreText(text: b) }.padding(.horizontal, S.margin) }
            }
        }
    }
}

struct AlbumStats: View {
    private var stats: NowStats { NowStats.shared }
    private var store: Store { Store.shared }
    var body: some View {
        if let s = store.shown, !s.album.isEmpty {
            let mine = stats.album?.userPlays ?? stats.albumStory?.plays
            StatsPage(title: s.album, byline: s.artist, open: .album(s.artist, s.album)) {
                BigFigures(items: [
                    stats.album?.listeners.map { (compact($0), "listeners") },
                    stats.album?.plays.map { (compact($0), "scrobbles") },
                    mine.map { (number($0), "your plays") },
                    mine.flatMap { m in share(m, of: store.profile?.playcount ?? 0).map { ($0, "of your scrobbles") } },
                ].compactMap { $0 }).padding(.horizontal, S.margin)
                let when = WhenFigures.items(stats.albumStory, noun: "albums")
                if !when.isEmpty { BigFigures(items: when).padding(.horizontal, S.margin) }
                if let tracks = stats.album?.tracks, !tracks.isEmpty {
                    let counts = Dictionary((stats.albumStory?.top ?? []).map { ($0.track.lowercased(), $0.plays) }) { a, _ in a }
                    let peak = max(counts.values.max() ?? 1, 1)
                    VStack(alignment: .leading, spacing: S.head) {
                        SectionHead(text: "tracks")
                        VStack(spacing: 10) {
                            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                                let n = counts[t.title.lowercased()] ?? 0
                                let on = t.title.lowercased() == s.title.lowercased()
                                HStack(spacing: S.gap) {
                                    Text("\(i + 1)").font(.zune(size: 22, .light)).monospacedDigit().foregroundStyle(Z.subtle).frame(width: 30, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(t.title).font(.zune(.body, on ? .semibold : .regular)).foregroundStyle(.white).lineLimit(1)
                                        GeometryReader { g in
                                            Capsule().fill(on ? AnyShapeStyle(Z.accent) : AnyShapeStyle(.white.opacity(0.5)))
                                                .frame(width: max(2, g.size.width * CGFloat(n) / CGFloat(peak)), height: 3)
                                        }.frame(height: 3)
                                    }
                                    Text(n > 0 ? number(n) : "–").font(.zune(.subheadline)).monospacedDigit().foregroundStyle(Z.subtle)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .padding(.horizontal, S.margin)
                }
                if let w = stats.album?.wiki { VStack(alignment: .leading, spacing: S.head) { SectionHead(text: "about"); MoreText(text: w) }.padding(.horizontal, S.margin) }
            }
        }
    }
}

// Tags as Zune's lowercase words, the leading one with how many people use it on Last.fm.
struct TagsBlock: View {
    let tags: [String]
    let reach: (tag: String, reach: Int)?
    var body: some View {
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "tags")
                Text(tags.joined(separator: "  ")).font(.zune(.title2, .light)).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                if let r = reach, tags.contains(r.tag) {
                    Text("\(compact(r.reach)) people listen to \(r.tag) on Last.fm").font(.zune(.subheadline)).foregroundStyle(Z.subtle)
                }
            }
            .padding(.horizontal, S.margin)
        }
    }
}

// History: his day, and every play. A pivot of two: "today" (the figures, the last song when nothing's on, the day by the
// hour) and "recent" (every scrobble, by day).
struct HistoryHub: View {
    @State private var page: Int
    init(start: Int = 0) { _page = State(initialValue: min(max(start, 0), 1)) }
    private var store: Store { Store.shared }
    var body: some View {
        let playing = store.shown?.nowPlaying ?? false
        HubPivot(page: $page, panels: [
            Panel(0, "today") {
                VStack(alignment: .leading, spacing: S.section) {
                    if store.trouble { TroubleNote().padding(.horizontal, S.margin) }
                    VStack(alignment: .leading, spacing: S.section) {
                        TodayFigures()
                        if !playing, let last = store.recent.first { LastPlayed(s: last) }
                    }
                    .padding(.horizontal, S.margin)
                    DaySection(lead: true).id("day")
                    // The day's songs under its chart, newest first (gate 1: half the page was empty).
                    let today = Array(store.today.reversed())
                    if !today.isEmpty {
                        VStack(alignment: .leading, spacing: S.head) {
                            SectionHead(text: "today's songs", trailing: "\(today.count)")
                            VStack(spacing: 0) { ForEach(today.prefix(40)) { s in TrackRow(s: s) } }
                        }
                        .padding(.horizontal, S.margin)
                    }
                }
            },
            Panel(1, "all plays") { RecentSection(skipFirst: false) },
        ])
    }
}
