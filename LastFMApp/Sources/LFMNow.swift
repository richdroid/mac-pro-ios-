import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Today in figures: plays, listening time (once enough lengths are known), artists, and the streak it keeps going.
struct TodayFigures: View {
    private var store: Store { Store.shared }
    var body: some View {
        let today = store.today
        VStack(alignment: .leading, spacing: S.inner) {
            VStack(alignment: .leading, spacing: S.pair) {
                Counting(today.count, key: "today").font(.zune(size: 64, .thin)).monospacedDigit().foregroundStyle(.white)
                Text(today.count == 1 ? "play" : "plays").font(.zune(.title3, .light)).foregroundStyle(S.soft)
            }
            .accessibilityElement(children: .combine)
            FigureGrid(items: [
                store.todaySecs.map { (duration($0), "listening") },
                (number(Set(today.map(\.artist)).count), Set(today.map(\.artist)).count == 1 ? "artist" : "artists"),
                // Albums, not the streak: the streak has its own card on the same screen (review 2026-11-14, item 2).
                { (n: Int) in (number(n), n == 1 ? "album" : "albums") }(Set(today.filter { !$0.album.isEmpty }.map { $0.artist + "\u{1F}" + $0.album }).count),
                // When his day's music began.
                today.first?.date.map { ($0.formatted(date: .omitted, time: .shortened), "first play") },
            ].compactMap { $0 })
        }
    }
}

// The last song, when nothing is playing: a small still cover and when it was, opening the song's page.
struct LastPlayed: View {
    let s: Scrobble
    var body: some View {
        Opens(route: .track(s), zoom: "last|\(s.id)") {
            HStack(spacing: S.inner) {
ArtView(s.art, px: 300, corner: 10).frame(width: 80).zoomSource("last|\(s.id)")
                VStack(alignment: .leading, spacing: S.pair) {
                    // Whole on one line, never "Played 52 min…" (run 25, folded): the long way when it fits, else the time alone.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { Image(systemName: "clock.arrow.circlepath"); Text("Played \(when(s.date))") }
                        HStack(spacing: 6) { Image(systemName: "clock.arrow.circlepath"); Text(when(s.date)) }
                        Text(when(s.date))
                    }
                    .lineLimit(1)
                    .font(.zune(.subheadline, .semibold)).foregroundStyle(.white.opacity(0.85))
                    Text(s.title).font(.zune(.title3, .bold)).foregroundStyle(.white).lineLimit(2)
                    Text(s.artist).font(.zune(.body)).foregroundStyle(S.soft).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.zune(.subheadline, .semibold)).foregroundStyle(S.soft)
            }
            .card()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the song")
    }
}

// His week at a glance on Now: plays so far, against his usual by now, and who he's played most, each opening its page.
struct WeekGlance: View {
    private var store: Store { Store.shared }
    var body: some View {
        let i = store.insights
        if let p = i.pace {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "this week")
                VStack(alignment: .leading, spacing: S.inner) {
                    HStack(alignment: .top, spacing: S.figures) {
                        Figure(value: number(p.now), label: "plays so far", size: 30)
                        let up = p.delta >= 0
                        VStack(alignment: .leading, spacing: S.pair) {
                            HStack(spacing: 4) {
                                Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.zune(.body, .semibold))
                                Text("\(Int((abs(p.delta) * 100).rounded()))%").font(.zune(size: 30, .light)).monospacedDigit()
                            }
                            .foregroundStyle(.white)
                            Text(up ? "more than usual" : "less than usual").font(.zune(.subheadline)).foregroundStyle(S.soft)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                    }
                    if !i.week.isEmpty {
                        HStack(spacing: S.gap) {
                            ForEach(Array(i.week.prefix(5).enumerated()), id: \.element.id) { k, a in
                                // Covers only: five names cut short in a narrow card read as clutter.
                                Opens(route: .artist(a.name), zoom: "week|\(a.name)") {
                                    ArtView(ArtRef(artist: a.name, album: a.album, url: a.image), px: 200, corner: 8).zoomSource("week|\(a.name)")
                                }
                                .frame(maxWidth: 76)
                                .accessibilityLabel("\(k + 1). \(a.name), \(a.plays) plays")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .card()
            }
            .padding(.horizontal, S.margin)
        }
    }
}

// Only after Last.fm hasn't answered for a while; a blip leaves nothing.
struct TroubleNote: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(S.soft)
            Text("Last.fm isn't answering. Showing what it last said.").font(.zune(.subheadline)).foregroundStyle(.white)
        }
        .padding(.horizontal, S.inner).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A plain band, as flat as the rest: a note, not a control.
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: S.square, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct NowHero: View {
    enum Layout { case column, wide, short, stage }
    let layout: Layout
    // In a panorama the section's header names it and the hub's title is his; the artist is said in the words.
    var titled = true
    @Environment(\.openRoute) private var open
    // His history with the song on now: his plays of it and of the artist, and when he first heard it.
    @State private var depth: Depth?
    // The song the figures were worked out for: the last ones stay until the next song's are known, then swap in place
    // (run 39: "Your 605th play" left and came back as the song changed).
    @State private var depthSong: Scrobble?
    // Where the song's block sits on the first screen (measured once, at rest), its height, and the screen's height:
    // the name's band goes whole above the foot or wholly under it, never cut by it (run 33, folded at rest).
    @State private var heroTop: CGFloat?
    @State private var heroHeight: CGFloat = 0
    @State private var viewport: CGFloat = 0
    struct Depth: Equatable { let id: String; let track: Int; let artist: Int; let first: Int? }
    init(layout: Layout, titled: Bool = true) { self.layout = layout; self.titled = titled; LaunchLog.mark("hero built") }
    private var store: Store { Store.shared }
    var body: some View {
        if let s = store.shown {
            let playing = s.nowPlaying
            VStack(alignment: .leading, spacing: S.head) {
                if titled {
                    HubTitle(text: s.artist, size: layout == .column || layout == .short ? 64 : 88)
                        .id(s.artist).transition(.opacity)
                }
                Group {
                    if layout == .wide {
                        // Open upright: the cover, and beside it his history with the song over its words, the column
                        // as tall as the cover (it was three lines under 250 pt of nothing; review 2026-11-14, item 20).
                        HStack(alignment: .top, spacing: S.figures) {
                            art(s, playing).frame(width: 300)
                            VStack(alignment: .leading, spacing: S.inner) {
                                if let d = depth, let ds = depthSong { FigureGrid(items: figures(ds, d, ds.nowPlaying)).contentTransition(.opacity) }
                                Spacer(minLength: 0)
                                words(s, playing, line: false).padding(.bottom, 6)
                            }
                            // At least the cover's height, more when the figures need it: held to 300 the column
                            // overflowed upward and "3rd" sat cut under the pivot's names (run 27).
                            .frame(minHeight: 300)
                        }
                    } else if layout == .short {
                        HStack(alignment: .bottom, spacing: S.figures) {
                            art(s, playing).frame(width: 250)
                            words(s, playing).padding(.bottom, 6)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: S.inner) {
                            art(s, playing).frame(maxWidth: layout == .stage ? 400 : 440)
                            words(s, playing)
                        }
                    }
                }
                .padding(.horizontal, S.margin)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { r in
                    if heroTop == nil { heroTop = r.minY }
                    heroHeight = r.height
                }
                // Zune HD's Now Playing: the artist's name huge and faint, drifting while it plays. A band of its own
                // under the song, never behind its words (it ran through "Orchard Lights / Velvet Rooms", run 32), and
                // always whole in its pane. Gone when nothing plays.
                if playing {
                    let size: CGFloat = layout == .wide ? 110 : 84
                    MixName(text: s.artist, size: size, moving: !store.trouble)
                        .padding(.top, bandDrop(ceil(size * 1.2)) - S.pair)
                        .id(s.artist)
                }
            }
            .background { Color.clear.containerRelativeFrame(.vertical).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 } }
            .animation(.smooth(duration: 0.5), value: s.id)
            .animation(.easeOut(duration: 0.3), value: depth)
            .task(id: "\(s.id)|\(HistorySync.shared.complete)") {
                // Only from the whole of his history: a count from part of it would be a guess.
                guard HistorySync.shared.complete else { depth = nil; depthSong = nil; return }
                let median = LengthFill.shared.median
                let t = await HistoryDB.reader.story(artist: s.artist, track: s.title, median: median)
                let a = await HistoryDB.reader.story(artist: s.artist, median: median)
                depth = Depth(id: s.id, track: t.plays, artist: a.plays, first: t.first)
                depthSong = s
            }
        } else {
            VStack(alignment: .leading, spacing: S.head) {
                if titled { HubTitle(text: "listening", size: 72) }
                // Before the very first answer: a record turning slowly, never an empty box. (The symbol's own
                // rotation, not a timeline worked out thirty times a second.)
                Image(systemName: "opticaldisc").resizable().scaledToFit().foregroundStyle(.white.opacity(0.35))
                    .frame(width: 120).symbolEffect(.rotate, options: .repeating)
                    .frame(maxWidth: 400).aspectRatio(1, contentMode: .fit)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: S.square, style: .continuous))
                .padding(.horizontal, S.margin)
                .accessibilityLabel("Waiting for your listening")
            }
        }
    }
    // How far the band is let down: nothing when it fits whole above the screen's foot at rest (or starts below it
    // anyway), else enough to start it just under the foot.
    private func bandDrop(_ band: CGFloat) -> CGFloat {
        guard let top = heroTop, viewport > 0, heroHeight > 0 else { return 0 }
        let start = top + heroHeight + S.head - S.pair
        guard start < viewport, start + band > viewport - 8 else { return 0 }
        return viewport - start + 8
    }
    private func art(_ s: Scrobble, _ playing: Bool) -> some View {
        let tint = ArtStore.shared.palette(s.art)?.vivid.color ?? Palette.from(name: s.artist + s.album).vivid.color
        return Button { open(Go(route: .track(s), zoom: "hero|\(s.id)")) } label: {
            // One view across songs: it crossfades its own picture over the last one (no new view per cover, which
            // showed the stand-in between). Still, no breathing: a forever animation with a 38 pt shadow redrew the
            // hero every frame (run 39 review, fault 8).
            ArtView(s.art, px: 1000, corner: 14)
                .zoomSource("hero|\(s.id)")
        }
        .buttonStyle(Press())
        .accessibilityLabel("\(s.title) by \(s.artist)")
        .accessibilityHint("Shows the song")
    }
    // Which play of the song this is. While it plays it isn't scrobbled yet, so it's one more than his plays so far.
    private func nth(_ d: Depth, _ playing: Bool) -> Int { d.track + (playing ? 1 : 0) }
    private func today(_ s: Scrobble, _ playing: Bool) -> Int {
        store.today.filter { !$0.nowPlaying && $0.artist == s.artist && $0.title == s.title }.count + (playing ? 1 : 0)
    }
    private static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private func figures(_ s: Scrobble, _ d: Depth, _ playing: Bool) -> [(String, String)] {
        let n = nth(d, playing), t = today(s, playing)
        return [
            (Self.ordinal(max(n, 1)), "play of this song"),
            t > 1 ? (Self.ordinal(t), "time today") : nil,
            d.artist > 0 ? (number(d.artist), "plays of the artist") : nil,
            d.first.map { (dateShort($0), "first heard") },
        ].compactMap { $0 }
    }
    private func depthLine(_: Scrobble, _: Bool) -> String? {
        guard let d = depth, let s = depthSong else { return nil }
        let playing = s.nowPlaying
        let n = nth(d, playing), t = today(s, playing)
        if n <= 1 { return "First listen" }
        return "Your \(Self.ordinal(n)) play" + (t > 1 ? " · \(Self.ordinal(t)) today" : "")
    }
    private func words(_ s: Scrobble, _ playing: Bool, line: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: S.pair) {
            HStack(spacing: 7) {
                if playing, !store.trouble {
                    // Under the hub's own "NOW PLAYING" the bars alone say it: the words once, not twice.
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating).foregroundStyle(Z.accent)
                    if titled { Text("Now playing") }
                } else if playing {
                    // Last.fm gone: what it last said was playing, not live bars over a song that may have ended (run 34).
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Last heard")
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Played \(when(s.date))")
                }
            }
            // Zune's label: small bold capitals. Then the song large and light, the artist under it in weight.
            .font(.zune(.caption, .bold)).textCase(.uppercase).tracking(0.8)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.bottom, S.pair)
            Text(s.title).font(.zune(.largeTitle, .light)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
            Text(s.artist).font(.zune(.title3, .semibold)).foregroundStyle(.white).lineLimit(2)
            if !s.album.isEmpty { Text(s.album).font(.zune(.body)).foregroundStyle(S.soft).lineLimit(2) }
            // A line of its own, its place held so the page doesn't jump when it's known.
            if line {
                Text(depthLine(s, playing) ?? " ").font(.zune(.subheadline, .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).padding(.top, S.pair)
            }
        }
        .contentTransition(.opacity)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// His day so far, hour by hour, each play a little block in its cover's own colour, stacked up as they happened: a strip
// that looks like the music it counts. Hold and slide to see an hour's songs.
struct DaySection: View {
    // Leading the page (nothing playing): today's figures sit just above, so the head doesn't count the plays again.
    var lead = false
    private var store: Store { Store.shared }
    @State private var colours = 0          // bumped as covers' colours come in
    @State private var held: Int?
    @State private var landed = DaySection.shown
    @MainActor static var shown = false
    var body: some View {
        let plays = store.today
        let start = store.dayStart
        // Columns run from the hour his day begins, round to the hour before it.
        let slot = { (d: Date) in (Calendar.current.component(.hour, from: d) - start + 24) % 24 }
        let bySlot = Dictionary(grouping: plays) { slot($0.date ?? Clock.now) }
        let tallest = max(bySlot.values.map(\.count).max() ?? 1, 6)
        let nowSlot = slot(Clock.now)
        VStack(alignment: .leading, spacing: S.head) {
            SectionHead(text: "your day", trailing: plays.isEmpty || lead ? nil : "\(plays.count) \(plays.count == 1 ? "play" : "plays")")
            ZStack(alignment: .top) {
                GeometryReader { g in
                    let gap: CGFloat = 3
                    let w = (g.size.width - gap * 23) / 24
                    let h = g.size.height - 22
                    let unit = min(h / CGFloat(tallest), 9)
                    ZStack(alignment: .topLeading) {
                        // The hours after dark, a shade lighter behind, so a night owl's evening reads as one stretch.
                        ForEach(Array(Self.nightRuns(start: start).enumerated()), id: \.offset) { _, run in
                            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04))
                                .frame(width: CGFloat(run.count) * (w + gap) - gap, height: h + 6)
                                .offset(x: CGFloat(run.first) * (w + gap), y: -3)
                        }
                        HStack(alignment: .bottom, spacing: gap) {
                            ForEach(0..<24, id: \.self) { k in
                                column(bySlot[k] ?? [], slot: k, now: nowSlot, unit: unit, width: w, height: h)
                            }
                        }
                        .frame(height: h, alignment: .bottom)
                        ForEach([0, 6, 12, 18], id: \.self) { k in
                            Text(Self.hourLabel((start + k) % 24)).font(.zune(.caption2, .medium)).foregroundStyle(S.soft)
                                .fixedSize()
                                .offset(x: CGFloat(k) * (w + gap), y: h + 6)
                        }
                    }
                    .contentShape(Rectangle())
                    .holdToScrub { p in
                        guard let p else { withAnimation(.snappy) { held = nil }; return }
                        let k = max(0, min(23, Int(p.x / (w + gap))))
                        if k != held {
                            #if os(iOS)
                            UISelectionFeedbackGenerator().selectionChanged()
                            #endif
                            withAnimation(.snappy(duration: 0.2)) { held = k }
                        }
                    }
                }
                .frame(height: 132)
                if let held { callout(bySlot[held] ?? [], hour: (start + held) % 24).offset(y: -8) }
            }
            .id(colours)
        }
        .padding(.horizontal, S.margin)
        .task(id: plays.count) {
            // Each album's colour, once; most come from the disk at once.
            var changed = false
            for ref in Set(plays.map(\.art)) where ArtStore.shared.palette(ref) == nil {
                if await ArtStore.shared.palette(loading: ref) != nil { changed = true }
            }
            if changed { withAnimation(.easeOut(duration: 0.35)) { colours += 1 } }
        }
        .task {
            // The build's pose: an hour held, its songs showing.
            guard Pose.name == "scrub" else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.snappy) { held = (21 - Store.shared.dayStart + 24) % 24 }
        }
        .onAppear {
            guard !landed else { return }
            if Pose.name == "nofall" { landed = true; Self.shown = true; return }
            // The blocks fall into place once, the first time the day is shown after launch; never on a return.
            Task { try? await Task.sleep(nanoseconds: 250_000_000); withAnimation(.spring(response: 0.7, dampingFraction: 0.72)) { landed = true }; Self.shown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your day: \(plays.count) plays")
    }
    static func hourLabel(_ h: Int) -> String {
        var c = DateComponents(); c.hour = h
        return (Calendar.current.date(from: c) ?? .now).formatted(.dateTime.hour())
    }
    // Night: 8 PM to 6 AM, as runs of columns from where his day starts (one run, or two when the day starts at night).
    static func nightRuns(start: Int) -> [(first: Int, count: Int)] {
        let night = (0..<24).map { k -> Bool in let h = (start + k) % 24; return h >= 20 || h < 6 }
        var runs: [(first: Int, count: Int)] = []
        for k in 0..<24 where night[k] {
            if let last = runs.last, last.first + last.count == k { runs[runs.count - 1].count += 1 } else { runs.append((k, 1)) }
        }
        return runs
    }
    private func column(_ list: [Scrobble], slot hour: Int, now: Int, unit: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 1.5) {
            if hour == now, let p = Store.shared.nowPlaying {
                // The song on now, a bright bead on top. Still: a forever animation is main-thread work every frame (run 40).
                Capsule().fill(colour(p)).frame(width: width, height: max(unit - 1.5, 3)).opacity(0.9)
            }
            ForEach(Array(list.reversed().enumerated()), id: \.element.id) { i, s in
                RoundedRectangle(cornerRadius: min(2.5, unit / 3), style: .continuous)
                    .fill(colour(s))
                    .frame(width: width, height: max(unit - 1.5, 1.5))
                    .offset(y: landed ? 0 : -height - CGFloat(i) * 6)
                    .opacity(landed ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(Double(hour) * 0.018 + Double(list.count - i) * 0.008), value: landed)
            }
            if list.isEmpty && hour > now {
                Circle().fill(.white.opacity(0.12)).frame(width: 3, height: 3)
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
        .opacity(held == nil || held == hour ? 1 : 0.35)
    }
    private func colour(_ s: Scrobble) -> Color {
        (ArtStore.shared.palette(s.art) ?? Palette.from(name: s.artist + s.album)).vivid.color
    }
    private func callout(_ list: [Scrobble], hour: Int) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -12) {
                ForEach(Array(list.suffix(4).reversed().enumerated()), id: \.element.id) { i, s in
                    ArtView(s.art, px: 120, corner: 5).frame(width: 38).zIndex(Double(10 - i))
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(list.isEmpty ? "Nothing played" : "\(list.count) \(list.count == 1 ? "play" : "plays")").font(.zune(.subheadline, .semibold))
                Text(list.last.map { "\($0.artist)" } ?? Self.hourLabel(hour)).font(.zune(.footnote)).foregroundStyle(S.soft).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(Self.hourLabel(hour)).font(.zune(.subheadline, .medium)).monospacedDigit().foregroundStyle(S.soft)
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

// Every scrobble, newest first, under the day it was played; more come as he nears the end. Three or more in a row
// from one album are one row (the album, how many songs, when), which opens in place to its songs: an album played
// through no longer floods the list with one cover (review 2026-11-14, item 24).
struct RecentSection: View {
    // The last song is already the card above (nothing playing): the list starts at the one before it.
    var skipFirst = false
    @State private var open: Set<String> = []
    private var store: Store { Store.shared }
    private enum Item: Identifiable {
        case one(Scrobble), run([Scrobble])
        var id: String { switch self { case .one(let s): return s.id; case .run(let r): return "run|" + (r.last?.id ?? "") } }
    }
    private func items(_ list: [Scrobble]) -> [Item] {
        var out: [Item] = [], run: [Scrobble] = []
        func flush() {
            if run.count >= 3 { out.append(.run(run)) } else { out.append(contentsOf: run.map { .one($0) }) }
            run = []
        }
        for s in list {
            if let f = run.first, !s.nowPlaying, !s.album.isEmpty, f.album == s.album, f.artist == s.artist { run.append(s) }
            else { flush(); if s.nowPlaying || s.album.isEmpty { out.append(.one(s)) } else { run = [s] } }
        }
        flush()
        return out
    }
    var body: some View {
        let all = skipFirst ? Array(store.recent.dropFirst()) : store.recent
        let groups = Dictionary(grouping: all) { Calendar.current.startOfDay(for: $0.date ?? Clock.now) }
        let days = groups.keys.sorted(by: >)
        let lastID = store.recent.last?.id
        LazyVStack(alignment: .leading, spacing: 0) {
            SectionHead(text: skipFirst ? "earlier" : "recent").padding(.bottom, S.head)
            ForEach(days, id: \.self) { day in
                Text(dayName(day)).font(.zune(.headline)).foregroundStyle(S.soft)
                    .padding(.top, day == days.first ? 0 : S.inner).padding(.bottom, S.pair)
                ForEach(items(groups[day] ?? [])) { item in
                    switch item {
                    case .one(let s):
                        TrackRow(s: s).onAppear { if s.id == lastID { Task { await store.loadMore() } } }
                    case .run(let r):
                        let on = open.contains(item.id)
                        RunRow(run: r, open: on) { withAnimation(.smooth(duration: 0.3)) { if on { open.remove(item.id) } else { open.insert(item.id) } } }
                            .onAppear { if r.contains(where: { $0.id == lastID }) { Task { await store.loadMore() } } }
                        if on { ForEach(r) { s in TrackRow(s: s).padding(.leading, S.gap).transition(.opacity) } }
                    }
                }
            }
            if store.loadingMore { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 16) }
        }
        .padding(.horizontal, S.margin)
    }
}

// An album played through: its cover, how many songs, and when, opening in place to the songs.
struct RunRow: View {
    let run: [Scrobble]        // newest first
    let open: Bool
    let toggle: () -> Void
    var body: some View {
        if let newest = run.first, let oldest = run.last {
            Button(action: toggle) {
                HStack(spacing: S.gap) {
                    ArtView(newest.art, px: 156, corner: 6).frame(width: S.art)
                    // The time beside the names when all of them fit whole; when narrow (folded, "Velvet Ro… / 6 songs
                    // · O…" beside "9:20 PM – 9:38 PM", run 32) it goes on a line of its own under them, and the names
                    // take two lines before they're ever cut.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: S.gap) {
                            VStack(alignment: .leading, spacing: S.pair / 2) {
                                Text(newest.album).font(.zune(.title3)).foregroundStyle(.white).lineLimit(1)
                                Text("\(run.count) songs · \(newest.artist)").font(.zune(.subheadline)).monospacedDigit().foregroundStyle(S.soft).lineLimit(1)
                            }
                            .fixedSize()
                            Spacer(minLength: 8)
                            Text(Self.span(oldest.date, newest.date)).font(.zune(.subheadline)).monospacedDigit().foregroundStyle(S.soft).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: S.pair / 2) {
                            Text(newest.album).font(.zune(.title3)).foregroundStyle(.white).lineLimit(2)
                            Text("\(run.count) songs · \(newest.artist)").font(.zune(.subheadline)).monospacedDigit().foregroundStyle(S.soft).lineLimit(2)
                            Text(Self.span(oldest.date, newest.date)).font(.zune(.subheadline)).monospacedDigit().foregroundStyle(S.soft).lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Image(systemName: "chevron.down").font(.zune(.footnote, .semibold)).foregroundStyle(.white.opacity(0.85))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.vertical, S.row / 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(Press())
            .accessibilityElement(children: .combine)
            .accessibilityHint(open ? "Hides the songs" : "Shows the songs")
        }
    }
    // "3:02 – 3:39 PM": the first time without its AM or PM when both share it.
    static func span(_ a: Date?, _ b: Date?) -> String {
        guard let a, let b else { return "" }
        let fa = a.formatted(date: .omitted, time: .shortened), fb = b.formatted(date: .omitted, time: .shortened)
        let pa = fa.split(separator: " "), pb = fb.split(separator: " ")
        if pa.count == 2, pb.count == 2, pa[1] == pb[1] { return "\(pa[0]) – \(fb)" }
        return "\(fa) – \(fb)"
    }
}

struct TrackRow: View {
    let s: Scrobble
    @Environment(\.openRoute) private var open
    var body: some View {
        Button { open(Go(route: .track(s), zoom: "recent|\(s.id)")) } label: {
            HStack(spacing: S.gap) {
                ArtView(s.art, px: 156, corner: 6).frame(width: S.art).zoomSource("recent|\(s.id)")
                VStack(alignment: .leading, spacing: S.pair / 2) {
                    Text(s.title).font(.zune(.title3)).foregroundStyle(.white).lineLimit(2)
                    Text(s.artist).font(.zune(.subheadline)).foregroundStyle(S.soft).lineLimit(2)
                }
                Spacer(minLength: 8)
                if s.loved { Image(systemName: "heart.fill").font(.zune(.footnote)).foregroundStyle(S.accent).accessibilityLabel("Loved") }
                Text(s.date?.formatted(date: .omitted, time: .shortened) ?? "").font(.zune(.subheadline)).monospacedDigit().foregroundStyle(S.soft)
            }
            .padding(.vertical, S.row / 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .accessibilityElement(children: .combine)
    }
}
