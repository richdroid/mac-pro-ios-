import SwiftUI
#if os(iOS)
import MediaPlayer
import AVKit
#endif

// Music on the Mac (Richard, 2026-11-25: "with the airplay thing i want it to make the bluetooth connection open apple
// music lyrics on its own … and disconnect when music is done so i can use the speaker with other devices", "controlled
// by phone"; 11-28: "display goes on, lyrics are on, I can control it with my phone in whatever capacity, and then I stop
// the AirPlay and it disconnects from my speaker, display goes off … I can continue on my phone if possible").
// AirPlaying to "Mac Pro" starts it all by itself. This is its card on the Dashboard tab:
//   no session  how it starts (AirPlay to Mac Pro, with the system's own AirPlay button), Lyrics by hand, the speaker
//   a session   where it is (connecting, playing, lyrics up), the song and how far in, for how long it has run;
//               play/pause and skips, the volume, Lyrics and the speaker switches, Continue on iPhone, End
//   just ended  "Disconnected · HK Invoke is free" for a minute
// Play/pause and skips go to the phone's own Music when it is the one AirPlaying that song (the Mac follows it); else
// to Music on the Mac. Bridge: GET /api/mac/music/session (macsession.js, machandoff.js), POST /api/mac/music/{session,
// lyrics,speaker,volume,control,continue}, GET /api/mac/audio (preferred), POST /api/mac/audio/{select,disconnect}.
// An older bridge without the session route: GET /api/mac/music/now, the two switches as before. Hidden without either.

struct MacSession: Decodable, Equatable {
    struct Song: Decodable, Equatable { var title: String?; var artist: String?; var position: Double?; var duration: Double?; var playing: Bool?; var from: String? }
    struct Volume: Decodable, Equatable { var level: Int; var of: String }
    struct Ended: Decodable, Equatable { var why: String?; var speaker: String?; var speakerFree: Bool?; var speakerSay: String?; var continued: Bool?; var ago: Int? }
    var on: Bool
    var phase: String?
    var elapsed: Int?
    var speaker: String?; var speakerConnected: Bool?; var speakerSay: String?; var speakerState: String?
    var music: String?; var lyrics: Bool?; var lyricsOff: Bool?
    var song: Song?
    var volume: Volume?
    var airplay: Bool?; var sender: String?
    var ended: Ended?
    var endsIn: Int?
}
// The older bridge's answer (before 11-28).
struct MacMusicNow: Decodable, Equatable {
    struct Session: Decodable, Equatable { var on: Bool; var speaker: String?; var speakerConnected: Bool?; var speakerSay: String? }
    var state: String?; var title: String?; var artist: String?; var session: Session?
}
struct MacAudioList: Decodable, Equatable {
    struct Output: Decodable, Equatable { let id: String; let name: String; var connected: Bool? }
    var outputs: [Output]; var preferred: String?
}
struct MacContinue: Decodable {
    var ok: Bool?; var say: String?; var mode: String?; var storeId: String?; var title: String?; var position: Double?; var playing: Bool?
}

extension API {
    // A POST whose answer is more than ok/say.
    func macPost<T: Decodable>(_ path: String, _ body: [String: Any], timeout: TimeInterval = 30) async throws -> T? {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue(MacFiles.origin(base), forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, _) = try await session.data(for: r)
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

// The phone's own Music (MediaPlayer's system player): asked once for Apple Music access (NSAppleMusicUsageDescription).
@MainActor
enum PhoneMusic {
    #if os(iOS)
    static var p: MPMusicPlayerController { .systemMusicPlayer }
    static var allowed: Bool { MPMediaLibrary.authorizationStatus() == .authorized }
    static var undecided: Bool { MPMediaLibrary.authorizationStatus() == .notDetermined }
    static func authorize() async -> Bool {
        if allowed { return true }
        guard undecided else { return false }
        return await withCheckedContinuation { c in MPMediaLibrary.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }
    static var title: String? { allowed ? p.nowPlayingItem?.title : nil }
    static func pause() { p.pause() }
    static func playPause() { if p.playbackState == .playing { p.pause() } else { p.play() } }
    static func next() { p.skipToNextItem() }
    static func previous() { if p.currentPlaybackTime > 4 { p.skipToBeginning() } else { p.skipToPreviousItem() } }
    static func load(_ storeID: String) async throws {
        p.setQueue(with: [storeID])
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in p.prepareToPlay { e in if let e { c.resume(throwing: e) } else { c.resume() } } }
    }
    static func play(from t: Double) { if t > 2 { p.currentPlaybackTime = t }; p.play() }
    #else
    static var allowed: Bool { false }
    static var undecided: Bool { false }
    static func authorize() async -> Bool { false }
    static var title: String? { nil }
    static func pause() {}
    static func playPause() {}
    static func next() {}
    static func previous() {}
    static func load(_ storeID: String) async throws {}
    static func play(from t: Double) {}
    #endif
}

@MainActor
final class MacMusicStore: ObservableObject {
    static let shared = MacMusicStore()
    @Published private(set) var s: MacSession?
    @Published private(set) var readAt = Date()
    @Published private(set) var legacy = false
    @Published private(set) var speaker: MacAudioList.Output?
    // Seeded from the last launch, so the section is there when the tab opens, not a moment later.
    @Published private(set) var available = UserDefaults.standard.bool(forKey: "macMusic.available")
    @Published private(set) var busy: String?
    @Published private(set) var say: String?
    // Which control the answer is about: it's said by that control, where he is looking.
    @Published private(set) var sayFor: String?
    @Published private(set) var answered = 0
    @Published private(set) var refused = 0
    // A switch shows what was asked for until the Mac answers; the slider what he set until the Mac has it.
    @Published var asked: [String: Bool] = [:]
    @Published var volumeDraft: Double?
    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "macMusic.speakerID"), let name = d.string(forKey: "macMusic.speakerName") { speaker = .init(id: id, name: name, connected: nil) }
    }
    var on: Bool { s?.on == true }
    var phase: String { s?.phase ?? (on ? "playing" : "idle") }
    /** The card's live state: a session, or one that is ending or just ended. */
    var live: Bool { on || phase == "ending" || phase == "ended" }

    func read(_ model: AppModel) async {
        async let n: MacSession? = try? model.api.macFeed("/api/mac/music/session", timeout: 15)
        async let a: MacAudioList? = try? model.api.macFeed("/api/mac/audio", timeout: 25)
        var got = await n
        var old = false
        if got == nil, let o: MacMusicNow = try? await model.api.macFeed("/api/mac/music/now", timeout: 15), let ss = o.session {
            old = true
            got = MacSession(on: ss.on, phase: ss.on ? (o.state == "playing" ? "lyrics" : "playing") : "idle", speaker: ss.speaker, speakerConnected: ss.speakerConnected, speakerSay: ss.speakerSay,
                             speakerState: ss.speakerConnected == true ? "connected" : "off", song: o.title.map { .init(title: $0, artist: o.artist, playing: o.state == "playing") })
        }
        if busy == nil, let got {   // a press began meanwhile: its own read follows
            available = true
            UserDefaults.standard.set(true, forKey: "macMusic.available")
            if got != s { s = got }
            legacy = old
            readAt = Date()
        }
        let gotAudio = await a
        guard busy == nil, got != nil else { return }
        if let gotAudio {
            let sp = gotAudio.outputs.first { $0.id == gotAudio.preferred }
            if sp != speaker { speaker = sp }
            UserDefaults.standard.set(sp?.id, forKey: "macMusic.speakerID"); UserDefaults.standard.set(sp?.name, forKey: "macMusic.speakerName")
        }
    }
    func loop(_ model: AppModel) async {
        while !Task.isCancelled {
            if busy == nil { await read(model) }
            // Every 2 s while a session runs (the song's place, the phases), every 10 s otherwise.
            let fast = live || phase == "connecting"
            try? await Task.sleep(for: .seconds(fast ? 2 : 10))
        }
    }
    private func act(_ model: AppModel, _ key: String, _ path: String, _ body: [String: Any], want: Bool? = nil) async {
        guard busy == nil else { return }
        busy = key; if let want { asked[key] = want }; say = nil; sayFor = key
        let a = try? await model.api.macDo(path, body, timeout: 45)
        if a?.done == true { answered += 1; say = nil } else { say = a?.say ?? a?.error ?? "Couldn’t reach the Mac."; refused += 1 }
        busy = nil
        await read(model)
        asked = [:]; volumeDraft = nil
        let said = say
        Task { try? await Task.sleep(for: .seconds(5)); if busy == nil, say == said { say = nil } }
    }
    private func tell(_ key: String, _ words: String, ok: Bool) {
        sayFor = key; say = words
        if ok { answered += 1 } else { refused += 1 }
        Task { try? await Task.sleep(for: .seconds(5)); if busy == nil, say == words { say = nil } }
    }

    // MARK: Switches
    func lyrics(_ model: AppModel, _ on: Bool) async {
        // During a session Lyrics only shows or hides them; with none it starts one (the older bridge: always that).
        if self.on && !legacy { await act(model, "lyrics", "/api/mac/music/lyrics", ["on": on], want: on) }
        else { await act(model, "lyrics", "/api/mac/music/session", ["on": on], want: on) }
    }
    func speaker(_ model: AppModel, _ on: Bool) async {
        if !legacy { await act(model, "speaker", "/api/mac/music/speaker", ["on": on], want: on); return }
        guard let sp = speaker else { return }
        if !on, self.on { await act(model, "speaker", "/api/mac/music/session", ["on": false], want: false); return }
        await act(model, "speaker", on ? "/api/mac/audio/select" : "/api/mac/audio/disconnect", ["id": sp.id], want: on)
    }
    func end(_ model: AppModel) async {
        // The phone's own Music AirPlaying this song is paused too: End is the end, not silence streamed to the Mac.
        if phoneHasSong { PhoneMusic.pause() }
        await act(model, "end", "/api/mac/music/session", ["on": false])
    }
    func setVolume(_ model: AppModel, _ v: Double) async { await act(model, "volume", "/api/mac/music/volume", ["level": Int(v.rounded())]) }

    // MARK: Transport
    /** The phone's own Music is playing the song the Mac shows: it is the one AirPlaying, so it's the one to drive. */
    var phoneHasSong: Bool {
        guard let t = s?.song?.title, !t.isEmpty, let item = PhoneMusic.title else { return false }
        return Self.same(item, t)
    }
    static func same(_ a: String, _ b: String) -> Bool {
        let n = { (x: String) in x.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber } }
        return n(a) == n(b) || n(a).hasPrefix(n(b)) || n(b).hasPrefix(n(a))
    }
    func transport(_ model: AppModel, _ cmd: String) async {
        // AirPlay from this phone: its own Music is asked (once) and driven; the Mac follows what the phone does.
        if s?.airplay == true, await PhoneMusic.authorize(), phoneHasSong {
            switch cmd {
            case "next": PhoneMusic.next()
            case "previous": PhoneMusic.previous()
            default: PhoneMusic.playPause()
            }
            answered += 1
            try? await Task.sleep(for: .seconds(1.2)); await read(model); return
        }
        await act(model, cmd, "/api/mac/music/control", ["cmd": cmd])
    }

    // MARK: Continue on iPhone
    // The Mac says which Apple Music song and where; the phone's Music queues it, the Mac stops first (one stream per
    // Apple Music account), then the phone plays from the same place. AirPlaying from this phone already: the song is
    // playing here, so it's only the AirPlay output to bring back (the system's picker), and the Mac ends as AirPlay stops.
    @Published var pickRoute = 0
    func carryOn(_ model: AppModel) async {
        guard busy == nil else { return }
        busy = "continue"; say = nil; sayFor = "continue"
        defer { busy = nil }
        guard await PhoneMusic.authorize() else { tell("continue", "Allow Mac Pro to use Apple Music (Settings › Apps › Mac Pro) to continue here.", ok: false); return }
        let prepAt = Date()
        guard let prep: MacContinue = try? await model.api.macPost("/api/mac/music/continue", ["step": "prepare"], timeout: 30), prep.ok == true else {
            tell("continue", "The Mac couldn’t say what’s playing.", ok: false); return
        }
        if prep.mode == "sender" || phoneHasSong {
            pickRoute += 1
            tell("continue", "Choose iPhone. The Mac lets the speaker go once AirPlay stops.", ok: true); return
        }
        guard let id = prep.storeId else { tell("continue", prep.say ?? "That song isn’t in Apple Music.", ok: false); return }
        do { try await PhoneMusic.load(id) }
        catch { tell("continue", "Music on this iPhone couldn’t load “\(prep.title ?? "the song")”. The Mac plays on.", ok: false); return }
        let stop: MacActionResult? = try? await model.api.macDo("/api/mac/music/continue", ["step": "stop"], timeout: 15)
        let at = (prep.position ?? 0) + (prep.playing == true ? Date().timeIntervalSince(prepAt) : 0)
        PhoneMusic.play(from: at)
        tell("continue", stop?.done == true ? "Playing on your iPhone." : "Playing on your iPhone. The Mac didn’t say it stopped.", ok: true)
        try? await Task.sleep(for: .seconds(1.5)); await read(model)
    }
}

// The system's AirPlay picker: shown as a button where AirPlay starts, and opened for Continue on iPhone.
#if os(iOS)
struct AirPlayPicker: UIViewRepresentable {
    var open: Int = 0
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = UIColor(macBlue); v.activeTintColor = UIColor(macBlue)
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {
        guard open != context.coordinator.opened else { return }
        context.coordinator.opened = open
        if open > 0 { (v.subviews.compactMap { $0 as? UIButton }.first)?.sendActions(for: .touchUpInside) }
    }
    func makeCoordinator() -> Box { Box() }
    final class Box { var opened = 0 }
}
#else
struct AirPlayPicker: View { var open: Int = 0; var body: some View { Image(systemName: "airplay.audio") } }
#endif

struct MacMusicSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = MacMusicStore.shared
    @State private var confirmEnd = false

    private var s: MacSession? { store.s }
    private func refusal(_ key: String) -> String? { store.sayFor == key ? store.say : nil }
    // "HK Invoke_C20142" → "HK Invoke": the name without the serial macOS adds.
    static func plain(_ n: String?) -> String {
        let n = n ?? "Speaker"
        if let r = n.range(of: #"_[0-9A-F]{4,}$"#, options: .regularExpression) { return String(n[..<r.lowerBound]) }
        return n
    }
    private var speakerName: String { Self.plain(s?.speaker ?? s?.ended?.speaker ?? store.speaker?.name) }

    private func row(_ title: String, _ note: String, _ symbol: String, warn: Bool = false) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Text(note).font(.footnote).foregroundStyle(warn ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(warn ? nil : 2).truncationMode(.tail).fixedSize(horizontal: false, vertical: warn)
                    .animation(.easeOut(duration: 0.2), value: warn)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(macBlue) }
    }

    var body: some View {
        if store.available {
            Section {
                if store.live && !store.legacy { live } else { idle }
            } header: { Text("Music") }
            .disabled(model.stale)
            .haptic(.done, trigger: store.answered)
            .haptic(.warn, trigger: store.refused)
            // For the build's shots only (-musicPress lyrics|speaker|end|endask|next): pressed once the Mac has answered, so the
            // waiting and refusal states are seen. Never on the phone.
            .task {
                guard let which = UserDefaults.standard.string(forKey: "musicPress") else { return }
                for _ in 0..<40 where store.s == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                switch which {
                case "speaker": await store.speaker(model, !(s?.speakerConnected ?? store.speaker?.connected ?? false))
                case "end": await store.end(model)
                case "endask": confirmEnd = true
                case "next": await store.transport(model, "next")
                default: await store.lyrics(model, !(s?.on == true && s?.lyricsOff != true))
                }
            }
        }
    }

    // MARK: No session

    @ViewBuilder private var idle: some View {
        HStack(spacing: 12) {
            row("AirPlay to Mac Pro", store.s == nil ? "Checking…" : "Lyrics on the Mac’s screen, sound on \(speakerName). Stop AirPlay and the speaker is free again.", "airplay.audio")
            Spacer(minLength: 0)
            AirPlayPicker().frame(width: 44, height: 44).accessibilityLabel("Choose where this iPhone plays")
        }
        .id("mac-music")
        Toggle(isOn: Binding(get: { store.asked["lyrics"] ?? store.on }, set: { w in Task { await store.lyrics(model, w) } })) {
            row("Lyrics", store.busy == "lyrics" ? "Asking the Mac…" : refusal("lyrics") ?? (store.s == nil ? "Checking…" : "What the Mac plays, full screen, through the speaker"), "quote.bubble", warn: refusal("lyrics") != nil)
        }
        .accessibilityIdentifier("switch.lyrics")
        .disabled(store.s == nil || store.busy != nil)
        if store.speaker != nil || s?.speaker != nil { speakerSwitch }
    }

    // MARK: A session

    private var phaseLine: String {
        switch store.phase {
        case "connecting": return s?.speakerState == "retrying" ? "Trying \(speakerName) again…" : "Connecting \(speakerName)…"
        case "starting": return "Finding the song in Music…"
        case "lyrics": return s?.song?.playing == false ? "Paused · lyrics on the Mac" : "Lyrics on the Mac"
        case "airplay": return "Playing the AirPlay sound · Music couldn’t take it"
        case "ending": return "Disconnecting \(speakerName)…"
        case "ended":
            if s?.ended?.continued == true { return "Continued on iPhone" }
            return s?.ended?.speakerFree == true ? "Disconnected · \(speakerName) is free" : "Ended · \(speakerName) kept"
        default: return s?.song?.playing == false ? "Paused" : (s?.lyricsOff == true ? "Playing · lyrics off" : "Playing")
        }
    }
    private var phaseSymbol: String {
        switch store.phase {
        case "connecting", "ending": return "hifispeaker"
        case "ended": return s?.ended?.speakerFree == true ? "checkmark.circle.fill" : "hifispeaker"
        default: return "music.note"
        }
    }
    private static func mmss(_ t: Double) -> String { let s = max(0, Int(t)); return String(format: "%d:%02d", s / 60, s % 60) }
    private static func ran(_ s: Int) -> String { s < 60 ? "just now" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h \(s % 3600 / 60) min" }

    @ViewBuilder private var live: some View {
        let ended = store.phase == "ended" || store.phase == "ending"
        // Now: the song, the phase, how far in, how long the session has run.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(macBlue.opacity(0.16))
                    Image(systemName: phaseSymbol).font(.title2.weight(.semibold)).foregroundStyle(store.phase == "ended" && s?.ended?.speakerFree == true ? .green : macBlue)
                        .symbolEffect(.pulse, isActive: ["connecting", "starting", "ending"].contains(store.phase))
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    if let t = s?.song?.title, !t.isEmpty, !ended {
                        Text(t).font(.headline).lineLimit(2)
                        if let a = s?.song?.artist, !a.isEmpty { Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Text(phaseLine).font(ended || s?.song?.title == nil ? .headline : .footnote).foregroundStyle(ended || s?.song?.title == nil ? .primary : .secondary)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            if !ended, let d = s?.song?.duration, d > 0 { progress(d) }
            if !ended, let e = s?.elapsed {
                TimelineView(.periodic(from: .now, by: 30)) { c in
                    Text("Session · \(Self.ran(e + Int(c.date.timeIntervalSince(store.readAt))))" + (s?.endsIn.map { " · ends in \($0) s unless AirPlay comes back" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
        .id("mac-music")
        .animation(.easeInOut(duration: 0.25), value: store.phase)
        if store.on {
            transport
            volume
            Toggle(isOn: Binding(get: { store.asked["lyrics"] ?? (s?.lyricsOff != true) }, set: { w in Task { await store.lyrics(model, w) } })) {
                row("Lyrics", store.busy == "lyrics" ? "Asking the Mac…" : refusal("lyrics") ?? (s?.lyricsOff == true ? "Off · the music plays on" : s?.lyrics == true ? "Full screen on the Mac" : "Coming up on the Mac"), "quote.bubble", warn: refusal("lyrics") != nil)
            }
            .accessibilityIdentifier("switch.lyrics")
            .disabled(store.busy != nil)
            speakerSwitch
            Button { Task { await store.carryOn(model) } } label: {
                HStack {
                    row("Continue on iPhone", store.busy == "continue" ? "Asking the Mac…" : refusal("continue") ?? "The same song, from the same place, here", "iphone", warn: refusal("continue") != nil && store.refused > 0)
                    Spacer(minLength: 0)
                    if store.busy == "continue" { ProgressView() }
                }
            }
            .tint(.primary)
            .disabled(store.busy != nil)
            .overlay { AirPlayPicker(open: store.pickRoute).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false) }
            Button(role: .destructive) { confirmEnd = true } label: {
                Label(store.busy == "end" ? "Ending…" : "End session", systemImage: "stop.circle")
            }
            .accessibilityIdentifier("music.end")
            .disabled(store.busy != nil)
            .confirmationDialog("End music on the Mac?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End session", role: .destructive) { Task { await store.end(model) } }
            } message: { Text("Music stops, \(speakerName) is let go and the Mac’s display goes back as it was.") }
        }
    }

    private func progress(_ d: Double) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { c in
            let playing = s?.song?.playing == true
            let p = min(d, (s?.song?.position ?? 0) + (playing ? c.date.timeIntervalSince(store.readAt) : 0))
            VStack(spacing: 4) {
                ProgressView(value: p, total: d).tint(macBlue)
                HStack { Text(Self.mmss(p)); Spacer(); Text("-" + Self.mmss(d - p)) }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var transport: some View {
        let playing = s?.song?.playing == true
        let skipsHere = s?.airplay != true || store.phoneHasSong || PhoneMusic.undecided
        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                key("backward.fill", "Previous", "previous", enabled: skipsHere)
                key(playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play", "playpause", big: true, enabled: true)
                key("forward.fill", "Next", "next", enabled: skipsHere)
            }
            if let r = ["playpause", "next", "previous"].compactMap({ refusal($0) }).first {
                Text(r).font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity)
            } else if !skipsHere {
                Text("Skip on the device that’s AirPlaying").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }
    private func key(_ symbol: String, _ label: String, _ cmd: String, big: Bool = false, enabled: Bool) -> some View {
        Button { Task { await store.transport(model, cmd) } } label: {
            Image(systemName: symbol).font(big ? .title.weight(.semibold) : .title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier("music.\(cmd)")
        .disabled(!enabled || store.busy != nil)
    }

    private var volume: some View {
        let v = s?.volume
        return HStack(spacing: 10) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.footnote)
            Slider(value: Binding(get: { store.volumeDraft ?? Double(v?.level ?? 50) }, set: { store.volumeDraft = $0 }), in: 0...100) { editing in
                if !editing, let d = store.volumeDraft { Task { await store.setVolume(model, d) } }
            }
            .tint(macBlue)
            .disabled(v == nil)
            .accessibilityLabel(v?.of == "music" ? "Music volume on the Mac" : "Mac volume")
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private var speakerSwitch: some View {
        let connected = s?.on == true ? (s?.speakerConnected == true) : (store.speaker?.connected == true)
        let note: String = {
            if store.busy == "speaker" { return "Asking the Mac…" }
            if let r = refusal("speaker") { return r }
            if s?.on == true {
                switch s?.speakerState {
                case "connecting": return "Connecting…"
                case "retrying": return "Trying again…"
                case "released": return "Let go · the Mac’s own speakers play"
                case "off": return s?.speakerSay ?? "Not connected"
                default: return "Connected · the music plays here"
                }
            }
            if store.speaker?.connected == nil && s == nil { return "Checking…" }
            return connected ? "Connected to the Mac" : "Free for your other devices"
        }()
        return Toggle(isOn: Binding(get: { store.asked["speaker"] ?? connected }, set: { w in Task { await store.speaker(model, w) } })) {
            row(speakerName, note, "hifispeaker", warn: refusal("speaker") != nil || (s?.on == true && s?.speakerState == "off"))
        }
        .accessibilityIdentifier("switch.speaker")
        .disabled(store.busy != nil || ["connecting", "retrying"].contains(s?.speakerState ?? ""))
    }
}

// The section's reads run while the Dashboard is up (its own task, apart from the Console remote's).
// Only while the Dashboard is the tab in front: DuoTabs keeps a visited tab in place unseen, and its reads went on behind
// Status (designer gate on mac-appliance-1125).
struct MacMusicLoop: ViewModifier {
    var on = true
    @EnvironmentObject var model: AppModel
    @Environment(\.duoTabFront) private var front
    func body(content: Content) -> some View { content.task(id: on && front) { if on && front { await MacMusicStore.shared.loop(model) } } }
}
