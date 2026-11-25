import SwiftUI
import CryptoKit

// What Claude writes about his listening, asked from the phone itself (no Mac in between): a portrait of what he plays
// and the threads through it (Sonnet), a note on his week (Sonnet), artists to hear next chosen from Last.fm's similar
// artists (Haiku), and a short answer to a question about his own music (Haiku). The prompts are the bridge's
// (lastfm-claude.js, tried on his data 2026-11-20), less the tags the phone doesn't keep.
// The key is baked in at signing (AnthropicKey, preset-ipa.sh); without it every piece hides. The mock shows written
// samples about the mock's own artists, for the build's shots. Answers are kept on disk and shown from disk first; the
// portrait and the note are written again at most once a day and only when his listening has moved; discovery once a
// day. A hard cap of $0.25 a day: each call reserves its worst case before it's made. The key is never logged.

// MARK: - Kept answers

struct TasteThread: Codable, Hashable { let name: String; let artists: [String]; let note: String }
struct TastePick: Codable, Hashable { let artist: String; let like: String; let why: String }
struct TasteAsked: Codable, Hashable { let q: String; let answer: String; let day: Int }

struct TasteKept: Codable {
    struct Piece<T: Codable>: Codable { var data: T; var at: Date; var sig: String }
    var portrait: Piece<[String]>?
    var threads: [TasteThread] = []
    var week: Piece<String>?
    var discovery: Piece<[TastePick]>?
    var tried: [String: Date] = [:]
    var asked: [TasteAsked] = []
    var asks = (day: 0, n: 0)
    var spend = (day: 0, dollars: 0.0)
    enum K: String, CodingKey { case portrait, threads, week, discovery, tried, asked, asksDay, asksN, spendDay, spendDollars }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        portrait = try? c.decode(Piece<[String]>.self, forKey: .portrait)
        threads = (try? c.decode([TasteThread].self, forKey: .threads)) ?? []
        week = try? c.decode(Piece<String>.self, forKey: .week)
        discovery = try? c.decode(Piece<[TastePick]>.self, forKey: .discovery)
        tried = (try? c.decode([String: Date].self, forKey: .tried)) ?? [:]
        asked = (try? c.decode([TasteAsked].self, forKey: .asked)) ?? []
        asks = ((try? c.decode(Int.self, forKey: .asksDay)) ?? 0, (try? c.decode(Int.self, forKey: .asksN)) ?? 0)
        spend = ((try? c.decode(Int.self, forKey: .spendDay)) ?? 0, (try? c.decode(Double.self, forKey: .spendDollars)) ?? 0)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encodeIfPresent(portrait, forKey: .portrait); try c.encode(threads, forKey: .threads)
        try c.encodeIfPresent(week, forKey: .week); try c.encodeIfPresent(discovery, forKey: .discovery)
        try c.encode(tried, forKey: .tried); try c.encode(asked, forKey: .asked)
        try c.encode(asks.day, forKey: .asksDay); try c.encode(asks.n, forKey: .asksN)
        try c.encode(spend.day, forKey: .spendDay); try c.encode(spend.dollars, forKey: .spendDollars)
    }
}

// MARK: - The model the screens read

@MainActor @Observable final class Taste {
    static let shared = Taste()
    static let sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5"
    static let cap = 0.25, asksADay = 5, askMax = 200
    private static let prices: [String: (in: Double, out: Double)] = [sonnet: (2, 10), haiku: (0.10, 0.50)]

    // The key, or nil: then nothing of this shows. Read once; never printed.
    @ObservationIgnored private let key: String? = (Bundle.main.infoDictionary?["AnthropicKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let mock = LastFM.shared.mock
    var on: Bool { mock || key != nil }

    // What the screens show, and what is kept on disk: a piece written while he's in the app goes to disk and is shown
    // when he next comes back to it, never landing at the head of a page while he reads it (run 48 gate, blocker 7).
    private(set) var kept = TasteKept()
    @ObservationIgnored private var store = TasteKept()
    // Plays of each thread's artists, all time, for the captions under their covers.
    private(set) var plays: [String: Int] = [:]
    // Covers for the threads' artists, found once they're known so the row draws whole.
    private(set) var art: [String: ArtRef] = [:]
    private(set) var asking = false
    private(set) var askError: String?
    @ObservationIgnored private var busy: Set<String> = []

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(LastFM.shared.mock ? "taste-mock.json" : "taste.json")
    }

    init() {
        if mock { store = Self.sample() } else if let d = try? Data(contentsOf: Self.file), let k = try? JSONDecoder().decode(TasteKept.self, from: d) { store = k }
        kept = store
        Task { await findArt() }
    }

    // Back in the app: what was written since is shown now, before he has scrolled anywhere.
    func show() {
        guard !mock else { return }
        kept = store
        Task { await findArt() }
    }

    private func save() {
        guard !mock, let d = try? JSONEncoder().encode(store) else { return }
        try? d.write(to: Self.file, options: .atomic)
    }

    var asksLeft: Int { Self.asksADay - (store.asks.day == LocalDay.today ? store.asks.n : 0) }

    // MARK: Refresh

    // On launch and on coming back, once his whole history is in: each piece that is due, one at a time.
    func refresh() async {
        guard key != nil, !mock, HistorySync.shared.complete else { return }
        await piece("portrait", Self.sonnet) { try await self.writePortrait() }
        await piece("week", Self.sonnet) { try await self.writeWeek() }
        await piece("discovery", Self.haiku) { try await self.writeDiscovery() }
    }

    private func piece(_ name: String, _ model: String, _ run: @escaping () async throws -> Void) async {
        guard !busy.contains(name) else { return }
        // Any try, good or bad, waits six hours before the next.
        if let t = store.tried[name], Clock.now.timeIntervalSince(t) < 6 * 3600 { return }
        busy.insert(name); defer { busy.remove(name) }
        do { try await run() } catch { }
    }

    // Due: never written, or a day old and his listening has moved since (or a week old regardless).
    private func due(_ at: Date?, _ sig: String, _ was: String?) -> Bool {
        guard let at else { return true }
        let age = Clock.now.timeIntervalSince(at)
        return age >= 7 * 86400 || (age >= 20 * 3600 && sig != was)
    }

    private func writePortrait() async throws {
        let d = await HistoryDB.reader.tasteFacts()
        let sig = Self.sig(d.periods[1].artists.prefix(10).map(\.0).sorted())
        guard due(store.portrait?.at, sig, store.portrait?.sig) else { return }
        store.tried["portrait"] = Clock.now; save()
        var user = d.portraitBlock
        if let last = store.portrait?.data { user += "\n\nYOUR LAST PORTRAIT (say what is true now; don't reuse its sentences):\n" + last.joined(separator: "\n") }
        let text = try await call(Self.sonnet, Prompts.portrait, user, maxTokens: 6000, effort: "medium")
        guard let j = Self.json(text), let lines = (j["lines"] as? [String])?.map(Self.line).filter({ !$0.isEmpty }), (3...4).contains(lines.count), !lines.contains(where: { $0.count > 230 }) else { return }
        let known = Dictionary(d.names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>(), threads: [TasteThread] = []
        for t in (j["threads"] as? [[String: Any]]) ?? [] {
            let artists = ((t["artists"] as? [String]) ?? []).compactMap { known[$0.lowercased()] }.filter { used.insert($0).inserted }.prefix(5)
            let name = Self.line(t["name"] as? String ?? "").lowercased(), note = Self.line(t["note"] as? String ?? "")
            guard artists.count >= 2, !name.isEmpty, name.count <= 40, !note.isEmpty, note.count <= 140 else { continue }
            threads.append(TasteThread(name: name, artists: Array(artists), note: note))
            if threads.count == 5 { break }
        }
        guard threads.count >= 3 else { return }
        store.portrait = .init(data: lines, at: Clock.now, sig: sig); store.threads = threads; save()
    }

    private func writeWeek() async throws {
        let d = await HistoryDB.reader.weekFacts()
        let sig = Self.sig(d.top)
        guard !d.top.isEmpty, due(store.week?.at, sig, store.week?.sig) else { return }
        store.tried["week"] = Clock.now; save()
        let text = try await call(Self.sonnet, Prompts.week, d.block, maxTokens: 3000, effort: "medium")
        let note = Self.line(Self.json(text)?["note"] as? String ?? "")
        guard note.count >= 20, note.count <= 260 else { return }
        store.week = .init(data: note, at: Clock.now, sig: sig); save()
    }

    private func writeDiscovery() async throws {
        let (seeds, facts) = await HistoryDB.reader.discoverySeeds()
        let sig = Self.sig(seeds.sorted())
        guard seeds.count >= 3, due(store.discovery?.at, sig, store.discovery?.sig) else { return }
        // Last.fm's similar artists for each (kept a month), less everyone he has ever played.
        let have = await HistoryDB.reader.everyArtist()
        var by: [String: (name: String, score: Double, via: [String])] = [:]
        for (k, s) in seeds.enumerated() {
            guard let j = try? await LastFM.shared.call("artist.getSimilar", ["artist": s, "limit": "30", "autocorrect": "1"], fresh: 30 * 86400) else { continue }
            let w = 1 - Double(k) / Double(seeds.count * 2)
            for a in j["similarartists"]["artist"].array {
                let name = a["name"].text, n = name.lowercased()
                guard !name.isEmpty, name.count <= 60, !have.contains(n) else { continue }
                let m = Double(a["match"].string ?? "") ?? 0
                var c = by[n] ?? (name, 0, []); c.score += w * m; c.via.append(s); by[n] = c
            }
        }
        let cands = by.values.sorted { $0.score > $1.score }.prefix(50)
        guard cands.count >= 10 else { return }
        store.tried["discovery"] = Clock.now; save()
        let user = facts + "\n\n" + (store.discovery.map { "SUGGESTED LAST TIME (keep the ones that are still the best; otherwise prefer someone new): " + $0.data.map(\.artist).joined(separator: ", ") + "\n\n" } ?? "")
            + "CANDIDATES (name | similar to, closest first)\n" + cands.map { "\($0.name) | \($0.via.prefix(4).joined(separator: "; "))" }.joined(separator: "\n")
        let text = try await call(Self.haiku, Prompts.discovery, user, maxTokens: 1500, thinkingOff: true)
        let known = Dictionary(cands.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>(), per: [String: Int] = [:], picks: [TastePick] = []
        for p in (Self.json(text)?["picks"] as? [[String: Any]]) ?? [] {
            guard let c = known[(p["artist"] as? String ?? "").lowercased()], seen.insert(c.name).inserted else { continue }
            let like = c.via.first { $0.lowercased() == (p["like"] as? String ?? "").lowercased() } ?? c.via[0]
            guard per[like, default: 0] < 3 else { continue }
            per[like, default: 0] += 1
            var why = Self.line(p["why"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            if why.count > 44 { why = String(why.prefix(43)) + "…" }
            picks.append(TastePick(artist: c.name, like: like, why: why))
            if picks.count == 15 { break }
        }
        guard picks.count >= 8 else { return }
        store.discovery = .init(data: picks, at: Clock.now, sig: sig); save()
    }

    // MARK: Ask

    // True when there's an answer to show: the field keeps his words otherwise, so a failed question isn't typed again.
    @discardableResult func ask(_ question: String) async -> Bool {
        let q = Self.line(question).prefix(Self.askMax).description
        guard q.count >= 3, !asking else { return false }
        askError = nil
        if let same = store.asked.first(where: { $0.day == LocalDay.today && $0.q.lowercased() == q.lowercased() }) {
            store.asked.removeAll { $0 == same }; store.asked.insert(same, at: 0)
            withAnimation(.smooth) { kept.asked = store.asked }; return true
        }
        if mock {
            store.asked.insert(TasteAsked(q: q, answer: "You have played Nadia Sorel 2,790 times, most of it this year, and first played them in February 2019.", day: LocalDay.today), at: 0)
            withAnimation(.smooth) { kept.asked = store.asked }
            return true
        }
        guard key != nil else { return false }
        guard asksLeft > 0 else { askError = "That's the \(Self.asksADay) questions for today."; return false }
        asking = true; defer { asking = false }
        // Counted before the call: a question that fails still used one of the day's.
        store.asks = (LocalDay.today, Self.asksADay - asksLeft + 1); save()
        do {
            let data = await HistoryDB.reader.askFacts(q)
            let text = try await call(Self.haiku, Prompts.ask, "QUESTION: \(q)\n\nDATA\n" + data, maxTokens: 400, thinkingOff: true)
            let answer = Self.line(Self.json(text)?["answer"] as? String ?? "")
            guard !answer.isEmpty else { askError = "No answer came back. Try asking another way."; return false }
            store.asked.insert(TasteAsked(q: q, answer: answer, day: LocalDay.today), at: 0)
            store.asked = Array(store.asked.prefix(3)); save()
            withAnimation(.smooth) { kept.asked = store.asked }
            return true
        } catch let e as TasteError {
            askError = e.say
        } catch { askError = "Couldn't answer just now. Try again in a while." }
        return false
    }

    // MARK: One call

    enum TasteError: Error { case cap, http(Int), shape
        var say: String {
            switch self {
            case .cap: return "That's all the questions for today. More tomorrow."
            case .http(let c): return c == 429 || c >= 500 ? "Couldn't answer just now. Try again in a while." : "Couldn't answer that one. Try asking another way."
            case .shape: return "No answer came back. Try asking another way."
            }
        }
    }

    private func cost(_ model: String, _ tin: Int, _ tout: Int) -> Double {
        let p = Self.prices[model] ?? (2, 10)
        return (Double(tin) * p.in + Double(tout) * p.out) / 1_000_000
    }

    private func call(_ model: String, _ system: String, _ user: String, maxTokens: Int, effort: String? = nil, thinkingOff: Bool = false) async throws -> String {
        guard let key else { throw TasteError.shape }
        // The worst case reserved before the call (a token is about 2.7 characters here; counted at 2 to be safe).
        let worst = cost(model, (system.count + user.count) / 2, maxTokens)
        if store.spend.day != LocalDay.today { store.spend = (LocalDay.today, 0) }
        guard store.spend.dollars + worst <= Self.cap else { throw TasteError.cap }
        store.spend.dollars += worst; save()
        var spent = worst
        defer { store.spend.dollars += spent - worst; save() }

        var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "system": system, "messages": [["role": "user", "content": user]]]
        if let effort { body["output_config"] = ["effort": effort] }
        if thinkingOff { body["thinking"] = ["type": "disabled"] }
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"; r.timeoutInterval = model == Self.sonnet ? 60 : 30
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // A refused request costs nothing; a failed one is counted at nothing too (its reservation is returned).
        spent = 0
        guard code == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TasteError.http(code) }
        if let u = o["usage"] as? [String: Any] {
            let tin = (u["input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
            spent = cost(model, tin, u["output_tokens"] as? Int ?? maxTokens)
        } else { spent = worst }
        // Refused, or cut off by its token limit (thinking counts toward it): no half answer is kept.
        guard o["stop_reason"] as? String == "end_turn" else { throw TasteError.shape }
        let text = ((o["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw TasteError.shape }
        return text
    }

    // MARK: Helpers

    private func findArt() async {
        let names = Set(kept.threads.flatMap(\.artists)).subtracting(art.keys)
        guard !names.isEmpty else { return }
        var found: [String: ArtRef] = [:], counts: [String: Int] = [:]
        for n in names { found[n] = await ArtistArt.ref(n); counts[n] = await HistoryDB.reader.plays(of: n, from: 0, to: Int.max) }
        withAnimation(.smooth) { art.merge(found) { a, _ in a }; plays.merge(counts) { a, _ in a } }
    }

    private static func sig(_ s: [String]) -> String {
        SHA256.hash(data: Data(s.joined(separator: "\n").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    private static func line(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func json(_ text: String) -> [String: Any]? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8))) as? [String: Any]
    }

    // The mock's own artists, so the build's shots show each piece in place (never his data: the repo is public).
    private static func sample() -> TasteKept {
        var k = TasteKept()
        k.portrait = .init(data: [
            "This week belongs to Nadia Sorel, with Glass Harbor close behind and Low Tide cutting in between.",
            "The older base is warm 2010s synth pop, while the newer listening is slower, hazier guitar records.",
            "Against the week before, June Halverson came back and Cassio Vale stepped aside.",
        ], at: Clock.now, sig: "")
        k.threads = [
            TasteThread(name: "after hours synth", artists: ["Nadia Sorel", "Glass Harbor"], note: "Bright melodies over drum machines, the heart of most weeks."),
            TasteThread(name: "slow guitar haze", artists: ["Low Tide", "June Halverson"], note: "Quieter records that have grown through the autumn."),
            TasteThread(name: "late night rap", artists: ["Cassio Vale", "Electric Rivers"], note: "Your oldest habit, still cutting through the quieter material."),
        ]
        k.week = .init(data: "A heavier week than usual, and Nadia Sorel took most of it, with Glass Harbor keeping close as a regular.", at: Clock.now, sig: "")
        k.discovery = .init(data: [
            TastePick(artist: "Marrow Lane", like: "Nadia Sorel", why: "same glow, slower and more hushed"),
            TastePick(artist: "Juniper Static", like: "Low Tide", why: "the same blur with a drum machine"),
            TastePick(artist: "Hollis Wren", like: "June Halverson", why: "brighter, more tuneful"),
            TastePick(artist: "Saltwater Hymns", like: "Glass Harbor", why: "colder, drier edges"),
            TastePick(artist: "Night Ferry", like: "Cassio Vale", why: "hazier, chopped and underground"),
        ], at: Clock.now, sig: "")
        k.asked = [TasteAsked(q: "How much Nadia Sorel have I played this year?", answer: "You have played Nadia Sorel 2,790 times in all, 912 of them this year, and first played them in February 2019.", day: LocalDay.today)]
        return k
    }
}

// MARK: - His listening, laid out for Claude (from the phone's own history)

extension HistoryDB {
    struct TasteFacts: Sendable {
        var periods: [(label: String, scrobbles: Int, artists: [(String, Int)], tracks: [(String, String, Int)])]
        var names: [String]
        var portraitBlock: String
    }

    func tracks(from: Int, to: Int, limit: Int) -> [(String, String, Int)] {
        var out: [(String, String, Int)] = []
        rows("SELECT artist, track, COUNT(*) c FROM plays WHERE uts >= ? AND uts < ? GROUP BY artist, track ORDER BY c DESC LIMIT ?", [from, to, limit]) { out.append((text($0, 0), text($0, 1), int($0, 2))) }
        return out
    }
    private func latest(_ n: Int) -> [String] {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        var out: [String] = []
        rows("SELECT uts, artist, track FROM plays ORDER BY uts DESC LIMIT ?", [n]) { out.append("\(f.string(from: Date(timeIntervalSince1970: TimeInterval(self.int($0, 0))))) | \(self.text($0, 1)) | \(self.text($0, 2))") }
        return out
    }
    private func head() -> String {
        var n = 0, first = 0
        rows("SELECT COUNT(*), MIN(uts) FROM plays") { n = self.int($0, 0); first = self.int($0, 1) }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd, EEEE"
        let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
        return "TODAY: \(f.string(from: Clock.now))\nHISTORY: \(n) scrobbles since \(d.string(from: Date(timeIntervalSince1970: TimeInterval(first))))"
    }
    private static func artistsLine(_ r: [(String, Int)]) -> String { r.isEmpty ? "none" : r.map { "\($0.0) (\($0.1))" }.joined(separator: ", ") }
    private static func tracksLine(_ r: [(String, String, Int)]) -> String { r.isEmpty ? "none" : r.map { "\($0.0): \($0.1) (\($0.2))" }.joined(separator: ", ") }

    func tasteFacts() -> TasteFacts {
        let now = Int(Clock.now.timeIntervalSince1970), D = 86400
        let spans = [("PAST 7 DAYS", 7, 15), ("PAST MONTH", 30, 20), ("PAST 3 MONTHS", 91, 25), ("PAST 12 MONTHS", 365, 30)]
        let periods = spans.map { s in (label: s.0, scrobbles: between(now - s.1 * D, now), artists: artists(from: now - s.1 * D, to: now, limit: s.2), tracks: tracks(from: now - s.1 * D, to: now, limit: 10)) }
        let prevWeek = artists(from: now - 14 * D, to: now - 7 * D, limit: 12), prevMonth = artists(from: now - 60 * D, to: now - 30 * D, limit: 15)
        var names: [String] = [], seen = Set<String>()
        for a in periods.flatMap(\.artists) + prevWeek + prevMonth where seen.insert(a.0).inserted { names.append(a.0) }
        let notes = names.map { n -> String in
            var c = 0, f = 0
            rows("SELECT COUNT(*), MIN(uts) FROM plays WHERE artist = ?", [n]) { c = self.int($0, 0); f = self.int($0, 1) }
            return "\(n) | \(c) | \(Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(f))))"
        }
        func block(_ p: (label: String, scrobbles: Int, artists: [(String, Int)], tracks: [(String, String, Int)])) -> [String] {
            ["\(p.label): \(p.scrobbles) scrobbles", "artists: " + Self.artistsLine(p.artists), "tracks: " + Self.tracksLine(p.tracks)]
        }
        var lines = [head(), ""] + block(periods[0])
        lines += ["THE 7 DAYS BEFORE THAT: \(between(now - 14 * D, now - 7 * D)) scrobbles", "artists: " + Self.artistsLine(prevWeek), ""]
        lines += block(periods[1]) + ["THE MONTH BEFORE THAT: \(between(now - 60 * D, now - 30 * D)) scrobbles", "artists: " + Self.artistsLine(prevMonth), ""]
        lines += block(periods[2]) + [""] + block(periods[3]) + [""]
        lines += ["ARTIST NOTES (artist | all-time plays | year he first played them)"] + notes + [""]
        lines += ["LATEST SCROBBLES (newest first; month-day time | artist | track)"] + latest(40)
        return TasteFacts(periods: periods, names: names, portraitBlock: lines.joined(separator: "\n"))
    }

    func weekFacts() -> (top: [String], block: String) {
        let now = Int(Clock.now.timeIntervalSince1970), D = 86400, from = now - 7 * D
        let week = artists(from: from, to: now, limit: 8)
        let usual = between(from - 84 * D, from) / 12
        let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
        let rows8 = week.map { a -> String in
            var n = 0, f = 0, l = 0
            rows("SELECT COUNT(*), MIN(uts), MAX(uts) FROM plays WHERE artist = ? AND uts < ?", [a.0, from]) { n = self.int($0, 0); f = self.int($0, 1); l = self.int($0, 2) }
            let q = plays(of: a.0, from: from - 90 * D, to: from)
            let first = n > 0 ? d.string(from: Date(timeIntervalSince1970: TimeInterval(f))) : "new this week"
            let last = n > 0 ? "\(d.string(from: Date(timeIntervalSince1970: TimeInterval(l)))), \((from - l) / D) days before this week began" : "never"
            return "\(a.0) | \(a.1) | \(q) | \(n) | \(first) | \(last)"
        }
        let lines = [head(), "", "THIS WEEK (the past 7 days): \(between(from, now)) scrobbles. HIS USUAL WEEK (average of the 12 before): \(usual) scrobbles. THE WEEK BEFORE: \(between(from - 7 * D, from)) scrobbles.", "",
                     "THIS WEEK'S ARTISTS (artist | plays this week | plays in the 90 days before | all-time plays before this week | first played | last played before this week)"] + rows8
            + ["", "THIS WEEK'S TRACKS: " + Self.tracksLine(tracks(from: from, to: now, limit: 6)), "",
               "THE WEEK BEFORE, ARTISTS: " + Self.artistsLine(artists(from: from - 7 * D, to: from, limit: 8)),
               "HIS USUAL (past 3 months), ARTISTS: " + Self.artistsLine(artists(from: now - 91 * D, to: now, limit: 15))]
        return (week.prefix(5).map(\.0), lines.joined(separator: "\n"))
    }

    // The artists the candidates gather around (the nearer periods first), and his listening as Claude is shown it.
    func discoverySeeds() -> (seeds: [String], facts: String) {
        let now = Int(Clock.now.timeIntervalSince1970), D = 86400
        let w = artists(from: now - 7 * D, to: now, limit: 10), q = artists(from: now - 91 * D, to: now, limit: 25), y = artists(from: now - 365 * D, to: now, limit: 20)
        var seeds: [String] = [], seen = Set<String>()
        for a in w.prefix(6) + q.prefix(10) + y.prefix(6) where seen.insert(a.0).inserted { seeds.append(a.0) }
        let facts = [head(), "", "HIS ARTISTS, PAST 7 DAYS: " + Self.artistsLine(w), "HIS ARTISTS, PAST 3 MONTHS: " + Self.artistsLine(q), "HIS ARTISTS, PAST 12 MONTHS: " + Self.artistsLine(y)].joined(separator: "\n")
        return (Array(seeds.prefix(14)), facts)
    }

    func everyArtist() -> Set<String> {
        var s = Set<String>()
        rows("SELECT DISTINCT artist FROM plays") { s.insert(self.text($0, 0).lowercased()) }
        return s
    }

    func askFacts(_ question: String) -> String {
        let now = Int(Clock.now.timeIntervalSince1970), D = 86400
        let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
        // By year: plays, artists, and the top five, from the month column (year × 12 + month).
        var years: [(Int, Int, Int)] = []
        rows("SELECT month / 12, COUNT(*), COUNT(DISTINCT artist) FROM plays WHERE month > 0 GROUP BY month / 12 ORDER BY 1") { years.append((self.int($0, 0), self.int($0, 1), self.int($0, 2))) }
        var yearTop: [Int: [(String, Int)]] = [:]
        rows("SELECT y, artist, n FROM (SELECT month / 12 y, artist, COUNT(*) n, ROW_NUMBER() OVER (PARTITION BY month / 12 ORDER BY COUNT(*) DESC) k FROM plays WHERE month > 0 GROUP BY y, artist) WHERE k <= 5 ORDER BY y, n DESC") { yearTop[self.int($0, 0), default: []].append((self.text($0, 1), self.int($0, 2))) }
        // Any of his artists (five plays or more) the question names, longest names first.
        let q = " " + question.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression) + " "
        var named: [String] = []
        rows("SELECT artist FROM plays GROUP BY artist HAVING COUNT(*) >= 5 ORDER BY LENGTH(artist) DESC") {
            let a = self.text($0, 0), n = " " + a.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression) + " "
            if named.count < 4, n.count > 3, q.contains(n), !named.contains(where: { $0.lowercased().contains(a.lowercased()) }) { named.append(a) }
        }
        var about: [String] = []
        for a in named {
            var n = 0, f = 0, l = 0, days = 0
            rows("SELECT COUNT(*), MIN(uts), MAX(uts), COUNT(DISTINCT day) FROM plays WHERE artist = ?", [a]) { n = self.int($0, 0); f = self.int($0, 1); l = self.int($0, 2); days = self.int($0, 3) }
            var byYear: [String] = []
            rows("SELECT month / 12, COUNT(*) FROM plays WHERE artist = ? AND month > 0 GROUP BY 1 ORDER BY 1", [a]) { byYear.append("\(self.int($0, 0)) (\(self.int($0, 1)))") }
            var top: [String] = []
            rows("SELECT track, COUNT(*) c FROM plays WHERE artist = ? GROUP BY track ORDER BY c DESC LIMIT 8", [a]) { top.append("\(self.text($0, 0)) (\(self.int($0, 1)))") }
            about += ["ARTIST: \(a). \(n) plays on \(days) days, first played \(d.string(from: Date(timeIntervalSince1970: TimeInterval(f)))), last played \(d.string(from: Date(timeIntervalSince1970: TimeInterval(l))))",
                      "plays by year: " + byYear.joined(separator: ", "), "top tracks: " + top.joined(separator: ", "), ""]
        }
        var lines = [head(), "BY YEAR (scrobbles, artists; top five artists): " + years.map { y in "\(y.0): \(y.1), \(y.2); " + (yearTop[y.0] ?? []).map { "\($0.0) (\($0.1))" }.joined(separator: ", ") }.joined(separator: " / "), ""]
        lines += about
        lines += ["ALL TIME", "artists: " + Self.artistsLine(artists(from: 0, to: now + D, limit: 30)), "tracks: " + Self.tracksLine(tracks(from: 0, to: now + D, limit: 15)), ""]
        for (label, days) in [("PAST 7 DAYS", 7), ("PAST MONTH", 30), ("PAST 3 MONTHS", 91), ("PAST 12 MONTHS", 365)] {
            lines += ["\(label): \(between(now - days * D, now)) scrobbles", "artists: " + Self.artistsLine(artists(from: now - days * D, to: now, limit: 15)), ""]
        }
        lines += ["LATEST SCROBBLES (newest first; month-day time | artist | track)"] + latest(25)
        return lines.joined(separator: "\n")
    }
}

// MARK: - What Claude is told (the bridge's words, less tags)

enum Prompts {
    static let voice = "Voice: plain, warm, exact, like a friend who knows records and has looked at the numbers. Speak to him as \"you\". No flattery, no praise of his taste, nothing about what kind of person he is. No clichés: never \"eclectic\", \"sonic\", \"journey\", \"soundtrack\", \"tapestry\", \"vibes\", \"deep dive\", \"rabbit hole\", \"on repeat\", \"comfort\", \"taste\". No exclamation marks, no questions, no dashes. Say only what the data shows or what is plainly true of the music itself (its era, mood, sound, scene)."

    static let portrait = """
    You write a short portrait of one person's music listening, shown to him in his own Last.fm app. You are given his top artists and tracks over four periods (plays in brackets), the periods before them for comparison, notes on his artists (all-time plays, the year he first played them), and his latest scrobbles.

    Write:
    - "lines": 3 or 4 lines, each one sentence of at most 150 characters. Between them they say: what his listening is right now; the eras and moods it lives in; and what changed against the period before (who rose, who faded, who came back). Name his artists, at most three in a line: a line is a sentence to read, not a list. Don't open two lines the same way.
    - "threads": 3 to 5 threads that run through his listening. Each has a "name" (2 to 4 words, lowercase), "artists" (2 to 5 of his artists that belong together, copied exactly as written in the data) and a "note" (one line, at most 90 characters, on what ties them or where the thread is heading). An artist goes in one thread only. Threads are about him: built from what he plays most now, not a genre list. Name a thread for its sound, era or scene, never for the people who make it.

    \(voice) Use at most two play counts in the whole portrait.

    Answer with JSON only, no other text and no code fence:
    {"lines":["...","...","..."],"threads":[{"name":"...","artists":["...","..."],"note":"..."}]}
    """

    static let discovery = """
    You choose new artists for one person to hear, shown in his own Last.fm app. You are given the artists he plays most and CANDIDATES: artists he has never played, each with the artists of his that Last.fm says it is similar to.

    Choose the 12 to 15 candidates he would most want to hear, best first.
    - Choose ONLY from CANDIDATES, by their exact name. Never add an artist that is not in the list.
    - Prefer a candidate close to what he is playing now, and one tied to several of his artists. Keep a spread: at most three picks tied to the same artist of his, and not all one genre.
    - For each pick give "like": the ONE artist of his (from that candidate's "similar to" list, exact name) it is closest to, and "why": what the new artist sounds like next to that one, in plain words, under 38 characters, lowercase, without either artist's name (the app shows both names beside it). Such as "slower, sadder, more pedal steel" or "the same blur with a drum machine". Not "similar to", not "fans also like", no flattery.

    Answer with JSON only, no other text and no code fence:
    {"picks":[{"artist":"<candidate name>","like":"<his artist>","why":"<under 38 characters>"}]}
    """

    static let week = """
    You write a note about one person's past seven days of music against his usual, shown to him in his own Last.fm app. You are given this week's top artists with what he played of each before (the 90 days before this week, all time before this week, when he first played them, when he last played them before this week), this week's tracks, and what he usually plays.

    Write "note": one or two sentences, at most 200 characters in all. Say the one or two things most worth saying: what he leaned into, a new obsession (an artist first played in the last few weeks and already played a lot), or a return (an artist back after a long gap). Name the artists, three at most. A week like his usual can be said to be like his usual.

    Say it in words, not figures: at most ONE number in the whole note, and never the word "scrobbles". Not "You played 706 scrobbles against a usual 506 and X went from 2 plays to 55" but the same thing as a person would say it: that it was a heavier week and X, hardly played since spring, took most of it. Find your own words; don't reuse these.

    \(voice)

    Answer with JSON only, no other text and no code fence:
    {"note":"..."}
    """

    static let ask = """
    You answer one short question from a person about his own music listening, in his own Last.fm app. You are given DATA from his scrobble history: totals, plays and top artists by year, top artists and tracks over several periods, his latest scrobbles, and details of any artist of his the question names.

    Answer from DATA only, in one to three sentences, at most 400 characters. Give the numbers that answer it. If DATA does not hold the answer, say in one sentence what you can't see from here and give the nearest thing DATA does show. Anything that isn't a question about his listening or music: say that's all you can answer here.

    \(voice)

    Answer with JSON only, no other text and no code fence:
    {"answer":"..."}
    """
}

// MARK: - The pieces on screen (Zune: large light words hung from the left edge, no card, no label saying who wrote it)

// The portrait under his figures, then its threads: each a lowercase head, his artists' covers, a line under them.
struct TastePortrait: View {
    private var t: Taste { Taste.shared }
    var body: some View {
        if t.on, let lines = t.kept.portrait?.data {
            VStack(alignment: .leading, spacing: S.section) {
                VStack(alignment: .leading, spacing: S.inner) {
                    ForEach(lines, id: \.self) { l in
                        Text(l).font(.zune(size: 24, .light)).foregroundStyle(.white.opacity(0.94)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, S.margin)
                .id("portrait")
                ForEach(t.kept.threads, id: \.self) { th in
                    VStack(alignment: .leading, spacing: S.pair) {
                        Panorama(title: th.name, items: th.artists.map { a in
                            let r = t.art[a]
                            return Entry(kind: .artists, artist: a, album: r?.album ?? "", track: "", plays: t.plays[a] ?? 0, image: r?.url)
                        }, tiles: true) { e in e.plays > 0 ? "\(number(e.plays)) \(e.plays == 1 ? "play" : "plays")" : " " }
                        Text(th.note).font(.zune(.subheadline)).foregroundStyle(S.soft).padding(.horizontal, S.margin).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .transition(.opacity)
        }
    }
}

// The week's note: one paragraph above what he's been playing, no title.
struct TasteWeekNote: View {
    private var t: Taste { Taste.shared }
    var body: some View {
        if t.on, let note = t.kept.week?.data {
            Text(note).font(.zune(size: 22, .light)).foregroundStyle(.white.opacity(0.94))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, S.margin)
                .transition(.opacity)
        }
    }
}

// A question about his own listening, at the foot of his page: one field, what's left today, the answers inline.
// The keyboard ask raised: up or not, and where the field is, so a tap anywhere else on his page puts it away (it left
// only by Send; run 49 gate). Read by StartTab, which holds the tap.
@MainActor @Observable final class AskKeyboard {
    static let shared = AskKeyboard()
    var up = false
    @ObservationIgnored var field: CGRect = .null
    func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

struct TasteAsk: View {
    private var t: Taste { Taste.shared }
    @State private var q = ""
    @FocusState private var focused: Bool
    private var ready: Bool { q.trimmingCharacters(in: .whitespaces).count >= 3 }
    var body: some View {
        if t.on {
            VStack(alignment: .leading, spacing: S.head) {
                SectionHead(text: "ask", trailing: "\(t.asksLeft) left today")
                HStack(spacing: S.gap) {
                    TextField("", text: $q, prompt: Text("How much did I play this year?").foregroundStyle(S.soft), axis: .vertical)
                        .lineLimit(1...3)
                        .font(.zune(.body)).foregroundStyle(.white)
                        .focused($focused)
                        .submitLabel(.send)
                        .onChange(of: q) { _, v in
                            if v.contains("\n") { q = v.replacingOccurrences(of: "\n", with: ""); send() }
                            else if v.count > Taste.askMax { q = String(v.prefix(Taste.askMax)) }
                        }
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { AskKeyboard.shared.field = $0 }
                        .onChange(of: focused) { _, f in AskKeyboard.shared.up = f }
                    if t.asking { ProgressView().tint(.white).frame(width: 44, height: 44) }
                    else {
                        // Dimmed until there's a question to send.
                        Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.zune(size: 32)).foregroundStyle(.white.opacity(ready ? 1 : 0.3)) }
                            .frame(width: 44, height: 44)
                            .disabled(!ready)
                            .accessibilityLabel("Ask")
                    }
                }
                if let e = t.askError { Text(e).font(.zune(.subheadline)).foregroundStyle(S.soft) }
                ForEach(t.kept.asked.prefix(3), id: \.self) { a in
                    VStack(alignment: .leading, spacing: S.pair) {
                        Text(a.q).font(.zune(.subheadline, .semibold)).foregroundStyle(S.soft)
                        Text(a.answer).font(.zune(size: 20, .light)).foregroundStyle(.white.opacity(0.94)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, S.pair)
                }
            }
            .padding(.horizontal, S.margin)
            .id("ask")
        }
    }
    // The words stay in the field until an answer comes; a question that failed is still there to send again.
    private func send() {
        let text = q
        guard ready else { return }
        focused = false
        Task { if await Taste.shared.ask(text), q == text { q = "" } }
    }
}
