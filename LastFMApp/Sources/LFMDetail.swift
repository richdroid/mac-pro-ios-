import SwiftUI

// A song's own page, grown out of its cover: the cover large on its own colours, then his plays of it and whether he
// loves it, how many people listen, its length, its tags and a few words, and the two ways out (Apple Music, Last.fm).
// Edge to edge; Close is the system's, where the Duo puts it.
struct TrackPage: View {
    let s: Scrobble
    let space: Namespace.ID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var info: TrackInfo?
    @State private var more = false
    @State private var music: URL?
    var body: some View {
        NavigationStack {
            PaneReader { Content(s: s, info: info, more: $more, music: music) }
                .background { Backdrop(ref: s.art, moving: false, dim: 0.1) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .zoomed(s.id, space)
        .task {
            info = await TrackInfo.load(s)
            music = ArtStore.shared.appleMusic(s.art)
        }
    }

    struct Content: View {
        let s: Scrobble
        let info: TrackInfo?
        @Binding var more: Bool
        let music: URL?
        @Environment(\.paneLayout) private var pane
        @Environment(\.openURL) private var openURL
        var body: some View {
            if pane {
                FoldSplit {
                    VStack(alignment: .leading, spacing: 18) { cover; titles }.padding(S.margin).frame(maxHeight: .infinity)
                } right: {
                    ScrollView { facts.padding(S.margin).padding(.top, 24) }.scrollIndicators(.hidden)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) { cover; titles; facts }
                        .padding(S.margin)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        private var cover: some View {
            let tint = ArtStore.shared.palette(s.art)?.vivid.color ?? .clear
            return ArtView(s.art, px: 1000, corner: 14).frame(maxWidth: 420).shadow(color: tint.opacity(0.45), radius: 34, y: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        private var titles: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.title).font(.system(.largeTitle, weight: .bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text(s.artist).font(.title3).foregroundStyle(.white.opacity(0.85))
                if !s.album.isEmpty { Text(s.album).font(.body).foregroundStyle(S.soft) }
                Text(s.nowPlaying ? "Playing now" : s.date.map { "\(dayName($0).capitalizedFirst) at \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8)).padding(.top, 6)
            }
        }
        @ViewBuilder private var facts: some View {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 26) {
                    Figure(value: info?.userPlays.map(number) ?? "–", label: info?.userPlays == 1 ? "your play" : "your plays", size: 40)
                    Figure(value: info?.listeners.map(compact) ?? "–", label: "listeners", size: 40)
                    if let d = info?.duration { Figure(value: String(format: "%d:%02d", d / 60, d % 60), label: "long", size: 40) }
                    Spacer(minLength: 0)
                    if info?.loved ?? s.loved {
                        Image(systemName: "heart.fill").font(.title).foregroundStyle(S.accent).padding(.top, 6).accessibilityLabel("Loved")
                    }
                }
                .redacted(reason: info == nil ? .placeholder : [])
                if let tags = info?.tags, !tags.isEmpty {
                    FlowTags(tags: tags)
                }
                if let words = info?.summary {
                    // More text grows in place.
                    Button { withAnimation(.smooth) { more.toggle() } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(words).font(.body).foregroundStyle(.white.opacity(0.9)).lineLimit(more ? nil : 3).multilineTextAlignment(.leading)
                            Text(more ? "Less" : "More").font(.subheadline.weight(.semibold)).foregroundStyle(S.accent)
                        }
                    }
                    .buttonStyle(.plain)
                }
                VStack(spacing: 10) {
                    if let music {
                        Button { openURL(music) } label: { Label("Open in Apple Music", systemImage: "music.note").frame(maxWidth: .infinity) }
                            .buttonStyle(.glassProminent).tint(S.accent).controlSize(.large)
                    }
                    if let u = (info?.url ?? s.url).flatMap(URL.init(string:)) {
                        Button { openURL(u) } label: { Label("Open on Last.fm", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }
                            .buttonStyle(.glass).controlSize(.large)
                    }
                }
            }
        }
    }
}

struct FlowTags: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { t in
                Text(t).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassEffect(.regular, in: Capsule())
            }
        }
    }
}

// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > w && x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > b.maxX && x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

extension String { var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() } }
