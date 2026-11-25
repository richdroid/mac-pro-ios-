import SwiftUI

// Home, as Zune HD's (lastfm.md §27): the application title small at the top, the song on now (or the last one) as a
// tile, then the menu as huge lowercase words in Zune's light face, each a hub; under them Quickplay's "history", the
// albums he's just played as covers running off the edge. Open flat the menu holds the left pane and Quickplay the right.
// Tapping a word: the menu turnstiles away about its left edge, the chosen word last, and the hub turns in.
struct HomeView: View {
    @Environment(\.paneLayout) private var pane
    @Environment(\.openRoute) private var open
    @State private var chosen: Int?
    private var store: Store { Store.shared }
    var body: some View {
        Group {
            if pane {
                FoldSplit {
                    Page { menuColumn.padding(.top, S.head) }
                } right: {
                    Page { Quickplay(wide: true).padding(.top, S.section) }
                }
            } else {
                Page {
                    VStack(alignment: .leading, spacing: S.section) {
                        menuColumn
                        Quickplay(wide: false)
                    }
                    .padding(.top, S.head)
                }
            }
        }
        .modifier(BarFade())
        .background { Backdrop(ref: store.shown?.art) }
        .toolbarBackground(.hidden, for: .navigationBar)
        // Back on home finds it as it was: the words flat again (they're reset once the hub has covered them).
        .onDisappear { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { chosen = nil } }
        .task(id: store.shown?.id) { if let s = store.shown { NowStats.shared.load(s, full: false) } }
    }

    private var menuColumn: some View {
        VStack(alignment: .leading, spacing: S.section) {
            AppTitle(text: "rotation")
                .modifier(TurnstileOut(index: 0, count: Hub.menu.count + 2, chosen: chosen.map { $0 + 2 }))
            NowTile { go(-1) }
                .padding(.horizontal, S.margin)
                .modifier(TurnstileOut(index: 1, count: Hub.menu.count + 2, chosen: chosen.map { $0 + 2 }))
            Menu(chosen: chosen) { go($0) }
        }
    }

    // The menu leaves first (0.25 s, feathered), then the hub is pushed without the system's slide: its own turnstile
    // brings it in. Back is the system's.
    private func go(_ i: Int) {
        guard chosen == nil else { return }
        chosen = i
        let hub = i < 0 ? Hub.nowPlaying : Hub.menu[i]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            open.hub(hub, nil)
        }
    }
}

// The menu's words. Zune HD set them so large they nearly fill the width; light, lowercase, tight.
private struct Menu: View {
    let chosen: Int?
    let go: (Int) -> Void
    @Environment(\.pageWidth) private var width
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1
    var body: some View {
        let size = min(76, max(50, width * 0.125)) * min(max(k, 0.9), 1.2)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Hub.menu.enumerated()), id: \.offset) { i, h in
                Button { go(i) } label: {
                    Text(h.word)
                        .font(.zune(size: size, .light)).tracking(-1.2)
                        .foregroundStyle(.white)
                        .lineLimit(1).fixedSize()
                        .padding(.leading, S.margin - 3)
                        .frame(maxWidth: .infinity, minHeight: size * 1.18, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Tilt())
                .modifier(TurnstileOut(index: i + 2, count: Hub.menu.count + 2, chosen: chosen.map { $0 + 2 }))
                .accessibilityLabel(h.word)
                .accessibilityAddTraits(.isButton)
            }
        }
    }
}

// What's on now, or the last song: the cover, the line that says which, the song, and its numbers at a glance.
struct NowTile: View {
    let go: () -> Void
    private var store: Store { Store.shared }
    private var stats: NowStats { NowStats.shared }
    var body: some View {
        if let s = store.shown {
            Button(action: go) {
                HStack(alignment: .top, spacing: S.gap + 2) {
                    ArtView(s.art, px: 240, corner: S.square).frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if s.nowPlaying, !store.trouble {
                                Image(systemName: "waveform").foregroundStyle(Z.accent)
                                    .symbolEffect(.variableColor.iterative, options: .repeating)
                                Text("now playing")
                            } else {
                                Text(s.nowPlaying ? "last heard" : "last played · \(when(s.date))")
                            }
                        }
                        .font(.zune(.caption, .semibold)).textCase(.uppercase).tracking(1).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        Text(s.title).font(.zune(.title3, .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(s.artist).font(.zune(.body)).foregroundStyle(Z.subtle).lineLimit(1)
                        Text(line).font(.zune(.subheadline)).monospacedDigit().foregroundStyle(Z.subtle).lineLimit(1)
                            .opacity(line.isEmpty ? 0 : 1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Tilt())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens now playing")
        }
    }
    // Everyone's listeners and his plays of it, once Last.fm has said.
    private var line: String {
        var parts: [String] = []
        if let l = stats.track?.listeners { parts.append("\(compact(l)) listeners") }
        if let n = stats.track?.userPlays ?? stats.trackStory?.plays, n > 0 { parts.append("your \(n == 1 ? "1 play" : "\(number(n)) plays")") }
        return parts.joined(separator: " · ")
    }
}

// Zune's Quickplay, read for him: "history" (the albums he's just played, newest first, covers running off the edge) and,
// open flat where there's room, his week's heavy rotation.
struct Quickplay: View {
    let wide: Bool
    @Environment(\.openRoute) private var open
    private var store: Store { Store.shared }
    var body: some View {
        VStack(alignment: .leading, spacing: S.section) {
            let albums = Self.albums(store.recent)
            if !albums.isEmpty {
                Panorama(title: "just played", items: albums, tiles: true) { e in when(e.last.map { Date(timeIntervalSince1970: TimeInterval($0)) }) }
            }
            // Open flat the right pane is Quickplay proper (gate 1: a strip over empty black): his week's heavy rotation,
            // who he's on repeat with, and what's new to him.
            if wide {
                RotationMosaic().padding(.horizontal, S.margin)
                WeekHub(title: "on repeat", list: store.insights.week)
                if store.insights.discoveries.count >= 3 { WeekHub(title: "new to you", list: store.insights.discoveries) }
            }
        }
    }
    // Each album once, in the order last played.
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
