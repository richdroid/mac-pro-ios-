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
    struct Song: Decodable, Equatable { var title: String?; var artist: String?; var position: Double?; var duration: Double?; var playing: Bool?; var from: String?; var cover: String? }
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
    @Published private(set) var sayOK = false
    // The song's cover, as the AirPlay sender gave it to the Mac (GET /api/mac/airplay/cover).
    @Published private(set) var cover: Image?
    private var coverPath: String?
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
            let path = got.on ? got.song?.cover : nil
            if path != coverPath { coverPath = path; await loadCover(model, path) }
        }
        let gotAudio = await a
        guard busy == nil, got != nil else { return }
        if let gotAudio {
            let sp = gotAudio.outputs.first { $0.id == gotAudio.preferred }
            if sp != speaker { speaker = sp }
            UserDefaults.standard.set(sp?.id, forKey: "macMusic.speakerID"); UserDefaults.standard.set(sp?.name, forKey: "macMusic.speakerName")
        }
    }
    private func loadCover(_ model: AppModel, _ path: String?) async {
        guard let path, let u = URL(string: path, relativeTo: model.api.base) else { cover = nil; return }
        let d = try? await model.api.session.data(from: u).0
        guard coverPath == path else { return }
        #if os(iOS)
        cover = d.flatMap(UIImage.init(data:)).map { Image(uiImage: $0) }
        #else
        cover = nil; _ = d
        #endif
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
        if a?.done == true { answered += 1; say = nil } else { say = a?.say ?? a?.error ?? "Couldn’t reach the Mac."; sayOK = false; refused += 1 }
        busy = nil
        await read(model)
        asked = [:]; volumeDraft = nil
        let said = say
        Task { try? await Task.sleep(for: .seconds(5)); if busy == nil, say == said { say = nil } }
    }
    private func tell(_ key: String, _ words: String, ok: Bool) {
        sayFor = key; say = words; sayOK = ok
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

// One card, one height, whatever the session does (designer gate on 25c4ab0: the page grew 208 pt as the card came,
// shrank 312 pt as a session ended, and grew with every conditional line — Richard's "going up upon going down"). Every
// row is always there; what can't be pressed now is dimmed, and the header's third line says why. Each line holds one
// line (the header's last holds two), so nothing changes size with its value.
struct MacMusicSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = MacMusicStore.shared
    @State private var confirmEnd = false

    private var s: MacSession? { store.s }
    private var session: Bool { store.on }
    private var ended: Bool { store.phase == "ended" || store.phase == "ending" }
    private func refusal(_ key: String) -> String? { store.sayFor == key ? store.say : nil }
    // "HK Invoke_C20142" → "HK Invoke": the name without the serial macOS adds, wherever it appears in a sentence.
    static func plain(_ n: String?) -> String {
        (n ?? "Speaker").replacingOccurrences(of: #"_[0-9A-F]{4,}"#, with: "", options: .regularExpression)
    }
    private var speakerName: String { Self.plain(s?.speaker ?? s?.ended?.speaker ?? store.speaker?.name) }
    private static func mmss(_ t: Double) -> String { let s = max(0, Int(t)); return String(format: "%d:%02d", s / 60, s % 60) }
    private static func ran(_ s: Int) -> String { s < 60 ? "just now" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h \(s % 3600 / 60) min" }

    private func row(_ title: String, _ note: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(macBlue) }
    }

    // MARK: The header's three lines

    private var title: String {
        if session || ended, let t = s?.song?.title, !t.isEmpty, !ended { return t }
        if ended { return "Music on the Mac" }
        return "AirPlay to Mac Pro"
    }
    private var subtitle: String {
        if session, let a = s?.song?.artist, !a.isEmpty { return a }
        if session || ended { return speakerName }
        // Short enough for one line folded and open flat ("…sound on the speaker" was cut there, gate on macpro-1128);
        // the speaker is named on its own row below.
        return "Lyrics on the Mac’s screen"
    }
    // The phase, or the Mac's answer to the last press for a few seconds, or why the keys are dimmed.
    private var line: (text: String, warn: Bool) {
        if let say = store.say, store.busy == nil { return (Self.plain(say), !store.sayOK) }
        if store.busy == "continue" { return ("Asking the Mac what’s playing…", false) }
        if store.busy == "end" { return ("Ending…", false) }
        if store.s == nil { return ("Checking…", false) }
        let ran = s?.elapsed.map { " · " + Self.ran($0 + Int(Date().timeIntervalSince(store.readAt))) } ?? ""
        switch store.phase {
        case "connecting": return ((s?.speakerState == "retrying" ? "Trying \(speakerName) again…" : "Connecting \(speakerName)…"), false)
        case "starting": return ("Finding the song in Music…", false)
        case "ending": return ("Disconnecting \(speakerName)…", false)
        case "ended":
            if s?.ended?.continued == true { return ("Continued on iPhone · \(speakerName) is free", false) }
            return (s?.ended?.speakerFree == true ? "Disconnected · \(speakerName) is free" : "Ended · \(speakerName) still connected", false)
        case "idle": return ("Nothing playing. Tap to choose Mac Pro.", false)
        default:
            if let e = s?.endsIn { return ("AirPlay stopped · ends in \(e) s unless it comes back", false) }
            var t = s?.song?.playing == false ? "Paused" : store.phase == "airplay" ? "Playing the AirPlay sound directly" : s?.lyricsOff == true ? "Playing · lyrics off" : "Lyrics on the Mac"
            if s?.speakerState == "off" || s?.speakerState == "released" { t += " · on the Mac’s speakers" }
            if s?.airplay == true, !store.phoneHasSong, let who = s?.sender { t += " · skip on \(who)" }
            return (t + ran, false)
        }
    }

    var body: some View {
        if store.available {
            Section {
                header
                progress
                transport
                volume
                lyricsSwitch
                speakerSwitch
                continueRow
                endRow
            } header: { Text("Music") }
            .disabled(model.stale)
            .haptic(.done, trigger: store.answered)
            .haptic(.warn, trigger: store.refused)
            // For the build's shots only (-musicPress lyrics|speaker|end|endask|next): pressed once the Mac has answered, so
            // the waiting and refusal states are seen. Never on the phone.
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

    // The song (its cover when the Mac has one), and the line. With nothing playing, the whole row opens the system's
    // AirPlay picker, where Mac Pro is chosen.
    private var header: some View {
        Button { if !session && !ended { store.pickRoute += 1 } } label: {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(macBlue.opacity(0.16))
                    if let c = store.cover, session { c.resizable().aspectRatio(contentMode: .fill) }
                    else {
                        Image(systemName: session ? (["connecting", "ending"].contains(store.phase) ? "hifispeaker" : "music.note") : ended ? (s?.ended?.speakerFree == true ? "checkmark" : "hifispeaker") : "airplay.audio")
                            .font(.title2.weight(.semibold)).foregroundStyle(macBlue)
                            .symbolEffect(.pulse, isActive: ["connecting", "starting", "ending"].contains(store.phase))
                    }
                }
                .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    let l = line
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if l.warn { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                        Text(l.text).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true).contentTransition(.opacity)
                    }
                    .font(.footnote)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background { AirPlayPicker(open: store.pickRoute).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false) }
        .accessibilityHint(session ? "" : "Opens the AirPlay picker")
        .id("mac-music")
        .animation(.easeInOut(duration: 0.25), value: store.phase)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { c in
            let d = s?.song?.duration ?? 0
            let live = session && d > 0
            let playing = s?.song?.playing == true
            let p = live ? min(d, (s?.song?.position ?? 0) + (playing ? c.date.timeIntervalSince(store.readAt) : 0)) : 0
            VStack(spacing: 4) {
                ProgressView(value: p, total: max(d, 1)).tint(macBlue)
                HStack { Text(live ? Self.mmss(p) : "–:––"); Spacer(); Text(live ? "-" + Self.mmss(d - p) : "–:––") }
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .opacity(live ? 1 : 0.4)
        }
        .accessibilityHidden(!session)
    }

    private var transport: some View {
        let playing = s?.song?.playing == true
        let skips = session && (s?.airplay != true || store.phoneHasSong || PhoneMusic.undecided)
        return HStack(spacing: Space.gap) {
            key("backward.fill", "Previous", "previous", enabled: skips)
            key(playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play", "playpause", big: true, enabled: session)
            key("forward.fill", "Next", "next", enabled: skips)
        }
        .padding(.vertical, 4)
    }
    // The remote's own key (DashboardTab.BigKey): one height, the same fill and corners; the main one filled.
    private func key(_ symbol: String, _ label: String, _ cmd: String, big: Bool = false, enabled: Bool) -> some View {
        Button { Task { await store.transport(model, cmd) } } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold))
                .foregroundStyle(big ? Color.white : macBlue)
                .opacity(store.busy == cmd ? 0 : 1)
                .overlay { if store.busy == cmd { ProgressView().controlSize(.small).tint(big ? .white : macBlue) } }
                .frame(maxWidth: .infinity).frame(height: Space.key)
                .background(big ? macBlue : Color(white: 0.17), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(enabled && store.busy == nil ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier("music.\(cmd)")
        .disabled(!enabled || store.busy != nil)
    }

    private var volume: some View {
        let v = s?.volume
        return HStack(spacing: 10) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.footnote)
            Slider(value: Binding(get: { store.volumeDraft ?? Double(v?.level ?? 0) }, set: { store.volumeDraft = $0 }), in: 0...100) { editing in
                if !editing, let d = store.volumeDraft { Task { await store.setVolume(model, d) } }
            }
            .tint(macBlue)
            .accessibilityLabel(v?.of == "music" ? "Music volume on the Mac" : "Mac volume")
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.footnote)
        }
        .padding(.vertical, 4)
        .disabled(!session || v == nil || store.busy != nil)
        .opacity(session && v != nil ? 1 : 0.4)
    }

    private var lyricsSwitch: some View {
        let on = session ? (s?.lyricsOff != true) : false
        let note = store.busy == "lyrics" ? "Asking the Mac…"
            : session ? (s?.lyricsOff == true ? "Off · the music plays on" : s?.lyrics == true ? "Full screen on the Mac" : "Coming up on the Mac")
            : "For what the Mac plays now"
        return Toggle(isOn: Binding(get: { store.asked["lyrics"] ?? on }, set: { w in Task { await store.lyrics(model, w) } })) {
            row("Lyrics", note, "quote.bubble")
        }
        .accessibilityIdentifier("switch.lyrics")
        .disabled(store.s == nil || store.busy != nil || ended)
    }

    private var speakerSwitch: some View {
        let connected = session ? (s?.speakerConnected == true) : (store.speaker?.connected == true)
        let note: String = {
            if store.busy == "speaker" { return "Asking the Mac…" }
            if session {
                switch s?.speakerState {
                case "connecting": return "Connecting…"
                case "retrying": return "Trying again…"
                case "released": return "Let go · playing on the Mac’s speakers"
                case "off": return "Not connected · playing on the Mac’s speakers"
                default: return "Connected · the music plays here"
                }
            }
            if store.speaker?.connected == nil { return "Free for your other devices" }
            return connected ? "Connected to the Mac" : "Free for your other devices"
        }()
        return Toggle(isOn: Binding(get: { store.asked["speaker"] ?? connected }, set: { w in Task { await store.speaker(model, w) } })) {
            row(speakerName, note, "hifispeaker")
        }
        .accessibilityIdentifier("switch.speaker")
        .disabled(store.s == nil || store.busy != nil || ended || ["connecting", "retrying"].contains(s?.speakerState ?? ""))
    }

    // An action that goes somewhere, drawn as "See the Mac's screen" is: blue, with the chevron.
    private var continueRow: some View {
        Button { Task { await store.carryOn(model) } } label: {
            HStack {
                Label("Continue on iPhone", systemImage: "iphone")
                Spacer(minLength: 8)
                if store.busy == "continue" { ProgressView().controlSize(.small) } else { RowChevron() }
            }
            .contentShape(Rectangle())
            // Dimmed as the card's other keys are when there's no session to carry on (it was drawn at full strength
            // with its chevron and did nothing, gate on macpro-1128).
            .opacity(session && store.busy == nil ? 1 : 0.4)
        }
        .accessibilityIdentifier("music.continue")
        .disabled(!session || store.busy != nil)
    }
    private var endRow: some View {
        Button(role: .destructive) { confirmEnd = true } label: { Label("End session", systemImage: "stop.circle").opacity(session && store.busy == nil ? 1 : 0.4) }
            .accessibilityIdentifier("music.end")
            .disabled(!session || store.busy != nil)
            .confirmationDialog("End the session?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End session", role: .destructive) { Task { await store.end(model) } }
            } message: { Text("Music stops, \(speakerName) is let go and the Mac’s display goes back as it was.") }
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
