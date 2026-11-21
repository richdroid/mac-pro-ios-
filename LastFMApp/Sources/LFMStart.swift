import SwiftUI

// Start: him (Richard, 2026-11-14: "i feel like start should be like my profile image with my stats"). A Zune
// panorama under his name: his face and his figures first (scrobbles, artists, albums, tracks, the streak, this week
// against his usual, his listening time), then what's playing or his day, then lately (what he's on repeat with, his
// canon, what's taking over, what's new, his clock), then his story across the years. What were the Now and You tabs,
// moved to where they belong, nothing dropped: Now's week glance is this week's card and "on repeat".
// Open flat his face and figures hold the left pane and the other three sections pan on the right.
struct StartTab: View {
    let top: Int
    @Environment(\.paneLayout) private var pane
    @Environment(\.horizontalSizeClass) private var size
    @State private var page = min(max(Pose.panel, 0), 3)
    private var store: Store { Store.shared }
    private var sync: HistorySync { HistorySync.shared }
    private var links: Links { Links.shared }
    var body: some View {
        // The shape of the room read in the pass that lays it out (it was measured after, so the first frame after a
        // turn was the upright layout).
        GeometryReader { g in
            let sideways = g.size.width > g.size.height * 1.15
            if pane {
                FoldSplit {
                    Page(top: top) {
                        VStack(alignment: .leading, spacing: S.head) { HubTitle(text: ProfileHead.name, size: 80, least: 0.3); stats(wide: false) }.padding(.top, S.head)
                    }
                } right: {
                    Pager(.pivot, page: Binding(get: { max(page, 1) }, set: { page = $0 }), top: top,
                          panels: [nowPanel(.stage), lately, story])
                }
            } else {
                // A pivot, its four names across the top, his own first: every section one tap away, as Charts and
                // Library are (it was a panorama whose other sections only a swipe could find; Richard, 2026-11-18:
                // "its almost impossible to use in its current state").
                Pager(.pivot, page: $page, top: top,
                      panels: [Panel(0, ProfileHead.name.lowercased()) { stats(wide: size == .regular && !sideways, strip: true) }, nowPanel(sideways ? .short : size == .regular ? .wide : .column), lately, story])
            }
        }
        .onChange(of: links.panel) { _, p in if let p { page = p; links.panel = nil } }
        // Claude's pieces that are due, once his whole history is in (each at most daily, only when it has moved).
        .task(id: sync.complete) { await Taste.shared.refresh() }
    }

    private func stats(wide: Bool, strip: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: S.section) {
            ProfileHead().padding(.horizontal, S.margin)
            if store.trouble { TroubleNote().padding(.horizontal, S.margin) }
            // What's on (or the last song) the moment the app opens, a tap from the rest of today.
            if strip { NowStrip { withAnimation(.snappy(duration: 0.4)) { page = 1 } }.padding(.horizontal, S.margin) }
            if wide {
                // Open upright there's room beside the count: today so far and who's on repeat (it was one number in
                // half a page; review 2026-11-14, item 21).
                HStack(alignment: .top, spacing: S.figures) {
                    Totals()
                    Spacer(minLength: 0)
                    TodayGlance().frame(width: 292, alignment: .leading)
                }
                .padding(.horizontal, S.margin)
            } else {
                Totals().padding(.horizontal, S.margin)
            }
            // Zune's Quickplay: his week's albums as a mosaic of covers, the most played the big tile.
            RotationMosaic().padding(.horizontal, S.margin)
            StreakCard().padding(.horizontal, S.margin)
            // The first read, while it runs, under his figures rather than over them: his stats come first.
            if !sync.complete { YearsSection().id("reading") }
            PaceCard().padding(.horizontal, S.margin)
            MilestoneCard().padding(.horizontal, S.margin)
            TimeCard()
            // What his listening says, in words, and a question about it.
            TastePortrait()
            TasteAsk()
        }
    }

    // What's on, or nothing pretending to be: today's figures and the last song. Then the day and every scrobble.
    private func nowPanel(_ layout: NowHero.Layout) -> Panel {
        let playing = store.shown.map(\.nowPlaying) ?? true
        // One name, playing or not: "now playing" over silence made no sense to him (2026-11-13), and a name that
        // flipped between polls re-laid the row of names (run 39 review, fault 7). What's on says so in its own label.
        return Panel(1, "today") {
            VStack(alignment: .leading, spacing: S.section) {
                // First, as on his own page: under the hero it sat below the first screen folded (run 34).
                // Open flat (.stage) his page's note is on screen in the left pane already: said once, not twice (run 36).
                if store.trouble, layout != .stage { TroubleNote().padding(.horizontal, S.margin) }
                if playing {
                    NowHero(layout: layout == .stage ? .column : layout, titled: false)
                    // Zune's Mixview: the artist on now ringed by the artists like them, his plays as the lines.
                    if let s = store.shown, s.nowPlaying { MixView(artist: s.artist, center: s.art).padding(.horizontal, S.margin) }
                } else {
                    VStack(alignment: .leading, spacing: S.section) {
                        TodayFigures()
                        if let last = store.recent.first { LastPlayed(s: last) }
                    }
                    .padding(.horizontal, S.margin)
                }
                DaySection(lead: !playing).id("day")
                RecentSection(skipFirst: !playing && !store.recent.isEmpty)
            }
            // Zune's Now Playing wall: his own covers behind what's on, in the playing cover's colour.
            .background(alignment: .top) {
                if playing, let s = store.shown {
                    ArtWall(tint: (ArtStore.shared.palette(s.art) ?? Palette.from(name: s.artist + s.album)).vivid.color)
                }
            }
        }
    }

    // This week and what's moving him now.
    private var lately: Panel {
        Panel(2, "lately") {
            VStack(alignment: .leading, spacing: S.section) {
                TasteWeekNote()
                WeekHub(title: "on repeat", list: store.insights.week)
                RisingCard().padding(.horizontal, S.margin)
                CanonCard().padding(.horizontal, S.margin)
                // A panorama when there are enough to run off the edge; one or two are a card, never a sparse row.
                if store.insights.discoveries.count >= 3 { WeekHub(title: "new to you", list: store.insights.discoveries) }
                else if !store.insights.discoveries.isEmpty { NewCard(list: store.insights.discoveries).padding(.horizontal, S.margin) }
                ClockCard().padding(.horizontal, S.margin)
            }
        }
    }

    // His story across the years, and all of it in months.
    private var story: Panel {
        Panel(3, "your story") {
            VStack(alignment: .leading, spacing: S.section) {
                // Always here: the story is made from the whole history, so until it's read the years being read are the
                // story so far, never a blank page (Richard's screenshot, 2026-11-14: "your story" and nothing under it).
                YearsSection()
                RiverCard()
                ErasSection()
                RecordsSection()
                DiscoveriesSection()
                VolumeCard()
                CarryCard()
            }
        }
    }
}

// The song on now, or the last one, in a line under his face: what he most often opens the app to see, without a
// swipe. Tapping it goes to the rest of today (the hero, his day, every play).
struct NowStrip: View {
    let go: () -> Void
    private var store: Store { Store.shared }
    var body: some View {
        if let s = store.shown {
            Button(action: go) {
                HStack(spacing: S.gap) {
                    ArtView(s.art, px: 156, corner: 0).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: S.pair / 2) {
                        HStack(spacing: 6) {
                            if s.nowPlaying, !store.trouble {
                                Image(systemName: "waveform")
                                Text("Now playing")
                            } else if s.nowPlaying {
                                // Last.fm gone: what it last said was playing, not live.
                                Image(systemName: "clock.arrow.circlepath")
                                Text("Last heard")
                            } else {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("Played \(when(s.date))")
                            }
                        }
                        .font(.caption.weight(.bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        Text(s.title).font(.system(.title3, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(s.artist).font(.subheadline).foregroundStyle(S.soft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(S.soft)
                }
                // Flat, hung from the page's edge like everything under it: a line of the page, not a pane of glass.
                .contentShape(Rectangle())
            }
            .buttonStyle(Press())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows today")
        }
    }
}

// Where a link from a widget asks to go: a tab, a section of Start, a page. Set by the app's URL handler and taken up
// by the view that owns each, which clears it.
@MainActor @Observable final class Links {
    static let shared = Links()
    var tab: Int?
    var panel: Int?
    var push: Ask?
    // A link to a tab's own root (a section of Start, a chart): any page pushed on that tab is closed first, or the link
    // changed the section behind an artist's page and seemed to do nothing.
    var root: Int?
    struct Ask: Equatable { let tab: Int; let go: Go }

    // rotation://you, /now, /lately, /story, /charts?period=week, /artist?name=, /album?artist=&album=,
    // /track?artist=&title=&album=&image=
    func open(_ url: URL) {
        guard url.scheme == LinkScheme.scheme else { return }
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
        switch url.host() ?? "" {
        case "you": tab = 0; root = 0; panel = 0
        case "now": tab = 0; root = 0; panel = 1
        case "lately": tab = 0; root = 0; panel = 2
        case "story": tab = 0; root = 0; panel = 3
        case "charts":
            tab = 1; root = 1
            switch q["period"] ?? "" {
            case "month": ChartsModel.shared.period = .days(30)
            case "year": ChartsModel.shared.period = .days(365)
            default: ChartsModel.shared.period = .days(7)
            }
        case "artist":
            if let n = q["name"], !n.isEmpty { tab = 0; push = Ask(tab: 0, go: Go(route: .artist(n), zoom: nil)) }
        case "album":
            if let a = q["artist"], let l = q["album"], !a.isEmpty, !l.isEmpty { tab = 0; push = Ask(tab: 0, go: Go(route: .album(a, l), zoom: nil)) }
        case "track":
            if let a = q["artist"], let t = q["title"], !a.isEmpty, !t.isEmpty {
                tab = 0
                push = Ask(tab: 0, go: Go(route: .track(Scrobble.song(artist: a, title: t, album: q["album"] ?? "", image: q["image"].flatMap { $0.isEmpty ? nil : $0 })), zoom: nil))
            }
        default: break
        }
    }
}
