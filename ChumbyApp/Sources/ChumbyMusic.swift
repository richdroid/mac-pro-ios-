import SwiftUI

// A song from the Mac's Music library, played on the Chumby (Richard, 2026-11-10: "choosing songs from apple music, idc
// where they actually play from"; 11-11: "Build it"). The Mac's Music app plays it and sends it to the Chumby by AirPlay,
// so the phone only chooses: it can lock, leave the room or leave the house, and the song plays on. The Mac does the
// careful part itself (its sound goes to the Chumby alone, and back to the Mac when the song ends; mac-dash music.js).
struct MacSong: Decodable, Identifiable, Hashable {
    let id: String, name: String, artist: String, album: String, secs: Int
}
// What the Mac's Music is playing on the Chumby right now, if anything.
struct MacPlaying: Equatable { var name: String, artist: String, album: String }

enum MacMusic {
    // The Mac itself, where the app already sends its notification token: baked in when the app is signed. The build's
    // own shots and films give a stand-in Mac at launch (-mac), never kept, so the row and its flows are seen before ship.
    static var address: String {
        if let a = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["mac"] as? String { return a }
        return Bundle.main.object(forInfoDictionaryKey: "MacAddress") as? String ?? ""
    }
    // Shown only where the app knows the Mac, and only when switched on (MacMusicOn, project.yml) or for the build's
    // films: the Mac's search takes 8 to 12 s on his library (measured 11-12), too slow for his phone (gate, 11-12).
    static var on: Bool {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["mac"] != nil
            || Bundle.main.object(forInfoDictionaryKey: "MacMusicOn") as? Bool == true
    }
    static var reachable: Bool { on && URL(string: address)?.host != nil }
    // How long the Mac may go unanswering before it's said (the 11-11 ruling: never on a single miss; opening on cellular,
    // Tailscale takes a few seconds to wake). Until then it's asked again every two seconds, quietly.
    static let patience: TimeInterval = 25
    struct Answer: Decodable {
        var ok: Bool?, error: String?, songs: [MacSong]?, playing: Bool?
        struct Now: Decodable { var name: String?, artist: String?, album: String? }
        var song: Now?
    }
    // What actually failed, said as that: the Mac not reached at all is one thing, the Mac answering with a problem
    // another, and the Mac's Music saying why is a third (its own sentence, mac-dash music.js).
    enum Trouble: LocalizedError {
        case noAnswer, refused(Int), garbled, said(String)
        var errorDescription: String? {
            switch self {
            case .noAnswer: return "Can’t reach the Mac."
            case .refused(let code): return code == 403 ? "The Mac turned the request away." : "The Mac answered with an error (\(code))."
            case .garbled: return "The Mac answered, but not about music."
            case .said(let why): return why
            }
        }
    }
    // One request to the Mac, as its own app makes them (it turns away anything that doesn't say which site it is).
    static func ask(_ path: String, query: [URLQueryItem] = [], post: Bool = false, timeout: TimeInterval = 20) async throws -> Answer {
        guard let base = URL(string: address), let host = base.host,
              var parts = URLComponents(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/music/" + path) else { throw Trouble.noAnswer }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw Trouble.noAnswer }
        var r = URLRequest(url: url); r.timeoutInterval = timeout; r.cachePolicy = .reloadIgnoringLocalCacheData
        r.httpMethod = post ? "POST" : "GET"
        r.setValue("\(base.scheme ?? "https")://\(host)\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: r) }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw Trouble.noAnswer }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Trouble.refused(code) }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw Trouble.garbled }
        if a.ok != true { throw Trouble.said(a.error ?? "The Mac’s Music didn’t answer.") }
        return a
    }
    // Asked again every two seconds while nothing answers, for `patience` from the first try; anything the Mac does say
    // (an error included) is the answer at once.
    static func persistently<T>(_ op: () async throws -> T) async throws -> T {
        let began = Date()
        while true {
            do { return try await op() }
            catch Trouble.noAnswer where Date().timeIntervalSince(began) < patience {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    static func search(_ text: String) async throws -> [MacSong] {
        try await ask("search", query: [URLQueryItem(name: "q", value: text)], timeout: 35).songs ?? []
    }
    // Reaching the Mac is made sure of first, with a quick question that's safe to ask again; the play itself is sent
    // once, as a second one could start the song over. If its answer doesn't come, the Mac is asked what it's playing.
    static func play(_ song: MacSong) async throws {
        _ = try await persistently { try await ask("now", timeout: 8) }
        do { _ = try await ask("play", query: [URLQueryItem(name: "id", value: song.id)], post: true, timeout: 45) }
        catch Trouble.noAnswer {
            if await now()?.name == song.name { return }
            throw Trouble.said("The Mac stopped answering while it started “\(song.name)”, and it isn’t playing.")
        }
    }
    static func stop() async throws { _ = try await persistently { try await ask("stop", post: true) } }
    static func now() async -> MacPlaying? {
        guard let a = try? await ask("now"), a.playing == true, let s = a.song, let name = s.name else { return nil }
        return MacPlaying(name: name, artist: s.artist ?? "", album: s.album ?? "")
    }
}

extension ChumbyModel {
    // What the Mac is playing on the Chumby, asked again; the Now card shows it with its Stop.
    func loadMacPlaying() async {
        // Not while a song is starting: the Mac says "nothing yet" for those seconds, and the card would flicker.
        guard MacMusic.reachable, macStarting == nil else { return }
        let now = await MacMusic.now()
        if macStarting == nil, now != macPlaying { withAnimation(.snappy) { macPlaying = now } }
    }
    // A song chosen: shown on the Now card at once as starting, since the Mac takes about a quarter of a minute to get
    // it playing on the Chumby. When it is, the card has its Stop; when it couldn't, the card goes back to what was
    // there and says why, in a note that stays until it's put away (music may or may not be playing in his room).
    func playOnChumby(_ song: MacSong) {
        tick()
        letGo("macmusic")
        let it = MacPlaying(name: song.name, artist: song.artist, album: song.album)
        withAnimation(.snappy) { macStarting = it }
        Task {
            // Only the newest pick's answer counts: a second song chosen while the first was still starting must not be
            // named, or called failed, by the first one's answer arriving late.
            do {
                try await MacMusic.play(song)
                guard macStarting == it else { return }
                withAnimation(.snappy) { macPlaying = it; macStarting = nil }
            } catch {
                guard macStarting == it else { return }
                withAnimation(.snappy) { macStarting = nil }
                if case MacMusic.Trouble.noAnswer = error { fail("macmusic", "Can’t reach the Mac, so “\(song.name)” didn’t start.") }
                else { fail("macmusic", "“\(song.name)” didn’t start. \(error.localizedDescription)") }
            }
        }
    }
    func stopMacMusic() {
        tick()
        letGo("macmusic")
        let was = macPlaying
        withAnimation(.snappy) { macPlaying = nil }
        Task {
            do { try await MacMusic.stop() }
            catch {
                withAnimation(.snappy) { macPlaying = was }
                if case MacMusic.Trouble.noAnswer = error { fail("macmusic", "Can’t reach the Mac, so the song is still playing.") }
                else { fail("macmusic", "The Mac didn’t stop the song. \(error.localizedDescription)") }
            }
        }
    }
}

// The build's poses of all this (ci branch films), driven from here so the views carry one line each. Never on his phone:
// only with a -pose at launch.
@MainActor enum MacMusicPose {
    static var pose: String { ChumbyModel.pose }
    static var active: Bool { pose.hasPrefix("mac") }
    // A song the stand-in Mac has, for the poses that start one without the picker.
    static let song = MacSong(id: "00000000000000A1", name: "Blue in Green", artist: "Miles Davis", album: "Kind of Blue", secs: 337)
    // Once per launch each: Sounds' row appears again when the picker closes (and twice in two panes), and must not
    // open it again; each opening of the picker types once and picks once.
    static var posed = false
    static var opens = 0
    static var picks = 0
    // Sounds: when the picker opens, and when it opens again for a second pick during a start.
    static func sounds(_ model: ChumbyModel, open: @escaping () -> Void) async {
        guard active, !posed else { return }
        posed = true
        // Its own task, not the row's: the row can be redrawn as a new cell mid-pose (open upright), which would end it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            switch pose {
            case "macgone": model.playOnChumby(song)
            case "macpick", "macpickgone", "macplay", "machome", "macfail", "macsecond", "macdrag", "macclose", "macpicknokb":
                open()
                guard pose == "macsecond" else { return }
                // The second pick lands while the first is still starting (searches take 9 s, as his library's do).
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                open()
            default: break
            }
        }
    }
    // In the picker: the words typed as he would, a moment after it opens. Returns them, or nil for no pose.
    static func typing() async -> String? {
        guard active, opens < 2 else { return nil }
        opens += 1
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return opens > 1 ? "so what" : "blue"
    }
    // With the list there, whether to pick its first song (the flows), once per opening.
    static func shouldPick() -> Bool {
        guard active, !["macpick", "macpickgone", "macdrag", "macclose", "macpicknokb"].contains(pose), picks < opens else { return false }
        picks += 1
        return true
    }
    // The Close button's path, once per launch.
    static var closed = false
    static func shouldClose() -> Bool {
        guard pose == "macclose", !closed else { return false }
        closed = true
        return true
    }
    // Home: the pick made on Sounds, then Home, where the Playing card carries it on.
    static func afterPick(_ model: ChumbyModel) {
        guard pose == "machome" else { return }
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); model.tab = 0 }
    }
}

// What he has typed in the picker and what came back, kept by Sounds rather than the page: the page is a cover or a
// pane by posture, two different views, and a turn or fold must never lose what he typed (11-11 ruling).
@MainActor final class MacSongDraft: ObservableObject {
    @Published var text = ""
    @Published var songs: [MacSong] = []
    @Published var searched = ""
    func clear() { text = ""; songs = []; searched = "" }
}

// Choosing the song: a search of the Mac's Music library. Folded and open upright, edge to edge with Close in a bar
// across the top (a modal with one button, as Add widgets is); open flat, in the right pane beside Sounds, as Add widgets
// and the editors are, so nothing runs across the fold (11-12 gate). The field is the page's own, under the title, with
// the keyboard up as the page opens (the system search bar arrived in three beats, hid the title and Close behind a
// second ✕, and floated over the results). A tap closes the page at once, and Sounds' Now card shows the song starting:
// the wait for the Mac (about a quarter of a minute) is never spent looking at a spinner in a list. The Mac's own search
// takes 8 to 12 s on his library (measured 11-12) and answers at most 25 songs.
struct MacSongPicker: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    // Set when the page is in the right pane open flat: how it closes there.
    @ObservedObject var draft: MacSongDraft
    var pane: (() -> Void)?
    @State private var searching = false
    @State private var problem: String?
    // "Still trying" is a live status, not a note to put away: it goes by itself when the Mac answers.
    @State private var stillTrying = false
    @FocusState private var fieldOn: Bool
    static let title = "Play on the Chumby"
    func length(_ secs: Int) -> String { String(format: "%d:%02d", secs / 60, secs % 60) }
    // The keyboard is let go first, so it goes down with the page rather than lingering over Sounds (11-12 gate).
    func close() { fieldOn = false; if let pane { pane() } else { dismiss() } }
    func choose(_ s: MacSong) { model.playOnChumby(s); close(); MacMusicPose.afterPick(model) }
    var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Song, artist or album", text: $draft.text)
                .focused($fieldOn).submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .padding(.horizontal, 14).frame(minHeight: 44)
        .glassEffect(.regular, in: Capsule())
    }
    @ViewBuilder var sections: some View {
        if let problem { Section { FailNote(text: problem, dismiss: { withAnimation(.snappy) { self.problem = nil } }) }.listRowBackground(GlassRow()) }
        Section {
            // One calm line for the wait, whatever it is: the library being looked through, or the Mac not answering yet
            // (never a red note as well: 11-12 gate).
            if searching && (draft.songs.isEmpty || stillTrying) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(stillTrying ? "Can’t reach the Mac. Still trying…" : "Looking in the Mac’s library…").foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            ForEach(draft.songs) { s in
                Button { choose(s) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).lineLimit(1)
                            Text([s.artist, s.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if s.secs > 0 { Text(length(s.secs)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Results of the question before this one, while the new one is asked: dimmed, so it shows.
                .opacity(searching ? 0.45 : 1)
                .accessibilityHint("Plays it on the Chumby")
            }
            if draft.songs.isEmpty && !searching && !draft.searched.isEmpty && draft.searched == draft.text.trimmingCharacters(in: .whitespaces) && problem == nil {
                Text("No songs like that in the Mac’s library.").foregroundStyle(.secondary)
            }
        }
        .listRowBackground(GlassRow())
    }
    // Nothing reads through the keyboard's glass: the list fades out over its last 18 pt, above the keyboard when it's
    // up (the list ends there) as the tabs do over the bar (11-05).
    var foot: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: pane == nil ? 10 : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
        }
    }
    var body: some View {
        Group {
            if pane != nil {
                let close = Button("Close") { self.close() }.foregroundStyle(.tint)
                List {
                    PageTitle(Self.title, pins: true) { close }
                    field.listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                    sections
                }
                .pinsTitle { PageTitle(Self.title) { close } }
                .scrollDismissesKeyboard(.immediately)
                .mask(foot)
            } else {
                NavigationStack {
                    // The field in the page's own layout, under the bar; the list starts below it, so no row reads
                    // through the field's glass, and its rows fade in under it as they do above the keyboard.
                    VStack(spacing: 0) {
                        field.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 4)
                        List { sections }
                            .seaList()
                            .scrollDismissesKeyboard(.immediately)
                            .mask(foot)
                    }
                        .background { SeaBackground().ignoresSafeArea() }
                        .navigationTitle(Self.title).navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            // Close, not Done: nothing here is confirmed by it (a pick closes the page itself).
                            ToolbarItem(placement: .cancellationAction) { Button { close() } label: { Label("Close", systemImage: "xmark") } }
                        }
                }
                .horizontalBars()
                .tint(ChumbyPalette.acc(scheme == .dark))
            }
        }
        .animation(.snappy, value: draft.songs)
        .animation(.snappy, value: stillTrying)
        // The keyboard comes up with the page, not after it.
        // (Moved by a turn or fold with words already typed, it comes back as it was, without pushing the keyboard up.)
        .defaultFocus($fieldOn, draft.text.isEmpty)
        .onAppear { if draft.text.isEmpty { fieldOn = true } }
        .task { if draft.text.isEmpty, let words = await MacMusicPose.typing() { draft.text = words } }
        .onChange(of: draft.songs) {
            guard !searching, let first = draft.songs.first else { return }
            if MacMusicPose.shouldPick() { Task { try? await Task.sleep(nanoseconds: 1_500_000_000); choose(first) } }
            else if MacMusicPose.shouldClose() { Task { try? await Task.sleep(nanoseconds: 1_500_000_000); close() } }
            else if MacMusicPose.pose == "macpicknokb" { Task { try? await Task.sleep(nanoseconds: 800_000_000); fieldOn = false } }
        }
        // Asked a moment after he stops typing, and only the newest question's answer is shown.
        .task(id: draft.text) {
            let q = draft.text.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { draft.songs = []; searching = false; stillTrying = false; return }
            // Already answered (the page moved by a turn or fold): kept as it is, not asked again.
            if draft.searched == q && !draft.songs.isEmpty { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            searching = true
            // Nothing answering is asked again quietly; only after `patience` is it said, calmly, and asked on until the
            // Mac answers, when it goes by itself. What the Mac does say is shown as it is.
            let began = Date()
            while !Task.isCancelled {
                do {
                    let found = try await MacMusic.search(q)
                    if Task.isCancelled { return }
                    searching = false
                    draft.songs = found; draft.searched = q
                    withAnimation(.snappy) { problem = nil; stillTrying = false }
                    return
                } catch MacMusic.Trouble.noAnswer {
                    if Task.isCancelled { return }
                    if Date().timeIntervalSince(began) >= MacMusic.patience, !stillTrying { stillTrying = true }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    if Task.isCancelled { return }
                    searching = false
                    draft.songs = []; draft.searched = q
                    withAnimation(.snappy) { stillTrying = false; problem = error.localizedDescription }
                    return
                }
            }
        }
    }
}
