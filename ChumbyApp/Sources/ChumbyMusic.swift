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
    // The Mac itself, where the app already sends its notification token: baked in when the app is signed.
    static var address: String { Bundle.main.object(forInfoDictionaryKey: "MacAddress") as? String ?? "" }
    static var reachable: Bool { URL(string: address)?.host != nil }
    struct Answer: Decodable {
        var ok: Bool?, error: String?, songs: [MacSong]?, playing: Bool?
        struct Now: Decodable { var name: String?, artist: String?, album: String? }
        var song: Now?
    }
    enum Trouble: LocalizedError {
        case unreachable, said(String)
        var errorDescription: String? {
            switch self {
            case .unreachable: return "Can’t reach the Mac. Is Tailscale on?"
            case .said(let why): return why
            }
        }
    }
    // One request to the Mac, as its own app makes them (it turns away anything that doesn't say which site it is).
    static func ask(_ path: String, query: [URLQueryItem] = [], post: Bool = false, timeout: TimeInterval = 20) async throws -> Answer {
        guard let base = URL(string: address), let host = base.host,
              var parts = URLComponents(string: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/music/" + path) else { throw Trouble.unreachable }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw Trouble.unreachable }
        var r = URLRequest(url: url); r.timeoutInterval = timeout; r.cachePolicy = .reloadIgnoringLocalCacheData
        r.httpMethod = post ? "POST" : "GET"
        r.setValue("\(base.scheme ?? "https")://\(host)\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw Trouble.unreachable }
        if a.ok != true { throw Trouble.said(a.error ?? "The Mac’s Music didn’t answer.") }
        return a
    }
    static func search(_ text: String) async throws -> [MacSong] {
        try await ask("search", query: [URLQueryItem(name: "q", value: text)], timeout: 35).songs ?? []
    }
    static func play(_ song: MacSong) async throws { _ = try await ask("play", query: [URLQueryItem(name: "id", value: song.id)], post: true, timeout: 35) }
    static func stop() async throws { _ = try await ask("stop", post: true) }
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
                fail("macmusic", error.localizedDescription)
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
            catch { withAnimation(.snappy) { macPlaying = was }; fail("macmusic", "The Mac didn’t stop. \(error.localizedDescription)") }
        }
    }
}

// Choosing the song: a search of the Mac's Music library, edge to edge, with Close in a bar across the top (a modal with
// one button, as Add widgets is). A tap closes the page at once, and Sounds' Now card shows the song starting: the wait
// for the Mac (about a quarter of a minute) is never spent looking at a spinner in a list.
struct MacSongPicker: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var text = ""
    @State private var songs: [MacSong] = []
    @State private var searched = ""
    @State private var searching = false
    @State private var problem: String?
    // The field has the keyboard as the page opens: there's nothing else to do here first.
    @State private var searchOn = true
    func length(_ secs: Int) -> String { String(format: "%d:%02d", secs / 60, secs % 60) }
    var body: some View {
        NavigationStack {
            List {
                if let problem { Section { FailNote(text: problem, dismiss: { withAnimation(.snappy) { self.problem = nil } }) }.listRowBackground(GlassRow()) }
                Section {
                    ForEach(songs) { s in
                        Button { model.playOnChumby(s); dismiss() } label: {
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
                    if songs.isEmpty {
                        if searching { HStack(spacing: 10) { ProgressView(); Text("Looking in the Mac’s library…").foregroundStyle(.secondary) } }
                        else if searched == text.trimmingCharacters(in: .whitespaces) && problem == nil { Text("No songs like that in the Mac’s library.").foregroundStyle(.secondary) }
                    }
                }
                .listRowBackground(GlassRow())
            }
            .seaList().background { SeaBackground().ignoresSafeArea() }
            .animation(.snappy, value: songs)
            .searchable(text: $text, isPresented: $searchOn, prompt: "Song, artist or album")
            .navigationTitle("Play on the Chumby").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Close, not Done: nothing here is confirmed by it (a pick closes the page itself).
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label("Close", systemImage: "xmark") } }
            }
            // Asked a moment after he stops typing, and only the newest question's answer is shown.
            .task(id: text) {
                let q = text.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { songs = []; searching = false; return }
                try? await Task.sleep(nanoseconds: 450_000_000)
                if Task.isCancelled { return }
                searching = true
                do {
                    let found = try await MacMusic.search(q)
                    if Task.isCancelled { return }
                    songs = found; searched = q; problem = nil
                } catch {
                    if Task.isCancelled { return }
                    songs = []; searched = q
                    withAnimation(.snappy) { problem = error.localizedDescription }
                }
                searching = false
            }
        }
        .horizontalBars()
        .tint(ChumbyPalette.acc(scheme == .dark))
    }
}
