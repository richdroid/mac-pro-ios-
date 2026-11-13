import SwiftUI
import Charts

// You: who he is on Last.fm and what moves him. His name as the hub's title, the totals as big numbers, the streak, this
// week against his usual, the artist taking over his week, the week's artists and what's new to him, and his years.
// Every figure comes from his own plays on the phone; a figure that can't yet be known (the history still being read)
// isn't shown rather than guessed.
struct YouTab: View {
    let top: Int
    @Environment(\.paneLayout) private var pane
    private var store: Store { Store.shared }
    private var sync: HistorySync { HistorySync.shared }
    var body: some View {
        if pane {
            FoldSplit {
                page { VStack(alignment: .leading, spacing: S.section) { identity; years } }
            } right: {
                page { VStack(alignment: .leading, spacing: S.section) { listening }.padding(.top, 28) }
            }
        } else {
            page {
                VStack(alignment: .leading, spacing: S.section) {
                    identity
                    if !sync.complete { YearsSection() }
                    listening
                    if sync.complete { YearsSection() }
                }
            }
        }
    }
    @ViewBuilder private var identity: some View {
        VStack(alignment: .leading, spacing: 22) {
            HubTitle(text: store.profile?.name ?? LastFM.shared.user, size: 80)
            ProfileHead().padding(.horizontal, S.margin)
            Totals().padding(.horizontal, S.margin)
            StreakCard().padding(.horizontal, S.margin)
        }
    }
    @ViewBuilder private var years: some View { YearsSection() }
    @ViewBuilder private var listening: some View {
        PaceCard().padding(.horizontal, S.margin)
        RisingCard().padding(.horizontal, S.margin)
        WeekHub(title: "this week", list: store.insights.week)
        if !store.insights.discoveries.isEmpty { WeekHub(title: "new to you", list: store.insights.discoveries) }
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

struct ProfileHead: View {
    private var store: Store { Store.shared }
    var body: some View {
        let p = store.profile
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(.white.opacity(0.08))
                if let p {
                    ArtView(ArtRef(artist: p.name, album: "avatar", url: p.image), px: 240, corner: 40)
                }
            }
            .frame(width: 64, height: 64).clipShape(Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
            VStack(alignment: .leading, spacing: 3) {
                Text(p.map { $0.realname.isEmpty ? $0.name : $0.realname } ?? " ").font(.title3.weight(.semibold)).foregroundStyle(.white)
                if let p { Text("Scrobbling since \(p.registered.formatted(.dateTime.month(.wide).year()))").font(.subheadline).foregroundStyle(S.soft) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Totals: View {
    private var store: Store { Store.shared }
    var body: some View {
        let p = store.profile
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(p.map { number($0.playcount) } ?? "–").font(.system(size: 64, weight: .thin)).monospacedDigit().foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                Text("scrobbles").font(.title3.weight(.light)).foregroundStyle(S.soft)
            }
            .accessibilityElement(children: .combine)
            HStack(alignment: .top, spacing: 0) {
                Figure(value: p.map { number($0.artists) } ?? "–", label: "artists").frame(maxWidth: .infinity, alignment: .leading)
                Figure(value: p.map { number($0.albums) } ?? "–", label: "albums").frame(maxWidth: .infinity, alignment: .leading)
                Figure(value: p.map { number($0.tracks) } ?? "–", label: "tracks").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// Days in a row with music, and the last four weeks as a row of dots, each as big as that day was.
struct StreakCard: View {
    private var store: Store { Store.shared }
    var body: some View {
        let i = store.insights
        let today = LocalDay.today
        let days = (0..<28).map { i.days[today - 27 + $0] ?? 0 }
        let peak = max(days.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "flame.fill").font(.title2).foregroundStyle(LinearGradient(colors: [.yellow, .orange, S.accent], startPoint: .top, endPoint: .bottom))
                    .symbolEffect(.bounce, value: i.streak)
                Text(i.streak.map { "\($0)" } ?? "–").font(.system(size: 44, weight: .light)).monospacedDigit().foregroundStyle(.white).contentTransition(.numericText())
                Text(i.streak == 1 ? "day in a row" : "days in a row").font(.title3.weight(.light)).foregroundStyle(S.soft)
                Spacer(minLength: 0)
                if let best = i.best { Figure(value: "\(best)", label: "best", size: 22).fixedSize() }
            }
            GeometryReader { g in
                let d = (g.size.width - 27 * 4) / 28
                HStack(spacing: 4) {
                    ForEach(0..<28, id: \.self) { k in
                        let v = days[k]
                        Circle()
                            .fill(v == 0 ? Color.white.opacity(0.1) : S.accent.opacity(0.35 + 0.65 * Double(v) / Double(peak)))
                            .frame(width: max(4, d * (v == 0 ? 0.35 : 0.45 + 0.55 * CGFloat(v) / CGFloat(peak))))
                            .frame(width: d, height: d)
                    }
                }
            }
            .frame(height: 12)
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(i.streak.map { "\($0) days in a row" } ?? "Streak not known yet")
    }
}

// This week against his usual: plays so far, and how that compares with the weeks before at the same moment of the week.
struct PaceCard: View {
    private var store: Store { Store.shared }
    var body: some View {
        if let p = store.insights.pace {
            let hero = ArtStore.shared.palette(Store.shared.hero?.art ?? ArtRef(artist: "", album: "", url: nil))?.vivid.color ?? S.accent
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "this week")
                HStack(alignment: .top, spacing: 28) {
                    Figure(value: number(p.now), label: "plays so far", size: 40)
                    let up = p.delta >= 0
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.title3.weight(.semibold))
                            Text("\(Int((abs(p.delta) * 100).rounded()))%").font(.system(size: 40, weight: .light)).monospacedDigit()
                        }
                        .foregroundStyle(.white)
                        Text(up ? "more than usual by now" : "less than usual by now").font(.subheadline).foregroundStyle(S.soft)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                }
                Chart {
                    ForEach(0..<7, id: \.self) { d in
                        AreaMark(x: .value("Day", d), yStart: .value("Usual low", p.usualBand[d].lo), yEnd: .value("Usual high", p.usualBand[d].hi))
                            .foregroundStyle(.white.opacity(0.12)).interpolationMethod(.monotone)
                        LineMark(x: .value("Day", d), y: .value("Usual", p.usualBand[d].mid), series: .value("Series", "usual"))
                            .foregroundStyle(.white.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 4])).interpolationMethod(.monotone)
                    }
                    ForEach(Array(p.thisWeek.enumerated()), id: \.offset) { d, v in
                        LineMark(x: .value("Day", d), y: .value("This week", v), series: .value("Series", "now"))
                            .foregroundStyle(hero).lineStyle(StrokeStyle(lineWidth: 3.5, lineCap: .round)).interpolationMethod(.monotone)
                    }
                    if let last = p.thisWeek.last {
                        PointMark(x: .value("Day", p.thisWeek.count - 1), y: .value("This week", last))
                            .foregroundStyle(hero).symbolSize(110)
                    }
                }
                .chartXScale(domain: 0...6)
                .chartXAxis {
                    AxisMarks(values: Array(0..<7)) { v in
                        AxisValueLabel { Text(Self.weekday(v.as(Int.self) ?? 0)).font(.caption2.weight(.medium)).foregroundStyle(S.soft) }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel().foregroundStyle(S.soft).font(.caption2)
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("This week's plays by day against your usual week")
                HStack(spacing: 16) {
                    legend(Capsule().fill(hero).frame(width: 16, height: 4), "this week")
                    legend(RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.2)).frame(width: 16, height: 10), "usual, \(p.weeks) weeks")
                }
                .font(.caption).foregroundStyle(S.soft)
            }
            .card()
        }
    }
    private func legend<V: View>(_ mark: V, _ text: String) -> some View { HStack(spacing: 6) { mark; Text(text) } }
    static func weekday(_ i: Int) -> String {
        let cal = Calendar.current
        let syms = cal.veryShortStandaloneWeekdaySymbols
        return syms[(cal.firstWeekday - 1 + i) % 7]
    }
}

// The artist taking over his week: a far bigger share of these seven days than of the year before. Its cover fills the
// card, Zune's full-bleed backdrop.
struct RisingCard: View {
    private var store: Store { Store.shared }
    var body: some View {
        if let r = store.insights.rising {
            let ref = ArtRef(artist: r.artist, album: r.album, url: r.image)
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "taking over")
                ZStack(alignment: .bottomLeading) {
                    GeometryReader { g in
                        ArtView(ref, px: 900, corner: 0).frame(width: g.size.width, height: g.size.width).position(x: g.size.width / 2, y: g.size.height / 2)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 14) {
                        Text(r.artist).font(.system(size: 38, weight: .bold)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                        share(r.weekShare, "of your week", strong: true)
                        share(r.yearShare, "of your year before", strong: false)
                    }
                    .padding(18)
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: S.corner, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: S.corner, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
                .accessibilityElement(children: .combine)
            }
        }
    }
    private func share(_ v: Double, _ label: String, strong: Bool) -> some View {
        HStack(spacing: 10) {
            Text(v < 0.01 && v > 0 ? "<1%" : "\(Int((v * 100).rounded()))%").font(.system(size: strong ? 28 : 20, weight: strong ? .semibold : .regular)).monospacedDigit().foregroundStyle(.white)
                .frame(width: 70, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white.opacity(strong ? 1 : 0.55)).frame(width: max(4, g.size.width * min(1, v / 0.5)))
                }
            }
            .frame(height: strong ? 8 : 6)
            Text(label).font(.subheadline).foregroundStyle(.white.opacity(0.85)).fixedSize()
        }
    }
}

// A panorama of artists: big covers in a row that runs off the edge, each with its rank in huge thin type.
struct WeekHub: View {
    let title: String
    let list: [ArtistCount]
    var body: some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: title).padding(.horizontal, S.margin)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { k, a in tile(k, a) }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, S.margin)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
    private func tile(_ k: Int, _ a: ArtistCount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                ArtView(ArtRef(artist: a.name, album: a.album, url: a.image), px: 400, corner: 10).frame(width: 136)
                if title != "new to you" {
                    Text("\(k + 1)").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 8)
                        .offset(x: -2, y: 18)
                }
                if a.isNew && title != "new to you" {
                    Text("new").font(.caption.weight(.bold)).foregroundStyle(.black).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.white)).offset(x: 88, y: -104)
                }
            }
            .padding(.bottom, title == "new to you" ? 0 : 12)
            Text(a.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            Text("\(a.plays) \(a.plays == 1 ? "play" : "plays")").font(.footnote).monospacedDigit().foregroundStyle(S.soft)
        }
        .frame(width: 136, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// His years: plays in each, as bars. While the history is being read this is where it shows, the bars growing from the
// newest year back as the pages come in, with how much is left; once it's all read it stays as his years.
struct YearsSection: View {
    private var sync: HistorySync { HistorySync.shared }
    private var store: Store { Store.shared }
    var body: some View {
        let years = sync.years.keys.sorted()
        let first = store.profile.map { Calendar.current.component(.year, from: $0.registered) } ?? years.first ?? Calendar.current.component(.year, from: Clock.now)
        let last = Calendar.current.component(.year, from: Clock.now)
        let all = Array(min(first, years.first ?? first)...last)
        let peak = max(sync.years.values.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: S.head) {
            SectionHead(text: sync.complete ? "your years" : "reading your history",
                        trailing: sync.complete ? nil : "\(Int((sync.fraction * 100).rounded(.down)))%")
            VStack(alignment: .leading, spacing: 14) {
                if !sync.complete {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(number(sync.read)).font(.system(size: 34, weight: .light)).monospacedDigit().foregroundStyle(.white).contentTransition(.numericText())
                        Text(sync.total > 0 ? "of \(number(sync.total)) scrobbles, newest first" : "scrobbles").font(.subheadline).foregroundStyle(S.soft)
                    }
                    .animation(.snappy, value: sync.read)
                    if let since = sync.stuckSince, Date().timeIntervalSince(since) > 25 {
                        Text("Waiting for Last.fm to answer. It carries on by itself.").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                }
                GeometryReader { g in
                    let gap: CGFloat = 6
                    let w = (g.size.width - gap * CGFloat(all.count - 1)) / CGFloat(max(all.count, 1))
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(all, id: \.self) { y in
                            let v = sync.years[y] ?? 0
                            VStack(spacing: 6) {
                                Text(v > 0 ? compact(v) : "").font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(S.soft).lineLimit(1).minimumScaleFactor(0.6)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(LinearGradient(colors: [S.accent, S.accent.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                                    .frame(width: w, height: max(3, (g.size.height - 40) * CGFloat(v) / CGFloat(peak)))
                                    .opacity(v == 0 ? 0.25 : 1)
                                Text("’" + String(String(y).suffix(2))).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(S.soft)
                            }
                            .frame(width: w)
                        }
                    }
                    .frame(height: g.size.height, alignment: .bottom)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: sync.read)
                }
                .frame(height: 170)
            }
            .card()
        }
        .padding(.horizontal, S.margin)
        .accessibilityElement(children: .combine)
    }
}
