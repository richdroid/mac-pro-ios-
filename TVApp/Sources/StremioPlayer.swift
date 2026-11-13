import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

// The film or episode playing on this phone: what it is, where it's got to, and everything the player's keys do. Its
// place is written back to his Stremio library as it plays, so the TV's Stremio picks up where the phone left off, and
// the phone where the TV did.

struct PhoneTitle: Equatable {
    var type: String          // movie or series
    var imdb: String          // the title's id
    var video: String         // the film's id again, or the episode's "tt…:s:e"
    var name: String
    var line: String          // "S2 E4 · The Name", or the year
    var poster: String
    var background: String
    var item: MediaItem {
        if type == "series" {
            let v = video.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? video
            return MediaItem(title: name, subtitle: line, art: poster, id: "stremio:///detail/series/\(imdb)/\(v)", kind: "series")
        }
        return MediaItem(title: name, subtitle: line, art: poster, id: imdb, kind: "movie")
    }
}

enum PlayerPanel: String, Identifiable { case audio, subtitles, speed; var id: String { rawValue } }

#if os(iOS)
@MainActor @Observable
final class PhoneSession {
    static var current: PhoneSession?
    let title: PhoneTitle
    private(set) var stream: PhoneStream
    let others: [PhoneStream]
    var position: Double = 0
    var duration: Double = 0
    var playing = false
    var buffering = true
    var failed: String?
    var ended = false
    var rate: Float = 1
    var fill = false
    var locked = false
    var pipActive = false
    var controls = true
    var panel: PlayerPanel?
    var audio: [PhoneTrack] = []
    var subs: [PhoneTrack] = []
    var caption: String?
    var flicking = false
    var flickNote: String?
    // A double tap's jump, shown where it was tapped: -1 back, 1 forward, with how far it's gone.
    var jump: (side: Int, seconds: Int, at: Date)?
    // Scrubbing: where the finger has the bar, not yet sent.
    var scrubbing: Double?
    @ObservationIgnored weak var model: TVModel?
    @ObservationIgnored var engine: PhoneEngine?
    @ObservationIgnored private var library: [String: Any]?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var hideAt = Date().addingTimeInterval(4)
    @ObservationIgnored private var savedAt = Date()
    @ObservationIgnored private var watchedFrom: Double = 0
    // Where it was asked to start, and whether playback has really got there: until then the player's own clock reads
    // 0:00, and writing that would wipe his place everywhere (gate on 916240e, item 1).
    @ObservationIgnored private var askedStart: Double = 0
    @ObservationIgnored private var settled = false
    @ObservationIgnored private var playingTicks = 0
    var place: Double { settled ? position : askedStart }
    @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var art: UIImage?
    @ObservationIgnored var close: @MainActor () -> Void = {}

    init(title: PhoneTitle, stream: PhoneStream, others: [PhoneStream], library: [String: Any]?, model: TVModel?) {
        self.title = title
        self.stream = stream
        self.others = others
        self.library = library
        self.model = model
    }

    func start(at: Double) {
        guard let url = stream.url else { failed = "This stream can only play on the TV."; return }
        Self.current = self
        PhoneLog.note("start \(PhoneEngines.name) at \(Int(at)) \(url.pathExtension)")
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        engine = PhoneEngines.make(url: url, headers: stream.headers, start: at)
        PhoneLog.note("engine made")
        engine?.onPiP = { [weak self] on in self?.pipActive = on; if on { self?.panel = nil } }
        position = at
        askedStart = at
        watchedFrom = at
        savedAt = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        remoteCommands()
        Task { if let u = URL(string: title.poster), let i = await ImageStore.shared.load(u) { self.art = i; self.nowPlaying() } }
        PhoneActivity.began(self)
    }

    private var ticks = 0
    private func tick() {
        guard let e = engine else { return }
        ticks += 1
        if !settled, e.isPlaying { playingTicks += 1 }
        // Got there, or has played 15 s without getting there (a file that can't seek): the player's clock from now on.
        if !settled, e.isPlaying, askedStart < 5 || e.position + 5 >= askedStart || playingTicks > 60 { settled = true }
        if scrubbing == nil, settled { position = e.position }
        if e.duration > 0 { duration = e.duration }
        let p = e.isPlaying
        if p != playing { playing = p; nowPlaying(); PhoneActivity.update(self); PhoneLog.note("playing \(p) at \(Int(position))/\(Int(duration))") }
        buffering = e.isBuffering && failed == nil
        if failed == nil, let err = e.error { failed = err; buffering = false; PhoneLog.note("failed: \(err)") }
        if e.ended, !ended { ended = true; Task { await save() } }
        caption = e.subtitle(at: position)
        e.keepPiPCurrent()
        // Tracks come with the file; asked again now and then, as a second player may take over.
        if ticks % 8 == 1 { audio = e.tracks(audio: true); subs = e.tracks(audio: false) }
        if ticks % 20 == 0 { nowPlaying() }
        if controls, playing || locked, panel == nil, scrubbing == nil, Date() > hideAt { withAnimation(.easeOut(duration: 0.3)) { controls = false } }
        if playing, Date().timeIntervalSince(savedAt) > 30 { Task { await save() } }
    }

    // MARK: Keys

    func poke() { hideAt = Date().addingTimeInterval(4) }
    func toggleControls() {
        withAnimation(.easeOut(duration: 0.2)) { controls.toggle() }
        poke()
    }
    func togglePlay() {
        guard let e = engine else { return }
        if playing { e.pause(); playing = false; Task { await save() } } else { if ended { e.seek(to: 0); ended = false }; e.play(); playing = true }
        poke(); nowPlaying(); PhoneActivity.update(self)
    }
    func skip(_ seconds: Double) {
        guard let e = engine else { return }
        guard settled else { return }
        let to = min(max(0, position + seconds), duration > 0 ? duration - 1 : .greatestFiniteMagnitude)
        e.seek(to: to)
        position = to
        let side = seconds < 0 ? -1 : 1
        if let j = jump, j.side == side, Date().timeIntervalSince(j.at) < 0.9 { jump = (side, j.seconds + Int(abs(seconds)), Date()) }
        else { jump = (side, Int(abs(seconds)), Date()) }
        poke(); nowPlaying()
    }
    func seek(to t: Double) { engine?.seek(to: t); position = t; settled = true; poke(); nowPlaying() }
    func setRate(_ r: Float) { rate = r; engine?.rate = r; nowPlaying() }
    func setFill(_ f: Bool) { fill = f; engine?.fill = f }
    func choose(_ id: String?, audio isAudio: Bool) {
        engine?.select(id, audio: isAudio)
        if let e = engine { audio = e.tracks(audio: true); subs = e.tracks(audio: false) }
        if !isAudio, id == nil { caption = nil }
    }
    func startPiP() {
        guard let pip = engine?.pip else { flickNote = "Picture in Picture isn’t ready yet."; clearNote(); PhoneLog.note("pip: none"); return }
        PhoneLog.note("pip: possible \(pip.isPictureInPicturePossible) active \(pip.isPictureInPictureActive)")
        panel = nil
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }
    var canPiP: Bool { engine?.pip != nil }
    private func clearNote() { Task { try? await Task.sleep(nanoseconds: 2_500_000_000); flickNote = nil } }

    // MARK: Where he is, kept in his library

    func save() async {
        savedAt = Date()
        let at = place, length = duration
        guard at > 0 || length > 0 else { return }
        let watched = settled ? max(0, at - watchedFrom) : 0
        watchedFrom = at
        if library == nil {
            let read = await StremioAPI.libraryRead(title.imdb)
            // Couldn't ask: nothing written this time, rather than a new entry over his real one.
            guard read.ok else { return }
            library = read.item
        }
        let ok = await StremioAPI.putProgress(id: title.imdb, type: title.type, name: title.name, poster: title.poster, video: title.video,
                                              at: at, length: length, watchedFor: watched, existing: library)
        if ok { library = await StremioAPI.libraryItem(title.imdb) ?? library }
        PhoneRecents.note(title, at: at, length: length)
    }

    func finish() {
        guard Self.current === self else { return }
        Self.current = nil
        ticker?.invalidate()
        let e = engine
        Task {
            await save()
            e?.shutdown()
        }
        engine?.pause()
        unregister()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        PhoneActivity.ended()
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        }
    }

    // MARK: To the TV

    // The same stream, at this very moment of it, on the TV: his place saved first, then the TV's own list asked for the
    // same file (the Mac's tokens are its own), and that one started there at this spot, the way a flick starts one.
    func flickToTV() {
        guard !flicking else { return }
        flicking = true
        engine?.pause()
        let at = place
        Task {
            await save()
            // The TV's own pick (its 1080p rule, tv.js), not the 4K file this phone was playing.
            let ok = await PhoneFlick.send(title: title, stream: nil, at: at, model: model)
            flicking = false
            if ok { close() } else { flickNote = "The TV couldn’t take it. Check the Mac’s connection."; clearNote() }
        }
    }

    // MARK: The system's Now Playing and its remote

    func nowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.type == "series" ? (title.line.isEmpty ? title.name : title.line) : title.name,
            MPMediaItemPropertyArtist: title.type == "series" ? title.name : title.line,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }
    private func remoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        func on(_ cmd: MPRemoteCommand, _ act: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            cmd.isEnabled = true
            commands.append((cmd, cmd.addTarget { e in MainActor.assumeIsolated { act(e) }; return .success }))
        }
        on(c.playCommand) { [weak self] _ in if self?.playing == false { self?.togglePlay() } }
        on(c.pauseCommand) { [weak self] _ in if self?.playing == true { self?.togglePlay() } }
        on(c.togglePlayPauseCommand) { [weak self] _ in self?.togglePlay() }
        on(c.skipForwardCommand) { [weak self] _ in self?.skip(10) }
        on(c.skipBackwardCommand) { [weak self] _ in self?.skip(-10) }
        on(c.changePlaybackPositionCommand) { [weak self] e in if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) } }
    }
    private func unregister() {
        for (cmd, target) in commands { cmd.removeTarget(target) }
        commands = []
    }
}

// MARK: The player's screen

struct PhonePlayerView: View {
    @Bindable var s: PhoneSession
    @State private var pictureWidth: CGFloat = 0
    var body: some View {
        GeometryReader { g in
            let crease = Self.crease(g)
            ZStack {
                Color.black.ignoresSafeArea()
                if let crease, crease.width > crease.height {
                    // Open upright, half closed like a laptop: the picture above the fold, the keys below it.
                    VStack(spacing: 0) {
                        picture.frame(height: max(crease.minY, 0))
                        Color.clear.frame(height: crease.height)
                        ZStack {
                            Color.black
                            VStack(spacing: 10) { if !s.locked { topBar }; Spacer(minLength: 0); if s.locked { overlay(g) } else { deck(compact: false) } }
                                .padding(.horizontal, 20).padding(.vertical, 12)
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    picture.ignoresSafeArea()
                    if s.controls && !s.locked { shade.ignoresSafeArea().allowsHitTesting(false).transition(.opacity) }
                    overlay(g)
                }
                if let note = s.flickNote ?? (s.flicking ? "Sending to the TV…" : nil) {
                    Text(note).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .top).padding(.top, 60)
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .statusBarHidden(!s.controls)
        .persistentSystemOverlays(s.controls ? .automatic : .hidden)
        .sheet(item: $s.panel) { p in PlayerPanelView(s: s, panel: p).presentationDetents([.medium, .large]).presentationBackground(.ultraThinMaterial) }
        .onAppear { PhonePose.run(s) }
    }

    // Where the fold is, when the phone is partly closed.
    static func crease(_ g: GeometryProxy) -> CGRect? {
        #if os(iOS)
        if #available(iOS 27.1, *) { return g.reservedRegions(kind: .division).first?.frame }
        #endif
        return nil
    }

    var picture: some View {
        ZStack {
            VideoSurface(s: s)
            if let c = s.caption {
                Text(c).font(.system(size: 19, weight: .semibold)).multilineTextAlignment(.center).foregroundStyle(.white)
                    .shadow(color: .black, radius: 2).shadow(color: .black.opacity(0.8), radius: 6)
                    .padding(.horizontal, 24).frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, s.controls && !s.locked ? 110 : 28)
                    .allowsHitTesting(false)
            }
            if s.buffering && s.failed == nil { ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false) }
            if let f = s.failed { failure(f) }
            jumpMark
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pictureWidth = $0 }
        .gesture(SpatialTapGesture(count: 2).onEnded { v in
            guard !s.locked else { return }
            s.skip(v.location.x < pictureWidth / 2 ? -10 : 10)
        }.exclusively(before: TapGesture().onEnded { s.toggleControls() }))
        .simultaneousGesture(MagnifyGesture().onEnded { v in if !s.locked { s.setFill(v.magnification > 1) } })
    }

    @ViewBuilder var jumpMark: some View {
        if let j = s.jump, Date().timeIntervalSince(j.at) < 0.8 {
            HStack {
                if j.side > 0 { Spacer() }
                VStack(spacing: 4) {
                    Image(systemName: j.side < 0 ? "gobackward" : "goforward").font(.system(size: 30, weight: .semibold))
                    Text("\(j.seconds) s").font(.footnote.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(.white).frame(width: 110, height: 110).background(.white.opacity(0.12), in: Circle())
                .padding(.horizontal, 40)
                if j.side < 0 { Spacer() }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .task(id: j.at) { try? await Task.sleep(nanoseconds: 850_000_000); withAnimation { s.jump = nil } }
        }
    }

    func failure(_ f: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(.yellow)
            Text(f).font(.headline).multilineTextAlignment(.center)
            Text("Pick another stream, or play this one on the TV.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Other streams") { s.close(); PhoneOpen.again(s) }.buttonStyle(.bordered)
                if s.model != nil { Button("Play on TV") { s.flickToTV() }.buttonStyle(.borderedProminent).tint(TVLook.accent).foregroundStyle(.black) }
            }
        }
        .padding(24).frame(maxWidth: 360)
    }

    var shade: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.65), location: 0), .init(color: .clear, location: 0.28),
                               .init(color: .clear, location: 0.62), .init(color: .black.opacity(0.75), location: 1)], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder func overlay(_ g: GeometryProxy) -> some View {
        if s.locked {
            // Locked: no key works but the lock, shown with a tap.
            if s.controls {
                Button { s.locked = false; s.poke() } label: {
                    Label("Unlock", systemImage: "lock.open.fill").font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 40)
            }
        } else if s.controls {
            VStack(spacing: 0) {
                topBar
                Spacer()
                deck(compact: g.size.width < 500)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .transition(.opacity)
        }
    }

    var topBar: some View {
        HStack(spacing: 6) {
            PlayerKey(icon: "xmark", label: "Close") { s.close() }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title.name).font(.headline).lineLimit(1)
                if !s.title.line.isEmpty { Text(s.title.line).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
            PhoneRoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
            if s.canPiP { PlayerKey(icon: s.pipActive ? "pip.exit" : "pip.enter", label: "Picture in Picture") { s.startPiP() } }
            if s.model != nil { PlayerKey(icon: "tv", label: "Play on the TV from here") { s.flickToTV() }.disabled(s.flicking) }
            PlayerKey(icon: "lock", label: "Lock the screen") { s.locked = true; s.panel = nil; s.poke() }
        }
    }

    func deck(compact: Bool) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: compact ? 34 : 54) {
                PlayerKey(icon: "gobackward.10", label: "Back 10 seconds", size: 28) { s.skip(-10) }
                PlayerKey(icon: s.playing ? "pause.fill" : "play.fill", label: s.playing ? "Pause" : "Play", size: 40) { s.togglePlay() }
                PlayerKey(icon: "goforward.10", label: "Forward 10 seconds", size: 28) { s.skip(10) }
            }
            Scrubber(s: s)
            HStack(spacing: 8) {
                PanelKey(icon: "speaker.wave.2", title: s.audio.first { $0.selected }?.name ?? "Audio") { s.panel = .audio }
                PanelKey(icon: "captions.bubble", title: s.subs.first { $0.selected }?.name ?? "Subtitles off") { s.panel = .subtitles }
                PanelKey(icon: "gauge.with.dots.needle.67percent", title: s.rate == 1 ? "Speed" : Self.rateName(s.rate)) { s.panel = .speed }
                Spacer(minLength: 0)
                PlayerKey(icon: s.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: s.fill ? "Fit the picture" : "Fill the screen") { s.setFill(!s.fill) }
            }
        }
        .padding(.bottom, 6)
    }
    static func rateName(_ r: Float) -> String { r == Float(Int(r)) ? "\(Int(r))×" : String(format: "%g×", r) }
}

struct PlayerKey: View {
    let icon: String, label: String
    var size: CGFloat = 19
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .frame(width: max(44, size + 22), height: max(44, size + 22)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}
struct PanelKey: View {
    let icon: String, title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 34).background(.white.opacity(0.14), in: Capsule()).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct Scrubber: View {
    @Bindable var s: PhoneSession
    static func time(_ t: Double) -> String {
        let n = Int(max(0, t.isFinite ? t : 0))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }
    var body: some View {
        let shown = s.scrubbing ?? s.position
        let length = max(s.duration, 1)
        VStack(spacing: 4) {
            GeometryReader { g in
                let x = g.size.width * min(max(shown / length, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: s.scrubbing == nil ? 5 : 9)
                    Capsule().fill(TVLook.accent).frame(width: x, height: s.scrubbing == nil ? 5 : 9)
                    Circle().fill(.white).frame(width: s.scrubbing == nil ? 14 : 22).offset(x: x - (s.scrubbing == nil ? 7 : 11))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .allowsHitTesting(s.duration > 0)
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    s.scrubbing = length * min(max(v.location.x / max(g.size.width, 1), 0), 1)
                    s.poke()
                }.onEnded { _ in
                    if let t = s.scrubbing { s.seek(to: t) }
                    s.scrubbing = nil
                })
                .animation(.easeOut(duration: 0.15), value: s.scrubbing == nil)
            }
            .frame(height: 28)
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(Self.time(shown))
            .accessibilityAdjustableAction { d in s.skip(d == .increment ? 10 : -10) }
            HStack {
                Text(Self.time(shown)).font(.caption.monospacedDigit().weight(.semibold))
                Spacer()
                Text(s.duration > 0 ? "-" + Self.time(s.duration - shown) : "").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

struct PlayerPanelView: View {
    @Bindable var s: PhoneSession
    let panel: PlayerPanel
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    var body: some View {
        NavigationStack {
            List {
                switch panel {
                case .audio:
                    if s.audio.isEmpty { Text("This file has one soundtrack.").foregroundStyle(.secondary) }
                    ForEach(s.audio) { t in row(t.name, on: t.selected) { s.choose(t.id, audio: true) } }
                case .subtitles:
                    row("Off", on: !s.subs.contains { $0.selected }) { s.choose(nil, audio: false) }
                    ForEach(s.subs) { t in row(t.name, on: t.selected) { s.choose(t.id, audio: false) } }
                    if s.subs.isEmpty { Text("This file has no subtitles of its own.").foregroundStyle(.secondary) }
                case .speed:
                    ForEach(Self.rates, id: \.self) { r in row(r == 1 ? "Normal" : PhonePlayerView.rateName(r), on: s.rate == r) { s.setRate(r) } }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(panel == .audio ? "Audio" : panel == .subtitles ? "Subtitles" : "Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { s.panel = nil } } }
        }
    }
    func row(_ title: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button { act(); s.poke(); s.panel = nil } label: {
            HStack { Text(title).foregroundStyle(.primary); Spacer(); if on { Image(systemName: "checkmark").foregroundStyle(TVLook.accent).fontWeight(.semibold) } }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

#if os(iOS)
struct VideoSurface: UIViewRepresentable {
    let s: PhoneSession
    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView(); v.backgroundColor = .black
        if let e = s.engine { v.addSubview(e.view) }
        return v
    }
    func updateUIView(_ v: PlayerHostView, context: Context) {
        if let e = s.engine, e.view.superview !== v { v.subviews.forEach { $0.removeFromSuperview() }; v.addSubview(e.view) }
    }
}
struct PhoneRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView(); v.tintColor = .white; v.activeTintColor = UIColor(TVLook.accent); v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

// The player over everything, the system's way: a full-screen presentation of its own, which Picture in Picture can
// leave and come back to.
final class PhonePlayerController: UIHostingController<PhonePlayerView> {
    let session: PhoneSession
    init(_ s: PhoneSession) {
        session = s
        super.init(rootView: PhonePlayerView(s: s))
        modalPresentationStyle = .fullScreen
        // Dark whatever the phone is set to: its words were drawn black on the black player (CI c970990).
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
}
#endif
#endif
