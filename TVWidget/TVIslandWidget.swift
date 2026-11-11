#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// The TV's Now Playing card: in the Dynamic Island (compact, minimal, opened) and on the Lock Screen. Laid out the way
// iOS's own Now Playing is, so it reads as part of the phone (Richard, 2026-11-10: "dynamic island is not fixed its ugly
// as is"): the cover, the name over its line, a bar with its times, and the three keys a player has. Every size is
// fixed, so nothing grows past the 160 pt the system gives a card and gets cut.
private func glyph(_ app: String) -> String {
    switch app {
    case "Stremio": return "film.fill"
    case "YouTube": return "play.rectangle.fill"
    default: return "music.note"
    }
}
// With no cover, the tile's glyph is in the colour of what's playing it (never the app's cyan, which is the bar's).
private func glyphTint(_ app: String) -> Color {
    switch app {
    case "Stremio": return Color(hex: 0x9B7BF0)
    case "YouTube": return Color(hex: 0xFF3B4E)
    default: return Color(hex: 0x3EB489)
    }
}
// The cover of what's on, carried in the activity: the poster, the video's still or the album. In its own shape where
// there's room (a poster upright, an album square, a still wide, to 4:3 at most); cut square for the small island.
// Corners as the system's own covers have them, small, so it reads as a cover and never as an app's icon. With none,
// the kind of thing on a quiet tile, the size a cover would be, never a loose glyph.
struct IslandCover: View {
    let state: TVIslandAttributes.ContentState
    var height: CGFloat
    var square = false
    var body: some View {
        let radius: CGFloat = height >= 40 ? 6 : 5
        if let d = state.art, let i = UIImage(data: d) {
            let shape = i.size.width / max(i.size.height, 1)
            Image(uiImage: i).resizable().aspectRatio(contentMode: .fill)
                .frame(width: height * (square ? 1 : min(max(shape, 0.66), 1.33)), height: height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                .accessibilityHidden(true)
        } else {
            Image(systemName: glyph(state.app)).font(.system(size: height * 0.42, weight: .semibold)).foregroundStyle(glyphTint(state.app))
                .frame(width: height * (square || state.app == "Mint" ? 1 : 0.72), height: height)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
// The name, and under it the episode, the channel or the artist: never the app doing the playing, which is plumbing.
// A film has no second line, so its name may take two.
struct IslandTitles: View {
    let state: TVIslandAttributes.ContentState
    var under: Bool { !state.subtitle.isEmpty && state.subtitle != state.title && state.subtitle != state.app }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title).font(.system(size: under ? 16 : 15, weight: .semibold)).foregroundStyle(.white).lineLimit(under ? 1 : 2)
                .multilineTextAlignment(.leading)
            if under { Text(state.subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.62)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
// Whether the TV has said how long it runs and where it is: only then is there a bar, and times beside it. Without
// (some episodes come with no running time), no empty track standing in for one.
extension TVIslandAttributes.ContentState {
    var timed: Bool { (length ?? 0) > 0 && (progress != nil || start != nil) }
}
// How far in, running on its own while it plays; held still when paused. On its own track, which the system's is too
// faint to show on the island's black.
struct IslandBar: View {
    let state: TVIslandAttributes.ContentState
    var body: some View {
        Group {
            if state.playing, let a = state.start, let b = state.end, b > a {
                ProgressView(timerInterval: a...b, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: min(max(state.progress ?? 0, 0), 1))
            }
        }
        .progressViewStyle(.linear).tint(TVLook.accent).labelsHidden()
        .background { Capsule().fill(.white.opacity(0.2)).frame(height: 4) }
    }
}
// The time it's at, or the time left, counting by itself while it plays, held where it stopped when paused. A fixed
// width: a running time takes all the room it's offered, and the bar beside it would have none.
struct IslandTime: View {
    let state: TVIslandAttributes.ContentState
    var left = false
    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    var body: some View {
        let long = (state.length ?? 0) >= 3600
        Group {
            if state.playing, let a = state.start, let b = state.end, b > a {
                // Past its end (the TV has moved on and the card hasn't heard), it holds at the end.
                // One text, its minus joined to it: side by side, the running time took the width and stood apart from
                // its minus ("-  24:02" on the simulator's own Lock Screen).
                (left ? Text("-") + Text(timerInterval: a...b, countsDown: true) : Text(timerInterval: a...b, countsDown: false))
                    .multilineTextAlignment(left ? .trailing : .leading)
            } else if let p = state.progress, let len = state.length, len > 0 {
                Text((left ? "-" : "") + Self.clock(left ? len * (1 - p) : len * p))
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
        .frame(width: (long ? 54 : 38) + (left ? 8 : 0), alignment: left ? .trailing : .leading)
    }
}
// Play or pause, saying what a press will do, as every player's does: a bare white glyph, as the system's card has, in
// the island and on the Lock Screen alike. Never a filled disc.
struct IslandPlay: View {
    let playing: Bool
    var size: CGFloat = 24
    var body: some View {
        Button(intent: TVIslandPlayPause()) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(playing ? "Pause the TV" : "Play the TV")
    }
}
// Ten seconds back or on for a film or a show (Stremio's player takes exact jumps); back and on for a video, by as
// much as the TV's own rewind and forward keys move it; the song before or after for Mint. Each glyph says which.
struct IslandSkip: View {
    let app: String
    let forward: Bool
    var size: CGFloat = 20
    // In a row of three the keys stand apart; at the ends of the island's bar they hug it, level with the cover.
    var wide = false
    var body: some View {
        let icon = app == "Mint" ? (forward ? "forward.end.fill" : "backward.end.fill")
            : app == "YouTube" ? (forward ? "forward.fill" : "backward.fill") : (forward ? "goforward.10" : "gobackward.10")
        let label = app == "Mint" ? (forward ? "Next song" : "Previous song")
            : app == "YouTube" ? (forward ? "Forward" : "Back") : (forward ? "Forward 10 seconds" : "Back 10 seconds")
        Button(intent: TVIslandSkip(forward: forward)) {
            Image(systemName: icon).font(.system(size: app == "Stremio" ? size : size - 4, weight: .medium)).foregroundStyle(.white)
                .frame(width: wide ? 44 : 32, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}
// The three keys in a row, where there's no bar for two of them to stand at the ends of, and on the Lock Screen.
struct IslandKeys: View {
    let state: TVIslandAttributes.ContentState
    var play: CGFloat = 24
    var body: some View {
        HStack(spacing: 34) {
            IslandSkip(app: state.app, forward: false, size: 22, wide: true)
            IslandPlay(playing: state.playing, size: play)
            IslandSkip(app: state.app, forward: true, size: 22, wide: true)
        }
        .frame(height: 40)
    }
}

// The island opened. Beside the camera: the TV's mark (the phone's own Now Playing sits in the same place), and the
// time left, counting while it plays and held while paused. Under it: the cover, the names and ⏯, then the bar between
// its two keys; with no running time known, no bar, and the three keys in a row. Out of date (the app closed a while
// and nothing heard since), it says what it last knew, dimmed, with no play state, no bar and no keys: a pause made
// with the TV's own remote is exactly what it can't have seen.
struct IslandOpenLeading: View {
    var body: some View {
        Image(systemName: "tv").font(.system(size: 13, weight: .semibold)).foregroundStyle(TVLook.accent)
            .padding(.leading, 6).accessibilityLabel("On the TV")
    }
}
struct IslandOpenTrailing: View {
    let state: TVIslandAttributes.ContentState
    let stale: Bool
    var body: some View {
        Group {
            if !stale, state.timed { IslandTime(state: state, left: true) }
        }
        .padding(.trailing, 6)
    }
}
struct IslandOpenBottom: View {
    let state: TVIslandAttributes.ContentState
    let stale: Bool
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                IslandCover(state: state, height: 48)
                IslandTitles(state: state)
                if !stale, state.timed { IslandPlay(playing: state.playing).padding(.trailing, -10) }
            }
            .opacity(stale ? 0.55 : 1)
            if !stale {
                if state.timed {
                    HStack(spacing: 6) {
                        IslandSkip(app: state.app, forward: false)
                        IslandBar(state: state)
                        IslandSkip(app: state.app, forward: true)
                    }
                    .frame(height: 32)
                    // The keys' glyphs, not their touch areas, line up with the cover and ⏯ above.
                    .padding(.horizontal, -4)
                } else {
                    IslandKeys(state: state).frame(height: 32)
                }
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 2)
    }
}
// The Lock Screen's card, in iOS's own order: the cover and the names, the bar with the time it's at and the time left
// (when the TV says them), the three keys.
struct IslandLockCard: View {
    let state: TVIslandAttributes.ContentState
    let stale: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                IslandCover(state: state, height: 48)
                IslandTitles(state: state).frame(minHeight: 48)
                // Whose it is: the TV's. Small and at the title's top, a mark and not a key.
                Image(systemName: "tv").font(.system(size: 13, weight: .semibold)).foregroundStyle(TVLook.accent).padding(.top, 5).accessibilityLabel("On the TV")
            }
            if !stale {
                if state.timed {
                    HStack(spacing: 8) {
                        IslandTime(state: state)
                        IslandBar(state: state)
                        IslandTime(state: state, left: true)
                    }
                    .frame(height: 14)
                }
                IslandKeys(state: state, play: 28)
            }
        }
        .opacity(stale ? 0.55 : 1)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, stale ? 14 : 8)
    }
}
// The small island, either side of the camera: the cover, and what it's doing. Playing, the time left, counting down
// by itself; paused, the pause mark. Never a key's glyph: nothing here can be pressed, and "⏸" while it played read as
// paused. Out of date, the cover alone.
struct IslandCompactTrailing: View {
    let state: TVIslandAttributes.ContentState
    let stale: Bool
    var body: some View {
        if stale { EmptyView() }
        else if !state.playing { Image(systemName: "pause.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).accessibilityLabel("Paused") }
        else if let a = state.start, let b = state.end, b > a {
            Text(timerInterval: a...b, countsDown: true).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(TVLook.accent)
                .multilineTextAlignment(.trailing).lineLimit(1).frame(width: (state.length ?? 0) >= 3600 ? 56 : 40, alignment: .trailing)
        } else {
            Image(systemName: "waveform").font(.system(size: 14, weight: .semibold)).foregroundStyle(TVLook.accent).accessibilityLabel("Playing")
        }
    }
}

struct TVIslandWidget: Widget {
    static let opens = URL(string: "tvremoteapp://tab/2")
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TVIslandAttributes.self) { context in
            IslandLockCard(state: context.state, stale: context.isStale)
                // The system's own dark glass, the wallpaper soft through it, as its Now Playing card has.
                .activityBackgroundTint(Color.black.opacity(0.45))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.opens)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { IslandOpenLeading() }
                DynamicIslandExpandedRegion(.trailing) { IslandOpenTrailing(state: context.state, stale: context.isStale) }
                DynamicIslandExpandedRegion(.bottom) { IslandOpenBottom(state: context.state, stale: context.isStale) }
            } compactLeading: {
                IslandCover(state: context.state, height: 24, square: true)
            } compactTrailing: {
                IslandCompactTrailing(state: context.state, stale: context.isStale)
            } minimal: {
                IslandCover(state: context.state, height: 22, square: true)
            }
            .widgetURL(Self.opens)
        }
    }
}

// The Live Activity's views drawn as they'd show, for the build's gallery: the same views the widget uses, each in a
// frame the size and shape iOS gives it (the opened island 160 pt at most with the camera's row kept clear, the Lock
// Screen card on a wallpaper), so what's judged in the build's shots is what's on the phone.
struct TVIslandGallery: View {
    let states: [(name: String, state: TVIslandAttributes.ContentState, stale: Bool)]
    // "open": the island opened and its small forms; "lock": the Lock Screen's card.
    let lock: Bool
    func opened(_ st: TVIslandAttributes.ContentState, _ stale: Bool) -> some View {
        VStack(spacing: 0) {
            // The camera's row: 37 pt, the camera itself in the middle of it.
            HStack {
                IslandOpenLeading()
                Spacer()
                Capsule().fill(Color(white: 0.09)).frame(width: 118, height: 33)
                Spacer()
                IslandOpenTrailing(state: st, stale: stale)
            }
            .frame(height: 37)
            IslandOpenBottom(state: st, stale: stale).padding(.top, 8)
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 14)
        .frame(width: 366)
        .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
    }
    func compact(_ st: TVIslandAttributes.ContentState, _ stale: Bool) -> some View {
        HStack(spacing: 0) {
            IslandCover(state: st, height: 24, square: true)
            Spacer(minLength: 0)
            IslandCompactTrailing(state: st, stale: stale)
        }
        .padding(.horizontal, 9).frame(width: 236, height: 37).background(.black, in: Capsule())
    }
    var body: some View {
        VStack(spacing: 12) {
            ForEach(states, id: \.name) { s in
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.name).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    if lock {
                        IslandLockCard(state: s.state, stale: s.stale).frame(width: 366)
                            .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .environment(\.colorScheme, .dark)
                    } else {
                        opened(s.state, s.stale)
                        HStack(spacing: 14) {
                            compact(s.state, s.stale)
                            IslandCover(state: s.state, height: 22, square: true).frame(width: 37, height: 37).background(.black, in: Circle())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 16).padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
