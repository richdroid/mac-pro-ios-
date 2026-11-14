import WidgetKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Rotation's widgets: what's on (or last played), the week's albums as a collage, the streak and his scrobbles, this
// week against his usual, and the artist on top this week. The app's language at widget size: covers lead, numbers are
// the graphics (thin), a warm coral for the streak, near-black ground. Covers stay in full colour on tinted and clear
// Home Screens; only the words and figures take the tint. Every tap opens the page it shows.

enum WS {
    static let ground = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let accent = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let soft = Color.white.opacity(0.7)
}

// A cover, or its stand-in: the album's own colour (stable per name) with a faint record, never a blank.
struct WArt: View {
    let cover: WCover?
    let data: Data?
    var corner: CGFloat = 0
    var body: some View {
        Group {
            #if canImport(UIKit)
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
            } else { stand }
            #else
            stand
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
    private var stand: some View {
        let h = Self.hue((cover?.artist ?? "") + (cover?.album ?? ""))
        return ZStack {
            LinearGradient(colors: [Color(hue: h, saturation: 0.55, brightness: 0.62), Color(hue: (h + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.26)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                Circle().strokeBorder(.white.opacity(0.14), lineWidth: max(1, g.size.width * 0.012))
                    .frame(width: g.size.width * 0.56).position(x: g.size.width / 2, y: g.size.height / 2)
                Circle().fill(.white.opacity(0.12)).frame(width: g.size.width * 0.12).position(x: g.size.width / 2, y: g.size.height / 2)
            }
        }
    }
    static func hue(_ s: String) -> Double {
        var x: UInt64 = 1469598103934665603
        for b in s.utf8 { x = (x ^ UInt64(b)) &* 1099511628211 }
        return Double(x % 360) / 360
    }
}

// One line that never ends in an ellipsis: whole if it fits, else it runs to the edge and fades.
struct WLine: View {
    let text: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(text).lineLimit(1).fixedSize()
            Text(text).lineLimit(1).fixedSize()
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                .clipped()
        }
    }
}

// The status line: "Now playing", "Played 12 min ago", or when Last.fm was last heard from.
struct WStatus: View {
    let entry: LFMEntry
    var body: some View {
        HStack(spacing: 4) {
            if entry.seen == nil {
                Image(systemName: "opticaldisc"); Text("Waiting for Last.fm")
            } else if entry.stale, let s = entry.seen {
                Image(systemName: "clock"); Text(lastSeen(s, now: entry.date))
            } else if entry.playing {
                Image(systemName: "waveform"); Text("Now playing")
            } else {
                Image(systemName: "clock.arrow.circlepath"); Text(playedWhen(entry.songAt, now: entry.date))
            }
        }
        .lineLimit(1)
    }
}

// MARK: Now playing

struct NowBody: View {
    let family: WidgetFamily
    let entry: LFMEntry
    var body: some View {
        let s = entry.song
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 6) {
                WArt(cover: s, data: entry.image(s), corner: 4).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 0) {
                    WStatus(entry: entry).font(.system(size: 11, weight: .semibold)).opacity(0.8)
                    WLine(text: s?.title ?? "–").font(.system(size: 14, weight: .bold)).widgetAccentable()
                    WLine(text: s?.artist ?? "").font(.system(size: 12))
                }
                Spacer(minLength: 0)
            }
        case .systemMedium:
            HStack(spacing: 14) {
                WArt(cover: s, data: entry.image(s), corner: 10).frame(width: 126, height: 126)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    WStatus(entry: entry).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).padding(.bottom, 3)
                    Text(s?.title ?? "–").font(.system(size: 19, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8).widgetAccentable()
                    WLine(text: s?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    if let a = s?.album, !a.isEmpty { WLine(text: a).font(.footnote).foregroundStyle(WS.soft) }
                }
                Spacer(minLength: 0)
            }
        default:
            // Small: the cover is the widget; the words sit on a dark fade at its foot.
            ZStack(alignment: .bottomLeading) {
                WArt(cover: s, data: entry.image(s))
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.78), location: 1)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    WStatus(entry: entry).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(.bottom, 2)
                    WLine(text: s?.title ?? "–").font(.system(size: 15, weight: .bold)).widgetAccentable()
                    WLine(text: s?.artist ?? "").font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(12)
            }
        }
    }
}

// The cover blurred to colour behind a widget, darker toward the foot.
struct WBlur: View {
    let data: Data?
    var body: some View {
        ZStack {
            WS.ground
            #if canImport(UIKit)
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill().blur(radius: 26).scaleEffect(1.3).opacity(0.75)
            }
            #endif
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
    }
}

func songLink(_ e: LFMEntry) -> URL {
    guard let s = e.song, !s.title.isEmpty else { return LinkScheme.now }
    return LinkScheme.track(s.artist, s.title, album: s.album, image: s.url)
}

// MARK: The week's albums

struct CollageBody: View {
    let family: WidgetFamily
    let entry: LFMEntry
    var body: some View {
        switch family {
        case .systemMedium:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("this week").font(.system(size: 17, weight: .bold)).widgetAccentable()
                    Spacer(minLength: 6)
                    if entry.stale, let s = entry.seen { Text(lastSeen(s, now: entry.date)).font(.caption2).foregroundStyle(WS.soft) }
                    else if entry.seen == nil { Text("Waiting for Last.fm").font(.caption2).foregroundStyle(WS.soft) }
                }
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { i in
                        let c = i < entry.week.count ? entry.week[i] : nil
                        Link(destination: c.map { LinkScheme.album($0.artist, $0.album) } ?? LinkScheme.charts("week")) {
                            VStack(alignment: .leading, spacing: 3) {
                                ZStack(alignment: .bottomLeading) {
                                    WArt(cover: c, data: entry.image(c), corner: 6).aspectRatio(1, contentMode: .fit)
                                    Text("\(i + 1)").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.6), radius: 4).offset(x: 1, y: 6).widgetAccentable()
                                }
                                Text(c.map { "\($0.plays)" } ?? "–").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(WS.soft)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
            }
        default:
            // Covers only, edge to edge, a hairline apart: 2 by 2 small, 3 by 3 large.
            let n = family == .systemLarge ? 3 : 2
            GeometryReader { g in
                let cw = (g.size.width - CGFloat(n - 1)) / CGFloat(n), ch = (g.size.height - CGFloat(n - 1)) / CGFloat(n)
                VStack(spacing: 1) {
                    ForEach(0..<n, id: \.self) { r in
                        HStack(spacing: 1) {
                            ForEach(0..<n, id: \.self) { col in
                                let i = r * n + col
                                let c = i < entry.week.count ? entry.week[i] : nil
                                Link(destination: c.map { LinkScheme.album($0.artist, $0.album) } ?? LinkScheme.charts("week")) {
                                    WArt(cover: c, data: entry.image(c)).frame(width: cw, height: ch).clipped()
                                }
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if entry.stale, let s = entry.seen { StaleChip(text: lastSeen(s, now: entry.date)) }
            }
        }
    }
}
struct StaleChip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule()).padding(8)
    }
}

// MARK: Streak and scrobbles

struct Flame: View {
    var body: some View {
        Image(systemName: "flame.fill")
            .foregroundStyle(LinearGradient(colors: [.yellow, .orange, WS.accent], startPoint: .top, endPoint: .bottom))
            .widgetAccentable()
    }
}

struct StreakBody: View {
    let family: WidgetFamily
    let entry: LFMEntry
    var body: some View {
        let n = entry.streak.map { $0.formatted() } ?? "–"
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Image(systemName: "flame.fill").font(.system(size: 13, weight: .semibold))
                    Text(n).font(.system(size: 20, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1).padding(.horizontal, 6)
                }
            }
            .widgetAccentable()
        case .accessoryInline:
            Label(entry.streak.map { "\($0.formatted()) \($0 == 1 ? "day" : "days") in a row" } ?? "Your streak", systemImage: "flame.fill")
        default:
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Flame().font(.system(size: 22))
                    Text(n).font(.system(size: 42, weight: .light)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5).widgetAccentable()
                }
                Text(entry.streak == 1 ? "day in a row" : "days in a row").font(.subheadline).foregroundStyle(WS.soft)
                Spacer(minLength: 4)
                Text(entry.scrobbles.map { $0.formatted() } ?? "–").font(.system(size: 22, weight: .light)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .widgetAccentable()
                if entry.stale, let s = entry.seen {
                    Text(lastSeen(s, now: entry.date)).font(.caption2).foregroundStyle(WS.soft).lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text(entry.today.map { "scrobbles · \($0) today" } ?? "scrobbles").font(.caption).foregroundStyle(WS.soft).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: This week against his usual

struct PaceChart: View {
    let pace: WPace
    var line: Color = WS.accent
    var body: some View {
        Canvas { ctx, size in
            let top = Double(max(pace.hi.max() ?? 1, pace.line.compactMap { $0 }.max() ?? 1, 1))
            func pt(_ d: Int, _ v: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(d) / 6, y: size.height * (1 - CGFloat(Double(v) / top)))
            }
            var band = Path()
            band.move(to: pt(0, pace.lo[0]))
            for d in 1..<7 { band.addLine(to: pt(d, pace.lo[d])) }
            for d in stride(from: 6, through: 0, by: -1) { band.addLine(to: pt(d, pace.hi[d])) }
            band.closeSubpath()
            ctx.fill(band, with: .color(.white.opacity(0.14)))
            var mid = Path()
            mid.move(to: pt(0, pace.mid[0]))
            for d in 1..<7 { mid.addLine(to: pt(d, pace.mid[d])) }
            ctx.stroke(mid, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            let known = pace.line.enumerated().compactMap { d, v in v.map { (d, $0) } }
            if let first = known.first {
                var p = Path()
                p.move(to: pt(first.0, first.1))
                for (d, v) in known.dropFirst() { p.addLine(to: pt(d, v)) }
                ctx.stroke(p, with: .color(line), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                if let last = known.last {
                    let c = pt(last.0, last.1)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(line))
                }
            }
        }
    }
}

struct PaceBody: View {
    let family: WidgetFamily
    let entry: LFMEntry
    var body: some View {
        let p = entry.pace
        let plays = p?.now ?? entry.weekPlays
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("this week").font(.system(size: 12, weight: .semibold))
                    Text(plays.map { $0.formatted() } ?? "–").font(.system(size: 22, weight: .medium)).monospacedDigit().widgetAccentable()
                    if let p { Text(change(p)).font(.system(size: 12, weight: .semibold)).monospacedDigit() }
                }
                if let p { PaceChart(pace: p, line: .white).frame(maxWidth: .infinity) }
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("this week").font(.system(size: 17, weight: .bold)).widgetAccentable()
                    Spacer(minLength: 6)
                    if entry.stale, let s = entry.seen { Text(lastSeen(s, now: entry.date)).font(.caption2).foregroundStyle(WS.soft).lineLimit(1) }
                }
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plays.map { $0.formatted() } ?? "–").font(.system(size: 36, weight: .light)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                            .widgetAccentable()
                        Text("plays so far").font(.caption).foregroundStyle(WS.soft)
                        if let p {
                            HStack(spacing: 3) {
                                Image(systemName: p.delta >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 12, weight: .bold))
                                Text("\(Int((abs(p.delta) * 100).rounded()))%").font(.system(size: 17, weight: .medium)).monospacedDigit()
                            }
                            .padding(.top, 4)
                            Text(p.delta >= 0 ? "more than usual" : "less than usual").font(.caption).foregroundStyle(WS.soft).lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: family == .systemMedium, vertical: false)
                    if family == .systemMedium {
                        if let p { PaceChart(pace: p).frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 4) }
                        else { Spacer(minLength: 0) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
    private func change(_ p: WPace) -> String { "\(p.delta >= 0 ? "+" : "−")\(Int((abs(p.delta) * 100).rounded()))% on usual" }
}

// MARK: Top artist this week

struct ArtistBody: View {
    let family: WidgetFamily
    let entry: LFMEntry
    var body: some View {
        let a = entry.artists.first
        switch family {
        case .systemMedium:
            HStack(spacing: 14) {
                Link(destination: a.map { LinkScheme.artist($0.artist) } ?? LinkScheme.charts("week")) {
                    WArt(cover: a, data: entry.image(a), corner: 10).frame(width: 126, height: 126).shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("top artist this week").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    Text(a?.artist ?? "–").font(.system(size: 20, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7).widgetAccentable()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(a.map { "\($0.plays)" } ?? "–").font(.system(size: 26, weight: .light)).monospacedDigit().widgetAccentable()
                        Text("plays").font(.caption).foregroundStyle(WS.soft)
                    }
                    Spacer(minLength: 2)
                    ForEach(Array(entry.artists.dropFirst().prefix(2).enumerated()), id: \.offset) { i, r in
                        Link(destination: LinkScheme.artist(r.artist)) {
                            HStack(spacing: 6) {
                                Text("\(i + 2)").font(.system(size: 13, weight: .light)).monospacedDigit().foregroundStyle(WS.soft).frame(width: 12, alignment: .leading)
                                WLine(text: r.artist).font(.system(size: 13, weight: .semibold))
                                Text("\(r.plays)").font(.system(size: 12)).monospacedDigit().foregroundStyle(WS.soft)
                            }
                        }
                    }
                    if entry.stale, let s = entry.seen { Text(lastSeen(s, now: entry.date)).font(.caption2).foregroundStyle(WS.soft) }
                }
                Spacer(minLength: 0)
            }
        default:
            ZStack(alignment: .bottomLeading) {
                WArt(cover: a, data: entry.image(a))
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.stale ? entry.seen.map { lastSeen($0, now: entry.date) } ?? "" : "top artist this week").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    WLine(text: a?.artist ?? "–").font(.system(size: 16, weight: .bold)).widgetAccentable()
                    Text(a.map { "\($0.plays) plays" } ?? " ").font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                }
                .padding(12)
            }
        }
    }
}

// MARK: The widgets

struct NowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "now", provider: LFMProvider(kind: "now")) { e in NowView(entry: e) }
            .configurationDisplayName("Now playing")
            .description("What's on, or the last song you played.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
            .contentMarginsDisabled()
    }
}
// The small one is the cover edge to edge; the medium one sits inside its margins.
private struct NowView: View {
    let entry: LFMEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        NowBody(family: family, entry: entry)
            .padding(family == .systemMedium ? 16 : 0)
            .foregroundStyle(.white)
            .containerBackground(for: .widget) { WBlur(data: entry.image(entry.song)) }
            .widgetURL(songLink(entry))
    }
}

struct CollageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "collage", provider: LFMProvider(kind: "collage")) { e in CollageView(entry: e) }
            .configurationDisplayName("This week's albums")
            .description("The albums you've played most in the last seven days.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}
private struct CollageView: View {
    let entry: LFMEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        CollageBody(family: family, entry: entry)
            .padding(family == .systemMedium ? 16 : 0)
            .foregroundStyle(.white)
            .containerBackground(for: .widget) { WS.ground }
            .widgetURL(LinkScheme.charts("week"))
    }
}

struct StreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "streak", provider: LFMProvider(kind: "streak")) { e in StreakView(entry: e) }
            .configurationDisplayName("Streak")
            .description("Days in a row with music, and your scrobbles.")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}
private struct StreakView: View {
    let entry: LFMEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        StreakBody(family: family, entry: entry)
            .foregroundStyle(.white)
            .containerBackground(for: .widget) { StreakGround() }
            .widgetURL(LinkScheme.you)
    }
}
struct StreakGround: View {
    var body: some View {
        ZStack {
            WS.ground
            RadialGradient(colors: [WS.accent.opacity(0.32), .clear], center: .topLeading, startRadius: 0, endRadius: 150)
        }
    }
}

struct PaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "week", provider: LFMProvider(kind: "week")) { e in PaceView(entry: e) }
            .configurationDisplayName("This week")
            .description("Your plays this week against your usual week.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
private struct PaceView: View {
    let entry: LFMEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        PaceBody(family: family, entry: entry)
            .foregroundStyle(.white)
            .containerBackground(for: .widget) { StreakGround() }
            .widgetURL(LinkScheme.you)
    }
}

struct ArtistWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "artist", provider: LFMProvider(kind: "artist")) { e in ArtistView(entry: e) }
            .configurationDisplayName("Top artist")
            .description("Who you've played most this week.")
            .supportedFamilies([.systemSmall, .systemMedium])
            .contentMarginsDisabled()
    }
}
private struct ArtistView: View {
    let entry: LFMEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        ArtistBody(family: family, entry: entry)
            .padding(family == .systemMedium ? 16 : 0)
            .foregroundStyle(.white)
            .containerBackground(for: .widget) { WBlur(data: entry.image(entry.artists.first)) }
            .widgetURL(entry.artists.first.map { LinkScheme.artist($0.artist) } ?? LinkScheme.charts("week"))
    }
}

#if !GALLERY
@main
struct RotationWidgets: WidgetBundle {
    var body: some Widget {
        NowWidget()
        CollageWidget()
        StreakWidget()
        PaceWidget()
        ArtistWidget()
    }
}
#endif
