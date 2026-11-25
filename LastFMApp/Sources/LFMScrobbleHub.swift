import SwiftUI
import MediaPlayer

// Scrobbling, as a hub of its own: a pivot of "log" (what the scrobbler is doing and every decision it has made) and
// "settings" (the switch, his Last.fm account, Apple Music's permission, how it works). Plain words, no plumbing: it
// says when it's waiting for Last.fm's secret rather than failing (lastfm.md §27.2).
struct ScrobbleHub: View {
    let start: Int
    @State private var page: Int
    init(start: Int) { self.start = start; _page = State(initialValue: min(max(start, 0), 1)) }
    var body: some View {
        HubPivot(page: $page, panels: [
            Panel(0, "log") { ScrobbleLogPage() },
            Panel(1, "settings") { ScrobbleSettingsPage() },
        ])
    }
}

private struct WaitingNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: S.head) {
            Text("waiting").font(.zune(size: 54, .light)).tracking(-1).foregroundStyle(.white)
            Text("Scrobbling arrives with the next build of Rotation. Until then nothing is sent, and your Last.fm is unchanged.")
                .font(.zune(.body)).foregroundStyle(Z.subtle).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, S.margin)
        .accessibilityElement(children: .combine)
    }
}

struct ScrobbleLogPage: View {
    private var sc: Scrobbler { Scrobbler.shared }
    private var account: LFMAccount { LFMAccount.shared }
    var body: some View {
        VStack(alignment: .leading, spacing: S.section) {
            switch account.state {
            case .noSecret: WaitingNote()
            case .signedOut, .waiting: ConnectBlock()
            case .signedIn:
                BigFigures(items: [
                    (number(sc.todayCount), "scrobbled today"),
                    (number(sc.queue.count), "waiting to send"),
                    (sc.lastCatchUp.map { $0.formatted(date: .omitted, time: .shortened).plainSpaces } ?? "–", "library checked"),
                ]).padding(.horizontal, S.margin)
                if !sc.enabled {
                    Text("Scrobbling is off. Turn it on in settings.").font(.zune(.body)).foregroundStyle(Z.subtle).padding(.horizontal, S.margin)
                }
                if let l = sc.live { LiveSong(l: l).padding(.horizontal, S.margin) }
            }
            // Only what was really sent: never ticks under "waiting" or "connect" (gate 1, item 12).
            if account.signedIn, !sc.log.isEmpty {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "latest")
                    LazyVStack(spacing: 0) { ForEach(sc.log.prefix(150)) { n in LogRow(n: n) } }
                }
                .padding(.horizontal, S.margin)
            }
        }
    }
}

// The song on now as the scrobbler sees it: how far in, and when it will count.
private struct LiveSong: View {
    let l: Scrobbler.Live
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let p = l.progress, need = l.threshold
            VStack(alignment: .leading, spacing: S.pair + 2) {
                Text("listening").font(.zune(.caption, .semibold)).textCase(.uppercase).tracking(1).foregroundStyle(.white.opacity(0.85))
                Text(l.title).font(.zune(.title3, .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(l.artist).font(.zune(.body)).foregroundStyle(Z.subtle).lineLimit(1)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(Z.accent).frame(width: g.size.width * CGFloat(min(1, p / max(need, 1))))
                    }
                }
                .frame(height: 3).padding(.top, 4)
                Text(l.sent ? "Scrobbled" : l.duration <= 30 ? "Too short to scrobble" : "Scrobbles at \(clock(need))")
                    .font(.zune(.subheadline)).monospacedDigit().foregroundStyle(Z.subtle)
            }
        }
    }
    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

private struct LogRow: View {
    let n: ScrobbleNote
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: S.gap) {
            Text(Date(timeIntervalSince1970: n.played).formatted(date: .omitted, time: .shortened).plainSpaces)
                .font(.zune(.subheadline)).monospacedDigit().foregroundStyle(Z.subtle).frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title).font(.zune(.body, .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(n.artist + (n.how == "caught up" ? " · caught up" : "")).font(.zune(.subheadline)).foregroundStyle(Z.subtle).lineLimit(1)
                if let d = n.detail, n.kind != .duplicate { Text(d).font(.zune(.footnote)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
            }
            Spacer(minLength: 0)
            mark
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var mark: some View {
        switch n.kind {
        case .scrobbled: Image(systemName: "checkmark").font(.zune(.subheadline, .semibold)).foregroundStyle(Z.accent).accessibilityLabel("Scrobbled")
        case .nowPlaying: Image(systemName: "waveform").font(.zune(.subheadline)).foregroundStyle(.white.opacity(0.8)).accessibilityLabel("Sent as now playing")
        case .duplicate: Text("already there").font(.zune(.caption, .semibold)).textCase(.uppercase).foregroundStyle(Z.subtle)
        case .tooShort: Text("skipped").font(.zune(.caption, .semibold)).textCase(.uppercase).foregroundStyle(Z.subtle)
        case .ignored, .failed: Text("not taken").font(.zune(.caption, .semibold)).textCase(.uppercase).foregroundStyle(Z.subtle)
        case .queued: Text("waiting").font(.zune(.caption, .semibold)).textCase(.uppercase).foregroundStyle(Z.subtle)
        }
    }
}

// Not connected yet: what it does, and one button.
private struct ConnectBlock: View {
    private var account: LFMAccount { LFMAccount.shared }
    var body: some View {
        VStack(alignment: .leading, spacing: S.inner) {
            Text("connect").font(.zune(size: 54, .light)).tracking(-1).foregroundStyle(.white)
            Text("Rotation can scrobble what you play in Apple Music, as Marvis does: live while it's open, and caught up from your library's play counts when it comes back or refreshes in the background.")
                .font(.zune(.body)).foregroundStyle(Z.subtle).fixedSize(horizontal: false, vertical: true)
            Button { account.connect() } label: {
                Text(account.state == .waiting ? "Finish in Safari, then come back" : "Connect Last.fm")
                    .font(.zune(.body, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(minHeight: 44)
            }
            .buttonStyle(Tilt())
            .glassEffect(.regular.interactive(), in: Capsule())
            if let p = account.problem { Text(p).font(.zune(.subheadline)).foregroundStyle(Z.subtle) }
        }
        .padding(.horizontal, S.margin)
    }
}

struct ScrobbleSettingsPage: View {
    @Bindable private var sc = Scrobbler.shared
    private var account: LFMAccount { LFMAccount.shared }
    var body: some View {
        VStack(alignment: .leading, spacing: S.section) {
            if account.state == .noSecret { WaitingNote() }
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "scrobbler")
                Toggle(isOn: $sc.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scrobble Apple Music").font(.zune(.body, .semibold)).foregroundStyle(.white)
                        Text("Live while open, caught up from your library").font(.zune(.subheadline)).foregroundStyle(Z.subtle)
                    }
                }
                .tint(Z.magenta)
                .disabled(!account.signedIn)
            }
            .padding(.horizontal, S.margin)
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "account")
                row(title: "Last.fm", value: accountLine) {
                    switch account.state {
                    case .signedIn: Button("Disconnect") { account.signOut() }
                    case .signedOut, .waiting: Button("Connect") { account.connect() }
                    case .noSecret: EmptyView()
                    }
                }
                row(title: "Apple Music", value: libraryLine) {
                    if account.signedIn, !libraryOK {
                        if Scrobbler.shared.library == .denied || Scrobbler.shared.library == .restricted {
                            Button("Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                        } else { Button("Allow") { Scrobbler.shared.askLibrary() } }
                    }
                }
            }
            .padding(.horizontal, S.margin)
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "how it works")
                VStack(alignment: .leading, spacing: S.gap) {
                    line("A song counts once it has played half its length or four minutes, whichever comes first, and it is longer than 30 seconds.")
                    line("While Rotation is closed, iOS doesn't let it listen. When it opens again, or refreshes in the background, it reads your library's play counts and scrobbles what played, timed from when each song last played.")
                    line("Songs played outside your library, like radio, can only be scrobbled while Rotation is open.")
                    line("Before sending, it checks what Last.fm already has at that time, so nothing is counted twice if another app scrobbles too.")
                }
            }
            .padding(.horizontal, S.margin)
        }
        .buttonStyle(.plain)
    }
    private var libraryOK: Bool { LastFM.shared.mock ? account.signedIn : Scrobbler.shared.library == .authorized }
    private var accountLine: String {
        switch account.state {
        case .noSecret: return "Waiting for the app's secret"
        case .signedOut: return "Not connected"
        case .waiting: return "Waiting for your approval"
        case .signedIn(let n): return "Connected as \(n)"
        }
    }
    private var libraryLine: String {
        if libraryOK { return "Allowed" }
        switch Scrobbler.shared.library {
        case .denied, .restricted: return "Off in Settings"
        default: return "Not asked yet"
        }
    }
    private func line(_ t: String) -> some View {
        Text(t).font(.zune(.body)).foregroundStyle(Z.subtle).fixedSize(horizontal: false, vertical: true)
    }
    private func row<B: View>(title: String, value: String, @ViewBuilder button: () -> B) -> some View {
        HStack(spacing: S.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.zune(.body, .semibold)).foregroundStyle(.white)
                Text(value).font(.zune(.subheadline)).foregroundStyle(Z.subtle)
            }
            Spacer(minLength: 0)
            button()
                .font(.zune(.subheadline, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(.vertical, 4)
    }
}
