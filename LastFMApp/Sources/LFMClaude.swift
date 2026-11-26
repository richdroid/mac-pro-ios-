import SwiftUI
import CryptoKit

// What Claude writes about his listening: a portrait of what he plays and the threads through it, a note on his week,
// artists to hear next chosen from Last.fm's similar artists, and a short answer to a question about his own music.
// Written on the Mac by the bridge (lastfm-claude.js, through the local Claude CLI on his plan; Richard, 2026-11-25:
// "dont use api key, figure out alternative way for now") and read here from it over the tailnet address baked into
// the build (DefaultAddress): /api/lastfm/claude for the pieces, /api/lastfm/claude/ask for a question. No key is in the
// app. The last good answers are kept on disk and shown from disk first, so the pieces stay when the Mac can't be
// reached; a piece written while he's in the app shows when he next comes back to it. The mock shows written samples
// about the mock's own artists, for the build's shots.

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
    static let askMax = 200

    // The Mac's bridge, or nil (a build with no address): then nothing of this shows.
    @ObservationIgnored private let bridge: URL? = {
        var a = (UserDefaults.standard.string(forKey: "address") ?? "").trimmingCharacters(in: .whitespaces)
        if a.isEmpty { a = (Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String ?? "").trimmingCharacters(in: .whitespaces) }
        guard !a.isEmpty else { return nil }
        if !a.contains("://") { a = "https://" + a }
        while a.hasSuffix("/") { a.removeLast() }
        return URL(string: a + "/api/lastfm/")
    }()
    let mock = LastFM.shared.mock
    var on: Bool { mock || bridge != nil || store.portrait != nil }
    // The day's questions as the bridge counts them (three on the plan).
    private(set) var asksADay = 3

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

    // The bridge's count when it last answered; on a new day, the whole day's.
    var asksLeft: Int { store.asks.day == LocalDay.today ? max(0, asksADay - store.asks.n) : asksADay }

    // MARK: Refresh

    // On launch and on coming back: the bridge's pieces as it holds them now (it writes them again behind the answer when
    // they're due). Nothing reached: the kept ones stand.
    func refresh() async {
        guard let bridge, !mock, !busy.contains("all") else { return }
        busy.insert("all"); defer { busy.remove("all") }
        var r = URLRequest(url: bridge.appendingPathComponent("claude")); r.timeoutInterval = 20
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        func at(_ p: [String: Any]) -> Date { Date(timeIntervalSince1970: (p["at"] as? Double ?? 0) / 1000) }
        func ready(_ k: String) -> [String: Any]? { (o[k] as? [String: Any]).flatMap { $0["ready"] as? Bool == true ? $0 : nil } }
        let first = store.portrait == nil && store.week == nil && store.discovery == nil
        if let p = ready("portrait"), let lines = p["lines"] as? [String], !lines.isEmpty {
            store.portrait = .init(data: lines.map(Self.line), at: at(p), sig: String(p["at"] as? Int ?? 0))
            store.threads = ((p["threads"] as? [[String: Any]]) ?? []).compactMap { t in
                guard let n = t["name"] as? String, let a = t["artists"] as? [String] else { return nil }
                return TasteThread(name: n, artists: a, note: t["note"] as? String ?? "")
            }
        }
        if let p = ready("week"), let note = p["note"] as? String, !note.isEmpty { store.week = .init(data: Self.line(note), at: at(p), sig: String(p["at"] as? Int ?? 0)) }
        if let p = ready("discovery"), let picks = p["picks"] as? [[String: Any]] {
            let list = picks.compactMap { x -> TastePick? in
                guard let a = x["artist"] as? String else { return nil }
                return TastePick(artist: a, like: x["like"] as? String ?? "", why: x["why"] as? String ?? "")
            }
            if !list.isEmpty { store.discovery = .init(data: list, at: at(p), sig: String(p["at"] as? Int ?? 0)) }
        }
        if let a = o["ask"] as? [String: Any] { counted(a) }
        save()
        // Nothing was showing yet: shown now (nothing on the page to move).
        if first { kept = store; await findArt() }
    }

    // The bridge's count of the day's questions.
    private func counted(_ a: [String: Any]) {
        if let n = a["aDay"] as? Int, n > 0 { asksADay = n }
        if let left = a["left"] as? Int { store.asks = (LocalDay.today, max(0, asksADay - left)) }
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
        guard let bridge else { return false }
        guard asksLeft > 0 else { askError = "That's the \(asksADay) questions for today."; return false }
        asking = true; defer { asking = false }
        var r = URLRequest(url: bridge.appendingPathComponent("claude/ask"))
        r.httpMethod = "POST"; r.timeoutInterval = 90
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["q": q])
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { askError = "Couldn't reach the Mac. Try again in a while."; return false }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            askError = "Couldn't answer that one. Try asking another way."; return false
        }
        counted(o)
        let answer = Self.line(o["answer"] as? String ?? "")
        guard o["ok"] as? Bool == true, !answer.isEmpty else {
            let reason = o["reason"] as? String ?? ""
            askError = reason.contains("for today") ? "That's the \(asksADay) questions for today." : "Couldn't answer just now. Try again in a while."
            save(); return false
        }
        store.asked.insert(TasteAsked(q: q, answer: answer, day: LocalDay.today), at: 0)
        store.asked = Array(store.asked.prefix(3)); save()
        withAnimation(.smooth) { kept.asked = store.asked }
        return true
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
