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
    @State private var sideways = false
    private var store: Store { Store.shared }
    private var sync: HistorySync { HistorySync.shared }
    private var links: Links { Links.shared }
    var body: some View {
        Group {
            if pane {
                FoldSplit {
                    Page(top: top) {
                        VStack(alignment: .leading, spacing: S.head) { HubTitle(text: ProfileHead.name, size: 80); stats }.padding(.top, S.head)
                    }
                } right: {
                    Pager(.panorama, page: Binding(get: { max(page, 1) }, set: { page = $0 }), top: top,
                          panels: [nowPanel(.stage), lately, story])
                }
            } else {
                Pager(.panorama, title: ProfileHead.name, page: $page, top: top,
                      panels: [Panel(0, "") { stats }, nowPanel(sideways ? .short : size == .regular ? .wide : .column), lately, story])
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height * 1.15 } action: { sideways = $0 }
        .onChange(of: links.panel) { _, p in if let p { page = p; links.panel = nil } }
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: S.section) {
            ProfileHead().padding(.horizontal, S.margin)
            // The first read, high on the page while it runs: the moment the app is reading his years.
            if !sync.complete { YearsSection() }
            Totals().padding(.horizontal, S.margin)
            StreakCard().padding(.horizontal, S.margin)
            PaceCard().padding(.horizontal, S.margin)
            TimeCard()
        }
    }

    // What's on, or nothing pretending to be: today's figures and the last song. Then the day and every scrobble.
    private func nowPanel(_ layout: NowHero.Layout) -> Panel {
        let playing = store.nowPlaying != nil || store.hero == nil
        return Panel(1, playing ? "now playing" : "today") {
            VStack(alignment: .leading, spacing: S.section) {
                if playing {
                    NowHero(layout: layout == .stage ? .column : layout, titled: false)
                } else {
                    VStack(alignment: .leading, spacing: S.section) {
                        TodayFigures()
                        if let last = store.recent.first { LastPlayed(s: last) }
                    }
                    .padding(.horizontal, S.margin)
                }
                if store.trouble { TroubleNote().padding(.horizontal, S.margin) }
                DaySection(lead: !playing)
                RecentSection()
            }
        }
    }

    // This week and what's moving him now.
    private var lately: Panel {
        Panel(2, "lately") {
            VStack(alignment: .leading, spacing: S.section) {
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
                if sync.complete { YearsSection() }
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

// Where a link from a widget asks to go: a tab, a section of Start, a page. Set by the app's URL handler and taken up
// by the view that owns each, which clears it.
@MainActor @Observable final class Links {
    static let shared = Links()
    var tab: Int?
    var panel: Int?
    var push: Ask?
    struct Ask: Equatable { let tab: Int; let go: Go }

    // rotation://you, /now, /lately, /story, /charts?period=week, /artist?name=, /album?artist=&album=,
    // /track?artist=&title=&album=&image=
    func open(_ url: URL) {
        guard url.scheme == LinkScheme.scheme else { return }
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
        switch url.host() ?? "" {
        case "you": tab = 0; panel = 0
        case "now": tab = 0; panel = 1
        case "lately": tab = 0; panel = 2
        case "story": tab = 0; panel = 3
        case "charts":
            tab = 1
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
