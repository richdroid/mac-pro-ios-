import SwiftUI

// Rediscovery (Richard, 2026-11-24: "making it a good hub for music discovery and rediscovery, be tasteful"): what he
// loved and left, all from his own history on the phone. Forgotten favourites (songs and albums he played a lot and not
// for a year or more), the songs he loved on Last.fm that have gone quiet, this week in each past year, and the artists
// he played a lot who have gone quiet (comebacks). Worked out once a day, off the main thread, once the whole history is
// read: part of it would call a song forgotten that isn't.
struct Rediscovery: Sendable {
    var songs: [Entry] = []
    var albums: [Entry] = []
    var loved: [Entry] = []
    var years: [(year: Int, e: Entry)] = []
    var comebacks: [Entry] = []
}

extension HistoryDB {
    func forgotten(_ kind: Kind, least: Int, quietSince: Int, limit: Int = 12) -> [Entry] {
        var out: [Entry] = []
        let sql = kind == .tracks
            ? "SELECT artist, track, MAX(album), COUNT(*) c, MAX(uts) l, MIN(uts) f FROM plays GROUP BY artist, track HAVING c >= ? AND l < ? ORDER BY c DESC LIMIT ?"
            : "SELECT artist, album, album, COUNT(*) c, MAX(uts) l, MIN(uts) f FROM plays WHERE album != '' GROUP BY artist, album HAVING c >= ? AND l < ? ORDER BY c DESC LIMIT ?"
        rows(sql, [least, quietSince, limit]) { s in
            let artist = text(s, 0), album = text(s, 2)
            out.append(Entry(kind: kind, artist: artist, album: album, track: kind == .tracks ? text(s, 1) : "", plays: int(s, 3), first: int(s, 5), last: int(s, 4)))
        }
        return out.map { e in var e = e; e.image = artURL(e.artist, e.album); return e }
    }
    // Each loved song's plays and last play, for the ones that have gone quiet.
    func quietLoved(_ loved: [(String, String, String?)], quietSince: Int) -> [Entry] {
        var out: [Entry] = []
        for (artist, title, image) in loved {
            var e: Entry?
            rows("SELECT COUNT(*), MAX(uts), MAX(album) FROM plays WHERE artist = ? AND track = ?", [artist, title]) { s in
                let n = int(s, 0), l = int(s, 1)
                if n > 0, l < quietSince { e = Entry(kind: .tracks, artist: artist, album: text(s, 2), track: title, plays: n, image: image, last: l) }
            }
            if var e { if e.image == nil { e.image = artURL(e.artist, e.album) }; out.append(e) }
        }
        return out.sorted { $0.plays > $1.plays }
    }
    // The album he played most in this same week (three days either side of today) in each year before this one.
    func thisWeek(years back: Int, now: Date) -> [(year: Int, e: Entry)] {
        let cal = Calendar.current
        var out: [(Int, Entry)] = []
        for k in 1...max(1, back) {
            guard let d = cal.date(byAdding: .year, value: -k, to: now) else { continue }
            let lo = Int(d.timeIntervalSince1970) - 3 * 86400, hi = Int(d.timeIntervalSince1970) + 4 * 86400
            rows("SELECT artist, album, COUNT(*) c FROM plays WHERE uts BETWEEN ? AND ? AND album != '' GROUP BY artist, album ORDER BY c DESC LIMIT 1", [lo, hi]) { s in
                let e = Entry(kind: .albums, artist: text(s, 0), album: text(s, 1), track: "", plays: int(s, 2))
                out.append((cal.component(.year, from: d), e))
            }
        }
        return out.map { (y, e) in var e = e; e.image = artURL(e.artist, e.album); return (y, e) }
    }
}

@MainActor @Observable final class RediscoverModel {
    static let shared = RediscoverModel()
    private(set) var r = Rediscovery()
    private(set) var day = 0
    private(set) var working = false
    // Songs like his favourites of the last month that he's never played (Last.fm's similar tracks), kept a day.
    private(set) var likeFavourites: [Entry] = []
    func appear() {
        guard HistorySync.shared.complete, !working, day != LocalDay.today else { return }
        working = true
        Task {
            let db = HistoryDB.reader
            let now = Int(Clock.now.timeIntervalSince1970)
            let year = now - 365 * 86400
            var out = Rediscovery()
            out.songs = await db.forgotten(.tracks, least: 15, quietSince: year)
            out.albums = await db.forgotten(.albums, least: 30, quietSince: now - 270 * 86400)
            out.loved = await db.quietLoved(Loved.kept().map { ($0.artist, $0.title, $0.image) }, quietSince: year).prefix(12).map { $0 }
            let first = Int(HistorySync.shared.coveredFrom)
            let years = max(1, (now - first) / (365 * 86400))
            out.years = await db.thisWeek(years: min(years, 12), now: Clock.now)
            out.comebacks = await db.comebacks(quietSince: now - 182 * 86400)
            withAnimation(.smooth) { r = out }
            // Then songs like his month's favourites that he hasn't played.
            let favs = await db.top(.tracks, from: now - 30 * 86400, to: now + 1, limit: 4, median: 215)
            var seen = Set<String>(), found: [Entry] = []
            for f in favs {
                for e in await TrackInfo.similar(Scrobble.song(artist: f.artist, title: f.track, album: f.album, image: nil)) {
                    let n = await db.playsOf(artist: e.artist, tracks: [e.track])[e.track.lowercased()] ?? 0
                    guard n == 0, seen.insert((e.artist + "|" + e.track).lowercased()).inserted else { continue }
                    var x = e
                    x.because = f.track
                    if x.image == nil, let c = await db.cover(of: x.artist) { x = x.with(album: c.album, image: c.url) }
                    found.append(x)
                    if found.count >= 12 { break }
                }
            }
            withAnimation(.smooth) { likeFavourites = found }
            day = LocalDay.today
            working = false
        }
    }
}

// Discover as a pivot of three (lastfm.md §27.2): who to hear next, songs to try, and what he loved and left.
struct DiscoverHub: View {
    let start: Int
    @State private var page: Int
    init(start: Int) { self.start = start; _page = State(initialValue: min(max(start, 0), 2)) }
    private var m: DiscoverModel { DiscoverModel.shared }
    private var re: RediscoverModel { RediscoverModel.shared }
    var body: some View {
        Pager(.pivot, page: $page, top: 0, panels: [
            Panel(0, "for you") { DiscoverParts.ForYou() },
            Panel(1, "songs") { DiscoverParts.Songs() },
            Panel(2, "rediscover") { RediscoverPage() },
        ])
        .onAppear { m.appear(); re.appear() }
        .onChange(of: HistorySync.shared.complete) { _, _ in m.appear(); re.appear() }
    }
}

struct RediscoverPage: View {
    private var re: RediscoverModel { RediscoverModel.shared }
    var body: some View {
        let r = re.r
        VStack(alignment: .leading, spacing: S.section) {
            if !HistorySync.shared.complete {
                Text("Ready once your history is read").font(.zune(.title3, .light)).foregroundStyle(Z.subtle).padding(.horizontal, S.margin)
            } else if r.songs.isEmpty && r.albums.isEmpty && r.loved.isEmpty && r.years.isEmpty && r.comebacks.isEmpty {
                Text(re.working ? "Looking back through your history" : "Nothing has gone quiet yet").font(.zune(.title3, .light)).foregroundStyle(Z.subtle).padding(.horizontal, S.margin)
            }
            if !r.years.isEmpty {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "this week, years ago")
                    VStack(spacing: 0) {
                        ForEach(r.years, id: \.year) { y in
                            EntryRow(e: y.e, showRank: false, context: "years", trailing: String(y.year))
                        }
                    }
                }
                .padding(.horizontal, S.margin)
            }
            if !r.songs.isEmpty {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "forgotten favourites")
                    VStack(spacing: 0) {
                        ForEach(r.songs) { e in EntryRow(e: e, showRank: false, context: "forgot", trailing: e.last.map(lastYear)) }
                    }
                }
                .padding(.horizontal, S.margin)
            }
            if !r.albums.isEmpty {
                Panorama(title: "albums you left", items: r.albums, tiles: true) { e in "\(number(e.plays)) plays" + (e.last.map { " · " + lastYear($0) } ?? "") }
            }
            if !r.loved.isEmpty {
                VStack(alignment: .leading, spacing: S.head) {
                    SectionHead(text: "you used to love")
                    VStack(spacing: 0) {
                        ForEach(r.loved) { e in EntryRow(e: e, showRank: false, context: "loved", trailing: e.last.map(lastYear)) }
                    }
                }
                .padding(.horizontal, S.margin)
            }
            if r.comebacks.count >= 3 {
                Panorama(title: "gone quiet", items: r.comebacks) { e in "\(number(e.plays)) plays" + (e.last.map { " · " + lastYear($0) } ?? "") }
            }
        }
    }
    private func lastYear(_ uts: Int) -> String {
        "last " + String(Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(uts))))
    }
}
