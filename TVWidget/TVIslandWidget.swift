#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private func glyph(_ app: String) -> String {
    switch app {
    case "Stremio": return "film.fill"
    case "YouTube": return "play.rectangle.fill"
    default: return "music.note"
    }
}
private struct IslandButton: View {
    let playing: Bool
    var body: some View {
        Button(intent: TVIslandPlayPause()) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .semibold))
                .frame(width: 46, height: 46).background(.white.opacity(0.18), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel(playing ? "Pause the TV" : "Play the TV")
    }
}
private struct IslandText: View {
    let state: TVIslandAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.title).font(.headline).lineLimit(1)
            Text(state.subtitle == state.title ? state.app : state.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
    }
}
struct TVIslandWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TVIslandAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: glyph(context.state.app)).font(.title2).foregroundStyle(TVLook.accent)
                IslandText(state: context.state).frame(maxWidth: .infinity, alignment: .leading)
                IslandButton(playing: context.state.playing)
            }
            .padding(14)
            .foregroundStyle(.white)
            .activityBackgroundTint(Color(hex: 0x14181C))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: glyph(context.state.app)).font(.title2).foregroundStyle(TVLook.accent).padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandText(state: context.state).frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandButton(playing: context.state.playing)
                }
            } compactLeading: {
                Image(systemName: glyph(context.state.app)).foregroundStyle(TVLook.accent)
            } compactTrailing: {
                Image(systemName: context.state.playing ? "pause.fill" : "play.fill").foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.playing ? glyph(context.state.app) : "pause.fill").foregroundStyle(TVLook.accent)
            }
            .widgetURL(URL(string: "tvremoteapp://tab/2"))
        }
    }
}
#endif
