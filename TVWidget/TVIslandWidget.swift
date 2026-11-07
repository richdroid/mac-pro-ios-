#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

private func glyph(_ app: String) -> String {
    switch app {
    case "Stremio": return "film.fill"
    case "YouTube": return "play.rectangle.fill"
    default: return "music.note"
    }
}
// The cover of what's on, carried in the activity: the poster, the video's thumbnail or the album. The glyph only until
// the cover is there.
private struct Cover: View {
    let state: TVIslandAttributes.ContentState
    var radius: CGFloat
    var height: CGFloat
    var body: some View {
        if let d = state.art, let i = UIImage(data: d) {
            Image(uiImage: i).resizable().aspectRatio(contentMode: .fill)
                .frame(width: height * min(max(i.size.width / max(i.size.height, 1), 0.66), 1.78), height: height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            Image(systemName: glyph(state.app)).font(.system(size: height * 0.5)).foregroundStyle(TVLook.accent)
                .frame(width: height * 0.8, height: height)
        }
    }
}
private struct IslandButton: View {
    let playing: Bool
    var body: some View {
        Button(intent: TVIslandPlayPause()) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 46, height: 46).background(.white.opacity(0.18), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel(playing ? "Pause the TV" : "Play the TV")
    }
}
// Out of date, only the title is still worth showing: whether it's playing, and which episode, may have changed.
private struct IslandText: View {
    let state: TVIslandAttributes.ContentState
    var stale = false
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.title).font(.headline).lineLimit(1)
            // The episode (or the artist), never the app doing the playing: that's plumbing.
            if !stale, !state.subtitle.isEmpty, state.subtitle != state.title, state.subtitle != state.app {
                Text(state.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
        }
    }
}
// How far in, running on its own while it plays; held still when paused; nothing when the TV doesn't say.
private struct IslandBar: View {
    let state: TVIslandAttributes.ContentState
    var body: some View {
        Group {
            if state.playing, let a = state.start, let b = state.end, b > a {
                ProgressView(timerInterval: a...b, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else if let p = state.progress {
                ProgressView(value: min(max(p, 0), 1))
            }
        }
        .progressViewStyle(.linear).tint(TVLook.accent).labelsHidden()
    }
}
private struct IslandCard: View {
    let state: TVIslandAttributes.ContentState
    let stale: Bool
    var cover: CGFloat = 56
    var body: some View {
        HStack(spacing: 12) {
            Cover(state: state, radius: 12, height: cover)
            VStack(alignment: .leading, spacing: 6) {
                IslandText(state: state, stale: stale)
                if !stale { IslandBar(state: state) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).opacity(stale ? 0.55 : 1)
            if !stale { IslandButton(playing: state.playing) }
        }
    }
}
// The Live Activity's views drawn as they'd show, for the build's gallery: the simulator never put up the island itself
// (r18: a blank shot). The Lock Screen card, the island opened, and its compact and minimal forms, playing and paused.
struct TVIslandGallery: View {
    let playing: TVIslandAttributes.ContentState
    let paused: TVIslandAttributes.ContentState
    var body: some View {
        VStack(spacing: 18) {
            ForEach([playing, paused], id: \.self) { st in
                IslandCard(state: st, stale: false, cover: 64).padding(14).foregroundStyle(.white)
                    .background(Color(hex: 0x14181C), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                IslandCard(state: st, stale: false).padding(.horizontal, 18).padding(.vertical, 16).foregroundStyle(.white)
                    .background(.black, in: RoundedRectangle(cornerRadius: 42, style: .continuous))
            }
            HStack(spacing: 16) {
                // Compact: the cover leading, the play state trailing, either side of the camera.
                HStack {
                    Cover(state: playing, radius: 8, height: 24)
                    Spacer(minLength: 90)
                    Image(systemName: playing.playing ? "pause.fill" : "play.fill").foregroundStyle(.white)
                }
                .padding(.horizontal, 10).frame(height: 36).background(.black, in: Capsule())
                // Minimal.
                Cover(state: playing, radius: 8, height: 22).padding(7).background(.black, in: Circle())
            }
        }
        .padding(16)
    }
}
struct TVIslandWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TVIslandAttributes.self) { context in
            IslandCard(state: context.state, stale: context.isStale, cover: 64)
                .padding(14)
                .foregroundStyle(.white)
                .activityBackgroundTint(Color(hex: 0x14181C))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    IslandCard(state: context.state, stale: context.isStale).padding(.horizontal, 4)
                }
            } compactLeading: {
                Cover(state: context.state, radius: 8, height: 24)
            } compactTrailing: {
                // A play state that may be out of date isn't shown.
                if !context.isStale { Image(systemName: context.state.playing ? "pause.fill" : "play.fill").foregroundStyle(.white) }
            } minimal: {
                Cover(state: context.state, radius: 8, height: 22)
            }
            .widgetURL(URL(string: "tvremoteapp://tab/2"))
        }
    }
}
#endif
