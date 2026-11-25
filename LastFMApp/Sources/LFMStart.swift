import SwiftUI

// Start: him (Richard, 2026-11-14: "i feel like start should be like my profile image with my stats"). A Zune
// panorama under his name: his face and his figures first (scrobbles, artists, albums, tracks, the streak, this week
// against his usual, his listening time), then what's playing or his day, then lately (what he's on repeat with, his
// canon, what's taking over, what's new, his clock), then his story across the years. What were the Now and You tabs,
// moved to where they belong, nothing dropped: Now's week glance is this week's card and "on repeat".
// Open flat his face and figures hold the left pane and the other three sections pan on the right.
struct ProfileHub: View {
    let start: Int
    @Environment(\.paneLayout) private var pane
    @Environment(\.horizontalSizeClass) private var size
    @State private var page: Int
    init(start: Int) { self.start = start; _page = State(initialValue: min(max(start, 0), 2)) }
    private var store: Store { Store.shared }
    private var sync: HistorySync { HistorySync.shared }
    private var links: Links { Links.shared }
    var body: some View {
        GeometryReader { g in
            let sideways = g.size.width > g.size.height * 1.15
            if pane {
                FoldSplit {
                    Page {
                        VStack(alignment: .leading, spacing: S.head) {
                            AppTitle(text: "profile").turnstile(0)
                            HubTitle(text: ProfileHead.name, size: 80, least: 0.3).turnstile(0)
                            stats(wide: false).turnstile(1)
                        }.padding(.top, S.head)
                    }
                } right: {
                    Pager(.pivot, title: " ", page: Binding(get: { max(page, 1) }, set: { page = $0 }), top: 0, panels: [lately, story])
                }
            } else {
                // A pivot of three, his own first: him and his figures, what's moving him lately, his story. Every name
                // a tap away; what's on now has its own hub (home's tile), his day and every play are history.
                Pager(.pivot, page: $page, top: 0,
                      panels: [Panel(0, ProfileHead.name.lowercased()) { stats(wide: size == .regular && !sideways) }, lately, story])
            }
        }
        // The ask's keyboard goes as his page scrolls, or with a tap anywhere but the field (the tap only listens while
        // the keyboard is up).
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { v in
            if !AskKeyboard.shared.field.contains(v.location) { AskKeyboard.shared.dismiss() }
        }, including: AskKeyboard.shared.up ? .all : .subviews)
        .onChange(of: links.panel) { _, p in if let p { page = p; links.panel = nil } }
        // Claude's pieces that are due, once his whole history is in (each at most daily, only when it has moved).
        .task(id: sync.complete) { await Taste.shared.refresh() }
    }

    private func stats(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: S.section) {
            ProfileHead().padding(.horizontal, S.margin)
            if store.trouble { TroubleNote().padding(.horizontal, S.margin) }
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
            // Below the first screen: drawn once the page has turned in.
            Later {
                VStack(alignment: .leading, spacing: S.section) {
                    PaceCard().padding(.horizontal, S.margin)
                    MilestoneCard().padding(.horizontal, S.margin)
                    TimeCard()
                    // What his listening says, in words, and a question about it.
                    TastePortrait()
                    TasteAsk()
                }
            }
        }
    }

    // This week and what's moving him now.
    private var lately: Panel {
        Panel(1, "lately") {
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
        Panel(2, "story") {
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
    @Environment(\.openRoute) private var open
    private var store: Store { Store.shared }
    var body: some View {
        if let s = store.shown {
            Button { open.hub(.nowPlaying, nil) } label: {
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
                        .font(.zuneCaps(.caption, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        Text(s.title).font(.zune(.title3, .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(s.artist).font(.zune(.subheadline)).foregroundStyle(S.soft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.zune(.subheadline, .semibold)).foregroundStyle(S.soft)
                }
                // Flat, hung from the page's edge like everything under it: a line of the page, not a pane of glass.
                .contentShape(Rectangle())
            }
            .buttonStyle(Press())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens now playing")
        }
    }
}

// Where a link from a widget asks to go: the stack it should show (home under it, so Back always reaches home), and the
// section of a pivot. Set by the app's URL handler and taken up by RootView, which clears it.
@MainActor @Observable final class Links {
    static let shared = Links()
    var go: [Nav]?
    var panel: Int?

    // rotation://you, /now, /lately, /story, /charts?period=week, /scrobbling, /artist?name=, /album?artist=&album=,
    // /track?artist=&title=&album=&image=
    func open(_ url: URL) {
        guard url.scheme == LinkScheme.scheme else { return }
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
        switch url.host() ?? "" {
        case "you": go = [.hub(.profile, 0)]; panel = 0
        case "now": go = [.hub(.nowPlaying, nil)]
        case "lately": go = [.hub(.profile, 1)]; panel = 1
        case "story": go = [.hub(.profile, 2)]; panel = 2
        case "history": go = [.hub(.history, nil)]
        case "discover": go = [.hub(.discover, nil)]
        case "scrobbling": go = [.hub(.scrobbling, nil)]
        case "charts":
            go = [.hub(.charts, nil)]
            switch q["period"] ?? "" {
            case "month": ChartsModel.shared.period = .days(30)
            case "year": ChartsModel.shared.period = .days(365)
            default: ChartsModel.shared.period = .days(7)
            }
        case "artist":
            if let n = q["name"], !n.isEmpty { go = [.page(Go(route: .artist(n), zoom: nil))] }
        case "album":
            if let a = q["artist"], let l = q["album"], !a.isEmpty, !l.isEmpty { go = [.page(Go(route: .album(a, l), zoom: nil))] }
        case "track":
            if let a = q["artist"], let t = q["title"], !a.isEmpty, !t.isEmpty {
                go = [.page(Go(route: .track(Scrobble.song(artist: a, title: t, album: q["album"] ?? "", image: q["image"].flatMap { $0.isEmpty ? nil : $0 })), zoom: nil))]
            }
        default: break
        }
    }
}
