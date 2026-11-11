import SwiftUI

// Mint's own screen, on the phone: the words of the song on the TV, the line being sung leading, and what plays after
// it. Read from the Mac (GET /api/tv/music-detail) only while the Playing tab is in front and a song is playing, about
// every two seconds; between readings the line moves on by Mint's own clock, counted on from the reading.
struct MusicDetail: Equatable {
    struct Line: Equatable, Identifiable { let id: Int; let start: Double; let end: Double; let text: String }
    struct Item: Equatable, Identifiable { let id: Int; let title: String; let artist: String; let art: String }
    var title = ""
    var artist = ""
    var playing = false
    // Where Mint was, in ms, when the Mac asked it (`askedAt`, ms on the Mac's clock).
    var position: Double = 0
    var askedAt: Double = 0
    var lines: [Line] = []
    // Timed to the song, or only the words.
    var synced = false
    var queue: [Item] = []
    var remaining = 0
    // Whether Mint said anything about the words and the queue at all: with its screen closed it says neither, which
    // isn't the same as a song with no words.
    var saysLyrics = false
    var saysQueue = false
    // Mint is still finding the words (it answers a new song with none and "Looking up…" for a few seconds).
    var lookingUp = false

    // Nil for an older Mint, nothing playing, or an answer that isn't one.
    static func parse(_ d: Data) -> MusicDetail? {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["ok"] as? Bool == true else { return nil }
        func number(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        var m = MusicDetail()
        m.title = j["title"] as? String ?? ""; m.artist = j["artist"] as? String ?? ""
        m.playing = j["playing"] as? Bool ?? false
        m.position = number(j["position_ms"]); m.askedAt = number(j["asked_at"])
        if let l = j["lyrics"] as? [String: Any] {
            m.saysLyrics = true
            m.lookingUp = (l["status"] as? String ?? "").lowercased().hasPrefix("looking up")
            m.synced = l["synced"] as? Bool ?? false
            let rows = l["lines"] as? [[Any]] ?? []
            m.lines = rows.enumerated().compactMap { i, r in
                guard r.count >= 3, let text = r[2] as? String else { return nil }
                return Line(id: i, start: number(r[0]), end: number(r[1]), text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // Words with no times in them are only words, whatever they're called.
            if m.synced, !m.lines.contains(where: { $0.start > 0 || $0.end > 0 }) { m.synced = false }
        }
        if let q = j["queue"] as? [String: Any] {
            m.saysQueue = true
            let items = q["items"] as? [[String: Any]] ?? []
            m.queue = items.enumerated().map { i, x in Item(id: i, title: x["title"] as? String ?? "", artist: x["artist"] as? String ?? "", art: x["art"] as? String ?? "") }
                .filter { !$0.title.isEmpty }
            m.remaining = max((q["remaining"] as? NSNumber)?.intValue ?? 0, m.queue.count)
        }
        return m
    }
    // Where Mint is now: counted on from the reading while it plays, held where it was when paused.
    func position(at date: Date) -> Double {
        playing && askedAt > 0 ? position + max(0, date.timeIntervalSince1970 * 1000 - askedAt) : position
    }
    // The line being sung at a spot: the last one that has started. −1 before the first, or for untimed words.
    func line(at ms: Double) -> Int {
        guard synced else { return -1 }
        return lines.lastIndex { $0.start <= ms } ?? -1
    }
}

// What's known of the song on the page, kept for the app's life (as Mint's home rows are), so folding the phone, which
// rebuilds the page, finds the words where they were.
@MainActor
final class MusicDetailStore: ObservableObject {
    static let shared = MusicDetailStore()
    @Published private(set) var detail: MusicDetail?
    @Published private(set) var line = -1
    // The song on the page has changed and its own answer hasn't come: the last song's block keeps its room, its words
    // out of sight, so nothing collapses and reopens between two songs.
    @Published private(set) var waiting = false
    @Published var showsAll = false
    private var song = ""
    private var misses = 0
    var hasWords: Bool { detail?.lines.isEmpty == false }
    var hasQueue: Bool { detail?.queue.isEmpty == false }
    // Whether there's anything to put on the page, on its own, for the page itself to watch: watching the store, the
    // whole Playing tab was redrawn at every reading and every sung line.
    final class Presence: ObservableObject { @Published var shows = false }
    let presence = Presence()
    private func present() { let s = hasWords || hasQueue; if presence.shows != s { presence.shows = s } }

    // The page's song, told on every pass: a new one puts the block in waiting. After the page has had something else
    // on (a film between two songs), a new song starts from nothing instead: the song before the film isn't brought
    // back for a moment under this one's name.
    func follow(_ name: String) {
        guard name != song else { left = false; return }
        song = name; misses = 0; lookups = 0
        unanswered = true; taken = 0
        if showsAll { showsAll = false }
        if left {
            if detail != nil { detail = nil }
            if line != -1 { line = -1 }
            if waiting { waiting = false }
            present()
        } else if detail != nil, !waiting { waiting = true }
        left = false
    }
    // Music is no longer what's on the page.
    func leave() { left = true }
    private var left = false
    private var lookups = 0
    // The song on the page hasn't had its own answer yet (a fitting one, past Mint's looking up), whether or not a
    // block is on the page waiting for it: asked for until it has, even paused. And when the last answer taken was
    // asked for, so one asked for earlier that lands later (a slow bridge) never replaces it.
    private(set) var unanswered = false
    private var taken = 0.0
    func read(playing: Bool) async {
        let asked = song, sent = Date().timeIntervalSince1970 * 1000
        let data = await TVBridge.data(TVBridge.url("/api/tv/music-detail"), timeout: 6)
        let parsed = await Task.detached(priority: .utility) { data.flatMap(MusicDetail.parse) }.value
        guard !Task.isCancelled, asked == song else { return }
        take(parsed, sent: sent)
    }
    // A paused song moved from the phone's own bar: asked again once the move has reached the TV.
    func moved() {
        Task { try? await Task.sleep(nanoseconds: 700_000_000); await read(playing: false) }
    }
    private func take(_ parsed: MusicDetail?, sent: Double) {
        guard sent >= taken else { return }
        taken = sent
        // Only what belongs to the song on the page: an answer about another (the reading and the page a moment apart
        // at a song's change; over AirPlay the phone knows of a skip before Mint does) is not this song's.
        let fits = parsed.map { $0.title.isEmpty || song.isEmpty || TVStatus.Session.sameName($0.title, song) } ?? false
        guard var d = parsed, fits else {
            // No answer, or not this song's. What's shown for this song stays; a block still waiting for its song gives
            // up after four misses (about eight seconds), and the asking for this song stops with it.
            misses += 1
            if misses >= 4 {
                unanswered = false
                if waiting { waiting = false; if detail != nil { detail = nil }; if line != -1 { line = -1 } }
            }
            present()
            return
        }
        misses = 0
        // Still looking the words up: nothing is decided yet. A block waiting for this song goes on waiting, and words
        // already shown for it stay, for five readings at most.
        if d.saysLyrics, d.lines.isEmpty, d.lookingUp, lookups < 5 {
            lookups += 1
            if waiting { return }
            if let old = detail { d.lines = old.lines; d.synced = old.synced }
        } else { lookups = 0; unanswered = false }
        // The phone's clock and the Mac's really apart (the Mac's reading stamped well before the ask went out, or
        // after now): counted from when the answer came instead. A slow answer alone is not that, and keeps its stamp.
        let now = Date().timeIntervalSince1970 * 1000
        if d.askedAt < sent - 1500 || d.askedAt > now + 1500 { d.askedAt = now }
        // Mint's screen closed mid-song says nothing of the words or the queue: the ones already shown for this song stay.
        if let old = detail, !waiting {
            if !d.saysLyrics { d.lines = old.lines; d.synced = old.synced }
            if !d.saysQueue { d.queue = old.queue; d.remaining = old.remaining }
        }
        let fresh = waiting || detail == nil
        if waiting { waiting = false }
        if d != detail { detail = d }
        present()
        settle(fresh: fresh)
    }
    // The sung line, now. It never steps back one line for a reading a moment behind (each reading is taken afresh, and
    // one that lands just short of the line's start would flick the words back and on again): only a spot more than
    // 400 ms before the line's own start, a real move back, takes it back.
    func settle(fresh: Bool = false) {
        guard let d = detail, d.synced else { if line != -1 { line = -1 }; return }
        let at = d.position(at: Date()), now = d.line(at: at)
        if !fresh, now == line - 1, d.lines.indices.contains(line), at > d.lines[line].start - 400 { return }
        if now != line { line = now }
    }
    // How long until the next line starts, in ms; nil when nothing more will change by itself.
    func untilNext() -> Double? {
        guard let d = detail, d.synced, d.playing else { return nil }
        let at = d.position(at: Date())
        return d.lines.first { $0.start > at }.map { $0.start - at }
    }
}

// Asks for the song's words and queue while the page is in front, and moves the sung line on between readings. It
// draws nothing and takes no room, so a song with neither leaves the page exactly as it was.
struct MusicDetailWatch: View {
    @Environment(TVModel.self) var model
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var store = MusicDetailStore.shared
    let song: String
    let playing: Bool
    // Where a paused song sits, in whole seconds: moved while paused (the phone's own bar), the words follow.
    let pausedAt: Int
    var watching: Bool { model.tab == 2 && phase == .active }
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: song, initial: true) { _, s in store.follow(s) }
            // Asked once whenever the page comes up, the song changes or a paused song is moved (so a paused song still
            // has its words), then every two seconds only while it plays and the page is in front.
            .task(id: "\(watching) \(playing) \(song) \(playing ? 0 : pausedAt)") {
                guard watching else { return }
                store.follow(song)
                await store.read(playing: playing)
                // Paused, it still asks until the song on the page has had its own answer (or is given up on).
                while playing || store.unanswered, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    await store.read(playing: playing)
                }
            }
            .onDisappear { store.leave() }
            // Between readings the line moves on by itself: set at the moment each next line starts. Away from the
            // page it's left where it is, and set right again as the page comes back.
            .task(id: "\(watching) \(song) \(store.detail?.askedAt ?? 0) \(store.detail?.playing ?? false)") {
                guard watching else { return }
                while !Task.isCancelled {
                    store.settle()
                    guard let wait = store.untilNext() else { return }
                    try? await Task.sleep(nanoseconds: UInt64(min(max(wait, 30), 2500) * 1_000_000))
                }
            }
    }
}

// Under a song on Playing: its words and what's next. Only on the page at all when Mint has one or the other.
struct MusicExtras: View {
    @ObservedObject private var store = MusicDetailStore.shared
    // Open flat, in the right pane: the words keep a short window and the queue its first three, so what he played
    // before and the field to play something stay in sight under them.
    var tall = false
    @State private var appearedAt = Date()
    @Environment(\.scenePhase) private var phase
    // Open flat the words' window holds the sung line and a wrapped next one whole, so Up next shows two there.
    var shown: Int { tall ? 2 : 5 }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let d = store.detail, !d.lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    RowTitle("Lyrics")
                    Group {
                        // A fixed window, 12 pt clear of the heading so no line is ever cut under it. Open flat it stays
                        // short enough that Recently played and Play on TV are still in the pane (gate dd1a, 276).
                        if d.synced { SyncedLyrics(lines: d.lines, line: store.line, height: tall ? 236 : 250, quiet: Date().timeIntervalSince(appearedAt) < 0.4).padding(.top, 12) }
                        else { PlainLyrics(lines: d.lines, showsAll: $store.showsAll) }
                    }
                    .opacity(store.waiting ? 0 : 1)
                }
                .transition(.opacity)
            }
            if let d = store.detail, !d.queue.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    RowTitle("Up next")
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(spacing: 10) {
                            ForEach(d.queue.prefix(shown)) { item in
                                HStack(spacing: 12) {
                                    Art(url: URL(string: item.art)) { $0.resizable().scaledToFill() } placeholder: {
                                        // No cover yet, or none: a note on the tile, never an empty box.
                                        ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").font(.system(size: 18)).foregroundStyle(.secondary) }
                                    }
                                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        if !item.artist.isEmpty { Text(item.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        if d.remaining > min(d.queue.count, shown) {
                            Text("and \(d.remaining - min(d.queue.count, shown)) more").font(.footnote.weight(.medium)).foregroundStyle(.secondary).padding(.top, 10)
                        }
                    }
                    .opacity(store.waiting ? 0 : 1)
                }
                .transition(.opacity)
            }
        }
        // The words and the queue arrive, change with the song and go with a fade, once the page has settled.
        .settledAnimation(.easeOut(duration: 0.25), value: store.detail?.lines.map(\.text))
        .settledAnimation(.easeOut(duration: 0.25), value: store.detail?.queue)
        .settledAnimation(.easeOut(duration: 0.2), value: store.waiting)
        // Coming to the page (or back to it): the sung line is where the song is from the first frame.
        .onAppear { appearedAt = Date(); store.settle(fresh: true) }
        // And coming back to the app with this page up, which is no appearance: the same, so the words don't glide
        // across everything sung while it was away.
        .onChange(of: phase) { _, now in if now == .active { appearedAt = Date(); store.settle(fresh: true) } }
    }
}

// Words timed to the song, as Apple Music shows its own: every line large, the one being sung bright and the rest
// stepped back, the page of them gliding so that line sits a third of the way down. It follows the song and takes no
// touch, so a finger on it scrolls the page it's in.
private struct SyncedLyrics: View {
    let lines: [MusicDetail.Line]
    let line: Int
    let height: CGFloat
    // The page has only just come up: the place is taken at once, with nothing gliding or brightening in front of him.
    let quiet: Bool
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var placed = false
    static let glide = Animation.spring(response: 0.55, dampingFraction: 0.86)
    // The sung line's place, in points from the window's top, the same in every window height: deep enough that the line
    // before it has the whole top fade to go through, and the one before that is gone before the edge (gate 276: at 30 %
    // of the window the line above sat half in the fade and showed as the foot of its letters under "Lyrics").
    static let lead: CGFloat = 82
    // Clear, then the fade: everything above `fadeEnd` is on its way out, nothing at the very edge shows at all.
    static let clearTop: CGFloat = 10, fadeEnd: CGFloat = 60
    var anchor: UnitPoint { UnitPoint(x: 0.5, y: min(Self.lead / max(height, 1), 0.6)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(lines) { l in
                    // An empty line is a break in the singing: a quiet mark keeps its place.
                    Text(l.text.isEmpty ? "···" : l.text)
                        .font(.system(size: 24, weight: .bold)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The sung line, and the one either side of it stepped back; the rest are out of the window's
                        // story, so no line further off can ever show as a sliver at either edge, whatever its height
                        // (gate 276: the foot of a line two back under "Lyrics", the top of a wrapped next line at the foot).
                        .opacity(l.id == line ? 1 : abs(l.id - line) == 1 ? 0.32 : 0)
                        .scaleEffect(l.id == line ? 1 : 0.96, anchor: .leading)
                        .id(l.id)
                }
            }
            .scrollTargetLayout()
            // The first line starts clear of the top fade, close under the heading; room under the last for it to sit
            // where the sung line sits.
            .padding(.top, Self.fadeEnd + 2).padding(.bottom, height * 0.6)
            .animation(placed && !quiet ? Self.glide : nil, value: line)
        }
        .scrollPosition($position, anchor: anchor)
        .scrollIndicators(.hidden)
        .scrollDisabled(true).allowsHitTesting(false)
        .frame(height: height)
        .mask {
            VStack(spacing: 0) {
                // The top few points fully clear, then a deep fade: the line before the sung one is passing through it,
                // the one before that is gone before the edge, so nothing is ever cut flat under the heading.
                Color.clear.frame(height: Self.clearTop)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Self.fadeEnd - Self.clearTop)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
            }
        }
        .onChange(of: line, initial: true) { _, now in
            let to = max(now, 0)
            if placed && !quiet { withAnimation(Self.glide) { position.scrollTo(id: to, anchor: anchor) } }
            else { position.scrollTo(id: to, anchor: anchor); Task { placed = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lyrics")
        .accessibilityValue(lines.indices.contains(line) ? lines[line].text : "")
    }
}

// Words with no times: set as text, quietly, the first dozen lines and a way to the rest.
private struct PlainLyrics: View {
    let lines: [MusicDetail.Line]
    @Binding var showsAll: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(showsAll ? lines : Array(lines.prefix(12))) { l in
                Text(l.text.isEmpty ? " " : l.text).font(.body.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            if lines.count > 12 {
                Button { withAnimation(.easeOut(duration: 0.25)) { showsAll.toggle() } } label: {
                    Text(showsAll ? "Show less" : "Show all").font(.subheadline.weight(.semibold)).foregroundStyle(TVLook.accent)
                        .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
