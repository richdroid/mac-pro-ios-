import SwiftUI

// The pages: an artist, an album, a track. Each is his story with it first (his plays, his rank, when he found it and
// when he last played it, his tide over the years), then what Last.fm knows (listeners, plays everywhere, words, tags,
// what's like it), then the ways out. Pushed on the tab's own stack, so Back is the system's, where the Duo puts it; a
// page opened from a cover grows out of that cover. Open flat, the story holds the left pane and the rest scrolls on
// the right.
struct RoutePage: View {
    let go: Go
    let space: Namespace.ID
    var body: some View {
        Group {
            switch go.route {
            case .artist(let a): ArtistPage(name: a)
            case .album(let a, let l): AlbumPage(artist: a, album: l)
            case .track(let s): TrackPage(s: s)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ZoomIf(id: go.zoom, space: space))
    }
}
struct ZoomIf: ViewModifier {
    let id: String?
    let space: Namespace.ID
    func body(content: Content) -> some View {
        if let id { content.zoomed(id, space) } else { content }
    }
}

// How a page lays out: open flat two panes; else one column, with the cover beside the figures where there's width.
struct PageLayout<Head: View, Rest: View>: View {
    let ref: ArtRef?
    @ViewBuilder let head: (_ wide: Bool) -> Head
    @ViewBuilder let rest: () -> Rest
    @Environment(\.paneLayout) private var pane
    @State private var wide = false
    var body: some View {
        Group {
            if pane {
                FoldSplit {
                    Page { head(false).padding(.top, S.head) }
                } right: {
                    Page { VStack(alignment: .leading, spacing: S.section) { rest() }.padding(.top, S.section) }
                }
            } else {
                Page {
                    VStack(alignment: .leading, spacing: S.section) { head(wide); rest() }.padding(.top, S.head)
                }
            }
        }
        .modifier(BarFade())
        .onGeometryChange(for: Bool.self) { $0.size.width > 640 } action: { wide = $0 }
        // Behind the fade, not under it: the page's colour runs to every edge.
        .background { Backdrop(ref: ref, moving: false, dim: 0.12) }
    }
}

// The cover large, with a shadow in its own colour.
struct BigCover: View {
    let ref: ArtRef
    let zoom: String?
    var round = false
    var body: some View {
        let tint = ArtStore.shared.palette(ref)?.vivid.color ?? Palette.from(name: ref.artist + ref.album).vivid.color
        ArtView(ref, px: 1000, corner: round ? 400 : 14)
            .shadow(color: tint.opacity(0.45), radius: 34, y: 14)
            .modifier(SourceIf(id: zoom))
    }
}
struct SourceIf: ViewModifier {
    let id: String?
    func body(content: Content) -> some View { if let id { content.zoomSource(id) } else { content } }
}

// His figures with it, then Last.fm's. "–" until each is known.
struct StoryFigures: View {
    let story: Story?
    let noun: String               // "artists", "albums", "tracks"
    var extra: [(String, String)] = []
    var body: some View {
        let st = story
        VStack(alignment: .leading, spacing: S.inner) {
            VStack(alignment: .leading, spacing: S.pair) {
                Text(st.map { number($0.plays) } ?? "–").font(.system(size: 64, weight: .thin)).monospacedDigit().foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                Text(st?.plays == 1 ? "your play" : "your plays").font(.title3.weight(.light)).foregroundStyle(S.soft)
            }
            .accessibilityElement(children: .combine)
            if let st, st.plays > 0 {
                FigureGrid(items: [
                    st.rank.map { ("#\(number($0))", "of your \(number(st.of)) \(noun)") },
                    st.first.map { (dateShort($0), "first played") },
                    st.last.map { (ago($0), "last played") },
                    st.secs.map { (duration($0), "listening") },
                ].compactMap { $0 } + extra)
            } else if !extra.isEmpty {
                FigureGrid(items: extra)
            }
        }
    }
}

// MARK: - Artist

struct ArtistPage: View {
    let name: String
    @State private var story: Story?
    @State private var info: ArtistInfo?
    @State private var cover: ArtRef?
    @State private var apple: URL?
    @State private var similar: [Entry] = []
    @State private var theirs: [Entry] = []
    @State private var mineOnTheirs: [String: Int] = [:]
    @State private var which = 0
    var body: some View {
        let ref = cover ?? ArtRef(artist: name, album: "", url: nil)
        PageLayout(ref: cover) { wide in
            VStack(alignment: .leading, spacing: S.head) {
                HubTitle(text: name, size: 72)
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: S.figures) { BigCover(ref: ref, zoom: nil).frame(width: 260); figures }
                    } else {
                        VStack(alignment: .leading, spacing: S.inner) { BigCover(ref: ref, zoom: nil).frame(maxWidth: 300); figures }
                    }
                }
                .padding(.horizontal, S.margin)
            }
        } rest: {
            if let st = story, st.plays > 0 { tide(st, ref) }
            topTracks
            if let st = story { Panorama(title: "your albums", items: st.albums) }
            about
            Panorama(title: "similar", items: similar) { e in e.plays > 0 ? "You: \(plays(e.plays))" : "New to you" }
            WaysOut(apple: apple, lastfm: info?.url.flatMap(URL.init(string:))).padding(.horizontal, S.margin)
        }
        .task(id: name) { await load() }
    }
    private var figures: some View {
        StoryFigures(story: story, noun: "artists", extra: [
            info?.listeners.map { (compact($0), "listeners") },
            info?.plays.map { (compact($0), "plays on Last.fm") },
        ].compactMap { $0 })
    }
    private func tide(_ st: Story, _ ref: ArtRef) -> some View {
        VStack(alignment: .leading, spacing: S.head) {
            SectionHead(text: "your tide")
            Tide(months: st.months, tint: ArtStore.shared.palette(ref)?.vivid.color ?? S.accent).card()
        }
        .padding(.horizontal, S.margin)
    }
    @ViewBuilder private var topTracks: some View {
        let mine = story?.top ?? []
        if !mine.isEmpty || !theirs.isEmpty {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "top tracks")
                Picker("Top tracks", selection: $which) {
                    Text("Yours").tag(0)
                    Text("On Last.fm").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.bottom, S.pair)
                if which == 0 {
                    ForEach(mine) { e in EntryRow(e: e, context: "mine") }
                } else {
                    ForEach(theirs) { e in
                        let you = mineOnTheirs[e.track.lowercased()] ?? 0
                        EntryRow(e: Entry(kind: .tracks, artist: e.artist, album: e.album, track: e.track, plays: you, image: e.image, rank: e.rank),
                                 context: "theirs", trailing: you > 0 ? nil : "–")
                    }
                }
            }
            .padding(.horizontal, S.margin)
        }
    }
    @ViewBuilder private var about: some View {
        if let info, info.bio != nil || !info.tags.isEmpty {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "about")
                if let bio = info.bio { MoreText(text: bio) }
                if !info.tags.isEmpty { FlowTags(tags: info.tags) }
            }
            .padding(.horizontal, S.margin)
        }
    }
    private func load() async {
        let median = LengthFill.shared.median
        async let st = HistoryDB.shared.story(artist: name, median: median)
        async let c = ArtistArt.ref(name)
        story = await st
        cover = await c
        let i = await ArtistInfo.load(name)
        info = i
        // Last.fm's top tracks, each with his own plays of it, and covers from his history where he has them.
        let mine = await HistoryDB.shared.playsOf(artist: name, tracks: i.top.map(\.track))
        mineOnTheirs = mine
        var t = i.top
        for k in t.indices {
            if let hit = story?.top.first(where: { $0.track.lowercased() == t[k].track.lowercased() }) { t[k] = t[k].with(album: hit.album, image: hit.image) }
            else if let c = cover { t[k] = t[k].with(album: c.album, image: c.url) }
        }
        theirs = t
        apple = await AppleMusic.shared.link(.artist, artist: name)
        // Similar artists, his plays of each, then their covers as they come.
        let counts = await HistoryDB.shared.playsOf(artists: i.similar.map(\.name))
        similar = i.similar.prefix(14).map { Entry(kind: .artists, artist: $0.name, album: "", track: "", plays: counts[$0.name.lowercased()] ?? 0) }
        for k in similar.indices {
            let r = await ArtistArt.ref(similar[k].artist)
            if k < similar.count { similar[k] = similar[k].with(album: r.album, image: r.url) }
        }
    }
}

// MARK: - Album

struct AlbumPage: View {
    let artist: String
    let album: String
    @State private var story: Story?
    @State private var info: AlbumInfo?
    @State private var image: String?
    @State private var apple: URL?
    var body: some View {
        let ref = ArtRef(artist: artist, album: album, url: image)
        PageLayout(ref: ref) { wide in
            VStack(alignment: .leading, spacing: S.head) {
                HubTitle(text: album, size: 72)
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: S.figures) { BigCover(ref: ref, zoom: nil).frame(width: 300); VStack(alignment: .leading, spacing: S.inner) { by; figures } }
                    } else {
                        VStack(alignment: .leading, spacing: S.inner) { BigCover(ref: ref, zoom: nil).frame(maxWidth: 440); by; figures }
                    }
                }
                .padding(.horizontal, S.margin)
            }
        } rest: {
            if let st = story, st.plays > 0 {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "your tide")
                    Tide(months: st.months, tint: ArtStore.shared.palette(ref)?.vivid.color ?? S.accent).card()
                }
                .padding(.horizontal, S.margin)
            }
            tracks(ref)
            if let info, info.wiki != nil || !info.tags.isEmpty {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "about")
                    if let w = info.wiki { MoreText(text: w) }
                    if !info.tags.isEmpty { FlowTags(tags: info.tags) }
                }
                .padding(.horizontal, S.margin)
            }
            WaysOut(apple: apple, lastfm: info?.url.flatMap(URL.init(string:))).padding(.horizontal, S.margin)
        }
        .task(id: album) { await load() }
    }
    private var by: some View {
        Opens(route: .artist(artist)) {
            HStack(spacing: 6) {
                Text(artist).font(.title2.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(S.soft)
            }
        }
        .accessibilityHint("Opens the artist")
    }
    private var figures: some View {
        StoryFigures(story: story, noun: "albums", extra: [
            info?.listeners.map { (compact($0), "listeners") },
            info?.plays.map { (compact($0), "plays on Last.fm") },
        ].compactMap { $0 })
    }
    // The album's tracks in order, each with his plays as a bar; tracks only he has (a deluxe, a single) after them.
    @ViewBuilder private func tracks(_ ref: ArtRef) -> some View {
        let mine = Dictionary((story?.top ?? []).map { ($0.track.lowercased(), $0.plays) }, uniquingKeysWith: +)
        let listed = info?.tracks ?? []
        let names = listed.isEmpty ? (story?.top ?? []).map { (title: $0.track, secs: Int?.none) } : listed
        if !names.isEmpty {
            let peak = max(mine.values.max() ?? 1, 1)
            let tint = ArtStore.shared.palette(ref)?.vivid.color ?? S.accent
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "tracks", trailing: "\(names.count)")
                VStack(spacing: 0) {
                    ForEach(Array(names.enumerated()), id: \.offset) { k, t in
                        let n = mine[t.title.lowercased()] ?? 0
                        Opens(route: .track(Scrobble.song(artist: artist, title: t.title, album: album, image: image))) {
                            HStack(spacing: S.gap) {
                                Text("\(k + 1)").font(.body.weight(.light)).monospacedDigit().foregroundStyle(S.soft).frame(width: 26, alignment: .trailing)
                                VStack(alignment: .leading, spacing: S.pair) {
                                    Text(t.title).font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                    GeometryReader { g in
                                        Capsule().fill(n > 0 ? tint : .white.opacity(0.12)).frame(width: n > 0 ? max(4, g.size.width * CGFloat(n) / CGFloat(peak)) : 4, height: 4)
                                    }
                                    .frame(height: 4)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: S.pair / 2) {
                                    Text(n > 0 ? number(n) : "–").font(.body.weight(.medium)).monospacedDigit().foregroundStyle(.white)
                                    if let s = t.secs { Text(String(format: "%d:%02d", s / 60, s % 60)).font(.caption).monospacedDigit().foregroundStyle(S.soft) }
                                }
                            }
                            .padding(.vertical, S.row / 2 + 2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.horizontal, S.margin)
        }
    }
    private func load() async {
        image = await HistoryDB.shared.artURL(artist, album)
        story = await HistoryDB.shared.story(artist: artist, album: album, median: LengthFill.shared.median)
        let i = await AlbumInfo.load(artist: artist, album: album)
        info = i
        if image == nil { image = i.image }
        apple = ArtStore.shared.appleMusic(ArtRef(artist: artist, album: album, url: image))
        if apple == nil { apple = await AppleMusic.shared.link(.album, artist: artist, title: album) }
    }
}

// MARK: - Track

// The song's page (phase 1's, grown): the cover, the song and where it's from (the artist and album open their pages),
// when this play was, his story with it, Last.fm's figures and words, songs like it, and the ways out.
struct TrackPage: View {
    let s: Scrobble
    @State private var story: Story?
    @State private var info: TrackInfo?
    @State private var similar: [Entry] = []
    @State private var apple: URL?
    var body: some View {
        PageLayout(ref: s.art) { wide in
            Group {
                if wide {
                    HStack(alignment: .bottom, spacing: S.figures) { BigCover(ref: s.art, zoom: nil).frame(width: 300); titles }
                } else {
                    VStack(alignment: .leading, spacing: S.inner) { BigCover(ref: s.art, zoom: nil).frame(maxWidth: 440); titles }
                }
            }
            .padding(.horizontal, S.margin)
            .padding(.top, S.inner)
        } rest: {
            StoryFigures(story: story, noun: "tracks", extra: [
                info?.listeners.map { (compact($0), "listeners") },
                info?.duration.map { (String(format: "%d:%02d", $0 / 60, $0 % 60), "length") },
            ].compactMap { $0 })
            .padding(.horizontal, S.margin)
            if let st = story, st.plays > 1 {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "your tide")
                    Tide(months: st.months, tint: ArtStore.shared.palette(s.art)?.vivid.color ?? S.accent).card()
                }
                .padding(.horizontal, S.margin)
            }
            if let info, info.summary != nil || !info.tags.isEmpty {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "about")
                    if let w = info.summary { MoreText(text: w) }
                    if !info.tags.isEmpty { FlowTags(tags: info.tags) }
                }
                .padding(.horizontal, S.margin)
            }
            if !similar.isEmpty {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "like this")
                    VStack(spacing: 0) { ForEach(similar) { e in EntryRow(e: e, showRank: false, context: "like", trailing: e.plays > 0 ? nil : "–") } }
                }
                .padding(.horizontal, S.margin)
            }
            WaysOut(apple: apple, lastfm: (info?.url ?? s.url).flatMap(URL.init(string:))).padding(.horizontal, S.margin)
        }
        .task(id: s.id) { await load() }
    }
    private var titles: some View {
        VStack(alignment: .leading, spacing: S.pair) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(s.title).font(.system(.largeTitle, weight: .bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                if info?.loved ?? s.loved { Image(systemName: "heart.fill").font(.title2).foregroundStyle(S.accent).accessibilityLabel("Loved") }
            }
            Opens(route: .artist(s.artist)) {
                HStack(spacing: 6) {
                    Text(s.artist).font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(S.soft)
                }
            }
            .accessibilityHint("Opens the artist")
            if !s.album.isEmpty {
                Opens(route: .album(s.artist, s.album)) {
                    HStack(spacing: 6) {
                        Text(s.album).font(.body).foregroundStyle(S.soft)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(S.soft)
                    }
                }
                .accessibilityHint("Opens the album")
            }
            if s.nowPlaying || s.date != nil {
                HStack(spacing: 7) {
                    if s.nowPlaying {
                        Image(systemName: "waveform").symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                        Text("Now playing")
                    } else if let d = s.date {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("Played \(dayName(d) == "today" ? "today" : dayName(d) == "yesterday" ? "yesterday" : dayName(d).capitalizedFirst) at \(d.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).padding(.top, S.pair)
            }
        }
    }
    private func load() async {
        async let st = HistoryDB.shared.story(artist: s.artist, track: s.title, median: LengthFill.shared.median)
        story = await st
        info = await TrackInfo.load(s)
        if let d = info?.duration { await HistoryDB.shared.keepLengths([(s.artist, s.title, d)]) }
        var sim = await TrackInfo.similar(s)
        for k in sim.indices {
            let n = await HistoryDB.shared.playsOf(artist: sim[k].artist, tracks: [sim[k].track])[sim[k].track.lowercased()] ?? 0
            var e = Entry(kind: .tracks, artist: sim[k].artist, album: "", track: sim[k].track, plays: n, image: sim[k].image)
            if e.image == nil, let c = await HistoryDB.shared.cover(of: e.artist) { e = e.with(album: c.album, image: c.url) }
            sim[k] = e
        }
        similar = Array(sim.prefix(8))
        apple = await AppleMusic.shared.link(.song, artist: s.artist, title: s.title)
    }
}

struct FlowTags: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: S.gap / 1.5) {
            ForEach(tags, id: \.self) { t in
                Text(t).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassEffect(.regular, in: Capsule())
            }
        }
    }
}

// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > w && x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > b.maxX && x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}


// Words that grow in place: three lines, and "More" only when there's more than three lines of them.
struct MoreText: View {
    let text: String
    @State private var more = false
    @State private var full: CGFloat = 0
    @State private var short: CGFloat = 0
    var body: some View {
        let cut = full > short + 1
        Button { if cut || more { withAnimation(.smooth) { more.toggle() } } } label: {
            VStack(alignment: .leading, spacing: S.pair) {
                Text(text).font(.body).foregroundStyle(.white.opacity(0.9)).lineLimit(more ? nil : 3).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !more { short = $0 } }
                    .background {
                        // The whole of it, measured unseen at the same width.
                        Text(text).font(.body).fixedSize(horizontal: false, vertical: true).hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full = $0 }
                    }
                if cut || more { Text(more ? "Less" : "More").font(.subheadline.weight(.semibold)).foregroundStyle(S.accent) }
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(cut || more)
    }
}
