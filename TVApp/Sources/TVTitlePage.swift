import SwiftUI

// A title's page: the poster as a large card, low and centred, in thumb reach, the lip above it and the choice of stream under
// it. The card is not inside any scroller, so it answers his finger from the first point (brief 3.4). He throws it; the
// page stays where it is.

struct TitleRoute: Hashable { let id: UUID }
@MainActor enum TitleRoutes {
    private static var targets: [UUID: FlickTarget] = [:]
    static func add(_ t: FlickTarget) -> TitleRoute { targets[t.id] = t; return TitleRoute(id: t.id) }
    static func target(_ r: TitleRoute) -> FlickTarget? { targets[r.id] }
}

@MainActor @Observable final class TitleState {
    let target: FlickTarget
    var item: MediaItem { target.item }
    var meta: StremioMeta?
    var episode: StremioEpisode?
    var season = 0
    var streams: [StremioStream] = []
    var finding = false
    var noStreams = false
    var chosen: String?
    var failed: Set<String> = []
    var startOver = false
    var about: String?
    var note: (text: String, at: Date)?
    var showsAllStreams = false
    // The token this page last sent, so its start's failure is this page's to answer.
    @ObservationIgnored var sentToken: String?
    init(_ t: FlickTarget) { target = t }

    var ref: (type: String, imdb: String, video: String?)? { target.send == nil && !item.isYouTube && target.source == .stremio ? item.stremioRef : nil }
    var isSeries: Bool { ref?.type == "series" }
    // What the card sends: the film, or the episode on the card.
    var video: String? { guard let r = ref else { return nil }; return r.type == "series" ? episode?.id : r.imdb }
    var playedKey: String { guard let r = ref else { return "" }; return r.imdb + "/" + (r.type == "series" ? video ?? "" : "") }
    var cardItem: MediaItem {
        guard let r = ref, r.type == "series", let e = episode else { return item }
        let p = e.id == r.video ? item.progress : (ShelfSend.progress(MediaItem(title: item.title, subtitle: "", art: item.art, id: NextUp.link(r.imdb, e.id), kind: "series")))
        return MediaItem(title: item.title, subtitle: "S\(e.season) E\(e.episode)", art: item.art, id: NextUp.link(r.imdb, e.id), kind: "series", progress: p)
    }
    var progress: Double? { ref == nil ? nil : ShelfSend.progress(cardItem) }
    var stream: StremioStream? { streams.first { $0.token == chosen } }
    var seasons: [Int] { Array(Set((meta?.episodes ?? []).map(\.season))).sorted { a, b in (a == 0 ? 1000 : a) < (b == 0 ? 1000 : b) } }
    var seasonEpisodes: [StremioEpisode] { (meta?.episodes ?? []).filter { $0.season == season }.sorted { $0.episode < $1.episode } }

    // The stream he used last for this, else the best one.
    static func preferred(_ list: [StremioStream], key: String, avoid: Set<String> = []) -> StremioStream? {
        if let f = PlayedStream.file(key), let s = list.first(where: { $0.description == f && !avoid.contains($0.token) }) { return s }
        return ShelfSend.best(list, avoid: avoid)
    }
    // The episode he's on: the card's own, then Continue watching, then what the TV has on, else the first.
    static func resumeEpisode(item: MediaItem, meta m: StremioMeta, model: TVModel) -> StremioEpisode? {
        guard let ref = item.stremioRef else { return nil }
        if let v = ref.video, let e = m.episodes.first(where: { $0.id == v }) { return e }
        let row = BrowseStore.shared(.stremio).rows.first { $0.title == "Continue watching" }?.items.first { $0.stremioRef?.imdb == ref.imdb }
        if let v = row?.stremioRef?.video, let e = m.episodes.first(where: { $0.id == v }) { return e }
        if let s = NextUp.shared.series, s.imdb == ref.imdb, let cur = m.episodes.first(where: { $0.id == s.current }) { return NextUp.after(cur, in: m.episodes) ?? cur }
        if let r = RecentFlicks.shared.list.first(where: { $0.imdb == ref.imdb }), let v = r.video, let e = m.episodes.first(where: { $0.id == v }) { return e }
        return m.episodes.filter { $0.season > 0 }.min { ($0.season, $0.episode) < ($1.season, $1.episode) } ?? m.episodes.first
    }

    func load(_ model: TVModel) async {
        guard let r = ref else { return }
        if r.type == "series" {
            if let m = NextUp.cached(r.imdb) { apply(m, model) }
            else if let m = await NextUp.meta(r.imdb) { apply(m, model) }
            about = meta?.about
        } else {
            await findStreams()
            let d = await TVBridge.data(TVBridge.url("/api/tv/stremio-meta?type=\(r.type)&id=\(r.imdb)"), timeout: 15)
            let m = await Task.detached(priority: .userInitiated) { d.flatMap { try? JSONDecoder().decode(StremioMeta.self, from: $0) } }.value
            if let a = m?.about, !a.isEmpty { about = a } else if let a = item.about { about = a }
        }
    }
    private func apply(_ m: StremioMeta, _ model: TVModel) {
        meta = m
        if episode == nil { episode = Self.resumeEpisode(item: item, meta: m, model: model) }
        season = episode?.season ?? seasons.first ?? 0
        Task { await findStreams() }
    }
    func choose(_ e: StremioEpisode) {
        guard e.id != episode?.id else { return }
        episode = e; season = e.season; startOver = false
        streams = []; chosen = nil; failed = []
        Task { await findStreams() }
    }
    func findStreams(again: Bool = false) async {
        guard let r = ref, let v = video else { return }
        if !again, let l = StreamCache.shared.inHand(type: r.type, imdb: r.imdb, video: v) { set(l); return }
        finding = true; noStreams = false
        let l = await StreamCache.shared.streams(type: r.type, imdb: r.imdb, video: v, again: again)
        guard v == video else { return }
        finding = false
        if let l, !l.isEmpty { set(l) } else { noStreams = true }
    }
    private func set(_ l: [StremioStream]) {
        // One frame, no stagger: the list is laid out whole.
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            streams = l
            if chosen == nil || !l.contains(where: { $0.token == chosen }) { chosen = Self.preferred(l, key: playedKey, avoid: failed)?.token }
        }
    }
    func say(_ s: String) { withAnimation(.easeOut(duration: 0.2)) { note = (s, Date()) } }
}

struct TitlePage: View {
    @Environment(TVModel.self) private var model
    @State private var st: TitleState
    @State private var carry = Carry()
    init(target: FlickTarget) { _st = State(initialValue: TitleState(target)) }
    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > g.size.height * 1.15 && g.size.width > 600
            Group {
                if wide {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 8)
                            card(maxH: g.size.height * 0.66, maxW: g.size.width * 0.36)
                            Spacer(minLength: 8)
                        }
                        .frame(width: g.size.width * 0.44)
                        .zIndex(1)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header.padding(.bottom, 20)
                                details
                            }
                            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                    }
                } else {
                    VStack(spacing: 0) {
                        header.padding(.horizontal, 20).padding(.top, 4)
                        card(maxH: g.size.height * (g.size.height < 560 ? 0.42 : 0.46), maxW: g.size.width * 0.55)
                            .padding(.vertical, 12)
                            .zIndex(1)
                        ScrollView {
                            details.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                    }
                }
            }
        }
        .background { TitleGround(art: st.item.art) }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if st.ref != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.tick(); PhoneOpen.open(st.cardItem, model: model) } label: { Label("Play on iPhone", systemImage: "iphone") }
                }
            }
        }
        .task { await st.load(model) }
        .onChange(of: model.starting?.failed) { _, f in
            guard f == true, let tok = st.sentToken, model.starting?.token == tok || model.startingAvoid.contains(tok) else { return }
            st.failed.formUnion(model.startingAvoid.union([tok]))
            st.chosen = TitleState.preferred(st.streams, key: "", avoid: st.failed)?.token
            st.sentToken = nil
            carry.dropBack()
            st.say("That stream didn’t start. The next one is on the card.")
            model.clearStart()
        }
    }
    // MARK: the card
    var art: String { st.item.art }
    var wideArt: Bool { st.item.isYouTube || st.target.send != nil || st.item.kind == "link" }
    func card(maxH: CGFloat, maxW: CGFloat) -> some View {
        let aspect: CGFloat = wideArt ? 16.0 / 9 : st.target.source == .mint ? 1 : 2.0 / 3
        var h = maxH
        var w = h * aspect
        if w > maxW { w = maxW; h = w / aspect }
        return ZStack(alignment: .bottom) {
            Group {
                if let i = st.target.image { i.resizable().scaledToFill() }
                else if art.isEmpty { CoverFallback(title: st.item.title, tint: Color(hex: 0x3A3152)) }
                else { Art(url: URL(string: art)) { $0.resizable().scaledToFill() } placeholder: { CoverWait() } }
            }
            .frame(width: w, height: h).clipped()
            chip.padding(10)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)) }
        .shadow(color: .black.opacity(carry.phase == .held ? 0.55 : 0.35), radius: carry.phase == .held ? 26 : 16, y: carry.phase == .held ? 16 : 8)
        .scaleEffect(carry.scale)
        .rotationEffect(.degrees(carry.tilt))
        .offset(carry.offset)
        .opacity(carry.opacity)
        .onGeometryChange(for: CGRect.self) { p in
            // The rest, not where the hand has it.
            p.frame(in: .global)
        } action: { r in if carry.phase == .rest { carry.rest = r } }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if carry.phase != .held {
                    guard carry.phase == .rest else { return }
                    touchDown()
                }
                carry.move(v.translation, velocity: v.velocity, finger: v.location)
                if Hand.shared.committed, !committedOnce { committedOnce = true; committed() }
            }
            .onEnded { v in release(v) })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(st.item.title)
        .accessibilityHint("Flick up to play on the TV")
        .accessibilityAction(named: "Play on the TV") { throwIt(CGSize(width: 0, height: -2000)) }
        .frame(maxWidth: .infinity)
    }
    @State private var committedOnce = false
    @State private var downAt = CGPoint.zero
    // What the card wears: the stream it carries, and where it starts.
    @ViewBuilder var chip: some View {
        let onTV = model.isOnTV(st.cardItem, st.target.source)
        let starting = model.starting.map { !$0.played && !$0.failed && $0.token != nil && $0.token == st.sentToken } ?? false
        HStack(spacing: 6) {
            if onTV { chipText("Playing on the TV", icon: "play.tv.fill", lit: true) }
            else if starting { chipText("Starting…", icon: "tv", lit: true) }
            else if st.ref != nil {
                if let s = st.stream { chipText(StreamWords.chip(s), icon: nil, lit: false) }
                else if st.noStreams { chipText("No streams", icon: nil, lit: false) }
                else { chipText("Finding streams…", icon: nil, lit: false) }
                if let p = st.progress, p > 0.01, p < 0.97 {
                    chipText(st.startOver ? "Start over" : "Resume" + (resumeClock(p).map { " " + $0 } ?? ""), icon: st.startOver ? "backward.end.fill" : "play.fill", lit: false)
                }
            }
        }
        .lineLimit(1)
    }
    func chipText(_ t: String, icon: String?, lit: Bool) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 12, weight: .bold)) }
            Text(t).font(.system(size: 14, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 10).frame(height: 30)
        .foregroundStyle(lit ? .black : .white)
        .background(lit ? AnyShapeStyle(TVLook.accent) : AnyShapeStyle(.black.opacity(0.62)), in: Capsule())
    }
    func resumeClock(_ p: Double) -> String? {
        let mins = st.isSeries ? (st.episode?.runtime ?? 0) : 0
        guard mins > 0 else { return nil }
        let s = Int(Double(mins * 60) * p)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    func touchDown() {
        committedOnce = false
        carry.down()
        // The TV is told the moment he has it: wake and get ready, and resolve what the card carries.
        if let r = st.ref {
            var b: [String: Any] = ["type": r.type, "imdb": r.imdb]
            if let v = st.video, r.type == "series" { b["video"] = v }
            Prepare.arm(b)
            Warm.ask(type: r.type, imdb: r.imdb, video: r.type == "series" ? st.video : nil)
        } else { Prepare.arm() }
    }
    func committed() {
        // Over the line: the stream itself resolved on the TV ahead of the release.
        if let r = st.ref, let s = st.stream {
            var b: [String: Any] = ["type": r.type, "imdb": r.imdb, "token": s.token]
            if let v = st.video, r.type == "series" { b["video"] = v }
            Prepare.arm(b)
        }
    }
    func release(_ v: DragGesture.Value) {
        let vel = v.velocity
        guard carry.phase == .held else { return }
        if carry.judge(vel) == .thrown { throwIt(vel); return }
        let d = v.translation
        // A tap on the card's foot (its chips) switches Resume and Start over.
        if abs(d.width) < 8, abs(d.height) < 8, let p = st.progress, p > 0.01, p < 0.97, v.startLocation.y > carry.rest.maxY - 48 {
            Haptic.fire(.tick); st.startOver.toggle()
        }
        // Swiped sideways below the line: the next or previous episode becomes the card.
        if st.isSeries, abs(d.width) > 90, abs(d.width) > abs(d.height) * 1.3, let e = st.episode, let all = st.meta?.episodes {
            let to = d.width < 0 ? NextUp.after(e, in: all) : NextUp.before(e, in: all)
            if let to { Haptic.fire(.tick); st.choose(to) }
        }
        carry.springHome(vel)
    }
    func throwIt(_ v: CGSize) {
        let m = model
        if let r = st.ref {
            guard let s = st.stream else {
                carry.springHome(v)
                st.say(st.noStreams ? "No streams to play" : "Still finding streams")
                return
            }
            _ = r
            st.sentToken = s.token
            Thrower.sendStream(m, item: st.cardItem, stream: s, list: st.streams, velocity: v, avoid: st.failed, startOver: st.startOver)
        } else {
            Thrower.sendPlain(m, target: st.target)
        }
        let tint = ImageStore.shared.cachedBand(URL(string: art))
        let title = st.item.title
        carry.fly(v) {
            Hand.shared.land(title: title, art: st.item.art, tint: tint)
            carry.reappear()
        }
    }
    // MARK: the words
    var facts: String {
        var parts: [String] = []
        let n = st.seasons.filter { $0 > 0 }.count
        if st.isSeries, n > 0 { parts.append(n == 1 ? "1 season" : "\(n) seasons") }
        let sub = st.item.shownSubtitle
        if !sub.isEmpty, !st.isSeries { parts.append(sub) }
        return parts.joined(separator: " · ")
    }
    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(st.item.title).font(.system(size: 28, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
            if let e = st.episode, st.isSeries {
                Text("S\(e.season) E\(e.episode)" + (Wording.episodeName(e.name, number: e.episode).map { " · " + $0 } ?? ""))
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            } else if !facts.isEmpty {
                Text(facts).font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let n = st.note, Date().timeIntervalSince(n.at) < 6 {
                Text(n.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(TVLook.away)
                    .padding(.bottom, 12)
                    .task(id: n.at) { try? await Task.sleep(nanoseconds: 6_000_000_000); withAnimation { st.note = nil } }
            }
            if st.ref != nil {
                SectionTitle("Streams")
                streamList
            }
            if st.isSeries, st.meta != nil {
                SectionTitle("Episodes").padding(.top, 24)
                seasonStrip.padding(.bottom, 8)
                ForEach(st.seasonEpisodes) { e in episodeRow(e) }
            }
            if let a = st.about ?? st.item.about, !a.isEmpty {
                SectionTitle("About").padding(.top, 24)
                Blurb(text: a)
            }
        }
    }
    // MARK: streams
    @ViewBuilder var streamList: some View {
        if st.streams.isEmpty {
            HStack(spacing: 10) {
                if st.finding || (!st.noStreams && st.video != nil) { ProgressView().controlSize(.small) }
                Text(st.noStreams ? "No streams found" : st.video == nil ? "Choose an episode" : "Finding streams…")
                    .font(.system(size: 17)).foregroundStyle(.secondary)
            }
            .frame(height: StreamRow.height, alignment: .leading)
        } else {
            let all = st.streams
            let shown = st.showsAllStreams ? all : Array(all.prefix(5))
            VStack(spacing: 8) {
                ForEach(shown) { s in
                    StreamRow(stream: s, chosen: s.token == st.chosen, failed: st.failed.contains(s.token),
                              usedLast: PlayedStream.file(st.playedKey) == s.description, twin: all.filter { StreamWords.chip($0) == StreamWords.chip(s) }.count > 1 ? (all.firstIndex(of: s) ?? 0) + 1 : nil) {
                        Haptic.fire(.tick)
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) { st.chosen = s.token }
                    }
                }
                if all.count > 5 && !st.showsAllStreams {
                    Button { model.tick(); withAnimation(.easeOut(duration: 0.2)) { st.showsAllStreams = true } } label: {
                        Text("\(all.count - 5) more").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    // MARK: episodes
    var seasonStrip: some View {
        ScrollViewReader { sp in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(st.seasons, id: \.self) { s in
                        let on = s == st.season
                        Button { Haptic.fire(.tick); st.season = s } label: {
                            Text(s == 0 ? "Specials" : "Season \(s)").font(.system(size: 16, weight: .semibold)).fixedSize()
                                .foregroundStyle(on ? .black : .white)
                                .padding(.horizontal, 16).frame(height: 40)
                                .background(on ? AnyShapeStyle(TVLook.accent) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).id(s)
                    }
                }
                .padding(.horizontal, 1)
            }
            .onAppear { sp.scrollTo(st.season, anchor: .center) }
        }
    }
    func episodeRow(_ e: StremioEpisode) -> some View {
        let on = e.id == st.episode?.id
        let r = st.ref!
        let item = MediaItem(title: st.item.title, subtitle: "S\(e.season) E\(e.episode)", art: e.thumb.isEmpty ? st.item.art : e.thumb, id: NextUp.link(r.imdb, e.id), kind: "series")
        let playing = model.isOn(imdb: r.imdb, title: st.item.title, episode: e.id)
        return Button { Haptic.fire(.tick); st.choose(e) } label: {
            HStack(alignment: .top, spacing: 14) {
                Art(url: URL(string: e.thumb.isEmpty ? st.item.art : e.thumb)) { $0.resizable().scaledToFill() } placeholder: { CoverWait() }
                    .frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .liftable(item, .stremio, wide: true) { v in Thrower.sendBest(model, item: item, velocity: v) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(e.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        if playing { Image(systemName: "play.tv.fill").font(.system(size: 13)).foregroundStyle(TVLook.accent) }
                    }
                    Text(e.overview ?? (e.runtime.map { "\($0) min" } ?? "")).font(.system(size: 15)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(10)
            .frame(height: 96, alignment: .top)
            .background(on ? AnyShapeStyle(TVLook.accent.opacity(0.16)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { if on { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TVLook.accent.opacity(0.7), lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -10)
    }
}

// The quality and size, plus languages where there's a choice. Never where it came from.
enum StreamWords {
    static func quality(_ s: StremioStream) -> String {
        var q = s.quality ?? s.name
        if q.isEmpty { q = "Stream" }
        if let h = s.hdr, !h.isEmpty, !q.contains(h) { q += " " + h }
        return q
    }
    static func chip(_ s: StremioStream) -> String { ([quality(s)] + (s.size.map { [$0] } ?? [])).joined(separator: " · ") }
    static func line(_ s: StremioStream) -> String {
        var parts: [String] = []
        if let z = s.size { parts.append(z) }
        if let l = s.lang, !l.isEmpty, l.contains(",") || l.contains("/") || l.lowercased().contains("multi") { parts.append(l.lowercased().contains("multi") ? "Several languages" : l) }
        if s.dubbed == true { parts.append("Dubbed") }
        return parts.joined(separator: " · ")
    }
}
struct StreamRow: View {
    static let height: CGFloat = 60
    let stream: StremioStream
    let chosen: Bool
    let failed: Bool
    let usedLast: Bool
    var twin: Int? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
                    .foregroundStyle(chosen ? TVLook.accent : .white.opacity(0.35))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(StreamWords.quality(stream)).font(.system(size: 17, weight: .bold))
                        if let twin { Text("#\(twin)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.5)) }
                    }
                    let l = failed ? "Didn’t start" : [StreamWords.line(stream), usedLast ? "Used last time" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !l.isEmpty { Text(l).font(.system(size: 15)).foregroundStyle(failed ? TVLook.away : .white.opacity(0.65)).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.height)
            .background(.white.opacity(chosen ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { if chosen { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TVLook.accent.opacity(0.7), lineWidth: 1.5) } }
            .contentShape(Rectangle())
            .opacity(failed ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

// Two full lines, and "More" to read the rest in place.
struct Blurb: View {
    let text: String
    @State private var all = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 17)).foregroundStyle(.white.opacity(0.82)).lineLimit(all ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if !all && text.count > 90 {
                Button { withAnimation(.easeOut(duration: 0.2)) { all = true } } label: {
                    Text("More").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// One heading style for every section: 22 pt bold, 24 pt above (given by the caller), 12 pt below.
struct SectionTitle: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        Text(title).font(.system(size: 22, weight: .bold)).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

// The page's ground: the poster's own colour, darkened, never a black void.
struct TitleGround: View {
    let art: String
    var body: some View {
        ZStack {
            Color(hex: 0x0E0B16)
            Art(url: URL(string: art)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                .blur(radius: 60).opacity(0.45).clipped()
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
