import SwiftUI

// The lip (brief 3.2, Richard 2026-11-20): the TV, as a strip of glass along the top of every tab and every page opened
// from one, in every posture. It says what the TV is doing now in his words, it is where a thrown card goes, and it has
// the TV's play key, so pause is one tap from anywhere. Everything it says is read from the one model every tab reads, so
// no two places can disagree about what is on.

// What the TV is doing, worked out once, for the lip, the Remote's heading and the Music tab's line.
struct TVNow: Equatable {
    enum Kind: Equatable { case starting, video, music, home, asleep, away, unknown }
    var kind: Kind
    var title: String
    var line: String?
    var art: String?
    // Whether it plays, when there is something to play or pause.
    var playing: Bool?

    @MainActor static func read(_ model: TVModel) -> TVNow {
        if let st = model.starting, !st.played {
            if st.failed { return TVNow(kind: .starting, title: st.title, line: st.note ?? "Didn’t start", art: st.art, playing: nil) }
            return TVNow(kind: .starting, title: st.title, line: st.note ?? startLine(st, model), art: st.art, playing: nil)
        }
        // The player has answered and the TV hasn't said so yet: still starting, never "Home" for a moment in between
        // (gate on b97a5e7).
        if let st = model.starting, st.played, !st.failed, !(model.videoIsCurrent && !(model.status?.session?.showName.isEmpty ?? true)), !model.musicIsCurrent {
            return TVNow(kind: .starting, title: st.title, line: "Starting…", art: st.art, playing: nil)
        }
        guard let s = model.status else { return TVNow(kind: .unknown, title: "TV", line: nil, art: nil, playing: nil) }
        // What the phone last knew stands until a reading says otherwise: never "Connecting…" over a known state (9.7).
        // Its play key waits for a fresh reading, as the Remote's does, so the two never disagree (gate 3, folded rfilm).
        // The Mac answers and the TV doesn't: said here as the Remote's picture says it, not the app last in front.
        if !model.staleStatus, !s.online { return TVNow(kind: .away, title: "Can’t reach the TV", line: nil, art: nil, playing: nil) }
        // One black TV, one name and one glyph, whichever way it went black (the box asleep, or the television off over
        // HDMI-CEC): "Asleep", as the Remote and Status say it (TVShared's Away.line; gate on eb040c7: "Off" here).
        if s.screen == "asleep" { return TVNow(kind: .asleep, title: "Asleep", line: nil, art: nil, playing: nil) }
        if !model.staleStatus, let a = s.away {
            if a == .off { return TVNow(kind: .asleep, title: a.line, line: nil, art: nil, playing: nil) }
            return TVNow(kind: .away, title: a.line, line: nil, art: nil, playing: nil)
        }
        if s.comingOn { return TVNow(kind: .home, title: "Waking the TV…", line: nil, art: nil, playing: nil) }
        if model.videoIsCurrent, let p = s.session, !p.showName.isEmpty {
            return TVNow(kind: .video, title: p.showName, line: p.seasonEpisode.map { "S\($0.season) E\($0.episode)" } ?? p.channel,
                         art: model.picture(for: p), playing: model.staleStatus ? nil : p.playing)
        }
        if let m = model.nowMusic, !m.title.isEmpty, model.songPlaying(m) == true || s.app == "com.codex.musicwebtv" {
            return TVNow(kind: .music, title: m.title, line: m.artist, art: m.art, playing: model.songPlaying(m))
        }
        if s.screen == "screensaver" { return TVNow(kind: .home, title: "Screensaver", line: nil, art: nil, playing: nil) }
        let app = s.apps?.first { $0.pkg == s.app }?.name
        return TVNow(kind: .home, title: app ?? "Home", line: nil, art: nil, playing: nil)
    }
    @MainActor static func startLine(_ st: TVModel.Starting, _ model: TVModel) -> String {
        let waited = Date().timeIntervalSince(st.since)
        if model.status?.screen == "asleep" || model.status?.comingOn == true { return "Waking the TV…" }
        if !model.reachable || (st.phase == nil && waited > 2) { return "Reaching the TV…" }
        return "Starting…"
    }
}

struct Lip: View {
    @Environment(TVModel.self) private var model
    @Environment(\.pagePush) private var pagePush
    @Environment(\.paneLayout) private var panes
    // The tab it sits on: only the one showing says where the lip is.
    let tab: Int
    static let height: CGFloat = 56
    @State private var pull: CGFloat = 0
    @State private var place = FrameBox()
    var body: some View {
        let _ = Timing.body("lip")
        let now = TVNow.read(model)
        let landed = Hand.shared.landed
        HStack(spacing: 12) {
            Button { if model.tab != 0 { model.tick(); model.tab = 0 } } label: {
                HStack(spacing: 12) {
                    picture(landed?.art ?? now.art, kind: now.kind)
                    // One set of words at a time, changed in place: crossfaded, "Heat" was drawn over "Home" and
                    // "Starting…" over "…the stream" for 0.2 s (gate on 339958b). While a start is under way its own title
                    // and line (the model's) are the words; the landing only gives the picture.
                    let starting = now.kind == .starting
                    VStack(alignment: .leading, spacing: 1) {
                        Text(starting ? now.title : landed?.title ?? now.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(now.kind == .asleep ? .white.opacity(0.6) : .white)
                        // The Mac out of reach (after its 25 s grace) is said here, in the lip's own line, calmly: never a pill
                        // over the page's title, never cut in (gate on 339958b).
                        if !model.reachable, landed == nil, !starting {
                            Text("Reconnecting…").font(.system(size: 14, weight: .medium)).foregroundStyle(TVLook.away).lineLimit(1)
                                .transition(.opacity)
                        }
                        // On the Remote the episode and the time are under its picture: the lip says only what's on, not twice.
                        else if now.kind == .video, tab == 0, landed == nil { EmptyView() }
                        else if now.kind == .video, landed == nil, let s = model.status?.session { LipClock(session: s, line: now.line) }
                        else if let l = (landed != nil && !starting ? "Starting…" : now.line) {
                            Text(l).font(.system(size: 14, weight: .medium)).foregroundStyle(starting || landed != nil ? TVLook.accent : .white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    .transaction { if starting || landed != nil { $0.animation = nil } }
                    .animation(.easeOut(duration: 0.3), value: model.reachable)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("TV: \(now.title)" + (now.line.map { ", \($0)" } ?? ""))
            .accessibilityHint("Opens the remote")
            // While it says Starting…, pulling down on it calls the start off (brief 3.4).
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { v in
                guard now.kind == .starting else { return }
                pull = max(0, min(28, v.translation.height * 0.5))
            }.onEnded { v in
                if now.kind == .starting, v.translation.height > 36 {
                    Haptic.fire(.tick); HandLog.note("lip pulled: start called off")
                    // As holding the play key does it: the TV told to stop what it was bringing up, then the start dropped.
                    model.post("stop-playing", ["pkg": "com.stremio.one"]); model.clearStart()
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull = 0 }
            })
            trailing(now)
        }
        .padding(.leading, 8).padding(.trailing, 6)
        .frame(height: Self.height)
        .background { LipGlass() }
        .offset(y: pull)
        // On the page's own left edge (20 pt, 34 open flat where the left pane's content starts), not 12 pt in (gate on
        // 4f36e1e).
        .padding(.leading, panes ? 34 : 20).padding(.trailing, 12).padding(.top, 2).padding(.bottom, 6)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
            place.rect = r
            guard model.tab == tab, r.width > 40 else { return }
            Hand.shared.lipFrame = r
        }
        .onChange(of: model.tab, initial: true) { _, t in
            pull = 0
            if t == tab, let r = place.rect, r.width > 40 { Hand.shared.lipFrame = r }
        }
        // A start that failed with no page left to answer it: said for a few seconds, then the lip is the TV's again.
        .task(id: model.starting?.failed == true) {
            guard model.starting?.failed == true, model.tab == tab else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled, model.starting?.failed == true { model.clearStart() }
        }
    }
    @ViewBuilder func picture(_ art: String?, kind: TVNow.Kind) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Group {
            if let a = art, !a.isEmpty, let u = URL(string: a) {
                Art(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: kind == .asleep ? "tv.slash" : "tv").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(kind == .asleep ? 0.5 : 0.85))
                }
            }
        }
        .frame(width: 64, height: 40).clipShape(shape)
    }
    @ViewBuilder func trailing(_ now: TVNow) -> some View {
        // On the Remote the big key in the pad's ring wakes it; the lip's own would be a second way on one screen.
        if now.kind == .asleep {
            if tab != 0 { LipKey(icon: "power", label: "Wake the TV") { if model.status?.away == .off { model.post("tv-on") } else { model.key("wake") } } }
        } else if now.playing != nil {
            let shown = model.shownPlaying(now.playing)
            LipKey(icon: shown == true ? "pause.fill" : "play.fill", label: shown == true ? "Pause" : "Play") { model.togglePlay(shown: shown) }
        }
        LipKey(icon: "gearshape", label: "Settings") { pagePush.push(SettingsRoute.root) }
    }
}

// A key on the lip: 44 pt to the finger, plain on the lip's own glass.
private struct LipKey: View {
    @Environment(TVModel.self) private var model
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button { model.tick(); action() } label: {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}

// "S9 E12 · 4:12": the episode and where the TV is, counted on between readings while it plays. Its own small view, so
// the second's tick redraws these few letters and nothing else.
private struct LipClock: View {
    @Environment(TVModel.self) private var model
    let session: TVStatus.Session
    let line: String?
    var body: some View {
        // The time whole, always: the episode's line gives way first (gate 5, item 11: folded it read "1:…").
        TimelineView(.periodic(from: .now, by: 1)) { t in
            HStack(spacing: 0) {
                if let line, !line.isEmpty { Text(line + (clock(at: t.date) == nil ? "" : " · ")).lineLimit(1).truncationMode(.tail) }
                if let c = clock(at: t.date) { Text(c).lineLimit(1).fixedSize() }
            }
            .font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
        }
    }
    func clock(at date: Date) -> String? {
        guard var ms = session.position else { return nil }
        let running = model.shownPlaying(session.playing) == true && session.playing
        if running, !model.staleStatus, let at = session.sampledAt { ms += max(0, min(120_000, date.timeIntervalSince1970 * 1000 - at)) }
        if let d = session.duration, d > 0 { ms = min(ms, d) }
        let s = Int(max(0, ms) / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// The lip's glass and its glow. The only part of the lip that follows a carried card: it brightens and deepens as the card
// nears, snaps full over the commit line, and takes the colour of what lands. Its own view, so a carry redraws this alone.
private struct LipGlass: View {
    var body: some View {
        let hand = Hand.shared
        let landed = hand.landed
        let glow = max(hand.glow, hand.committed ? 1 : 0)
        let tint = landed?.tint ?? TVLook.accent
        let lit = glow > 0 || landed != nil
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint.opacity(0.10 + 0.30 * Double(glow) + (landed != nil ? 0.25 : 0)))
                .opacity(lit ? 1 : 0)
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.15 + 0.85 * Double(glow)), lineWidth: 1 + 1.5 * glow)
                .opacity(lit ? 1 : 0)
        }
        // The glow is a soft layer behind the glass whose opacity follows the card, never a shadow whose radius changes
        // every frame (a re-drawn shadow the width of the lip held the flight open flat, gate on 339958b).
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint).blur(radius: 16).padding(4).offset(y: 6)
                .opacity(0.55 * Double(glow))
        }
    }
}
