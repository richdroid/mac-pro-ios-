import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Now: what's playing (or last played) as the hero, his day so far drawn in its covers' colours, and every scrobble
// since, newest first. Folded and open upright one column; open flat the hero holds the left pane still while the day
// and the list scroll on the right.
struct NowTab: View {
    let top: Int
    @Environment(\.paneLayout) private var pane
    @Environment(\.horizontalSizeClass) private var size
    // Wider than tall in one column: folded and turned sideways. The hero goes side by side so the song's words stay
    // on screen with its cover.
    @State private var sideways = false
    private var store: Store { Store.shared }
    var body: some View {
        Group {
            if pane {
                FoldSplit {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        NowHero(layout: .stage)
                        Spacer(minLength: 0)
                    }
                } right: {
                    page { VStack(alignment: .leading, spacing: S.section) { trouble; DaySection(); RecentSection() }.padding(.top, 24) }
                }
            } else {
                page {
                    VStack(alignment: .leading, spacing: S.section) {
                        NowHero(layout: sideways ? .short : size == .regular ? .wide : .column)
                        trouble
                        DaySection()
                        RecentSection()
                    }
                }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height * 1.15 } action: { sideways = $0 }
    }
    @ViewBuilder private var trouble: some View {
        if store.trouble { TroubleNote().padding(.horizontal, S.margin) }
    }
    private func page<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        let content = c()
        return ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("top")
                content.padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .onChange(of: top) { _, _ in withAnimation(.smooth) { proxy.scrollTo("top", anchor: .top) } }
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
    @Environment(\.openTrack) private var open
    @State private var breathe = false
    private var store: Store { Store.shared }
    var body: some View {
        if let s = store.hero {
            let playing = s.nowPlaying
            VStack(alignment: .leading, spacing: 18) {
                HubTitle(text: s.artist, size: layout == .column || layout == .short ? 64 : 88)
                    .id(s.artist).transition(.opacity)
                Group {
                    if layout == .wide || layout == .short {
                        HStack(alignment: .bottom, spacing: 24) {
                            art(s, playing).frame(width: layout == .short ? 250 : 300)
                            words(s, playing).padding(.bottom, 6)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            art(s, playing).frame(maxWidth: layout == .stage ? 400 : 440)
                            words(s, playing)
                        }
                    }
                }
                .padding(.horizontal, S.margin)
            }
            .animation(.smooth(duration: 0.5), value: s.id)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                HubTitle(text: "listening", size: 72)
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)).aspectRatio(1, contentMode: .fit).frame(maxWidth: 400)
                    .padding(.horizontal, S.margin)
            }
        }
    }
    private func art(_ s: Scrobble, _ playing: Bool) -> some View {
        let tint = ArtStore.shared.palette(s.art)?.vivid.color ?? Palette.from(name: s.artist + s.album).vivid.color
        return Button { open(s) } label: {
            ArtView(s.art, px: 1000, corner: 14)
                .id(s.art.key)
                .transition(.opacity.animation(.easeInOut(duration: 0.45)))
                .shadow(color: tint.opacity(0.5), radius: 38, y: 16)
                .scaleEffect(playing && breathe ? 1.012 : 1)
                .animation(playing ? .easeInOut(duration: 3.6).repeatForever(autoreverses: true) : .smooth, value: breathe)
                .zoomSource(s.id)
        }
        .buttonStyle(Press())
        .onAppear { breathe = true }
        .accessibilityLabel("\(s.title) by \(s.artist)")
        .accessibilityHint("Shows the song")
    }
    private func words(_ s: Scrobble, _ playing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
            .padding(.bottom, 4)
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
            SectionHead(text: "your day", trailing: plays.isEmpty ? nil : "\(plays.count) \(plays.count == 1 ? "play" : "plays")")
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
                    .padding(.top, day == days.first ? 0 : 22).padding(.bottom, 8)
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
    @Environment(\.openTrack) private var open
    var body: some View {
        Button { open(s) } label: {
            HStack(spacing: 14) {
                ArtView(s.art, px: 156, corner: 6).frame(width: 52).zoomSource(s.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(s.artist).font(.subheadline).foregroundStyle(S.soft).lineLimit(1)
                }
                Spacer(minLength: 8)
                if s.loved { Image(systemName: "heart.fill").font(.footnote).foregroundStyle(S.accent).accessibilityLabel("Loved") }
                Text(s.date?.formatted(date: .omitted, time: .shortened) ?? "").font(.subheadline).monospacedDigit().foregroundStyle(S.soft)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .accessibilityElement(children: .combine)
    }
}
