import SwiftUI
import CoreText

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
                // Open flat, the wide screen: a Windows 8 hub, not the phone's panorama (Richard, 11-26 on build 81: "look at
                // a windows 8 metro app").
                MetroHub(go: go)
            } else {
                HomePanorama(go: go)
            }
        }
        .opacity(HomeLeave.shared.cleared ? 0 : 1)
        // Home's entrance plays at launch only. Built any later (opened deep by a link or a build's pose, or made again by a
        // turn of the posture while a hub covers it), home is first seen under a Back, and there it must be whole at rest:
        // its parts waited at -80 degrees for the swipe to end, so the Back showed the bare ground and an edge-on title,
        // then home cut in (gate on build 83, open flat).
        .environment(\.turnstileArrived, Home.launchedDeep || !FirstFrames.launching)
        // Open flat, Windows 8's hub ground: one flat dark colour behind the groups (Xbox Music 8.1's), the imagery carried by
        // the hero (lastfm.md §30.6). Folded and upright the panorama draws its own picture.
        .background { (pane ? Color(white: 0.075) : Color.black).ignoresSafeArea() }
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

// Open flat, a Windows 8 hub page (Richard, 2026-11-26 on build 81 open flat: "look at a windows 8 metro app also the way
// this scroll bar is placed is retarded"; study: ~/.claude/design/reference/zune/w8-metro-hub-study.md). One surface that
// pans sideways as a whole: the app's name top left in Light at the page header's place (42 pt Segoe UI Light, its
// baseline 100 px down, 120 px in), then groups side by side from 140 px down, 80 px apart, each under its own 20 pt
// header: start (his live tiles, now playing as the 2x2 hero), menu (the hubs' words in columns), just played and on
// repeat (covers in rows). Everything fits the height, so nothing scrolls up and down and there is no bar down the seam;
// the one scroll bar is Windows 8's own, thin across the foot, shown only while it pans. Sizes from a 768 px tall page,
// scaled to the screen's height.
private struct MetroHub: View {
    let go: (String, Hub, Int?) -> Void
    private var store: Store { Store.shared }
    var body: some View {
        GeometryReader { out in
            let insets = out.safeAreaInsets
            GeometryReader { g in
                let H = max(g.size.height, 1)
                let u = min(1.15, max(0.8, H / 768))
                let left = insets.leading + 120 * u
                let headSize = 56 * u
                let m = HomePanorama.metrics(headSize)
                let headTop = 100 * u - m.ascender
                let contentTop = 140 * u
                let foot = max(50 * u, insets.bottom + 24)
                let sub = 44 * u
                let gap = max(8, 10 * u)
                let rows = H - contentTop - foot - sub
                let t = max(90, floor((rows - gap * 2) / 3))
                // The 8.1 hub's hero: the first section, the screen's full height from its very left edge, no header (study
                // §3); the song on now or last played, his cover.
                let heroW = min(780 * u, g.size.width * 0.62)
                ZStack(alignment: .topLeading) {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 80 * u) {
                            tile("now", .nowPlaying, nil, w: heroW, h: H) { MetroHero(top: contentTop, u: u, left: left) }
                                .modifier(EnterPage(index: 0, u: u))
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear.frame(height: contentTop)
                                HStack(alignment: .top, spacing: 80 * u) {
                                    group("start", 1, sub, u) { startTiles(t, gap) }
                                    group("menu", 2, sub, u) { words(t, gap, u) }
                                    if !Quickplay.albums(store.recent).isEmpty {
                                        group("just played", 3, sub, u, key: "h-played", opens: (.history, 1)) { covers(t, gap) }
                                    }
                                    if !store.insights.week.isEmpty {
                                        group("on repeat", 3, sub, u, key: "h-repeat", opens: (.charts, nil)) { artists(t, gap) }
                                    }
                                }
                            }
                        }
                        .padding(.trailing, 120 * u + insets.trailing)
                        .frame(height: H, alignment: .topLeading)
                    }
                    // Windows 8's panning indicator instead of the system's bar (study §5): thin, at the foot, only while it pans.
                    .scrollIndicators(.hidden)
                    .onScrollPhaseChange { _, p in
                        HomeSwipe.moving = p != .idle; Store.shared.scrolling = p != .idle
                        PanBar.shared.panning(p != .idle)
                    }
                    .onScrollGeometryChange(for: PanBar.Spot.self) { g in
                        PanBar.Spot(x: g.contentOffset.x, content: g.contentSize.width, view: g.containerSize.width)
                    } action: { _, v in PanBar.shared.spot = v }
                    PanIndicator(left: left, right: 120 * u + insets.trailing, bottom: max(insets.bottom, 0) + 10 * u)
                    // The hub's title stays where it is while the sections pan under it (study §3, the 8.1 Hub).
                    Text(Home.title).font(.zuneLower(size: headSize)).tracking(-0.5)
                        .foregroundStyle(.white).lineLimit(1).fixedSize()
                        .padding(.leading, left - 2).offset(y: headTop)
                        .allowsHitTesting(false)
                        .accessibilityAddTraits(.isHeader)
                        .modifier(TurnstileOut(index: Home.order("title"), count: Home.count))
                        .modifier(EnterPage(index: 0, u: u))
                }
            }
            .ignoresSafeArea()
        }
    }

    // A group: its header (Windows 8's subheader, 20 pt Light), then its items.
    // A group: its header (Windows 8's subheader, 20 pt Light; one that opens a page carries the chevron), then its items.
    private func group<C: View>(_ name: String, _ i: Int, _ sub: CGFloat, _ u: CGFloat, key: String? = nil, opens: (Hub, Int?)? = nil, @ViewBuilder _ c: () -> C) -> some View {
        let head = HStack(alignment: .firstTextBaseline, spacing: 8 * u) {
            Text(name).font(.zuneLower(size: 27 * u)).foregroundStyle(.white).lineLimit(1).fixedSize()
            if opens != nil { Image(systemName: "chevron.right").font(.system(size: 15 * u, weight: .light)).foregroundStyle(.white.opacity(0.8)) }
        }
        .frame(height: sub, alignment: .topLeading)
        .modifier(TurnstileOut(index: Home.order(key ?? "h-" + (name == "menu" ? "menu" : "start")), count: Home.count))
        .accessibilityAddTraits(.isHeader)
        return VStack(alignment: .leading, spacing: 0) {
            if let o = opens, let key { Button { go(key, o.0, o.1) } label: { head.contentShape(Rectangle()) }.buttonStyle(Tilt()) }
            else { head }
            c().modifier(TurnstileOut(index: key.map { Home.order($0) } ?? -1, count: Home.count))
        }
        .modifier(EnterPage(index: i, u: u))
    }

    private func tile<C: View>(_ key: String, _ hub: Hub, _ panel: Int?, w: CGFloat, h: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
        Button { go(key, hub, panel) } label: { c().frame(width: w, height: h) }
            .buttonStyle(Tilt())
            .modifier(TurnstileOut(index: Home.order(key), count: Home.count))
    }

    // His live tiles in three rows, flowing right in columns (now playing is the hero before them).
    private func startTiles(_ t: CGFloat, _ gap: CGFloat) -> some View {
        let wide = t * 2 + gap
        return HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .leading, spacing: gap) {
                HStack(spacing: gap) {
                    tile("profile", .profile, 0, w: t, h: t) { ProfileLiveTile() }
                    tile("today", .history, 0, w: t, h: t) { TodayLiveTile() }
                }
                tile("discover", .discover, 0, w: wide, h: t) { DiscoverLiveTile() }
                HStack(spacing: gap) {
                    tile("charts", .charts, nil, w: t, h: t) { ChartsLiveTile() }
                    tile("library", .library, nil, w: t, h: t) { LibraryLiveTile() }
                }
            }
            VStack(alignment: .leading, spacing: gap) {
                tile("scrobbling", .scrobbling, nil, w: wide, h: t) { ScrobbleLiveTile() }
                HStack(spacing: gap) {
                    tile("rediscover", .discover, 2, w: t, h: t) { RediscoverLiveTile() }
                    tile("history", .history, 1, w: t, h: t) { HistoryLiveTile() }
                }
            }
        }
    }

    // The hubs' words, Zune HD's menu, in columns of three as tall as a tile row each.
    private func words(_ t: CGFloat, _ gap: CGFloat, _ u: CGFloat) -> some View {
        let size = min(64 * u, floor(t * 0.5))
        let colW = (Hub.menu.map { textWidth($0.word, size: size, tracking: -1.2, weight: -0.4, face: Z.lower()) }.max() ?? 200) + 40 * u
        return LazyHGrid(rows: Array(repeating: GridItem(.fixed(t), spacing: gap, alignment: .topLeading), count: 3), alignment: .top, spacing: 0) {
            ForEach(Hub.menu, id: \.self) { h in
                Button { go("w-" + h.rawValue, h, nil) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.word).font(.zuneLower(size: size)).tracking(-1.2).foregroundStyle(.white)
                            .lineLimit(1).fixedSize().padding(.leading, -3)
                        Text(MenuWords.inside(h)).font(.zuneCaps(size: 12, .semibold)).tracking(0.6)
                            .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    .frame(width: colW, height: t, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Tilt())
                .modifier(TurnstileOut(index: Home.order("w-" + h.rawValue), count: Home.count))
                .accessibilityLabel(h.word)
            }
        }
    }

    private func covers(_ t: CGFloat, _ gap: CGFloat) -> some View {
        LazyHGrid(rows: Array(repeating: GridItem(.fixed(t), spacing: gap), count: 3), alignment: .top, spacing: gap) {
            ForEach(Quickplay.albums(store.recent).prefix(12)) { e in
                Opens(route: e.route, zoom: "tile|\(e.id)") {
                    CoverTile(ref: e.art, name: e.title, line: when(e.last.map { Date(timeIntervalSince1970: TimeInterval($0)) }), side: t)
                        .zoomSource("tile|\(e.id)")
                }
            }
        }
    }

    private func artists(_ t: CGFloat, _ gap: CGFloat) -> some View {
        LazyHGrid(rows: Array(repeating: GridItem(.fixed(t), spacing: gap), count: 3), alignment: .top, spacing: gap) {
            ForEach(store.insights.week.prefix(12)) { a in
                Opens(route: .artist(a.name), zoom: "tile|a|\(a.name)", seed: ArtRef(artist: a.name, album: a.album, url: a.image)) {
                    CoverTile(ref: ArtRef(artist: a.name, album: a.album, url: a.image), name: a.name, line: "\(number(a.plays)) plays", side: t)
                        .zoomSource("tile|a|\(a.name)")
                }
            }
        }
    }
}

// Windows 8's enterPage (WinJS.UI.Animation.enterPage, study §6): each group slides in from the right, 100 px, eased
// with WinJS's entrance curve (cubic 0.1, 0.9, 0.2, 1), its opacity up in the first sixth of a second, the groups a
// twelfth of a second apart in reading order. Once, at launch onto home open flat; home found again by Back is simply
// there (turnstileArrived, as the phone's turnstile).
private struct EnterPage: ViewModifier {
    let index: Int
    let u: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.turnstileArrived) private var arrived
    func body(content: Content) -> some View {
        let on = shown || still || arrived
        content
            .offset(x: on ? 0 : 100 * u)
            .opacity(on ? 1 : 0)
            .onAppear {
                guard !on else { return }
                let d = Double(index) * 0.083
                let go = {
                    withAnimation(.timingCurve(0.1, 0.9, 0.2, 1, duration: 0.8).delay(d)) { shown = true }
                }
                if FirstFrames.launching { go() } else { FirstFrames.shared.after(go) }
            }
    }
}

// The hub's panning indicator: where the screen is along the hub, as a thin bar at the foot, faded in as a pan begins
// and out half a second after it ends. Its own observable, read only by the bar, so a pan redraws the bar and nothing else.
@MainActor @Observable final class PanBar {
    static let shared = PanBar()
    struct Spot: Equatable { var x: CGFloat = 0; var content: CGFloat = 1; var view: CGFloat = 1 }
    var spot = Spot()
    var shown = false
    @ObservationIgnored private var hide: Task<Void, Never>?
    func panning(_ on: Bool) {
        hide?.cancel()
        if on { if !shown { withAnimation(.easeOut(duration: 0.15)) { shown = true } }; return }
        hide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { shown = false }
        }
    }
}
private struct PanIndicator: View {
    let left: CGFloat
    let right: CGFloat
    let bottom: CGFloat
    var body: some View {
        GeometryReader { g in
            let b = PanBar.shared
            let track = max(1, g.size.width - left - right)
            let k = min(1, b.spot.view / max(b.spot.content, 1))
            let w = max(24, track * k)
            let travel = max(1, b.spot.content - b.spot.view)
            let f = min(1, max(0, b.spot.x / travel))
            Capsule().fill(.white.opacity(0.55))
                .frame(width: w, height: 3)
                .offset(x: left + (track - w) * f, y: g.size.height - bottom - 3)
                .opacity(b.shown && k < 1 ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            let r = ImageRenderer(content: HubView(hub: h, panel: nil).environment(\.turnstileArrived, true).environment(\.offscreen, true).frame(width: 390, height: 844))
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
    // The panorama's title (Richard, 11-26 on build 80: "rotation should say last.fm"): plain white, WP7's size.
    static let title = "last.fm"
    static let keys = ["title", "h-start", "now", "profile", "today", "charts", "library", "discover", "rediscover", "history", "scrobbling",
                       "h-menu"] + Hub.menu.map { "w-" + $0.rawValue } + ["h-played", "h-repeat"]
    static var count: Int { keys.count }
    // The app came up on a hub (a build's pose, a link at launch): home is first seen under a Back, never turning in.
    static let launchedDeep = !RootView.posed().isEmpty
    static func order(_ k: String) -> Int { keys.firstIndex(of: k) ?? 0 }
}

// The panorama: its title, then its sections on a ring (LFMPanorama.swift, UIKit since build 81): each section lands at
// the left margin by WP7's paging, the last one is followed by the first, and the title slides at a fraction of the
// sections' rate, leaving and coming back round the wrap.
private struct HomePanorama: View {
    let go: (String, Hub, Int?) -> Void
    @Environment(\.openRoute) private var open
    @Environment(\.zoomSpace) private var space
    @Environment(\.turnstileArrived) private var arrived
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
                // Fitted so the whole word reads on the first screen: "last.fm" is short, and stretched past the screen its
                // "m" sat under the side strip's clock folded and was cut to "last.fn" upright (gate on build 83). It ends
                // 12 pt inside the page, still WP7's size or near it, and slides away slowest as the panorama pans.
                let w0 = textWidth(Home.title, size: T0, tracking: -3, weight: -0.4, face: Z.lower())
                // Never past WP7's own size (build 85 stretched it to x1.4, so its letters rose past the top edge); only
                // stepped down to fit.
                let T = w0 > 0 ? T0 * max(0.8, min(1.0, (pw - 10 - 12) / w0)) : T0
                let m = Self.metrics(T)
                let across = TopBar.across()
                let tray = across?.maxY ?? insets.top
                // The tallest letters' tops (l, f, t) just under the tray, as WP7's sat under its 32 px tray; folded there is
                // no tray at the top (the status is in the side strip), so they sit 20 pt under the bare edge, where WP7's
                // did (Richard's shot, 11-27: "last.fm" cut off at the top: the x-height was placed and the ascenders rose
                // 8 pt past the screen's top edge). The sections keep WP7's distance under the title's baseline.
                let clear = tray > 0 ? tray + 4 : 20
                let titleTop = clear - (m.ascender - m.glyphTop)
                let baseline = titleTop + m.ascender
                let sectionsTop = baseline + T * 0.79 - m.xHeight
                let titleW = textWidth(Home.title, size: T, tracking: -3, weight: -0.4, face: Z.lower())
                let travel = max(1, sec * CGFloat(count - 1))
                // The layers' rates from their widths (study §2: "the speed relates to the ratio of the content's width to
                // the background's"): each crosses its own overhang once over the panorama's travel. The title, shorter,
                // is the slowest; the background (as tall as the screen, square) next; the sections 1:1.
                let titleRate = max(0.05, (titleW + 10 - pw) / travel)
                let bgRate = max(titleRate + 0.05, min(0.9, (H * 1.02 - pw) / travel))
                // Wide enough for the whole travel at that rate, the side strip included (gate on build 78 and run 79).
                let bgSide = max(H * 1.02, W + bgRate * travel + 40)
                let h = H - sectionsTop
                #if canImport(UIKit)
                PanoramaStrip(
                    geo: PanoGeo(sec: sec, count: count, W: W, H: H, leading: side.leading, trailing: side.trailing, sectionsTop: sectionsTop,
                                 titleTop: titleTop, titleW: titleW, titleH: ceil(T * 1.45),
                                 titleRate: titleRate, bgRate: bgRate, bgSide: bgSide),
                    start: max(0, min(count - 1, Int(UserDefaults.standard.string(forKey: "section") ?? "") ?? 0)),
                    background: AnyView(PanoramaBackground(side: bgSide)
                        .modifier(TurnstileOut(index: 0, count: Home.count))),
                    title: AnyView(PanoramaTitle(text: Home.title, size: T)
                        .modifier(TurnstileOut(index: 0, count: Home.count))
                        .turnstile(0).environment(\.turnstileArrived, arrived)),
                    sections: [
                        hosted(section("start", key: "h-start", 0, sec, h, side) { StartTiles(width: sec - S.margin - 12, go: go) }),
                        hosted(section("menu", key: "h-menu", 1, sec, h, side) { MenuWords { go($0, $1, $2) } }),
                        hosted(section("just played", key: "h-played", 2, sec, h, side) {
                            AlbumTiles(title: nil, items: Quickplay.albums(store.recent), width: sec - S.margin - 12)
                        }),
                        hosted(section("on repeat", key: "h-repeat", 3, sec, h, side) {
                            ArtistTiles(title: nil, list: store.insights.week, width: sec - S.margin - 12)
                        }),
                    ])
                .frame(width: W, height: H)
                #else
                Color.black
                #endif
            }
            .ignoresSafeArea(.container, edges: .all)
        }
    }

    // A hosted section keeps what the stack hands down (its own hosting controller doesn't inherit it).
    private func hosted<V: View>(_ v: V) -> AnyView {
        AnyView(v.environment(\.openRoute, open).environment(\.zoomSpace, space).environment(\.paneLayout, false)
            .environment(\.turnstileArrived, arrived).tint(.white))
    }

    // A section: its name (WP7's panorama header, Semilight 42.667 px, lowercase), then its content, which scrolls on its
    // own under the name.
    private func section<C: View>(_ name: String, key: String, _ i: Int, _ w: CGFloat, _ h: CGFloat, _ side: (leading: CGFloat, trailing: CGFloat), @ViewBuilder _ content: () -> C) -> some View {
        // The header over its items with WP7's PanoramaItem air under it (its header's bottom margin, ~26 px), so a list
        // scrolled up under it reads as scrolled, not as a word jammed under "menu" (Richard's home shot, 11-27).
        VStack(alignment: .leading, spacing: 22) {
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
            // A section's edge is mid-screen (the next section shows past it): no scroll bar there (Richard, 11-26).
            .scrollIndicators(.hidden)
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
    var body: some View {
        Text(text)
            .font(.zuneLower(size: size)).tracking(-3)
            .foregroundStyle(.white)
            .lineLimit(1).fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

extension HomePanorama {
    // The title face's ascender and x-height at a size, measured once per size.
    @MainActor private static var kept: [CGFloat: (ascender: CGFloat, xHeight: CGFloat, glyphTop: CGFloat)] = [:]
    // glyphTop: how far the title's tallest letters rise over the baseline (their ink, not the face's ascender line).
    @MainActor static func metrics(_ size: CGFloat) -> (ascender: CGFloat, xHeight: CGFloat, glyphTop: CGFloat) {
        if let k = kept[size] { return k }
        #if canImport(UIKit)
        let f = UIFont(name: Z.lower(), size: size) ?? Z.uiFont(size, weight: -0.4)
        let ct = f as CTFont
        var chars = Array("lftdkh".utf16), glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(ct, &chars, &glyphs, chars.count)
        let ink = CTFontGetBoundingRectsForGlyphs(ct, .horizontal, glyphs, nil, glyphs.count)
        let v = (f.ascender, f.xHeight, ink.height > 1 ? ink.maxY : f.ascender * 0.92)
        #else
        let v = (size * 1.08, size * 0.5, size * 0.75)
        #endif
        kept[size] = v
        return v
    }
}

// The panorama's picture (the ground: one per visit, Ground.hubs), square, as tall as the screen, darkened, sliding at
// its width's rate. A new artist's picture fades in over the old one (1.2 s), never cut.
private struct PanoramaBackground: View {
    let side: CGFloat
    var body: some View {
        // Read here, in its own hosting view, so the ground's change fades in this view's own update.
        let ref = Ground.hubs.pick?.ref
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
            .clipped()
            .animation(.easeInOut(duration: Ground.fade), value: ref?.key)
        }
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

// Open flat, the hub's hero (Windows 8.1's first section, Xbox Music's: a picture the screen's full height, the words over
// its foot). The cover whole, never a slab of colour over it (gate on build 83: the folded tile's peek laid the song on a
// flat blue panel across the lower half): the song in a band over a gradient at the foot, and a gradient under the white
// title at the top, so it reads over any cover however bright. A new song's cover fades in slowly over the old one.
private struct MetroHero: View {
    let top: CGFloat
    let u: CGFloat
    let left: CGFloat
    private var store: Store { Store.shared }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let s = store.shown {
                    // Xbox Music's hero: the artist's picture (the calm ground's, one per visit, faded slowly to a new
                    // artist's), drifting; the cover itself rides in the song's band.
                    let pic = Ground.hubs.pick?.ref ?? s.art
                    Drifting(key: pic.key) { TileCover(ref: pic, px: 1000) }
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                        .id(pic.key)
                        .transition(.opacity)
                    // Under the title: dark enough at the very top for white Light type over a white cover.
                    LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0), .init(color: .black.opacity(0.45), location: 0.6),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: top * 1.35)
                        .frame(maxHeight: .infinity, alignment: .top)
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 0.45),
                                           .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: g.size.height * 0.42)
                    HStack(alignment: .bottom, spacing: 16 * u) {
                        TileCover(ref: s.art, px: 300).frame(width: 96 * u, height: 96 * u)
                            .overlay { Rectangle().strokeBorder(.black.opacity(0.35), lineWidth: 1) }
                            .id(s.art.key).transition(.opacity)
                        VStack(alignment: .leading, spacing: 2 * u) {
                            Text(s.nowPlaying ? "now playing" : "last played").font(.zuneLower(size: 22 * u)).foregroundStyle(.white.opacity(0.75))
                            Text(s.title).font(.zuneLower(size: 42 * u)).tracking(-0.6).foregroundStyle(.white).lineLimit(1)
                            Text(s.album.isEmpty ? s.artist : "\(s.artist) · \(s.album)").font(.zune(size: 19 * u)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        }
                    }
                    .padding(.leading, left)
                    .padding(.trailing, 24 * u)
                    .padding(.bottom, 56 * u)
                } else {
                    TileIcon(name: "music.note")
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
            .animation(.easeInOut(duration: Ground.fade), value: store.shown?.art.key)
            .animation(.easeInOut(duration: Ground.fade), value: Ground.hubs.pick?.ref.key)
        }
        .accessibilityElement(children: .combine)
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
