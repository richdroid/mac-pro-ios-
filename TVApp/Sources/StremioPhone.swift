import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// "Play on iPhone": a title's streams from his own add-ons, picked here and played on this phone, beside every way to
// flick it to the TV. Nothing goes through the Mac; only "Play on TV" does, as any flick does.

// The titles played on this phone lately, newest first, with where he got to: for Continue watching on the widget,
// Spotlight, Shortcuts and Handoff. Kept on the phone only.
struct PhoneRecent: Codable, Hashable, Identifiable {
    var type: String, imdb: String, video: String, name: String, line: String, poster: String
    var at: Double, length: Double, when: Date
    var id: String { imdb }
    var title: PhoneTitle { PhoneTitle(type: type, imdb: imdb, video: video, name: name, line: line, poster: poster, background: "") }
    var progress: Double { length > 0 ? min(at / length, 1) : 0 }
}
@MainActor enum PhoneRecents {
    static let key = "phoneRecents"
    static var all: [PhoneRecent] {
        guard let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([PhoneRecent].self, from: d) else { return [] }
        return l
    }
    static func note(_ t: PhoneTitle, at: Double, length: Double) {
        let r = PhoneRecent(type: t.type, imdb: t.imdb, video: t.video, name: t.name, line: t.line, poster: t.poster, at: at, length: length, when: Date())
        let l = Array(([r] + all.filter { $0.imdb != t.imdb }).prefix(12))
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: key) }
        PhoneSystem.noted(r)
    }
}

// Sending what's playing here to the TV: the Mac's own list for the title asked for the same file (its tokens are its
// own), then that one started there at this spot, through the flick's own play-stream.
@MainActor enum PhoneFlick {
    static func send(title: PhoneTitle, stream: PhoneStream?, at: Double, model: TVModel?) async -> Bool {
        guard let model else { return false }
        let video = title.type == "series" ? title.video : title.imdb
        guard let list = await StreamCache.shared.streams(type: title.type, imdb: title.imdb, video: video), !list.isEmpty else { return false }
        // A row he chose is sent only if the TV has that very file; otherwise its own streams open on the phone to pick
        // from, never a stand-in he didn't choose (gate item 5). From the player, the TV's own first pick (1080p).
        let pick: StremioStream
        if let s = stream {
            guard let same = list.first(where: { $0.description == s.file }) else {
                model.flick(FlickTarget(item: title.item, source: .stremio))
                return true
            }
            pick = same
        } else {
            pick = list.first { $0.stalled != true } ?? list[0]
        }
        var body: [String: Any] = ["token": pick.token, "imdb": title.imdb]
        if title.type == "series" { body["video"] = title.video }
        if at > 30 { body["resumeMs"] = Int(at * 1000) }
        body["receipt"] = FlickReceipt.body(id: UUID().uuidString, title: title.name, line: title.line, art: title.poster,
                                            kind: title.type == "series" ? "episode" : "film", shape: "poster")
        model.tab = 0
        model.say("Starting on the TV…")
        Task {
            do { _ = try await TVBridge.post("play-stream", body, timeout: 60) }
            catch { model.say("The TV couldn’t start it. Try it from the TV’s streams.") }
        }
        return true
    }
}

// The way in, from a card, the flick page, a shortcut, Spotlight or the widget.
#if os(iOS)
// Touches on its own bare root go through to the app below: it never holds a tap while it hides (gate item 2).
final class PassWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === rootViewController?.view ? nil : v
    }
}
#endif

@MainActor enum PhoneOpen {
    static func open(_ item: MediaItem, model: TVModel?) {
        guard let ref = item.stremioRef else { return }
        #if os(iOS)
        present(PhonePicker(type: ref.type, imdb: ref.imdb, video: ref.video, name: item.title, poster: item.art, model: model))
        #endif
    }
    static func open(_ t: PhoneTitle, model: TVModel?) {
        #if os(iOS)
        present(PhonePicker(type: t.type, imdb: t.imdb, video: t.type == "series" && t.video.contains(":") ? t.video : nil, name: t.name, poster: t.poster, model: model))
        #endif
    }
    // From a link: tvremoteapp://phone?type=movie&id=tt…&video=…
    static func open(url: URL, model: TVModel?) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
        guard let id = v("id"), id.hasPrefix("tt") else { return }
        let type = v("type") ?? "movie"
        let t = PhoneTitle(type: type, imdb: id, video: v("video") ?? id, name: v("name") ?? "", line: "", poster: v("poster") ?? "", background: "")
        open(t, model: model)
    }
    #if os(iOS)
    static func again(_ s: PhoneSession) {
        let t = s.title
        Task { try? await Task.sleep(nanoseconds: 500_000_000); open(t, model: s.model) }
    }
    // The picker and the player live in a window of their own over the app's: presented from the app's own root, SwiftUI
    // took them down again whenever it changed its own presentations (CI c970990: the player gone seconds after it
    // came up, still playing). The window shows only while one of them is up.
    private static var window: UIWindow?
    private static var watching = false
    static var top: UIViewController? {
        // The scene the app is showing in now: the one whose own window is key (folded and open are different displays).
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { s in s.windows.contains { $0.isKeyWindow && $0 !== window } }
            ?? scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let scene else { return nil }
        // Never moved while something is up in it: the player keeps playing where it is.
        if window?.windowScene !== scene, window?.rootViewController?.presentedViewController == nil {
            let w = PassWindow(windowScene: scene)
            w.windowLevel = .normal + 1
            w.backgroundColor = .clear
            let root = UIViewController(); root.view.backgroundColor = .clear
            w.rootViewController = root
            window = w
        }
        guard let w = window else { return nil }
        if w.isHidden { w.isHidden = false; w.makeKeyAndVisible() }
        watch()
        var vc = w.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
    // Hidden again once nothing is up in it (closed, swiped away), so it never sits over the app taking touches.
    private static func watch() {
        guard !watching else { return }
        watching = true
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let w = window else { break }
                if w.rootViewController?.presentedViewController == nil {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if w.rootViewController?.presentedViewController == nil { w.isHidden = true; w.windowScene?.windows.first { $0 !== w && !$0.isHidden }?.makeKey(); break }
                }
            }
            watching = false
        }
    }
    static func present(_ picker: PhonePicker) {
        // One player at a time: one already open is closed (its place saved) before another title opens.
        if let s = PhoneSession.current {
            s.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { present(picker) }
            return
        }
        if let up = top, up is UIHostingController<PhonePicker>, !up.isBeingDismissed {
            up.dismiss(animated: true) { present(picker) }
            return
        }
        let host = UIHostingController(rootView: picker)
        host.view.backgroundColor = .clear
        host.overrideUserInterfaceStyle = .dark
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        top?.present(host, animated: true)
    }
    static func play(_ title: PhoneTitle, stream: PhoneStream, others: [PhoneStream], library: [String: Any]?, at: Double, model: TVModel?) {
        PhoneLog.note("play \(stream.title) from \(Int(at))")
        let s = PhoneSession(title: title, stream: stream, others: others, library: library, model: model)
        let vc = PhonePlayerController(s)
        s.close = { [weak vc, weak s] in
            s?.finish()
            vc?.presentingViewController?.dismiss(animated: true)
        }
        s.start(at: at)
        let go = { PhoneLog.note("present player"); top?.present(vc, animated: true) }
        if let picker = top, picker is UIHostingController<PhonePicker> { picker.dismiss(animated: true) { go() } } else { go() }
    }
    #endif
}

#if os(iOS)
// The picker: the title, its episode for a show, where he got to, and the streams his add-ons offer, best first.
struct PhonePicker: View {
    let type: String, imdb: String
    @State var video: String?
    let name: String, poster: String
    weak var model: TVModel?
    @State private var account = StremioAccount.shared
    @State private var meta: StremioAPI.Meta?
    @State private var library: [String: Any]?
    @State private var streams: [PhoneStream] = []
    @State private var loading = false
    @State private var problem: String?
    @State private var startOver = false
    @State private var sending = false
    @State private var only = "All"
    // His place is known (the library answered, or said it has none): until then a row would start at 0:00.
    @State private var placeKnown = false
    @Environment(\.dismiss) private var dismiss

    init(type: String, imdb: String, video: String?, name: String, poster: String, model: TVModel?) {
        self.type = type; self.imdb = imdb; _video = State(initialValue: video); self.name = name; self.poster = poster; self.model = model
    }
    var shownName: String { meta?.name.isEmpty == false ? meta!.name : name }
    var art: String { meta?.poster.isEmpty == false ? meta!.poster : poster }
    var episode: StremioAPI.Episode? { meta?.episodes.first { $0.id == video } }
    var line: String {
        guard type == "series", let e = episode else { return "" }
        return "S\(e.season) E\(e.episode)" + (e.name.isEmpty ? "" : " · \(e.name)")
    }
    var playID: String { type == "series" ? (video ?? "") : imdb }
    var resume: Double? { StremioAPI.resumeAt(library, video: playID) }
    var title: PhoneTitle { PhoneTitle(type: type, imdb: imdb, video: playID, name: shownName, line: line, poster: art, background: meta?.background ?? "") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !account.signedIn {
                        GlassSection(header: "Sign in to Stremio", footer: "Once, on this phone. Streams then come from your own add-ons, wherever you are.") {
                            StremioSignInForm { Task { await load() } }
                        }
                    } else {
                        if type == "series" { episodeRow }
                        if let r = resume {
                            Picker("Where to start", selection: $startOver) {
                                Text("Resume at " + Scrubber.time(r)).tag(false)
                                Text("Start over").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        streamList
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .background { Color.black.opacity(0.35).ignoresSafeArea() }
            .navigationTitle("Play on iPhone").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.ultraThinMaterial)
        .task { await load() }
        .onChange(of: video) { was, _ in
            guard was != nil else { return }
            // His place still unread: read it with the new episode, never streams alone (gate on 1c8b616).
            Task { if placeKnown { await loadStreams(force: true) } else { problem = nil; streams = []; await load() } }
        }
    }

    var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Art(url: URL(string: art)) { $0.resizable().scaledToFill() } placeholder: { CoverWait() }
                .frame(width: 70, height: 104).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(shownName).font(.title3.weight(.bold)).lineLimit(2)
                if !line.isEmpty { Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
    }

    var episodeRow: some View {
        let seasons = Dictionary(grouping: meta?.episodes ?? [], by: { $0.season }).keys.sorted { ($0 == 0 ? 999 : $0) < ($1 == 0 ? 999 : $1) }
        return Menu {
            ForEach(seasons, id: \.self) { s in
                Section(s == 0 ? "Specials" : "Season \(s)") {
                    ForEach((meta?.episodes ?? []).filter { $0.season == s }, id: \.id) { e in
                        Button { video = e.id } label: {
                            if e.id == video { Label("\(e.episode). \(e.name)", systemImage: "checkmark") } else { Text("\(e.episode). \(e.name)") }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "list.bullet").foregroundStyle(TVLook.accent)
                Text(episode.map { "Season \($0.season), episode \($0.episode)" } ?? (meta == nil ? "Finding episodes…" : "Choose an episode"))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).frame(height: 48).tvCard(14)
        }
        .tint(.white)
        .disabled(meta?.episodes.isEmpty != false)
    }

    @ViewBuilder var streamList: some View {
        // Best is 4K here; the quality chips let him pick another (the TV's own list leads with 1080p).
        let qualities = ["4K", "1080p", "720p", "480p"].filter { q in streams.contains { $0.quality == q } }
        HStack(spacing: 8) {
            Text("Streams").font(.title3.weight(.bold))
            Spacer(minLength: 4)
            if qualities.count > 1 {
                ForEach(["All"] + qualities, id: \.self) { q in
                    Button(q) { withAnimation(.snappy) { only = q } }
                        .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(height: 30)
                        .background(only == q ? TVLook.accent.opacity(0.25) : .white.opacity(0.1), in: Capsule())
                        .foregroundStyle(only == q ? TVLook.accent : .primary).buttonStyle(.plain)
                        .accessibilityAddTraits(only == q ? .isSelected : [])
                }
            }
        }
        .padding(.top, 4)
        if (loading || (problem == nil && meta == nil) || !placeKnown) && (streams.isEmpty || !placeKnown) && problem == nil {
            Text("Asking your add-ons…").font(.footnote).foregroundStyle(.secondary)
            ForEach(0..<4, id: \.self) { i in PlaceholderRow(delay: Double(i) * 0.12) }
        } else if let note = problem {
            VStack(spacing: 10) {
                Text(note).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { if placeKnown && !playID.isEmpty { await loadStreams(force: true) } else { problem = nil; streams = []; await load() } } }.tint(TVLook.accent)
            }
            .frame(maxWidth: .infinity).padding(.top, 18)
        }
        let best = streams.first { $0.playsHere && !$0.dubbed }
        if placeKnown { ForEach(streams.filter { only == "All" || $0.quality == only }) { s in row(s, best: s == best) } }
    }

    func row(_ s: PhoneStream, best: Bool) -> some View {
        Button { pick(s) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(s.title).font(.subheadline.weight(.bold)).lineLimit(1)
                        if best { tag(s.quality.isEmpty ? "Best" : "Best · \(s.quality)", lit: true) }
                        if s.torrent { tag("TV only", lit: false) }
                    }
                    Text(s.details).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    if !s.file.isEmpty { Text(s.file).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                Text(s.size ?? "").font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                Image(systemName: s.playsHere ? "play.fill" : "tv").font(.system(size: 15, weight: .semibold)).foregroundStyle(TVLook.accent).frame(width: 24)
            }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .tvCard(16)
        }
        .buttonStyle(.plain)
        .disabled(sending || (!s.playsHere && model == nil))
        .opacity(!s.playsHere && model == nil ? 0.45 : 1)
        .accessibilityLabel([s.title, s.details, s.size ?? "", s.playsHere ? "Plays on this iPhone" : "Plays on the TV"].filter { !$0.isEmpty }.joined(separator: ", "))
    }
    func tag(_ t: String, lit: Bool) -> some View {
        Text(t).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(lit ? TVLook.accent.opacity(0.22) : .white.opacity(0.14), in: Capsule())
            .foregroundStyle(lit ? TVLook.accent : .secondary)
    }

    func pick(_ s: PhoneStream) {
        let at = startOver ? 0 : (resume ?? 0)
        if s.playsHere {
            PhoneOpen.play(title, stream: s, others: streams.filter { $0 != s && $0.playsHere }, library: library, at: at, model: model)
        } else {
            // A torrent: the TV plays it, from the same spot.
            sending = true
            Task {
                let ok = await PhoneFlick.send(title: title, stream: s, at: at, model: model)
                sending = false
                if ok { dismiss() } else { problem = "The TV couldn’t be reached. Check the Mac’s connection." }
            }
        }
    }

    func load() async {
        guard account.signedIn else { return }
        loading = true
        // The streams are asked for at once when what to play is already known (a film, an episode named): the details
        // and his place come alongside, never first (gate item 3).
        let early = !playID.isEmpty
        async let first: Void = early ? loadStreams() : ()
        async let m = StremioAPI.meta(type: type, id: imdb)
        async let l = StremioAPI.libraryRead(imdb)
        let read = await l
        library = read.item
        meta = await m
        if !read.ok {
            // No rows until his place is known: a tap would start at 0:00 and then save over it (gate on 36e1b24).
            await first
            streams = []
            loading = false
            problem = "Couldn’t read where you are in it from Stremio. Try again."
            return
        }
        placeKnown = true
        if type == "series", video == nil {
            let on = (library?["state"] as? [String: Any])?["video_id"] as? String
            video = meta?.episodes.first { $0.id == on }?.id ?? meta?.episodes.first { $0.season > 0 }?.id ?? meta?.episodes.first?.id
        }
        await first
        if type == "series", video == nil {
            loading = false
            problem = "Couldn’t find this show’s episodes. Try again."
            return
        }
        if !early { await loadStreams() }
        if PhonePose.shouldPick() { await PhonePose.wait(3); if let s = streams.first(where: { $0.playsHere }) { pick(s) } }
    }
    func loadStreams(force: Bool = false) async {
        guard account.signedIn, !playID.isEmpty else { return }
        loading = true; problem = nil
        if force { streams = [] }
        do {
            let found = try await StremioAPI.streams(type: type, video: playID, title: shownName).filter { !$0.service }
            withAnimation(.easeOut(duration: 0.2)) { streams = found }
            if found.isEmpty { problem = "Your add-ons found no streams for this." }
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }
}
#endif

// Signing in, once: his email and password go to Stremio and nowhere else, and only the key it answers with is kept.
struct StremioSignInForm: View {
    var done: () -> Void = {}
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Email", text: $email).textContentType(.username).autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                #endif
            Divider()
            SecureField("Password", text: $password).textContentType(.password).onSubmit { go() }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Button { go() } label: {
                HStack { if busy { ProgressView().tint(.black) }; Text(busy ? "Signing in…" : "Sign in").fontWeight(.semibold) }
                    .frame(maxWidth: .infinity).frame(height: 44)
            }
            .buttonStyle(.borderedProminent).tint(TVLook.accent).foregroundStyle(.black)
            .disabled(busy || email.isEmpty || password.isEmpty)
        }
        .padding(.horizontal, GlassCard.inset).padding(.vertical, 14)
        .onAppear { PhonePose.signIn { e, p in email = e; password = p; go() } }
    }
    func go() {
        guard !busy, !email.isEmpty, !password.isEmpty else { return }
        busy = true; problem = nil
        Task {
            do { try await StremioAccount.shared.signIn(email: email, password: password); password = ""; done() }
            catch { problem = error.localizedDescription }
            busy = false
        }
    }
}

// Settings: Stremio on this phone. Signed in, who as, and the way out; signed out, the form.
enum StremioRoute: Hashable { case account }
struct StremioSettingsSection: View {
    @State private var account = StremioAccount.shared
    var body: some View {
        GlassSection(header: "On this iPhone") {
            NavigationLink(value: StremioRoute.account) {
                GlassRow(title: account.signedIn ? "Stremio · signed in" : "Stremio · sign in to play here", icon: "play.rectangle", opens: true)
            }
        }
        .buttonStyle(GlassRowPress())
    }
}
struct StremioAccountPage: View {
    @Environment(\.paneLayout) private var panes
    @State private var account = StremioAccount.shared
    var body: some View {
        Group { if panes { FoldSplit { page } right: { Color.clear } } else { page } }
            .background { Ambience() }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .barPage()
    }
    var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading("Stremio").padding(.horizontal, 4)
                if account.signedIn {
                    GlassSection(header: "Signed in", footer: "Play on iPhone uses your own add-ons and keeps your place in your Stremio library, so the TV and this phone carry on from each other.") {
                        GlassRow(title: account.email ?? "Your Stremio account", icon: "person.crop.circle")
                        Button(role: .destructive) { account.signOut() } label: { GlassRow(title: "Sign out", icon: "rectangle.portrait.and.arrow.right", acts: true) }
                            .buttonStyle(GlassRowPress())
                    }
                } else {
                    GlassSection(header: "Sign in", footer: "Your email and password go to Stremio only and aren’t kept; this phone keeps just the key Stremio answers with, in its Keychain.") {
                        StremioSignInForm()
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .topShade().topFade()
        .summonsBar()
    }
}

// What the player is doing, on the console (the build's films keep it; nothing about his account is in it).
enum PhoneLog { static func note(_ s: String) { FileHandle.standardError.write(Data(("[phone] \(Int(Date().timeIntervalSince1970) % 1000) " + s + "\n").utf8)) } }

// For the build's films only, against the stand-in Stremio ("-stremioAPI http://127.0.0.1:…"), never his account: the
// stand-in's sample login filled in, a title opened, its best stream played, and every key of the player pressed in
// turn at a finger's pace. Nothing happens without "-pose phone…" and a stand-in API.
@MainActor enum PhonePose {
    static var pose: String { UserDefaults.standard.string(forKey: "pose") ?? "" }
    static var on: Bool { pose.hasPrefix("phone") && StremioAPI.isStandIn }
    private static var ran = false, signed = false, chose = false
    static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    static func signIn(_ fill: @escaping (String, String) -> Void) {
        guard on, !signed else { return }
        signed = true
        Task { await wait(2.5); fill("sample@example.com", "sample") }
    }
    // The app up: Settings' Stremio page for the sign-in film, else the sample title's picker.
    static func launch(_ model: TVModel) {
        PhoneSystem.model = model
        guard on, !ran else { return }
        ran = true
        if UserDefaults.standard.bool(forKey: "phoneSignOut") { StremioAccount.shared.signOut() }
        Task {
            await wait(4)
            if pose == "phoneflick" {
                // The other way: Play on iPhone from the flick page's own streams.
                let item = MediaItem(title: "Sample Film", subtitle: "2024", art: "", id: "tt0000001", kind: "movie")
                // The stand-in Mac's own sample flick (a show) is taken down first: one flick at a time.
                model.closeFlick()
                await wait(1)
                model.flick(FlickTarget(item: item, source: .stremio))
                // The row itself is tapped by the film (Device Hub, by its label).
                return
            }
            let id = UserDefaults.standard.string(forKey: "phoneTitle") ?? "tt0000001"
            let type = UserDefaults.standard.string(forKey: "phoneType") ?? (id.contains(":") ? "series" : "movie")
            PhoneOpen.open(PhoneTitle(type: type, imdb: String(id.split(separator: ":").first ?? ""), video: id,
                                      name: "", line: "", poster: "", background: ""), model: model)
        }
    }
    static func shouldPick() -> Bool {
        guard on, !chose, pose != "phonepicker", pose != "phoneflick" else { return false }
        chose = true
        return true
    }
    #if os(iOS)
    static func run(_ s: PhoneSession) {
        guard on else { return }
        Task {
            func say(_ what: String) { Task { _ = await TVBridge.data(TVBridge.url("/api/tv/applied?what=phone-\(what)"), timeout: 3) } }
            // Played on while the film folds, opens and half closes the phone, a panel up part of the way.
            if pose == "phoneposture" {
                await wait(6); say("playing"); s.controls = true; s.poke()
                await wait(16); s.panel = .audio
                await wait(14); s.panel = nil
                await wait(30); say("saved"); await s.save()
                return
            }
            await wait(6); say("playing"); s.controls = true; s.poke()
            await wait(3); s.skip(10); await wait(0.4); s.skip(10)
            await wait(2); s.skip(-10)
            await wait(2); s.panel = .audio
            await wait(3); s.panel = nil
            await wait(1); s.panel = .subtitles
            await wait(2); if let t = s.subs.first { s.choose(t.id, audio: false) }; s.panel = nil
            await wait(3); s.panel = .speed
            await wait(2); s.setRate(1.5); s.panel = nil
            await wait(3); s.setRate(1); s.togglePlay()
            await wait(2); s.togglePlay()
            await wait(2); s.locked = true; s.controls = true
            await wait(3); s.locked = false; s.controls = true; s.poke()
            await wait(2); say("pip"); s.startPiP()
            await wait(6); s.startPiP()
            await wait(4); say("saved"); await s.save()
            if pose == "phoneplay-flick" { await wait(2); say("flick"); s.flickToTV() }
            if pose == "phoneplay-close" { await wait(2); say("close"); s.close() }
        }
    }
    #endif
}
