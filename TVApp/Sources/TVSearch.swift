import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// One search for everything the TV can put on: shows, films, music, YouTube and the TV's own apps, in the Search tab
// (Richard, 2026-11-11: "the search function in tv is fucked and unintuitive"). Before it there were four: the Apps
// page's bar (films, shows and music, each keystroke blanking the page to a spinner while all three were asked again),
// Watch's (films or shows, whichever the switch said), and Stremio's and Mint's own pages. Now every one of those fields
// opens this.
//
// What it does as he types: what the phone already knows answers at once (Continue watching, Watch's rows, Mint's,
// what was flicked, the TV's apps, and every answer the Mac has given before, typo-tolerant), and the last answer stays
// up, narrowed to the new words, while the Mac is asked; the Mac's answer replaces it when it comes. Nothing goes blank
// and "No results" is only said once every source has answered and nothing matches.

// MARK: - Matching

struct SearchQuery: Equatable {
    // The words, folded: lower case, no accents or punctuation, "&" as "and".
    var words: String
    // "s2e5", "2x5" or "season 2 episode 5" at the end of what's typed.
    var season: Int?
    var episode: Int?
}

enum SearchMatch {
    nonisolated static func fold(_ s: String) -> String {
        let t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
        var out = ""
        var space = false
        for ch in t {
            if ch.isLetter || ch.isNumber { out.append(ch); space = false }
            else if ch == "'" || ch == "’" { continue }
            else if !space && !out.isEmpty { out.append(" "); space = true }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
    private nonisolated static let episodePattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:s(?:eason)?\s*(\d{1,2})\s*(?:e(?:p(?:isode)?)?\s*(\d{1,3})?)?|(\d{1,2})x(\d{1,3})?)\s*$"#, options: .caseInsensitive)
    nonisolated static func parse(_ text: String) -> SearchQuery {
        let f = fold(text)
        let ns = f as NSString
        if let m = episodePattern.firstMatch(in: f, range: NSRange(location: 0, length: ns.length)) {
            func n(_ i: Int) -> Int? { let r = m.range(at: i); return r.location == NSNotFound ? nil : Int(ns.substring(with: r)) }
            let words = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            // A season alone ("s2") only counts with a name before it; "s" on its own is a word being typed.
            if !words.isEmpty, let s = n(1) ?? n(3) { return SearchQuery(words: words, season: s, episode: n(2) ?? n(4)) }
        }
        return SearchQuery(words: f)
    }
    private nonisolated static func dropThe(_ s: String) -> String { s.hasPrefix("the ") ? String(s.dropFirst(4)) : s }
    // How well a title answers the words: 100 the very title, 90 its start, 80 the start of each word, 65 inside it,
    // 40–55 a slip of a key or two. nil when it doesn't answer.
    nonisolated static func score(_ title: String, _ q: String) -> Int? {
        guard !q.isEmpty else { return nil }
        let t = fold(title)
        guard !t.isEmpty else { return nil }
        if t == q { return 100 }
        let bt = dropThe(t), bq = dropThe(q)
        if bt == bq { return 98 }
        if t.hasPrefix(q) || bt.hasPrefix(bq) { return 90 }
        let tw = t.split(separator: " "), qw = q.split(separator: " ")
        if qw.allSatisfy({ w in tw.contains { $0.hasPrefix(w) } }) { return qw.count > 1 ? 80 : 72 }
        if t.contains(q) { return 65 }
        // A slip: the words against the start of the title, or against any of its words, by edits.
        let allowed = q.count <= 3 ? 0 : q.count <= 6 ? 1 : 2
        guard allowed > 0 else { return nil }
        let qa = Array(bq)
        var best = Int.max
        best = min(best, distance(qa, Array(bt.prefix(qa.count)), limit: allowed))
        best = min(best, distance(qa, Array(bt), limit: allowed))
        if qw.count == 1 { for w in tw { best = min(best, distance(qa, Array(w.prefix(qa.count + 1)), limit: allowed), distance(qa, Array(w), limit: allowed)) } }
        return best <= allowed ? 55 - best * 8 : nil
    }
    // Edits (with a swap of two keys counting as one) between two strings, stopping once past `limit`.
    nonisolated static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            prev2 = prev; prev = cur
        }
        return prev[b.count]
    }
}

// MARK: - Results

struct SearchHit: Identifiable, Hashable {
    enum Kind: String { case show, film, music, video, app }
    let kind: Kind
    let item: MediaItem
    // How well it matched (SearchMatch.score), how much it's his (Continue watching, flicked, his lists), and where the
    // source put it (the catalogue's own order is by popularity).
    let match: Int
    let mine: Int
    let order: Int
    // A show asked for at an episode ("the bear s2e5").
    var season: Int?
    var episode: Int?
    var id: String { kind.rawValue + ":" + (item.stremioRef?.imdb ?? item.id) }
    var source: MediaSource { kind == .music ? .mint : .stremio }
    // Exact first, then strong matches with his own first, then everything else.
    // On a tie, an app named exactly, then a show or film, then a video, then music.
    var rank: (Int, Int, Int, Int, Int, Int) {
        let pref = kind == .app ? 3 : kind == .show || kind == .film ? 2 : kind == .video ? 1 : 0
        return (match >= 98 ? 1 : 0, match >= 72 ? 2 : match >= 60 ? 1 : 0, mine, match, pref, -order)
    }
    static func better(_ a: SearchHit, _ b: SearchHit) -> Bool { a.rank > b.rank }
    // What one tap does, said on the top result.
    var action: String {
        switch kind {
        case .show:
            if let s = season, let e = episode { return "S\(s) E\(e) · Choose a stream" }
            if let s = season { return "Season \(s) · Choose an episode" }
            return mine >= 30 ? "Carry on · Choose an episode" : "Choose an episode"
        case .film: return "Choose a stream"
        case .music: return "Play on the TV"
        case .video: return "Play on the TV"
        case .app: return "Open on the TV"
        }
    }
    var kindName: String {
        switch kind {
        case .show: return "Show"
        case .film: return "Film"
        case .music: return item.kind == "song" ? "Song" : item.kind == "album" ? "Album" : "Music"
        case .video: return "YouTube"
        case .app: return "App"
        }
    }
    // The line under the name: what it is, and the useful bit of what came with it.
    var line: String {
        var parts: [String] = []
        if kind != .app { parts.append(kindName) }
        let sub = item.shownSubtitle
        if !sub.isEmpty { parts.append(sub) }
        if kind == .app { parts.append("On the TV") }
        return parts.joined(separator: " · ")
    }
}

struct SearchResults: Equatable {
    var text = ""
    var top: SearchHit?
    struct Group: Identifiable { let kind: SearchHit.Kind; let hits: [SearchHit]; var id: SearchHit.Kind { kind } }
    var groups: [Group] = []
    // Every source has answered these words: only then can nothing found be said.
    var settled = false
    // Too short to ask the Mac (one letter): what the phone knows, or nothing, and no waiting shapes.
    var short = false
    // The Mac couldn't be asked.
    var offline = false
    var isEmpty: Bool { top == nil && groups.allSatisfy { $0.hits.isEmpty } }
    static func == (a: SearchResults, b: SearchResults) -> Bool {
        a.text == b.text && a.settled == b.settled && a.offline == b.offline && a.top?.id == b.top?.id && a.groups.map(\.kind) == b.groups.map(\.kind)
            && a.groups.map { $0.hits.map(\.id) } == b.groups.map { $0.hits.map(\.id) }
    }
    static func title(_ k: SearchHit.Kind) -> String {
        switch k { case .show: return "Shows"; case .film: return "Films"; case .music: return "Music"; case .video: return "YouTube"; case .app: return "Apps on the TV" }
    }
}

// MARK: - The store

@MainActor
final class SearchStore: ObservableObject {
    static let shared = SearchStore()
    @Published private(set) var results = SearchResults()
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    // What the Mac said for some words, by part. Kept on the phone, so a search made before answers at once next time.
    struct Answer: Codable {
        var films: [MediaItem]?
        var shows: [MediaItem]?
        var music: [MediaItem]?
        var youtube: [MediaItem]?
        var at = Date()
        // Films and shows couldn't be had from the Mac: never kept, and asked again.
        var offline: Bool?
        var complete: Bool { films != nil && shows != nil && music != nil && youtube != nil }
    }
    private var answers: [String: Answer] = [:]
    private var asked: [String: Date] = [:]
    private var debounce: Task<Void, Never>?
    private var text = ""
    // When the words now on screen were typed, for the time to the first results.
    private var typedAt = Date()
    private var timed = false
    private weak var model: TVModel?
    private static var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tv-search-answers.json")
    }
    private var sample: Bool { ["127.0.0.1", "localhost"].contains(where: { TVBridge.address.contains($0) }) }
    init() {
        guard !sample, let f = Self.file else { return }
        Task { [weak self] in
            let kept: [String: Answer]? = await Task.detached(priority: .utility) {
                guard let d = try? Data(contentsOf: f) else { return nil }
                return try? JSONDecoder().decode([String: Answer].self, from: d)
            }.value
            guard let self, let kept else { return }
            for (k, v) in kept where self.answers[k] == nil { self.answers[k] = v }
        }
    }
    private var saving: Task<Void, Never>?
    private func saveSoon() {
        guard !sample, let f = Self.file else { return }
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            // The newest forty searches, the ones worth having at once.
            let keep = Dictionary(uniqueKeysWithValues: self.answers.sorted { $0.value.at > $1.value.at }.prefix(40).map { ($0.key, $0.value) })
            Task.detached(priority: .utility) { if let d = try? JSONEncoder().encode(keep) { try? d.write(to: f, options: .atomic) } }
        }
    }

    // The words in the field changed.
    func typed(_ raw: String, model: TVModel) {
        self.model = model
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != text else { return }
        text = t
        typedAt = Date(); timed = false
        rebuild()
        debounce?.cancel()
        let q = SearchQuery.key(t)
        guard q.count >= 2, !SendBar.isLink(t) else { return }
        // What's already been answered needs no asking; anything else, once the keys pause for a moment.
        if let a = answers[q], a.complete, a.offline != true, Date().timeIntervalSince(a.at) < 600 { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            self?.ask(q)
        }
    }
    private func ask(_ q: String) {
        if let at = asked[q], Date().timeIntervalSince(at) < 20 { return }
        asked[q] = Date()
        let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        func items(_ d: Data?) -> [MediaItem]? {
            guard let d, let a = try? JSONDecoder().decode(BrowseAnswerRows.self, from: d) else { return nil }
            return a.rows.flatMap(\.items)
        }
        // Films and shows come from the same catalogue and are shown together, so one never pushes the other down.
        Task {
            async let f = TVBridge.data(TVBridge.url("/api/tv/discover?type=movie&q=\(enc)"), timeout: 12)
            async let s = TVBridge.data(TVBridge.url("/api/tv/discover?type=series&q=\(enc)"), timeout: 12)
            let (fd, sd) = await (f, s)
            var a = answers[q] ?? Answer()
            let films = items(fd), shows = items(sd)
            a.films = films ?? a.films ?? []; a.shows = shows ?? a.shows ?? []; a.at = Date()
            a.offline = films == nil && shows == nil ? true : nil
            if a.offline == true { asked[q] = nil }
            answers[q] = a
            arrived(q)
        }
        Task {
            let d = await TVBridge.data(TVBridge.url("/api/tv/mint?q=\(enc)"), timeout: 12)
            var a = answers[q] ?? Answer()
            a.music = items(d) ?? a.music ?? []
            answers[q] = a
            arrived(q)
        }
        Task {
            // YouTube's own results, from a Mac that has them; one that doesn't simply has none to give.
            let d = await TVBridge.data(TVBridge.url("/api/tv/youtube-search?q=\(enc)"), timeout: 8)
            var a = answers[q] ?? Answer()
            a.youtube = items(d) ?? a.youtube ?? []
            answers[q] = a
            arrived(q)
        }
    }
    private func arrived(_ q: String) {
        if answers.count > 120, let old = answers.min(by: { $0.value.at < $1.value.at })?.key { answers[old] = nil }
        if answers[q]?.complete == true, answers[q]?.offline != true { saveSoon() }
        // Only redrawn if it's an answer to what's typed, or to words this one grew out of.
        let now = SearchQuery.key(text)
        if now == q || now.hasPrefix(q) || q.hasPrefix(now) { rebuild() }
    }

    // MARK: building what's shown
    private func rebuild() {
        let t = text
        var r = SearchResults(text: t)
        guard !t.isEmpty else { results = r; SendDraft.shared.firstResult = nil; return }
        if SendBar.isLink(t) { r.settled = true; results = r; return }
        let query = SearchMatch.parse(t)
        let q = query.words
        guard !q.isEmpty else { results = r; return }
        let key = SearchQuery.key(t)
        // The Mac's answer to these words, else to the nearest words asked before, part by part.
        let exact = answers[key]
        let near = answers.filter { $0.key != key && (key.hasPrefix($0.key) || $0.key.hasPrefix(key)) }.sorted { $0.key.count > $1.key.count }.map(\.value)
        // An answer to other words only keeps what these words still match; this one's own is shown whole.
        func part(_ get: (Answer) -> [MediaItem]?) -> ([MediaItem], String?) {
            if let e = exact.flatMap(get) { return (e, "") }
            return (near.lazy.compactMap(get).first ?? [], nil)
        }
        let mine = Mine.now()
        var seen = Set<String>()
        var hits: [SearchHit] = []
        func add(_ item: MediaItem, _ kind: SearchHit.Kind, order: Int, haystack: String? = nil) {
            let k = kind.rawValue + ":" + (item.stremioRef?.imdb ?? item.id)
            guard !seen.contains(k) else { return }
            var m = SearchMatch.score(item.title, q)
            if kind == .music || kind == .video {
                // An artist's or a channel's name finds their things too, a little below a title's own.
                if let a = SearchMatch.score(item.subtitle, q) { m = max(m ?? 0, a - 12) }
                if let b = SearchMatch.score(item.title + " " + item.subtitle, q) { m = max(m ?? 0, b - 6) }
            }
            // The Mac's own answer found it by words the title may not hold (a show's original name): it stays, low.
            if m == nil, haystack != nil { m = 30 }
            guard var m else { return }
            // An episode asked for: it's a show that's meant.
            if query.season != nil, kind != .show { m -= 30 }
            seen.insert(k)
            var h = SearchHit(kind: kind, item: item, match: m, mine: mine.weight(item, kind), order: order)
            if kind == .show, let s = query.season { h.season = s; h.episode = query.episode }
            hits.append(h)
        }
        func kindOf(_ i: MediaItem) -> SearchHit.Kind? {
            if i.isYouTube { return .video }
            if i.stremioRef?.type == "series" || i.kind == "series" { return .show }
            if i.stremioRef != nil || i.kind == "movie" { return .film }
            return nil
        }
        // The Mac's answers first, in their own order.
        for (get, kind) in [(\Answer.films, SearchHit.Kind.film), (\.shows, .show), (\.music, .music), (\.youtube, .video)] {
            let (list, whole) = part { $0[keyPath: get] }
            for (n, i) in list.enumerated() { add(i, kind, order: n, haystack: whole) }
        }
        // Then everything the phone knows, which answers the first key at once and forgives a slip.
        for (n, i) in Mine.corpus().enumerated() {
            if let k = i.1 ?? kindOf(i.0) { add(i.0, k, order: 1000 + n) }
        }
        for (n, a) in (model?.status?.apps ?? []).enumerated() where !AppsTab.hidden.contains(a.pkg) {
            let item = MediaItem(title: a.name, subtitle: "", art: TVBridge.url("/api/tv/icon?pkg=\(a.pkg)")?.absoluteString ?? "", id: a.pkg, kind: "app")
            add(item, .app, order: n)
        }
        // Words of one letter only find what's his or what starts with it.
        if q.count < 2 { hits.removeAll { $0.match < 90 && $0.mine == 0 } }
        // Stable, so on a full tie a film (asked first) leads a show of the same name.
        hits = hits.enumerated().sorted { a, b in a.element.rank != b.element.rank ? a.element.rank > b.element.rank : a.offset < b.offset }.map(\.element)
        // The one he most likely means, when it's clear enough: an exact or strong match, or one of his own.
        // A slip of a key on one of his own titles still makes it the one.
        if let first = hits.first, first.match >= 72 || (first.mine > 0 && first.match >= 55) || (first.mine >= 30 && first.match >= 39) {
            r.top = first
            hits.removeFirst()
        }
        let limits: [SearchHit.Kind: Int] = [.show: 12, .film: 12, .music: 12, .video: 8, .app: 4]
        // The groups in the order of their best: the kind he most likely means comes first (the top result's own first).
        var order: [SearchHit.Kind] = r.top.map { [$0.kind] } ?? []
        for h in hits where !order.contains(h.kind) { order.append(h.kind) }
        for k in order {
            let g = hits.filter { $0.kind == k }.prefix(limits[k] ?? 8)
            if !g.isEmpty { r.groups.append(.init(kind: k, hits: Array(g))) }
        }
        r.settled = exact?.complete ?? false
        r.offline = exact?.offline == true
        r.short = key.count < 2
        results = r
        // The first thing found, for the build's search flow to tap as a finger would.
        if let h = r.top ?? r.groups.first?.hits.first { SendDraft.shared.firstResult = (Self.target(h), h.source) } else { SendDraft.shared.firstResult = nil }
        if let top = r.top, top.kind == .film || top.kind == .show { prefetch(top) }
        if !timed, !r.isEmpty {
            timed = true
            let ms = Int(Date().timeIntervalSince(typedAt) * 1000)
            let how = exact?.complete == true ? "cached" : exact != nil || !near.isEmpty ? "near" : "local"
            Self.report(ms: ms, how: how, text: t)
        }
    }
    private var prefetched: String?
    private func prefetch(_ h: SearchHit) {
        guard prefetched != h.id else { return }
        prefetched = h.id
        let id = h.id
        Task {
            // Still the top after a breath: its streams (or its episodes) asked for now, so the tap finds them.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard results.top?.id == id else { return }
            let target = Self.target(h)
            if h.kind == .film || (h.kind == .show && h.episode != nil) { StreamCache.shared.prefetch(target) }
            else if h.kind == .show, let imdb = target.stremioRef?.imdb { _ = await NextUp.meta(imdb) }
        }
    }
    // For the build's timing: keystroke to the first results on screen, in the stand-in Mac's log.
    private static func report(ms: Int, how: String, text: String) {
        #if os(iOS)
        HitchLog.shared.note("search \(text) first results \(ms) ms (\(how))")
        #endif
        guard UserDefaults.standard.string(forKey: "pose") != nil else { return }
        let t = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        Task { _ = await TVBridge.data(TVBridge.url("/api/tv/applied?what=search&ms=\(ms)&how=\(how)&text=\(t)"), timeout: 3) }
    }

    // MARK: what a tap does
    // The card the flick is given: a show as itself, so it opens on its episodes at the one he's up to; at an episode
    // when one was asked for; anything else as it came.
    static func target(_ h: SearchHit) -> MediaItem {
        let i = h.item
        guard h.kind == .show, let imdb = i.stremioRef?.imdb else { return i }
        if let s = h.season, let e = h.episode {
            return MediaItem(title: i.title, subtitle: "S\(s) E\(e)", art: i.art, id: NextUp.link(imdb, "\(imdb):\(s):\(e)"), kind: "series", about: i.about)
        }
        return MediaItem(title: i.title, subtitle: i.subtitle, art: i.art, id: imdb, kind: "series", about: i.about)
    }
    // He's done something on the page (tapped, scrolled, sent): the keyboard is never brought back for him after that.
    var touched = false
    func open(_ h: SearchHit, model: TVModel, origin: CGRect?) {
        touched = true
        remember()
        if h.kind == .app {
            // On the TV now: nothing left behind here, and the Remote to drive it, as every other "on the TV" does.
            Keyboard.dismiss()
            model.tick(); model.opening(h.item.id); model.post("open", ["pkg": h.item.id])
            model.tab = 0
            return
        }
        FlickCardButton.tap(model, Self.target(h), h.source, origin: origin)
    }
    // MARK: recent searches
    func remember(_ words: String? = nil) {
        let t = (words ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, !SendBar.isLink(t) else { return }
        recent = Array(([t] + recent.filter { $0.caseInsensitiveCompare(t) != .orderedSame }).prefix(8))
        UserDefaults.standard.set(recent, forKey: "recentSearches")
    }
    func forget(_ t: String) {
        recent.removeAll { $0 == t }
        UserDefaults.standard.set(recent, forKey: "recentSearches")
    }
    func forgetAll() { recent = []; UserDefaults.standard.set(recent, forKey: "recentSearches") }

    // From any field that used to search on its own (Apps, Watch, Stremio's and Mint's pages, the Remote): the Search
    // tab, with the keyboard up.
    static func show(_ model: TVModel, text: String? = nil) {
        model.tick()
        if let text { SendDraft.shared.text = text }
        shared.touched = false
        SendDraft.shared.wantsFocus = true; SendDraft.shared.focusRequest += 1
        model.browsing = nil
        model.tab = 6
    }
}
private struct BrowseAnswerRows: Decodable { let rows: [MediaRow] }

extension SearchQuery {
    // What the Mac is asked: the words only (an episode is chosen on the phone), folded.
    static func key(_ text: String) -> String { SearchMatch.parse(text).words }
}

// What's his, for the ranking and for answering the first key at once.
@MainActor
enum Mine {
    struct Weights {
        var by: [String: Int] = [:]
        func weight(_ i: MediaItem, _ k: SearchHit.Kind) -> Int { by[i.stremioRef?.imdb ?? i.id] ?? by[SearchMatch.fold(i.title) + "|" + k.rawValue] ?? 0 }
    }
    static func now() -> Weights {
        var w = Weights()
        func put(_ key: String, _ v: Int) { w.by[key] = max(w.by[key] ?? 0, v) }
        let home = BrowseStore.shared(.stremio).rows
        for r in home {
            let base = r.title == "Continue watching" ? 40 : ["Your watchlist", "Recommended for you", "From your friends"].contains(r.title) ? 8 : 0
            guard base > 0 else { continue }
            for (n, i) in r.items.enumerated() { put(i.stremioRef?.imdb ?? i.id, base - min(n, 10)) }
        }
        for (n, f) in RecentFlicks.shared.list.enumerated() { put(f.imdb, 30 - n) }
        for r in BrowseStore.shared(.mint).rows where r.title == "Recently played" {
            for (n, i) in r.items.enumerated() { put(i.id, 20 - min(n, 10)); put(SearchMatch.fold(i.title) + "|music", 20 - min(n, 10)) }
        }
        return w
    }
    // Everything already on the phone, his own first.
    static func corpus() -> [(MediaItem, SearchHit.Kind?)] {
        var out: [(MediaItem, SearchHit.Kind?)] = []
        out += RecentFlicks.shared.list.map { ($0.item, $0.type == "series" ? .show : .film) }
        for r in BrowseStore.shared(.stremio).rows { out += r.items.map { ($0, nil) } }
        for t in ["series", "movie"] { for r in BrowseStore.discover(t).rows { out += r.items.map { ($0, nil) } } }
        for r in BrowseStore.shared(.mint).rows { out += r.items.map { ($0, .music) } }
        return out
    }
}

// MARK: - The page

struct SearchPage: View {
    @Environment(TVModel.self) var model
    @Environment(\.paneLayout) private var panes
    @ObservedObject private var draft = SendDraft.shared
    @ObservedObject private var store = SearchStore.shared
    @FocusState private var focused: Bool
    var body: some View {
        // The field stays put above what scrolls, as the system's own search does. Inside the scroll view, open upright
        // the keyboard's own lift scrolled the page, and a scroll that puts the keyboard away put it away at once
        // (tv-search-ci 829e7c4 and e40ae26: focus on, then off, in every open-upright pose; the probe's field above the
        // list kept it).
        Group {
            if panes {
                FoldSplit {
                    VStack(alignment: .leading, spacing: 14) {
                        field.padding(.top, 12)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                if draft.text.isEmpty { RecentSearches(store: store) } else { ResultList(results: store.results, part: .left) }
                            }
                            .padding(.bottom, 12)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .backToTop(posed: false)
                    }
                } right: {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if draft.text.isEmpty { SearchSuggestions() } else { ResultList(results: store.results, part: .right) }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .backToTop()
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    field.padding(.top, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if draft.text.isEmpty {
                                RecentSearches(store: store)
                                SearchSuggestions()
                            } else {
                                ResultList(results: store.results, part: .all)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .backToTop()
                }
            }
        }
        .onChange(of: draft.text, initial: true) { _, t in store.typed(t, model: model) }
        .onScrollPhaseChange { _, p in if p == .interacting { store.touched = true } }
        // Continue watching there on the first frame, not cut in under the page later.
        .task { await BrowseStore.shared(.stremio).loadHome() }
        // The tab opened straight (at launch, or before anything asked for the keyboard): the field takes it.
        .onAppear { if !draft.wantsFocus { draft.wantsFocus = true; draft.focusRequest += 1 } }
    }
    var link: Bool { SendBar.isLink(draft.text) }
    var field: some View {
        HStack(spacing: 8) {
            Image(systemName: link ? "paperplane" : "magnifyingglass").foregroundStyle(.secondary).padding(.leading, 14)
                .contentTransition(.symbolEffect(.replace))
            TextField(panes ? "Search" : "Shows, films, music, apps", text: $draft.text)
                .focused($focused).autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(link ? .send : .search)
                .hidesTabBar(while: focused, "search")
                .onChange(of: focused) { _, on in
                    if UserDefaults.standard.string(forKey: "pose") != nil { Task { _ = await TVBridge.data(TVBridge.url("/api/tv/applied?what=focus&on=\(on ? 1 : 0)"), timeout: 3) } }
                }
                // Return sends a link; for words it does the obvious thing with the top result, as a tap on it would.
                .onSubmit {
                    store.touched = true
                    if link { Keyboard.dismiss(); model.send(draft.text); draft.text = "" }
                    else if let h = store.results.top { store.open(h, model: model, origin: nil) }
                    else { store.remember(); focused = false }
                }
                // The keyboard comes up when the tab is opened from any other field, and when the tab itself is tapped:
                // asked for until the field has it, as the Apps page's field did (open upright it came on some runs only).
                // Open upright the field took the keyboard and lost it again half a second later as the tab settled
                // (tv-search-ci 829e7c4: focus on, then off, in every open-upright pose), so it's held for the first
                // three seconds, and given back if it goes.
                .task(id: draft.focusRequest) {
                    guard draft.wantsFocus else { return }
                    store.touched = false
                    focused = true
                    var held = 0
                    for _ in 0..<12 {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        // Taken down mid-ask (open upright the page is first laid out as two panes, then as one, and the
                        // field is rebuilt): the request stays for the field that replaces it, which carries on with it.
                        if Task.isCancelled { return }
                        // Never once he's tapped, scrolled or sent something, and never while a flick is up.
                        if store.touched || model.flicking != nil { break }
                        if !focused { focused = true; held = 0 } else { held += 1 }
                        if held >= 6 { break }
                    }
                    draft.wantsFocus = false
                }
            if draft.text.isEmpty {
                // The system's own paste key: no "Allow Paste" question each time. A link goes to the TV, words are searched.
                PasteButton(payloadType: String.self) { got in
                    guard let s = got.first?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
                    Task { @MainActor in
                        if SendBar.isLink(s) { store.touched = true; Keyboard.dismiss(); model.send(s) } else { draft.text = s }
                    }
                }
                .labelStyle(.iconOnly).buttonBorderShape(.circle).tint(TVLook.accent.opacity(0.25)).padding(.trailing, 4)
            } else if link {
                Button { store.touched = true; Keyboard.dismiss(); model.send(draft.text); draft.text = "" } label: { Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(TVLook.accent).accessibilityLabel("Send to the TV")
            } else {
                Button { draft.text = ""; focused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .frame(height: 50)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 20)
        .animation(.easeOut(duration: 0.2), value: link)
        .animation(.easeOut(duration: 0.2), value: draft.text.isEmpty)
    }
}

// Every other search field in the app: it looks the same and opens the one search.
struct OpensSearchField: View {
    @Environment(TVModel.self) var model
    var prompt = "Shows, films, music, apps"
    var body: some View {
        Button { SearchStore.show(model, text: "") } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(prompt).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(height: 46).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Search")
    }
}

// What's found, grouped. Open flat, the top result on the left and the groups on the right.
private struct ResultList: View {
    @Environment(TVModel.self) var model
    enum Part { case all, left, right }
    let results: SearchResults
    let part: Part
    @State private var opened: Set<SearchHit.Kind> = []
    // Open flat: the top result under the field on the left, every group on the right, so neither side sits empty.
    var showsGroups: Bool { part != .left }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if SendBar.isLink(results.text) {
                if part != .right { LinkRow(text: results.text) }
            } else {
                if part != .right, let top = results.top { TopHit(hit: top).transition(.opacity) }
                ForEach(showsGroups ? results.groups : []) { g in
                    let open = opened.contains(g.kind)
                    let few = 4
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            RowTitle(SearchResults.title(g.kind))
                            Spacer()
                            if g.hits.count > few {
                                Button(open ? "Show fewer" : "Show all \(g.hits.count)") {
                                    model.tick()
                                    withAnimation(.snappy) { if open { opened.remove(g.kind) } else { opened.insert(g.kind) } }
                                }
                                .font(.subheadline.weight(.semibold)).tint(TVLook.accent)
                            }
                        }
                        .padding(.horizontal, 20)
                        VStack(spacing: 4) {
                            ForEach(open ? g.hits : Array(g.hits.prefix(few))) { h in HitRow(hit: h) }
                        }
                        .padding(.horizontal, 12)
                    }
                    .transition(.opacity)
                }
                if part != .left, results.isEmpty, !results.short {
                    if results.offline {
                        ContentUnavailableView("Can’t reach the Mac", systemImage: "wifi.exclamationmark", description: Text("Is Tailscale on?")).frame(maxWidth: .infinity).padding(.top, 30)
                    } else if results.settled {
                        ContentUnavailableView.search(text: results.text).frame(maxWidth: .infinity).padding(.top, 30)
                    } else {
                        // Asked and on its way: the shape of the rows, never a blank page or a spinner box.
                        VStack(spacing: 4) { ForEach(0..<4, id: \.self) { _ in HitRowWait() } }.padding(.horizontal, 12).transition(.opacity)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.28), value: results)
        // "Show all" is for these words: new words start folded again.
        .onChange(of: SearchQuery.key(results.text)) { _, _ in if !opened.isEmpty { opened = [] } }
    }
}

// The one he most likely means, larger, saying what a tap does.
private struct TopHit: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var store = SearchStore.shared
    let hit: SearchHit
    @State private var place = FrameBox()
    var body: some View {
        Button { store.open(hit, model: model, origin: place.rect) } label: {
            HStack(alignment: .top, spacing: 14) {
                HitArt(hit: hit, height: 118)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { place.rect = $0 }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Top result").font(.footnote.weight(.semibold)).foregroundStyle(TVLook.accent)
                    Text(hit.item.title).font(.title3.weight(.bold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(hit.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Label(hit.action, systemImage: hit.kind == .app ? "tv" : "play.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(TVLook.accent, in: Capsule())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(minHeight: 142)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: TVLook.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: TVLook.card, style: .continuous))
        }
        .buttonStyle(PressCard(onPress: hit.kind == .film ? { StreamCache.shared.prefetch(SearchStore.target(hit)); Prepare.arm() } : nil))
        .padding(.horizontal, 12)
        .accessibilityLabel("\(hit.item.title), \(hit.line). \(hit.action)")
    }
}

private struct HitRow: View {
    @Environment(TVModel.self) var model
    let hit: SearchHit
    @State private var place = FrameBox()
    var body: some View {
        Button { SearchStore.shared.open(hit, model: model, origin: place.rect) } label: {
            HStack(spacing: 12) {
                HitArt(hit: hit, height: 60)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { place.rect = $0 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.item.title).font(.body.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(hit.line).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if hit.mine >= 30 && hit.kind != .music {
                    Image(systemName: "clock.arrow.circlepath").font(.footnote.weight(.semibold)).foregroundStyle(TVLook.accent)
                        .accessibilityLabel("You’re watching this")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressCard(onPress: hit.kind == .film ? { StreamCache.shared.prefetch(SearchStore.target(hit)); Prepare.arm() } : nil))
        .accessibilityLabel("\(hit.item.title), \(hit.line)")
    }
}
private struct HitRowWait: View {
    var body: some View {
        HStack(spacing: 12) {
            CoverWait().frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(.white.opacity(0.1)).frame(width: 160, height: 12)
                Capsule().fill(.white.opacity(0.07)).frame(width: 90, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6).frame(minHeight: 72)
        .accessibilityHidden(true)
    }
}

// Each kind in its own shape: a poster, a square cover, a wide still, an app's banner.
private struct HitArt: View {
    let hit: SearchHit
    let height: CGFloat
    var width: CGFloat {
        switch hit.kind {
        case .show, .film: return height * 2 / 3
        case .music: return height
        case .video, .app: return height * 16 / 9
        }
    }
    var body: some View {
        Group {
            if hit.item.art.isEmpty { CoverFallback(title: hit.item.title, tint: CoverWait.band) }
            else { Art(url: URL(string: hit.item.art)) { $0.resizable().scaledToFill() } placeholder: { CoverWait() } }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: height > 80 ? 9 : 6, style: .continuous))
        .overlay(alignment: .bottom) {
            if let p = hit.item.progress, p > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) { Color.white.opacity(0.25); TVLook.accent.frame(width: g.size.width * min(p, 1)) }
                }
                .frame(height: 3).clipShape(RoundedRectangle(cornerRadius: 1.5))
            }
        }
    }
}

private struct LinkRow: View {
    @Environment(TVModel.self) var model
    let text: String
    var body: some View {
        Button { SearchStore.shared.touched = true; Keyboard.dismiss(); model.send(text); SendDraft.shared.text = "" } label: {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill").font(.title3).foregroundStyle(.black.opacity(0.85))
                    .frame(width: 48, height: 48).background(TVLook.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to the TV").font(.body.weight(.semibold))
                    Text(LinkPeek.site(text)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: TVLook.card, style: .continuous))
        }
        .buttonStyle(PressCard())
        .padding(.horizontal, 12)
    }
}

// Before anything is typed: the searches he made lately, one tap to make again.
private struct RecentSearches: View {
    @ObservedObject var store: SearchStore
    var body: some View {
        if !store.recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    RowTitle("Recent searches")
                    Spacer()
                    Button("Clear") { withAnimation(.snappy) { store.forgetAll() } }.font(.subheadline.weight(.semibold)).tint(TVLook.accent)
                }
                .padding(.horizontal, 20)
                ForEach(store.recent, id: \.self) { t in
                    HStack(spacing: 12) {
                        Button { SendDraft.shared.text = t } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 24)
                                Text(t).font(.body).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { withAnimation(.snappy) { store.forget(t) } } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 44, height: 44) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(t)")
                    }
                    .padding(.leading, 20).padding(.trailing, 8)
                }
            }
            .transition(.opacity)
        }
    }
}

// Before anything is typed: what he's in the middle of, each a tap from carrying on, and what was flicked lately.
private struct SearchSuggestions: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var home = BrowseStore.shared(.stremio)
    @ObservedObject private var flicks = RecentFlicks.shared
    var continuing: [MediaItem] { Array((home.rows.first { $0.title == "Continue watching" }?.items ?? []).prefix(5)) }
    var flicked: [MediaItem] {
        let skip = Set(continuing.compactMap { $0.stremioRef?.imdb })
        return Array(flicks.list.filter { !skip.contains($0.imdb) }.prefix(4).map(\.item))
    }
    func hit(_ i: MediaItem, mine: Int) -> SearchHit {
        let k: SearchHit.Kind = i.isYouTube ? .video : i.stremioRef?.type == "series" || i.kind == "series" ? .show : .film
        return SearchHit(kind: k, item: i, match: 0, mine: mine, order: 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !continuing.isEmpty { list("Continue watching", continuing.map { hit($0, mine: 40) }, carryOn: true) }
            if !flicked.isEmpty { list("Recently flicked", flicked.map { hit($0, mine: 30) }, carryOn: false) }
        }
    }
    func list(_ title: String, _ hits: [SearchHit], carryOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RowTitle(title).padding(.horizontal, 20)
            VStack(spacing: 4) {
                ForEach(hits) { h in
                    // Continue watching's tap is its own: the streams of the episode he's up to, as everywhere else.
                    if carryOn { SuggestionRow(hit: h) } else { HitRow(hit: h) }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}
private struct SuggestionRow: View {
    @Environment(TVModel.self) var model
    let hit: SearchHit
    @State private var place = FrameBox()
    var body: some View {
        Button { FlickCardButton.tap(model, hit.item, .stremio, origin: place.rect) } label: {
            HStack(spacing: 12) {
                HitArt(hit: hit, height: 60)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { place.rect = $0 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.item.title).font(.body.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(hit.item.shownSubtitle.isEmpty ? hit.kindName : hit.item.shownSubtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6).frame(minHeight: 72).contentShape(Rectangle())
        }
        .buttonStyle(PressCard(onPress: { if !model.isOnTV(hit.item, .stremio) { StreamCache.shared.prefetch(hit.item); Prepare.arm() } }))
        .onAppear { if hit.item.progress != nil, hit.kind == .show { NextUp.prefetch(hit.item) } }
    }
}

// MARK: - Descriptions that open where they are

// A show's or a film's words: a few lines, and a tap opens the rest right there, and closes it again. Never a page
// pushed over it or a sheet (Richard, 2026-11-11: "the description like expansion shouldnt come via the form of like
// another screen"). What else is known of it (who's in it, who made it) comes in under the words when it's open.
struct ExpandingText<Extra: View>: View {
    @Environment(TVModel.self) var model
    let text: String
    var lines = 4
    var font: Font = .subheadline
    var reserves = false
    // There's more to open than the words (who's in it, who made it): "More" is offered even when the words fit.
    var more = false
    @ViewBuilder var extra: () -> Extra
    @State private var open = false
    @State private var full: CGFloat = 0
    @State private var short: CGFloat = 0
    var cut: Bool { more || full > short + 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(font).foregroundStyle(.secondary)
                .modifier(Lines(limit: open ? nil : lines, reserves: reserves))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !open { short = $0 } }
                // The whole of it, unseen, to know whether there's more than the lines shown.
                .background(alignment: .topLeading) {
                    Text(text).font(font).fixedSize(horizontal: false, vertical: true).hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full = $0 }
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            if open { extra().transition(.opacity.combined(with: .move(edge: .top))) }
            // Its line held from the start where the page reserves room, so working out whether it's needed never moves
            // what's under it (the review of 829e7c4: the flick's heading dropped 10 pt after landing).
            if cut || open || reserves {
                Text(open ? "Less" : "More").font(.footnote.weight(.semibold)).foregroundStyle(TVLook.accent)
                    .opacity(cut || open ? 1 : 0)
                    .contentTransition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard cut || open else { return }
            model.tick()
            withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { open.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(cut || open ? .isButton : [])
        .accessibilityHint(cut ? (open ? "Shows less" : "Shows the whole description") : "")
        .onChange(of: text) { _, _ in if open { open = false } }
        // For the build's films: the words opened, then closed again, as a finger would.
        .task {
            guard UserDefaults.standard.string(forKey: "pose") == "blurbopen" else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { open = true }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { open = false }
        }
    }
}
private struct Lines: ViewModifier {
    let limit: Int?
    let reserves: Bool
    func body(content: Content) -> some View {
        if let limit, reserves { content.lineLimit(limit, reservesSpace: true) } else { content.lineLimit(limit) }
    }
}
extension ExpandingText where Extra == EmptyView {
    init(text: String, lines: Int = 4, font: Font = .subheadline, reserves: Bool = false) {
        self.init(text: text, lines: lines, font: font, reserves: reserves, more: false) { EmptyView() }
    }
}

// Who's in it and who made it, under a description opened in place: what the details page held besides the words.
struct TitleFacts: View {
    let type: String
    let imdb: String
    @State private var info: TitleInfo?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let info {
                HStack(spacing: 10) {
                    if let r = info.imdbRating, !r.isEmpty {
                        Label(r, systemImage: "star.fill").labelStyle(.titleAndIcon).font(.footnote.weight(.bold)).foregroundStyle(Color(hex: 0xF5C518))
                    }
                    if !info.facts.isEmpty { Text(info.facts).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                }
                if let c = info.cast, !c.isEmpty { fact("With", c.prefix(6).joined(separator: ", ")) }
                if let d = info.director, !d.isEmpty { fact("Directed by", d.joined(separator: ", ")) }
            }
        }
        .task(id: imdb) {
            if let c = TitleInfoStore.cached(type, imdb) { info = c; return }
            let i = await TitleInfoStore.load(type, imdb)
            withAnimation(.easeOut(duration: 0.2)) { info = i }
        }
    }
    func fact(_ label: String, _ value: String) -> some View {
        (Text(label + "  ").font(.footnote.weight(.semibold)).foregroundStyle(.secondary) + Text(value).font(.footnote))
            .fixedSize(horizontal: false, vertical: true)
    }
}
