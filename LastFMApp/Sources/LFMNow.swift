import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Now. While a song plays: the song as the hero (its cover large, breathing), his day so far drawn in its covers'
// colours, his week, and every scrobble since. While nothing plays, nothing pretends to: the page leads with his
// listening (today's figures, his day, his week) and the last song sits in a small card, "Last played 2 h ago", its
// cover still. Folded and open upright one column; open flat the hero (or today) holds the left pane while the rest
// scrolls on the right.
struct NowTab: View {
    let top: Int
    @Environment(\.paneLayout) private var pane
    @Environment(\.horizontalSizeClass) private var size
    // Wider than tall in one column: folded and turned sideways. The hero goes side by side so the song's words stay
    // on screen with its cover.
    @State private var sideways = false
    private var store: Store { Store.shared }
    var body: some View {
        let playing = store.nowPlaying != nil || store.hero == nil
        Group {
            if pane {
                FoldSplit {
                    if playing {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            NowHero(layout: .stage)
                            Spacer(minLength: 0)
                        }
                    } else {
                        Page(top: top) { idleHead.padding(.top, S.head) }
                    }
                } right: {
                    Page(top: top) {
                        VStack(alignment: .leading, spacing: S.section) { trouble; DaySection(lead: !playing); WeekGlance(); RecentSection() }.padding(.top, S.section)
                    }
                }
            } else {
                Page(top: top) {
                    VStack(alignment: .leading, spacing: S.section) {
                        if playing {
                            NowHero(layout: sideways ? .short : size == .regular ? .wide : .column)
                        } else {
                            idleHead
                        }
                        trouble
                        DaySection(lead: !playing)
                        WeekGlance()
                        RecentSection()
                    }
                    .padding(.top, S.head)
                }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height * 1.15 } action: { sideways = $0 }
    }
    // Nothing playing: today first, then the last song, plainly.
    private var idleHead: some View {
        VStack(alignment: .leading, spacing: S.head) {
            HubTitle(text: "today", size: 80)
            VStack(alignment: .leading, spacing: S.section) {
                TodayFigures()
                if let last = store.recent.first { LastPlayed(s: last) }
            }
            .padding(.horizontal, S.margin)
        }
    }
    @ViewBuilder private var trouble: some View {
        if store.trouble { TroubleNote().padding(.horizontal, S.margin) }
    }
}

// Today in figures: plays, listening time (once enough lengths are known), artists, and the streak it keeps going.
struct TodayFigures: View {
    private var store: Store { Store.shared }
    var body: some View {
        let today = store.today
        VStack(alignment: .leading, spacing: S.inner) {
            VStack(alignment: .leading, spacing: S.pair) {
                Text(number(today.count)).font(.system(size: 64, weight: .thin)).monospacedDigit().foregroundStyle(.white).contentTransition(.numericText())
                Text(today.count == 1 ? "play" : "plays").font(.title3.weight(.light)).foregroundStyle(S.soft)
            }
            .accessibilityElement(children: .combine)
            FigureGrid(items: [
                store.todaySecs.map { (duration($0), "listening") },
                (number(Set(today.map(\.artist)).count), Set(today.map(\.artist)).count == 1 ? "artist" : "artists"),
                store.insights.streak.map { ("\($0)", $0 == 1 ? "day in a row" : "days in a row") },
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
                ArtView(s.art, px: 300, corner: 10).frame(width: 96).zoomSource("last|\(s.id)")
                VStack(alignment: .leading, spacing: S.pair) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("Last played \(when(s.date))")
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    Text(s.title).font(.title3.weight(.bold)).foregroundStyle(.white).lineLimit(2)
                    Text(s.artist).font(.body).foregroundStyle(S.soft).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(S.soft)
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
                                Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.body.weight(.semibold))
                                Text("\(Int((abs(p.delta) * 100).rounded()))%").font(.system(size: 30, weight: .light)).monospacedDigit()
                            }
                            .foregroundStyle(.white)
                            Text(up ? "more than usual" : "less than usual").font(.subheadline).foregroundStyle(S.soft)
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
            Text("Last.fm isn't answering. Showing what it last said.").font(.subheadline).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct NowHero: View {
    enum Layout { case column, wide, short, stage }
    let layout: Layout
    @Environment(\.openRoute) private var open
    @State private var breathe = false
    init(layout: Layout) { self.layout = layout; LaunchLog.mark("hero built") }
    private var store: Store { Store.shared }
    var body: some View {
        if let s = store.hero {
            let playing = s.nowPlaying
            VStack(alignment: .leading, spacing: S.head) {
                HubTitle(text: s.artist, size: layout == .column || layout == .short ? 64 : 88)
                    .id(s.artist).transition(.opacity)
                Group {
                    if layout == .wide || layout == .short {
                        HStack(alignment: .bottom, spacing: S.figures) {
                            art(s, playing).frame(width: layout == .short ? 250 : 300)
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
            }
            .animation(.smooth(duration: 0.5), value: s.id)
        } else {
            VStack(alignment: .leading, spacing: S.head) {
                HubTitle(text: "listening", size: 72)
                // Before the very first answer: a record turning slowly on glass, never an empty box.
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    Image(systemName: "opticaldisc").resizable().scaledToFit().foregroundStyle(.white.opacity(0.35))
                        .frame(width: 120).rotationEffect(.degrees(tl.date.timeIntervalSinceReferenceDate * 40))
                }
                .frame(maxWidth: 400).aspectRatio(1, contentMode: .fit)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, S.margin)
                .accessibilityLabel("Waiting for your listening")
            }
        }
    }
    private func art(_ s: Scrobble, _ playing: Bool) -> some View {
        let tint = ArtStore.shared.palette(s.art)?.vivid.color ?? Palette.from(name: s.artist + s.album).vivid.color
        return Button { open(Go(route: .track(s), zoom: "hero|\(s.id)")) } label: {
            ArtView(s.art, px: 1000, corner: 14)
                .id(s.art.key)
                .transition(.opacity.animation(.easeInOut(duration: 0.45)))
                .shadow(color: tint.opacity(0.5), radius: 38, y: 16)
                .scaleEffect(playing && breathe ? 1.012 : 1)
                .animation(playing ? .easeInOut(duration: 3.6).repeatForever(autoreverses: true) : .smooth, value: breathe)
                .zoomSource("hero|\(s.id)")
        }
        .buttonStyle(Press())
        .onAppear { breathe = true }
        .accessibilityLabel("\(s.title) by \(s.artist)")
        .accessibilityHint("Shows the song")
    }
    private func words(_ s: Scrobble, _ playing: Bool) -> some View {
        VStack(alignment: .leading, spacing: S.pair) {
            HStack(spacing: 7) {
                if playing {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                    Text("Now playing")
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Played \(when(s.date))")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.bottom, S.pair)
            Text(s.title).font(.system(.title, weight: .bold)).foregroundStyle(.white).lineLimit(2)
            Text(s.artist).font(.title3).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            if !s.album.isEmpty { Text(s.album).font(.body).foregroundStyle(S.soft).lineLimit(1) }
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
                            Text(Self.hourLabel((start + k) % 24)).font(.caption2.weight(.medium)).foregroundStyle(S.soft)
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
                // The song on now, a bright bead on top, breathing.
                Capsule().fill(colour(p)).frame(width: width, height: max(unit - 1.5, 3)).opacity(0.9)
                    .phaseAnimator([0.45, 1]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 1.2) }
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
                Text(list.isEmpty ? "Nothing played" : "\(list.count) \(list.count == 1 ? "play" : "plays")").font(.subheadline.weight(.semibold))
                Text(list.last.map { "\($0.artist)" } ?? Self.hourLabel(hour)).font(.footnote).foregroundStyle(S.soft).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(Self.hourLabel(hour)).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(S.soft)
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

// Every scrobble, newest first, under the day it was played; more come as he nears the end.
struct RecentSection: View {
    private var store: Store { Store.shared }
    var body: some View {
        let groups = Dictionary(grouping: store.recent) { Calendar.current.startOfDay(for: $0.date ?? Clock.now) }
        let days = groups.keys.sorted(by: >)
        LazyVStack(alignment: .leading, spacing: 0) {
            SectionHead(text: "recent").padding(.bottom, S.head)
            ForEach(days, id: \.self) { day in
                Text(dayName(day)).font(.headline).foregroundStyle(S.soft)
                    .padding(.top, day == days.first ? 0 : S.inner).padding(.bottom, S.pair)
                ForEach(groups[day] ?? []) { s in
                    TrackRow(s: s)
                        .onAppear { if s.id == store.recent.last?.id { Task { await store.loadMore() } } }
                }
            }
            if store.loadingMore { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 16) }
        }
        .padding(.horizontal, S.margin)
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
                    Text(s.title).font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(s.artist).font(.subheadline).foregroundStyle(S.soft).lineLimit(1)
                }
                Spacer(minLength: 8)
                if s.loved { Image(systemName: "heart.fill").font(.footnote).foregroundStyle(S.accent).accessibilityLabel("Loved") }
                Text(s.date?.formatted(date: .omitted, time: .shortened) ?? "").font(.subheadline).monospacedDigit().foregroundStyle(S.soft)
            }
            .padding(.vertical, S.row / 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .accessibilityElement(children: .combine)
    }
}
