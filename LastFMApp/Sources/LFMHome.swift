import SwiftUI

// Home, as a Windows Phone 7 panorama (Richard, 2026-11-25: "just make this work as a zune windows phone app", "tiles r
// super important"): the app's name huge and light across the top, wider than the screen, sliding at a slower rate than
// the sections under it; then the sections side by side, each a little narrower than the screen so the next one shows at
// the right: "start", his live tiles (now playing, profile, today, charts, library, discover, rediscover, history,
// scrobbling); "menu", Zune HD's huge lowercase words; "just played" and "on repeat", covers as tiles. Open flat the start
// screen holds the left pane and the rest the right, nothing across the fold.
// Opening anything: everything on the screen turnstiles away about its left edge, 20 ms apart, the tapped one last, and
// the hub turns in. Back is the system's.
struct HomeView: View {
    @Environment(\.paneLayout) private var pane
    @Environment(\.openRoute) private var open
    private var store: Store { Store.shared }
    var body: some View {
        Group {
            if pane {
                FoldSplit {
                    Page {
                        VStack(alignment: .leading, spacing: S.head) {
                            AppTitle(text: "rotation").modifier(order("title"))
                            StartTiles(width: nil, go: go)
                        }
                        .padding(.top, S.head)
                    }
                } right: {
                    Page {
                        VStack(alignment: .leading, spacing: S.section) {
                            MenuWords(go: go).padding(.leading, S.margin)
                            AlbumTiles(title: "just played", items: Quickplay.albums(store.recent), width: nil)
                            ArtistTiles(title: "on repeat", list: store.insights.week, width: nil)
                        }
                        .padding(.top, S.head)
                    }
                }
            } else {
                HomePanorama(go: go)
            }
        }
        .opacity(HomeLeave.shared.cleared ? 0 : 1)
        .background { if pane { Backdrop(ref: Ground.hubs.pick?.ref).opacity(HomeLeave.shared.cleared ? 0 : 1) } else { Color.black.ignoresSafeArea() } }
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { TileClock.shared.start(); HomeSwipe.moving = false; TouchTravel.swiped = false }
        // Back on home finds it as it was: everything flat again (reset once the hub has covered it).
        .onDisappear {
            TileClock.shared.stop()
            var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { HomeLeave.shared.chosen = nil; HomeLeave.shared.cleared = false }
        }
        .task(id: store.shown?.id) { if let s = store.shown { NowStats.shared.load(s, full: false) } }
        // What the rediscover tile shows, worked out off the main thread once the screen has settled.
        .task { try? await Task.sleep(nanoseconds: 2_500_000_000); RediscoverModel.shared.appear() }
        // The hubs prewarmed once home is at rest: the backdrops a hub and now playing open on, baked for the song shown,
        // so a push's first frame never waits on them (gate on build 71: bare frames after a tile tap).
        .task(id: store.shown?.id) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let s = store.shown else { return }
            _ = await ArtStore.shared.treated(s.art, .muted)
            let tint = (ArtStore.shared.palette(s.art) ?? Palette.from(name: s.art.artist + s.art.album)).vivid
            if let photo = ArtistPhotos.shared.plain(s.artist) { _ = await ArtStore.shared.treated(photo, .tinted(tint)) }
            else { _ = await ArtStore.shared.treated(s.art, .duotone) }
        }
        // Each hub drawn once, small and unseen, while home rests, and his figures worked out: a hub's first push spent
        // 0.4-0.9 s resolving its view types for the first time (profile runs 10-13: swift_conformsToProtocol and the
        // metadata of every hub under the push), a bare backdrop the whole time. Drawn into a bitmap, nothing of theirs
        // runs; done before the tiles start turning.
        .task { await HubWarm.run() }
    }

    private func order(_ key: String) -> TurnstileOut { TurnstileOut(index: Home.order(key), count: Home.count) }

    // Everything leaves first (0.25 s, feathered, the tapped one last), then the hub is pushed without the system's slide:
    // its own turnstile brings it in.
    private func go(_ key: String, _ hub: Hub, _ panel: Int?) {
        guard HomeLeave.shared.chosen == nil else { return }
        // A swipe begun on a tile or word, or one let go while the panorama still moves, is never a tap (WP7; gate on
        // build 71: a quick flick across the menu open flat opened History).
        if TouchTravel.swiped || HomeSwipe.moving { TouchTravel.swiped = false; return }
        // Read by the turnstiles alone: the tiles and words under them aren't worked out again as they leave.
        HomeLeave.shared.chosen = Home.order(key)
        Task { @MainActor in
            // The parts all but gone (the last starts at 0.06 s and swings 0.25 s, ease in), then the hub, whose own
            // turnstile starts on its first frame: out and in chained, with no bare frames between (gate on build 71).
            try? await Task.sleep(nanoseconds: UInt64(HomeLeave.wait(Home.order(key)) * 1_000_000_000))
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { HomeLeave.shared.cleared = true }
            // Two frames for the black to be on screen before the push's stall.
            try? await Task.sleep(nanoseconds: 34_000_000)
            open.hub(hub, panel)
        }
    }
}

@MainActor enum HubWarm {
    private static var done: Set<Hub> = []
    static func run() async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        for h in [Hub.profile, .nowPlaying, .charts, .library, .discover, .history, .scrobbling] where !done.contains(h) {
            // Only while home is at rest and on screen.
            for _ in 0..<40 {
                if !Store.shared.scrolling, !HomeSwipe.moving, HomeLeave.shared.chosen == nil, !NavTransit.shared.inFlight { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled, HomeLeave.shared.chosen == nil else { return }
            let r = ImageRenderer(content: HubView(hub: h, panel: nil).environment(\.turnstileArrived, true).frame(width: 390, height: 844))
            r.scale = 0.05
            _ = r.cgImage
            done.insert(h)
            if h == .profile { await Totals.warm() }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}

// The panorama between a finger's touch and its rest (the landing included): a tap let go then is never an opening.
@MainActor enum HomeSwipe { static var moving = false }

// The order things leave home in (top to bottom, left to right), for the turnstile out.
enum Home {
    static let keys = ["title", "h-start", "now", "profile", "today", "charts", "library", "discover", "rediscover", "history", "scrobbling",
                       "h-menu"] + Hub.menu.map { "w-" + $0.rawValue } + ["h-played", "h-repeat"]
    static var count: Int { keys.count }
    static func order(_ k: String) -> Int { keys.firstIndex(of: k) ?? 0 }
}

// The panorama: its title, then its sections, each paged to the left margin with WP7's paging; the title slides at
// a fraction of the sections' rate, so its end comes into view only as the last section does.
private struct HomePanorama: View {
    let go: (String, Hub, Int?) -> Void
    @State private var motion = PagerMotion()
    @State private var pos = ScrollPosition(edge: .leading)
    // Where the panorama rests, kept out of view state: as state, the lift redrew the whole panorama in the first frame
    // of its settle. The tick has a small view of its own.
    @State private var rest = Rest()
    final class Rest { var section = 0 }
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1
    private var store: Store { Store.shared }
    var body: some View {
        GeometryReader { out in
            let insets = out.safeAreaInsets
            GeometryReader { g in
                let side = (leading: insets.leading, trailing: insets.trailing)
                let W = max(g.size.width, 1), H = g.size.height
                let pw = max(W - side.leading - side.trailing, 1)
                // A section is the screen less WP7's 48 px, so the next one's first tiles show at the right; open upright,
                // no wider than a phone's, so more of the next section shows (never stretched tiles).
                let sec = min(pw - 48, 440)
                let count = 4
                // WP7's panorama title (study §1): FontSize 187 on a 480 px screen (0.39 of the width), Light, plain white,
                // Margin 10,-76,0,9 in its row under the 32 px tray: the letters' x-height starts 0.18 of the size below
                // the tray and the items begin 0.97 of the size below it. Placed here from the face's own metrics.
                let T0 = min(300, max(112, pw * 0.39)) * min(max(k, 0.9), 1.1)
                // Always wider than the screen, as WP7's panorama title is (open upright a short name fitted inside it).
                let w0 = textWidth("rotation", size: T0, tracking: -3, weight: -0.4, face: Z.lower())
                let T = w0 > 0 && w0 < pw * 1.12 ? T0 * pw * 1.12 / w0 : T0
                let m = Self.metrics(T)
                let across = TopBar.across()
                let tray = across?.maxY ?? insets.top
                let titleTop = tray + T * 0.18 - (m.ascender - m.xHeight)
                let sectionsTop = tray + T * 0.97
                let titleW = textWidth("rotation", size: T, tracking: -3, weight: -0.4, face: Z.lower())
                let travel = max(1, sec * CGFloat(count - 1))
                // The layers' rates from their widths (study §2: "the speed relates to the ratio of the content's width to
                // the background's"): each crosses its own overhang once over the panorama's travel. The title, shorter,
                // is the slowest; the background (as tall as the screen, square) next; the sections 1:1.
                let titleRate = max(0.05, (titleW + 10 - pw) / travel)
                let bgSide = max(H * 1.02, pw + 40)
                let bgRate = max(titleRate + 0.05, min(0.9, (bgSide - pw) / travel))
                ZStack(alignment: .topLeading) {
                    PanoramaBackground(ref: Ground.hubs.pick?.ref, motion: motion, rate: bgRate, side: bgSide)
                        .modifier(TurnstileOut(index: 0, count: Home.count))
                    PanoramaTitle(text: "rotation", size: T, motion: motion, rate: titleRate)
                        .padding(.leading, side.leading + 10)
                        .offset(y: titleTop)
                        .modifier(TurnstileOut(index: 0, count: Home.count))
                        .turnstile(0)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            section("start", key: "h-start", 0, sec, H - sectionsTop, side) { StartTiles(width: sec - S.margin - 12, go: go) }
                            section("menu", key: "h-menu", 1, sec, H - sectionsTop, side) { MenuWords { go($0, $1, $2) } }
                            section("just played", key: "h-played", 2, sec, H - sectionsTop, side) {
                                AlbumTiles(title: nil, items: Quickplay.albums(store.recent), width: sec - S.margin - 12)
                            }
                            section("on repeat", key: "h-repeat", 3, sec, H - sectionsTop, side) {
                                ArtistTiles(title: nil, list: store.insights.week, width: sec - S.margin - 12)
                            }
                        }
                        // WP7's panorama stops hard at both ends.
                        .background(alignment: .topLeading) { NoBounce(); FastSettle(lander: motion.lander) }
                        .padding(.leading, side.leading)
                        // Room after the last section so it, too, rests at the left margin.
                        .padding(.trailing, pw - sec + side.trailing)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(WPPaging(width: sec, count: count, motion: motion))
                    .scrollPosition($pos)
                    .scrollIndicators(.hidden)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in if !motion.landing { motion.x = x; motion.sample(x) } }
                    // Let go: the section chosen (WPPaging) is reached by the lander in 0.35 s, the tick as it starts.
                    .onScrollPhaseChange { old, p in
                        motion.phase = p
                        if p == .interacting, old != .interacting { motion.began() }
                        if old == .idle, p != .idle { Store.shared.scrolling = true; HomeSwipe.moving = true }
                        if p == .interacting { motion.lander.stop() }
                        guard p == .idle else { return }
                        if let t = motion.target {
                            motion.target = nil
                            arrive(max(0, min(count - 1, t)), sec)
                        } else if !motion.lander.active {
                            settle(sec, count)
                        }
                    }
                    .frame(width: W, height: H - sectionsTop)
                    .offset(y: sectionsTop)
                    .background { PagerTick(motion: motion) }
                }
                .frame(width: W, height: H, alignment: .topLeading)
                .clipped()
                // The build's poses: opened on a later section (-section n).
                .task {
                    let n = Int(UserDefaults.standard.string(forKey: "section") ?? "") ?? 0
                    guard n > 0 else { return }
                    // Again as the panorama settles (run 61: once, too early, and the shot stayed on start).
                    for _ in 0..<4 {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) { pos.scrollTo(x: CGFloat(min(n, count - 1)) * sec) }
                    }
                    rest.section = n
                }
            }
            .ignoresSafeArea(.container, edges: .all)
        }
    }

    private func arrive(_ t: Int, _ sec: CGFloat) {
        if t != rest.section { motion.landed += 1 }
        rest.section = t
        let x = CGFloat(t) * sec
        if !motion.lander.land(to: x, done: { settle(sec, 4) }) {
            withAnimation(Z.easeOut(0.35)) { pos.scrollTo(x: x) } completion: { settle(sec, 4) }
        }
    }
    private func settle(_ sec: CGFloat, _ count: Int) {
        let x = motion.offset
        let r = max(0, min(count - 1, Int((x / max(sec, 1)).rounded())))
        if abs(x - CGFloat(r) * sec) > 1, motion.lander.land(to: CGFloat(r) * sec, done: { settle(sec, count) }) { return }
        motion.rested(w: sec, slots: count)
        rest.section = r
        Store.shared.scrolling = false
        HomeSwipe.moving = false
    }

    // A section: its name (WP7's panorama header, Semilight 42.667 px, lowercase), then its content, which scrolls on its
    // own under the name.
    private func section<C: View>(_ name: String, key: String, _ i: Int, _ w: CGFloat, _ h: CGFloat, _ side: (leading: CGFloat, trailing: CGFloat), @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: S.gap) {
            Text(name).font(.zuneLower(size: 40)).tracking(-0.8).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.leading, S.margin - 2)
                .modifier(TurnstileOut(index: Home.order(key), count: Home.count))
                .accessibilityAddTraits(.isHeader)
            let body = content()
                // The cover sections leave whole with their names (run 77: "just played" stayed through the leave).
                .modifier(TurnstileOut(index: key == "h-played" || key == "h-repeat" ? Home.order(key) : -1, count: Home.count))
            WPScroll {
                body
                    .padding(.leading, S.margin)
                    .padding(.bottom, max(S.section, 34))
                    .frame(width: w, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .onScrollPhaseChange { _, p in Store.shared.scrolling = p != .idle }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .environment(\.pageWidth, w)
        .turnstile(min(i, 2) + 1)
    }
}

// The panorama's title, the only thing that reads where the panorama is, so a swipe redraws the title and nothing else.
// Plain white (Richard, 11-26: "no color on topmost text saying rotation"; WP7.0's music+videos title was white).
private struct PanoramaTitle: View {
    let text: String
    let size: CGFloat
    let motion: PagerMotion
    let rate: CGFloat
    var body: some View {
        Text(text)
            .font(.zuneLower(size: size)).tracking(-3)
            .foregroundStyle(.white)
            .lineLimit(1).fixedSize()
            .offset(x: -motion.x * rate)
            .accessibilityAddTraits(.isHeader)
    }
}

extension HomePanorama {
    // The title face's ascender and x-height at a size, measured once per size.
    @MainActor private static var kept: [CGFloat: (ascender: CGFloat, xHeight: CGFloat)] = [:]
    @MainActor static func metrics(_ size: CGFloat) -> (ascender: CGFloat, xHeight: CGFloat) {
        if let k = kept[size] { return k }
        #if canImport(UIKit)
        let f = UIFont(name: Z.lower(), size: size) ?? Z.uiFont(size, weight: -0.4)
        let v = (f.ascender, f.xHeight)
        #else
        let v = (size * 1.08, size * 0.5)
        #endif
        kept[size] = v
        return v
    }
}

// The panorama's picture (the ground: one per visit, Ground.hubs), square, as tall as the screen, darkened, sliding at
// its width's rate. A new artist's picture fades in over the old one (1.2 s), never cut.
private struct PanoramaBackground: View {
    let ref: ArtRef?
    let motion: PagerMotion
    let rate: CGFloat
    let side: CGFloat
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black
                if let ref {
                    ArtView(ref, px: 1000, corner: 0).frame(width: side, height: side)
                        .offset(y: (g.size.height - side) / 2)
                        .id(ref.key)
                        .transition(.opacity)
                }
                // WP7: "dark, soft, low-contrast… a semi-transparent black filter".
                LinearGradient(stops: [.init(color: .black.opacity(0.42), location: 0), .init(color: .black.opacity(0.6), location: 0.4),
                                       .init(color: .black.opacity(0.82), location: 1)], startPoint: .top, endPoint: .bottom)
                    .frame(width: side, height: g.size.height)
            }
            .frame(width: side, height: g.size.height, alignment: .topLeading)
            .offset(x: -motion.x * rate)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The start screen: live tiles

// WP7's start screen, his tiles: two columns of squares with wide ones across both, 12 between, in the accent or a cover.
// Each opens its hub with the turnstile; each tips under the finger; they turn one at a time (TileClock).
struct StartTiles: View {
    let width: CGFloat?
    let go: (String, Hub, Int?) -> Void
    @Environment(\.pageWidth) private var pageWidth
    private var store: Store { Store.shared }
    var body: some View {
        let cw = width ?? max(200, pageWidth - S.margin * 2)
        let t = floor((cw - S.gap) / 2)
        let wide = t * 2 + S.gap
        VStack(alignment: .leading, spacing: S.gap) {
            tile("now", .nowPlaying, nil, w: wide, h: t) { NowLiveTile() }
            HStack(spacing: S.gap) {
                tile("profile", .profile, 0, w: t, h: t) { ProfileLiveTile() }
                tile("today", .history, 0, w: t, h: t) { TodayLiveTile() }
            }
            HStack(spacing: S.gap) {
                tile("charts", .charts, nil, w: t, h: t) { ChartsLiveTile() }
                tile("library", .library, nil, w: t, h: t) { LibraryLiveTile() }
            }
            tile("discover", .discover, 0, w: wide, h: t) { DiscoverLiveTile() }
            HStack(spacing: S.gap) {
                tile("rediscover", .discover, 2, w: t, h: t) { RediscoverLiveTile() }
                tile("history", .history, 1, w: t, h: t) { HistoryLiveTile() }
            }
            tile("scrobbling", .scrobbling, nil, w: wide, h: floor(t * 0.5)) { ScrobbleLiveTile() }
        }
        .frame(width: cw, alignment: .leading)
    }
    private func tile<C: View>(_ key: String, _ hub: Hub, _ panel: Int?, w: CGFloat, h: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
        Button { go(key, hub, panel) } label: { c().frame(width: w, height: h) }
            .buttonStyle(Tilt())
            .modifier(TurnstileOut(index: Home.order(key), count: Home.count))
    }
}

// A tile's colour from the art it stands for (Zune's colour came from the covers), darkened until white reads on it.
@MainActor func tileColor(_ ref: ArtRef?) -> Color {
    guard let ref else { return Z.magenta }
    let p = ArtStore.shared.palette(ref) ?? Palette.from(name: ref.artist + ref.album)
    let v = p.vivid
    let l = 0.2126 * v.r + 0.7152 * v.g + 0.0722 * v.b
    return v.scaled(l > 0.42 ? 0.42 / l : 1).color
}

// A tile's words over the accent: a figure large and light, a line under it (WP7's tile back).
private struct TileWords: View {
    let big: String
    let line: String
    var small: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let small { Text(small).font(.zuneCaps(size: 14, .semibold)).textCase(.uppercase).tracking(0.8).foregroundStyle(.white.opacity(0.85)).lineLimit(1) }
            Text(big).font(.zune(size: 40, .light)).monospacedDigit().foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
            Text(line).font(.zune(size: 16, .regular)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
// A symbol in the tile's centre, white, as WP7's tile icons are.
private struct TileIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.system(size: 38, weight: .light)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 14)
    }
}
// A cover filling the tile (cropped to the tile's shape).
private struct TileCover: View {
    let ref: ArtRef
    var px = 400
    var body: some View {
        GeometryReader { g in
            ArtView(ref, px: px, corner: 0).frame(width: max(g.size.width, g.size.height), height: max(g.size.width, g.size.height))
                .frame(width: g.size.width, height: g.size.height).clipped()
        }
    }
}

private struct NowLiveTile: View {
    private var store: Store { Store.shared }
    private var stats: NowStats { NowStats.shared }
    var body: some View {
        if let s = store.shown {
            // The cover, peeking up now and then to show what it is (WP7's peek).
            LiveTile(id: "now", name: s.nowPlaying ? "now playing" : "last played", motion: .peek, fill: tileColor(s.art)) {
                TileCover(ref: s.art, px: 600)
            } back: {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    Text(s.title).font(.zune(size: 22, .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(s.artist).font(.zune(size: 17)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .accessibilityLabel("\(s.nowPlaying ? "Now playing" : "Last played"): \(s.title) by \(s.artist)")
        } else {
            LiveTile(id: "now", name: "now playing") { TileIcon(name: "music.note") } back: { TileIcon(name: "music.note") }
        }
    }
}

private struct ProfileLiveTile: View {
    private var store: Store { Store.shared }
    var body: some View {
        let p = store.profile
        LiveTile(id: "profile", name: "profile") {
            if let p { TileCover(ref: ArtRef(artist: p.name, album: "avatar", url: p.image), px: 300) } else { TileIcon(name: "person") }
        } back: {
            TileWords(big: p.map { compact($0.playcount) } ?? "–", line: "scrobbles", small: ProfileHead.name)
        }
    }
}

private struct TodayLiveTile: View {
    private var store: Store { Store.shared }
    var body: some View {
        let n = store.today.filter { !$0.nowPlaying }.count
        LiveTile(id: "today", name: "today", fill: tileColor(store.shown?.art)) {
            TileWords(big: number(n), line: n == 1 ? "play today" : "plays today")
        } back: {
            TileWords(big: store.insights.streak.map { "\($0)" } ?? "–", line: store.insights.streak == 1 ? "day in a row" : "days in a row")
        }
    }
}

private struct ChartsLiveTile: View {
    private var store: Store { Store.shared }
    var body: some View {
        if let a = store.insights.week.first {
            LiveTile(id: "charts", name: "charts", fill: tileColor(ArtRef(artist: a.name, album: a.album, url: a.image))) {
                TileCover(ref: ArtRef(artist: a.name, album: a.album, url: a.image), px: 300)
            } back: {
                TileWords(big: a.name, line: "\(number(a.plays)) plays this week", small: "no. 1")
            }
        } else {
            LiveTile(id: "charts", name: "charts") { TileIcon(name: "chart.bar") } back: { TileIcon(name: "chart.bar") }
        }
    }
}

private struct LibraryLiveTile: View {
    private var store: Store { Store.shared }
    var body: some View {
        let covers = Quickplay.albums(store.recent).prefix(4).map(\.art)
        LiveTile(id: "library", name: "library", fill: tileColor(covers.first)) {
            if covers.count == 4 {
                // Four covers, two by two, as WP7's music tile showed his collection.
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { TileCover(ref: covers[0], px: 160); TileCover(ref: covers[1], px: 160) }
                    GridRow { TileCover(ref: covers[2], px: 160); TileCover(ref: covers[3], px: 160) }
                }
            } else { TileIcon(name: "square.stack") }
        } back: {
            TileWords(big: store.profile.map { number($0.artists) } ?? "–", line: "artists in your library")
        }
    }
}

private struct DiscoverLiveTile: View {
    private var picks: [Rec] { DiscoverModel.shared.recs }
    var body: some View {
        if let r = picks.first {
            LiveTile(id: "discover", name: "discover", motion: .peek, fill: tileColor(ArtRef(artist: r.name, album: r.album, url: r.image))) {
                HStack(spacing: 0) {
                    ForEach(Array(picks.prefix(3).enumerated()), id: \.offset) { _, p in
                        TileCover(ref: ArtRef(artist: p.name, album: p.album, url: p.image), px: 300)
                    }
                }
            } back: {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    Text("for you: \(r.name)").font(.zune(size: 20, .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let b = r.because.first { Text("because you play \(b)").font(.zune(size: 16)).foregroundStyle(.white.opacity(0.85)).lineLimit(1) }
                    Color.clear.frame(height: 28)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        } else {
            LiveTile(id: "discover", name: "discover") { TileIcon(name: "sparkles") } back: { TileIcon(name: "sparkles") }
        }
    }
}

private struct RediscoverLiveTile: View {
    private var model: RediscoverModel { RediscoverModel.shared }
    var body: some View {
        if let e = model.r.albums.first ?? model.r.songs.first {
            LiveTile(id: "rediscover", name: "rediscover", fill: tileColor(e.art)) {
                TileCover(ref: e.art, px: 300)
            } back: {
                TileWords(big: e.title, line: "you used to love", small: nil)
            }
        } else {
            LiveTile(id: "rediscover", name: "rediscover") { TileIcon(name: "arrow.counterclockwise") } back: { TileIcon(name: "arrow.counterclockwise") }
        }
    }
}

private struct HistoryLiveTile: View {
    private var store: Store { Store.shared }
    var body: some View {
        let last = store.recent.first
        LiveTile(id: "history", name: "history", fill: tileColor(store.recent.dropFirst().first?.art ?? last?.art)) {
            TileWords(big: last.map { $0.title } ?? "–", line: last.map { when($0.date) } ?? "")
        } back: {
            TileWords(big: last.map { $0.artist } ?? "–", line: "last played")
        }
    }
}

private struct ScrobbleLiveTile: View {
    private var account: LFMAccount { LFMAccount.shared }
    var body: some View {
        let on = account.signedIn
        LiveTile(id: "scrobbling", name: "scrobbling", fill: on ? Z.magenta : Color(white: 0.2)) {
            HStack(spacing: 10) {
                Image(systemName: on ? "dot.radiowaves.left.and.right" : "pause").font(.system(size: 24, weight: .light))
                Text(on ? "on" : "off").font(.zune(size: 30, .light))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } back: {
            Text(on ? "Apple Music listening goes to Last.fm" : "not scrobbling Apple Music yet")
                .font(.zune(size: 16)).foregroundStyle(.white).lineLimit(2)
                .padding(.horizontal, 10).padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - The menu: Zune HD's huge words

struct MenuWords: View {
    let go: (String, Hub, Int?) -> Void
    @Environment(\.pageWidth) private var width
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1
    var body: some View {
        let want = min(64, max(46, width * 0.13)) * min(max(k, 0.9), 1.2)
        // Every word whole within its section: open upright "scrobbling" ran past the menu's edge and was cut mid-screen
        // (run 62). The longest word sets the size; measured once per width.
        let size = Self.fit(want, width)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Hub.menu, id: \.self) { h in
                Button { go("w-" + h.rawValue, h, nil) } label: {
                    // Zune HD's menu: the huge word, and under it in small grey capitals what's inside.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.word)
                            .font(.zuneLower(size: size)).tracking(-1.2)
                            .foregroundStyle(.white)
                            .lineLimit(1).fixedSize()
                            .padding(.leading, -3)
                        Text(Self.inside(h)).font(.zuneCaps(size: 12, .semibold)).tracking(0.6)
                            .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: size * 1.3, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Tilt())
                .modifier(TurnstileOut(index: Home.order("w-" + h.rawValue), count: Home.count))
                .accessibilityLabel(h.word)
            }
        }
    }
}

extension MenuWords {
    @MainActor private static var fitted: [String: CGFloat] = [:]
    @MainActor static func fit(_ want: CGFloat, _ width: CGFloat) -> CGFloat {
        let key = "\(want)|\(width)"
        if let f = fitted[key] { return f }
        let room = width - S.margin * 2 + 3
        let widest = Hub.menu.map { textWidth($0.word, size: want, tracking: -1.2, weight: -0.4, face: Z.lower()) }.max() ?? 0
        let f = width > 0 && widest > room ? max(30, floor(want * room / widest)) : want
        fitted[key] = f
        return f
    }
    static func inside(_ h: Hub) -> String {
        switch h {
        case .profile: return "scrobbles  streak  lately  story"
        case .charts: return "week  month  year  collage"
        case .library: return "artists  albums  songs  loved"
        case .discover: return "for you  songs  rediscover"
        case .history: return "today  all plays"
        case .scrobbling: return "log  settings"
        case .nowPlaying: return "song  artist  album"
        }
    }
}

// MARK: - Cover tiles (Zune's quickplay and hubs)

// Albums as square tiles, two across, each opening its album; the name and when under it are the tile's own label.
struct AlbumTiles: View {
    let title: String?
    let items: [Entry]
    let width: CGFloat?
    @Environment(\.pageWidth) private var pageWidth
    var body: some View {
        let cw = width ?? max(200, pageWidth - S.margin * 2)
        let t = floor((cw - S.gap) / 2)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: S.gap) {
                if let title { Text(title).font(.zuneLower(size: 40)).tracking(-0.8).foregroundStyle(.white).padding(.leading, -2) }
                LazyVGrid(columns: [GridItem(.fixed(t), spacing: S.gap), GridItem(.fixed(t), spacing: S.gap)], alignment: .leading, spacing: S.gap) {
                    ForEach(items.prefix(8)) { e in
                        Opens(route: e.route, zoom: "tile|\(e.id)") {
                            CoverTile(ref: e.art, name: e.title, line: when(e.last.map { Date(timeIntervalSince1970: TimeInterval($0)) }), side: t)
                                .zoomSource("tile|\(e.id)")
                        }
                    }
                }
            }
            .padding(.horizontal, width == nil ? S.margin : 0)
        }
    }
}
// His week's artists as tiles, the most played first.
struct ArtistTiles: View {
    let title: String?
    let list: [ArtistCount]
    let width: CGFloat?
    @Environment(\.pageWidth) private var pageWidth
    var body: some View {
        let cw = width ?? max(200, pageWidth - S.margin * 2)
        let t = floor((cw - S.gap) / 2)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: S.gap) {
                if let title { Text(title).font(.zuneLower(size: 40)).tracking(-0.8).foregroundStyle(.white).padding(.leading, -2) }
                LazyVGrid(columns: [GridItem(.fixed(t), spacing: S.gap), GridItem(.fixed(t), spacing: S.gap)], alignment: .leading, spacing: S.gap) {
                    ForEach(list.prefix(8)) { a in
                        Opens(route: .artist(a.name), zoom: "tile|a|\(a.name)", seed: ArtRef(artist: a.name, album: a.album, url: a.image)) {
                            CoverTile(ref: ArtRef(artist: a.name, album: a.album, url: a.image), name: a.name, line: "\(number(a.plays)) plays", side: t)
                                .zoomSource("tile|a|\(a.name)")
                        }
                    }
                }
            }
            .padding(.horizontal, width == nil ? S.margin : 0)
        }
    }
}
// A cover as a WP7 tile: square, edge to edge, its name small at the foot-left over a dark foot so it reads on any cover.
struct CoverTile: View {
    let ref: ArtRef
    let name: String
    let line: String
    let side: CGFloat
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtView(ref, px: 400, corner: 0).frame(width: side, height: side)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.zune(size: 17, .semibold)).foregroundStyle(.white).lineLimit(1)
                if !line.isEmpty { Text(line).font(.zune(size: 14)).foregroundStyle(.white.opacity(0.8)).lineLimit(1) }
            }
            .padding(.leading, 10).padding(.bottom, 6).padding(.trailing, 6)
        }
        .frame(width: side, height: side)
        .clipped()
        .accessibilityElement(children: .combine)
    }
}

// Zune's Quickplay helpers: each album once, in the order last played.
enum Quickplay {
    static func albums(_ recent: [Scrobble]) -> [Entry] {
        var seen = Set<String>(), out: [Entry] = []
        for s in recent where !s.album.isEmpty {
            let k = (s.artist + "|" + s.album).lowercased()
            guard seen.insert(k).inserted else { continue }
            out.append(Entry(kind: .albums, artist: s.artist, album: s.album, track: "", plays: 0, image: s.image, last: s.date.map { Int($0.timeIntervalSince1970) }))
            if out.count == 12 { break }
        }
        return out
    }
}
