import SwiftUI
#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#endif

@main
struct ChumbyApp: App {
    @StateObject private var model = ChumbyModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .font(.custom("Trebuchet MS", size: 16))
                .toggleStyle(SwitchToggleStyle(tint: ChumbyPalette.on))
                .onChange(of: phase) { _, p in
                    if p == .active { model.start(); CalendarWake.shared.syncIfDue(); Task { await model.loadSongs(force: true) } } else { model.stop() }
                    #if os(iOS)
                    if p == .background { CalendarWake.shared.scheduleRefresh() }
                    #endif
                }
                .onAppear {
                    model.start()
                    ChumbyApp.dressBars()
                    // Calendar alarms follow the calendar from the start, not only once the Alarms tab has been opened.
                    if CalendarWake.shared.rules.enabled { CalendarWake.shared.startWatching() }
                    CalendarWake.shared.syncIfDue()
                    // "Woke up to" covers, from the kept list and then the fresh one, long before Alarms is opened.
                    SongArt.shared.prefetch(model.songs, model.state.alarms, model.rings)
                    Task { await model.loadSongs(); SongArt.shared.prefetch(model.songs, model.state.alarms, model.rings) }
                    TabTour.run([0, 1, 2, 3, 4]) { model.tab = $0 }
                }
                .onOpenURL { if $0.host == "tab", let t = Int($0.lastPathComponent) { model.tab = t } }
                // While music plays on the Chumby, "Woke up to" and its widget follow it song by song, on any tab.
                .task(id: model.state.musicPlaying) {
                    while model.state.musicPlaying && !Task.isCancelled {
                        await model.loadSongs(force: true)
                        SongArt.shared.prefetch(model.songs, model.state.alarms, model.rings)
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                    }
                }
        }
        #if os(iOS)
        // iOS decides when, so this only helps; the alarms already on the Chumby ring regardless.
        .backgroundTask(.appRefresh(CalendarWake.refreshID)) {
            await CalendarWake.shared.sync()
            await CalendarWake.shared.scheduleRefresh()
        }
        #endif
    }
}

extension ChumbyApp {
    // A pushed page's title is the system's own large title (so Back and the title are laid out by iOS the Duo's way),
    // in the face every tab's title wears: Trebuchet, bold, 30 pt, and 18 pt once it has collapsed into the bar.
    static func dressBars() {
        #if canImport(UIKit)
        let bar = UINavigationBar.appearance()
        if let big = UIFont(name: "Trebuchet MS", size: 30), let small = UIFont(name: "Trebuchet MS", size: 18) {
            let bold = UIFontDescriptor.SymbolicTraits.traitBold
            bar.largeTitleTextAttributes = [.font: UIFont(descriptor: big.fontDescriptor.withSymbolicTraits(bold) ?? big.fontDescriptor, size: 30)]
            bar.titleTextAttributes = [.font: UIFont(descriptor: small.fontDescriptor.withSymbolicTraits(bold) ?? small.fontDescriptor, size: 18)]
        }
        #endif
    }
}

// MARK: - The sea, the ghost, the glass
// The sea's soft blobs and the ghost octopus, each drawn once and kept, so the drift only moves pictures: drawing four big
// gradients and a path again every frame cost every tab its smoothness, and every glass control over them its backdrop.
@MainActor enum SeaArt {
    private static var blobs: [String: Image] = [:], ghosts: [String: Image] = [:]
    // The gradient for one blob, at a fixed size; a soft gradient scaled up looks the same as one drawn at full size.
    static func blob(_ dark: Bool, _ i: Int, _ color: Color) -> Image {
        let key = "\(dark)-\(i)"
        if let b = blobs[key] { return b }
        let side: CGFloat = 512
        let r = ImageRenderer(content: Circle().fill(RadialGradient(colors: [color, color.opacity(0.75), color.opacity(0)], center: .center, startRadius: 0, endRadius: side / 2)).frame(width: side, height: side))
        r.scale = 1
        let image = r.cgImage.map { Image(decorative: $0, scale: 1) } ?? Image(systemName: "circle")
        blobs[key] = image
        return image
    }
    // The ghost at the size it's shown, at the display's scale, so its edge is as crisp as the shape drawn live.
    static func ghost(_ dark: Bool, _ size: CGSize, _ scale: CGFloat) -> Image {
        let key = "\(dark)-\(Int(size.width))x\(Int(size.height))@\(scale)"
        if let g = ghosts[key] { return g }
        let r = ImageRenderer(content: ArtShape(art: ChumbyArt.octBody, box: ChumbyArt.octBox)
            .fill(dark ? ChumbyPalette.hex(0x79bbff).opacity(0.08) : Color.white.opacity(0.34), style: FillStyle(eoFill: true))
            .frame(width: max(size.width, 1), height: max(size.height, 1)))
        r.scale = scale
        let image = r.cgImage.map { Image(decorative: $0, scale: scale) } ?? Image(systemName: "circle")
        if ghosts.count > 6 { ghosts.removeAll() }
        ghosts[key] = image
        return image
    }
}
// Soft gradients drifting with the clock. Only where they are in their drift changes, worked out afresh each frame from
// the size the sea has now, so nothing ever animates from where it was before the page had a size.
struct SeaBackground: View {
    var active = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        let c = ChumbyPalette.sea(scheme == .dark)
        GeometryReader { g in
            let m = max(g.size.width, g.size.height)
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still || !active)) { ctx in
                let t = still ? 0 : ctx.date.timeIntervalSinceReferenceDate
                let dark = scheme == .dark
                ZStack {
                    c[0]
                    blob(SeaArt.blob(dark, 1, c[1]), m * 1.05, -0.30, -0.28, 26, m, t)
                    blob(SeaArt.blob(dark, 2, c[2]), m * 0.75, 0.34, -0.10, 33, m, t)
                    blob(SeaArt.blob(dark, 3, c[3]), m * 0.80, -0.22, 0.32, 29, m, t)
                    blob(SeaArt.blob(dark, 4, c[4]), m * 0.55, 0.26, 0.32, 37, m, t)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .transaction { $0.animation = nil }
    }
    // The same ease in and out as before, back and forth over twice its period, as a sine of the time. Each frame only
    // moves and scales a gradient drawn once (SeaArt), rather than drawing the gradient again.
    func blob(_ art: Image, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ period: Double, _ m: CGFloat, _ t: Double) -> some View {
        let k = CGFloat(0.5 - 0.5 * cos(.pi * t / period))
        return art.resizable().interpolation(.high)
            .frame(width: size, height: size)
            .scaleEffect(1 + 0.14 * k)
            .offset(x: m * x + size * (-0.05 + 0.12 * k), y: m * y + size * (-0.03 + 0.09 * k))
    }
}

struct GhostOctopus: View {
    var active = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        GeometryReader { g in
            // Drawn once at this size, then only turned and moved each frame.
            let size = CGSize(width: min(g.size.width, g.size.height) * 1.5, height: g.size.height)
            let art = SeaArt.ghost(scheme == .dark, size, displayScale)
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still || !active)) { ctx in
                let k = still ? 0.5 : 0.5 - 0.5 * cos(.pi * ctx.date.timeIntervalSinceReferenceDate / 14)
                art.resizable()
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(-3 + 6 * k))
                    .offset(y: -8 + 22 * k)
                    .position(x: g.size.width / 2, y: g.size.height * 0.42)
            }
        }
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
    }
}

// Content sits on soft translucent cards, per Apple's guidance to keep Liquid Glass off the content layer.
struct CardFill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: scheme == .dark ? [Color(red: 0.12, green: 0.24, blue: 0.47).opacity(0.7), Color(red: 0.04, green: 0.12, blue: 0.29).opacity(0.6)] : [.white.opacity(0.72), .white.opacity(0.42)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(scheme == .dark ? 0.22 : 0.7), lineWidth: 1))
        }
    }
}
extension View {
    func card(_ radius: CGFloat = 26) -> some View { modifier(CardFill(radius: radius)) }
    func glass(_ radius: CGFloat = 26) -> some View { self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
    func glassCircle() -> some View { self.glassEffect(.regular.interactive(), in: Circle()) }
    func seaList() -> some View { self.scrollContentBackground(.hidden).listSectionSpacing(14).roomyIndicators() }
    // No scroll bars in any Chumby list or scroll. Inset 7 pt they only hung as a grey line against the cards, by the rail
    // (Richard, 2026-11-05: "the scroll bar is too close to the screen for my eyes", then "the scroll bar dude"); the pages
    // are short and their content shows where you are.
    // Every list and scroll in the app comes through here, and each says when it's moving: readings from the Chumby
    // wait while one is, so no row changes height under a page pulled past its end, which snaps the page back in one
    // move instead of letting it spring (Richard, 2026-11-08, on the Mac Pro app: "it doesnt bounce back naturally its
    // like a sudden move back", to be fixed "in all apps if it exists").
    func roomyIndicators() -> some View { self.scrollIndicators(.hidden).modifier(ScrollMoving()) }
}
struct ScrollMoving: ViewModifier {
    @State private var id = UUID()
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onScrollPhaseChange { _, phase in ScrollHold.set(id, moving: phase != .idle) }
            .onDisappear { ScrollHold.set(id, moving: false) }
        #else
        content
        #endif
    }
}
// Which pages are moving right now. Readings from the Chumby wait while any is, never more than 4 s at a stretch; his
// own saves, skips and channel changes never wait, and a ring starting or ending never does either (ChumbyModel).
@MainActor
enum ScrollHold {
    private static var moving: Set<UUID> = []
    private static var since = Date.distantPast
    static var onRelease: (() -> Void)?
    static var holding: Bool { !moving.isEmpty && Date().timeIntervalSince(since) < 4 }
    static func set(_ id: UUID, moving now: Bool) {
        let was = !moving.isEmpty
        if now { moving.insert(id) } else { moving.remove(id) }
        if !was && !moving.isEmpty { since = Date() }
        if was && moving.isEmpty { onRelease?() }
    }
}
struct GlassRow: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(scheme == .dark ? Color(red: 0.09, green: 0.19, blue: 0.38).opacity(0.62) : Color.white.opacity(0.46))
    }
}
struct PageTitle<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) { self.title = title; self.trailing = trailing() }
    var body: some View {
        HStack {
            Text(title).font(.custom("Trebuchet MS", size: 30).weight(.bold))
            Spacer()
            trailing
        }
        .frame(minHeight: 44)
        .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 0, trailing: 6))
    }
}

// MARK: - iPhone Duo panes
struct TwoPane<L: View, R: View>: View {
    @Environment(\.paneLayout) private var panes
    @Environment(\.horizontalSizeClass) private var size
    let left: L, right: R
    // The right pane's own title, when it shows a page of its own (Calendar settings), with its way back. Nil when the
    // page brings its own title row (the alarm editor, a calendar day).
    var rightTitle: String? = " "
    var rightTrailing: AnyView?
    init(rightTitle: String? = " ", rightTrailing: AnyView? = nil, @ViewBuilder _ left: () -> L, @ViewBuilder right: () -> R) {
        self.rightTitle = rightTitle; self.rightTrailing = rightTrailing; self.left = left(); self.right = right()
    }
    var body: some View {
        if panes {
            FoldSplit {
                List { Group { left }.listRowBackground(GlassRow()) }
            } right: {
                // A title row, blank unless the pane holds a page, so both panes start level.
                List { if let rightTitle { PageTitle(rightTitle) { rightTrailing } }; Group { right }.listRowBackground(GlassRow()) }
            }
            .seaList()
        } else {
            // Open in portrait the status bar has the top to itself, so the list's own top margin is left off there.
            List { Group { left; right }.listRowBackground(GlassRow()) }
                .contentMargins(.top, size == .regular ? 0 : nil, for: .scrollContent)
        }
    }
}

// The page fades out just above the tab bar, so nothing reads through its glass ("Chumby Classic" did, on Home, under the
// tabs: Richard's phone, 2026-11-05). A mask on the page, not a band of colour over it: the sea behind stays whole, and
// only the page's own cards and words dissolve as they reach the bar. The bar's own space is the page's bottom safe area,
// so this follows it folded (bar along the foot) and open (rail at the side, only the home indicator below).
// The fade runs from the bar's top edge down its first 18 pt, so a card resting just above the bar is never touched.
// The inset is read on the page itself: a reader inside the mask that ignores the safe area always saw 0, so the fade was
// 0 pt tall and the words read through the bar anyway (r24/r25).
struct TabBarFade: ViewModifier {
    static let fade: CGFloat = 18
    @State private var inset: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset = $0 }
            .mask {
            GeometryReader { _ in
                // Fades over the 18 pt above the bar's top edge, and nothing at all from that edge down, so no word reads
                // through the bar. Only where a tab bar runs across the foot (an inset that tall); elsewhere, no mask.
                let bar = inset > 40
                VStack(spacing: 0) {
                    Color.black
                    if bar {
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
                        Color.clear.frame(height: inset)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    // Each tab paints its own sea: the system tab view is opaque behind its content. Only the tab on screen drifts.
    func overSea(active: Bool = true, shown: Bool = true) -> some View {
        self.background { if shown { ZStack { SeaBackground(active: active); GhostOctopus(active: active) }.ignoresSafeArea() } }
    }
    // A tab's own page: its title is the first row, so no empty bar sits above it and every tab starts at the same height.
    func tabPage(_ tab: Int, _ model: ChumbyModel) -> some View {
        self.modifier(TabBarFade()).overSea(active: model.tab == tab).toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - The shell
// System tabs get Liquid Glass and move to the Duo's right edge by themselves.
struct RootView: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var size
    @State private var resets: [Int: Int] = [:]
    var body: some View {
        PaneReader {
            ZStack {
                // The sea's own base colour under everything, so the first frame matches the launch screen.
                ChumbyPalette.sea(scheme == .dark)[0].ignoresSafeArea()
                // The Duo's side column (clock, Wi-Fi and the tab bar) is the trailing safe area.
                Color.clear.ignoresSafeArea().onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: { model.railWidth = $0 }
                TabView(selection: TabReset.binding($model.tab) { t in
                    resets[t, default: 0] += 1
                    if t == 2 { model.alarmsPage = false }
                    // Home again: the octopus answers, as it does to a tap.
                    if t == 0 { model.homePoke = Date() }
                }) {
                    Tab(value: 0) { NavigationStack { HomeTab().tabPage(0, model) }.id(resets[0, default: 0]) } label: { tabLabel("my chumby", asset: "OctoTab", fit: 34) }
                    Tab(value: 1) { NavigationStack { ChannelsTab().tabPage(1, model) }.id(resets[1, default: 0]) } label: { tabLabel("channels", "tv") }
                    Tab(value: 2) { NavigationStack { AlarmsTab().tabPage(2, model) }.id(resets[2, default: 0]) } label: { tabLabel("alarms", "alarm") }
                    Tab(value: 3) { NavigationStack { SoundsTab().tabPage(3, model) }.id(resets[3, default: 0]) } label: { tabLabel("sounds", "music.note") }
                    Tab(value: 4) { NavigationStack { TinkerTab().tabPage(4, model) }.id(resets[4, default: 0]) } label: { tabLabel("tinker", "wrench.adjustable") }
                }
                .onChange(of: model.tab) { _, t in model.tick(); UserDefaults.standard.set(t, forKey: "tab") }
            }
            .tint(ChumbyPalette.acc(scheme == .dark))
            .foregroundStyle(ChumbyPalette.ink(scheme == .dark))
        }
        .sheet(isPresented: $model.needsAddress) { ConnectionView().environmentObject(model).interactiveDismissDisabled(model.api == nil) }
    }
}
// "Offline · last seen 7:12" as a row under a page's title, never floating over the list; a tap says what to do.
struct ReachRow: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var open = false
    var seen: String { model.seenAt.map { " · last seen " + seenText($0) } ?? "" }
    var body: some View {
        if model.unreachable {
            chip
                .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 6, trailing: 6))
        }
    }
    var chip: some View {
        Button { withAnimation(.snappy) { open.toggle() } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text((model.dead ? "Not answering" : "Offline") + seen).font(.custom("Trebuchet MS", size: 15).weight(.bold)).lineLimit(1)
                }
                if open {
                    Text(model.dead ? model.deadText : "Can’t reach the Mac or the Chumby. Check Tailscale; the Chumby may also be restarting.")
                        .font(.custom("Trebuchet MS", size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 300, alignment: .leading)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glass(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows what to do")
    }
}
func seenText(_ d: Date) -> String {
    Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

struct ConnectionView: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://chumby.local", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Chumby address") }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Connection").font(.custom("Trebuchet MS", size: 18).weight(.bold)) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        model.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        if model.api != nil { model.needsAddress = false; model.start(); dismiss() }
                    }.disabled(address.isEmpty)
                }
            }
            .onAppear { address = model.address }
        }
    }
}

// MARK: - The octopus
struct SkewEffect: GeometryEffect {
    var skew: CGFloat, anchorY: CGFloat
    var animatableData: CGFloat { get { skew } set { skew = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(a: 1, b: 0, c: tan(skew), d: 1, tx: -tan(skew) * size.height * anchorY, ty: 0))
    }
}
struct Bubble: Identifiable { let id = UUID(); let x: CGFloat, size: CGFloat, dx: CGFloat, delay: Double, born: Date }

struct LiveOctopus: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    @EnvironmentObject var model: ChumbyModel
    let squishedAt: Date?
    var scale: CGFloat = 1
    // How far his top edge may ever rise above where he rests, whatever bob, wobble or hop is playing: the wordmark sits just past it.
    var headroom: CGFloat = .infinity
    static let knee: CGFloat = 6
    // His top edge's lift, eased into the headroom past the knee so a hop slows to a stop instead of hitting a flat ceiling.
    func clamped(_ rise: CGFloat) -> CGFloat {
        let k = min(Self.knee, headroom)
        guard rise > k, headroom.isFinite, headroom > k else { return min(rise, headroom) }
        return k + (headroom - k) * (1 - exp(-(rise - k) / (headroom - k)))
    }
    var body: some View {
        // Ringing, he wobbles hard; gone quiet, he sinks a little with his eyes shut.
        let asleep = model.unreachable
        let ringing = !asleep && (model.sys.ringing.map { !$0.snoozed } ?? false)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || model.tab != 0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // The same curves as the web app's CSS: ease-in-out both ways, as a sine.
            // Asleep he bobs less and a little higher, so the tips of his arms stay well clear of the bezel (about 8 pt).
            let bob = (asleep ? -3 : -7) * scale * (0.5 - 0.5 * cos(2 * .pi * t / (asleep ? 7 : ringing ? 0.9 : 4.2))) - (asleep ? 5 : 0)
            let swing = 0.5 - 0.5 * cos(2 * .pi * t / (ringing ? 0.32 : 3))
            let wave = swing * 2 - 1
            let lift = swing
            let cycle = t.truncatingRemainder(dividingBy: 5.3) / 5.3
            let blink: CGFloat = asleep ? 0.06 : cycle > 0.94 ? (cycle < 0.97 ? 1 - (cycle - 0.94) / 0.03 * 0.94 : 0.06 + (cycle - 0.97) / 0.03 * 0.94) : 1
            let (sx, sy, dy0) = squish(at: ctx.date)
            let dy = dy0 * scale
            let stretch = 1 + (ringing ? 0.08 : 0.035) * lift
            // Where his top edge lands after the stretch (anchored 16% down), the squish (anchored 90% down) and the bob;
            // the skew only leans him sideways. Any lift past the headroom is taken back off the offset.
            let h = 92 * scale * ChumbyArt.octBox.height / ChumbyArt.octBox.width
            let top = 0.9 * h + (0.16 * h * (1 - stretch) - 0.9 * h) * sy + bob + dy
            let rise = max(0, -top)
            OctopusMark(color: ChumbyPalette.oct(scheme == .dark), blink: blink)
                .scaleEffect(x: 1, y: stretch, anchor: UnitPoint(x: 0.5, y: 0.16))
                .modifier(SkewEffect(skew: CGFloat(wave) * (ringing ? 11 : 4.5) * .pi / 180, anchorY: 0.16))
                .scaleEffect(x: sx, y: sy, anchor: UnitPoint(x: 0.5, y: 0.9))
                .offset(y: bob + dy + (rise - clamped(rise)))
                .opacity(asleep ? 0.75 : 1)
        }
    }
    func squish(at now: Date) -> (CGFloat, CGFloat, CGFloat) {
        guard let squishedAt else { return (1, 1, 0) }
        let p = now.timeIntervalSince(squishedAt) / 0.62
        guard p >= 0, p < 1 else { return (1, 1, 0) }
        func mix(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k * k * (3 - 2 * k)) }
        if p < 0.28 { let k = p / 0.28; return (mix(1, 1.28, k), mix(1, 0.68, k), mix(0, 12, k)) }
        if p < 0.62 { let k = (p - 0.28) / 0.34; return (mix(1.28, 0.86, k), mix(0.68, 1.2, k), mix(12, -20, k)) }
        let k = (p - 0.62) / 0.38
        return (mix(0.86, 1, k), mix(1.2, 1, k), mix(-20, 0, k))
    }
}
// Snoozing: a ring of water round the octopus that drains as the snooze runs out.
// Always there, faded and grown in by `shown`, which moves in the same spring as the device's drop, so the ring
// never pops in on one frame. While it fades out it keeps the water level it had.
struct SnoozeRing: View {
    @EnvironmentObject var model: ChumbyModel
    var shown: CGFloat
    @State private var kept: Double = 1
    func left(_ now: Date) -> Double {
        guard let r = model.sys.ringing, r.snoozed, !model.unreachable else { return kept }
        return model.snoozeEnds.map { end in
            let total = Double(model.state.alarms.first { $0.name == r.name }?.snooze ?? "") ?? 9
            return min(max(end.timeIntervalSince(now) / (total * 60), 0), 1)
        } ?? 1
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let l = left(ctx.date)
            ZStack {
                Circle().stroke(ChumbyPalette.hex(0x79bbff).opacity(0.18), lineWidth: 5)
                Circle().trim(from: 0, to: l).stroke(ChumbyPalette.hex(0x79bbff).opacity(0.75), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .scaleEffect(0.85 + 0.15 * shown)
        .opacity(shown)
        .allowsHitTesting(false)
        .accessibilityHidden(shown < 0.5)
        // Noted each second while snoozed, so once stopped it fades out at the level it was showing.
        .task(id: model.sys.ringing?.snoozed == true) {
            while model.sys.ringing?.snoozed == true && !Task.isCancelled {
                kept = left(Date())
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

// MARK: - My Chumby
struct HomeTab: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.paneLayout) private var wide
    @Environment(\.colorScheme) private var scheme
    @AppStorage("welcomed") private var welcomed = false
    @State private var moreInfo = false
    @State private var say: String?
    @State private var line = 0
    @State private var squishedAt: Date?
    @State private var ink: (CGPoint, UUID)?
    @State private var bubbles: [Bubble] = []
    @State private var goneAt: Date?
    @State private var demoed = false
    private static let lines = ["chumbalicious!", "welcome back.", "enjoy tinkering?", "wake up to your internet life", "eight arms, one job", "squeeze me!", "blub.", "i run on 175 MHz and vibes"]
    var dark: Bool { scheme == .dark }
    var ringing: Bool { !model.unreachable && (model.sys.ringing.map { !$0.snoozed } ?? false) }

    func poke() {
        model.tick()
        squishedAt = Date()
        withAnimation(.spring(duration: 0.38, bounce: 0.6)) { say = Self.lines[line % Self.lines.count] }
        line += 1
        puff(7)
        let now = Date()
        Task {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if Date().timeIntervalSince(now) >= 1.85 { withAnimation(.spring(duration: 0.3)) { say = nil } }
        }
    }
    func puff(_ n: Int) {
        let now = Date()
        bubbles.removeAll { now.timeIntervalSince($0.born) > 2.2 }
        bubbles += (0..<n).map { _ in Bubble(x: .random(in: 0...1), size: .random(in: 8...28), dx: .random(in: -40...40), delay: .random(in: 0...0.25), born: now) }
    }

    // The web app's proportions: the octopus is 92 wide on a 380 stage and sits 58 above its top edge.
    var stageWidth: CGFloat { wide ? 340 : 330 }
    var k: CGFloat { stageWidth / 380 }
    var ringSize: CGFloat { 92 * k * 1.15 }
    var octHeight: CGFloat { 92 * k * ChumbyArt.octBox.height / ChumbyArt.octBox.width }
    var ringLift: CGFloat { -(ringSize - octHeight) / 2 - 2 }
    var snoozing: Bool { !model.unreachable && model.sys.ringing?.snoozed == true }
    // Top to bottom, all hung off the device so nothing outside can shift one against another:
    // 6 pt margin, the 30 pt wordmark, 14 pt of clear air, the octopus (top 58k + 15 above the device), the device.
    // Of those 14 pt the octopus may rise 8 at most (bob, wobble, hop, clamped in LiveOctopus), so 6 always stay clear.
    static let wordTop: CGFloat = 6, wordHeight: CGFloat = 30, headroom: CGFloat = 8, clearance: CGFloat = 6
    var restGap: CGFloat { Self.headroom + Self.clearance }
    var octLift: CGFloat { 58 * k + 15 }
    // The snooze ring stands this far above the octopus's top: its extra size, its 2 pt lift and half its 5 pt stroke.
    var ringRise: CGFloat { ringSize - octHeight + 2 + 2.5 }
    // Snoozed, the octopus and device drop just enough that the ring's top keeps the same 6 pt clear of the wordmark.
    // Read straight from the ring, so the drop moves in the very transaction (and spring) that changed it, with the card's
    // buttons, rather than starting a frame later from an onChange.
    var snoozeK: CGFloat { snoozing ? 1 : 0 }
    var snoozeRoom: CGFloat { max(0, ringRise + Self.clearance - restGap) * snoozeK }
    // From the octopus's top up to the wordmark's foot.
    var wordGap: CGFloat { restGap + snoozeRoom }
    // How high a bubble may rise, from the octopus's centre: fully gone 8 pt below the wordmark's foot (the y's tail
    // included), so none ever crosses a letter.
    static let bubbleAir: CGFloat = 8
    var bubbleCeiling: CGFloat { -(octHeight / 2 + wordGap - Self.bubbleAir) }
    // A box the octopus's size, where he rests, for hanging things off his centre.
    func atOctopus<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        Color.clear.frame(width: 92 * k, height: octHeight).overlay { content() }.offset(y: -octLift)
    }
    var stage: some View {
        Image("Device").resizable().scaledToFit()
            .shadow(color: Color(red: 0.02, green: 0.09, blue: 0.26).opacity(0.45), radius: 22, y: 24)
            .overlay {
                GeometryReader { g in
                    liveScreen
                        .frame(width: g.size.width * 0.6065, height: g.size.height * 0.517)
                        .position(x: g.size.width * (0.1833 + 0.6065 / 2), y: g.size.height * (0.234 + 0.517 / 2))
                }
            }
            // Layers, back to front: octopus, bubbles, wordmark, his speech bubble. The wordmark and octopus never share a
            // point (see wordGap and headroom), and bubbles are gone 8 pt below its foot (bubbleCeiling).
            .overlay(alignment: .top) {
                ZStack {
                    LiveOctopus(squishedAt: squishedAt, scale: k, headroom: Self.headroom).frame(width: 92 * k)
                        // Hung off the octopus, so it never changes where he sits.
                        // Its foot level with the tips of his arms, so it stays above the device too.
                        .overlay {
                            SnoozeRing(shown: snoozeK).frame(width: ringSize, height: ringSize).offset(y: ringLift)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { poke() }
                        .accessibilityLabel("Octopus").accessibilityAddTraits(.isButton)
                    bubbleLayer
                }
                // The octopus sits clear above the device, not on it.
                .offset(y: -octLift)
            }
            .overlay(alignment: .top) {
                wordmark.offset(y: -(octLift + wordGap + Self.wordHeight)).allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                atOctopus {
                    if let say {
                        Text(say).font(.custom("Trebuchet MS", size: 15).weight(.bold)).lineLimit(1).fixedSize().padding(.horizontal, 15).padding(.vertical, 7).glass(18)
                            .offset(y: -46 * k - 8).transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: stageWidth)
            .padding(.top, Self.wordTop + Self.wordHeight + wordGap + octLift)
            // While it rings, bubbles keep coming.
            .task(id: ringing) {
                while ringing && !Task.isCancelled { puff(2); try? await Task.sleep(nanoseconds: 450_000_000) }
            }
            .onChange(of: model.unreachable) { _, gone in goneAt = gone ? Date() : nil }
            // Going quiet mid-snooze moves him too, in the same spring a ring change would.
            .animation(ChumbyModel.ringChange(to: model.sys.ringing), value: snoozing)
            .onAppear {
                if model.unreachable && goneAt == nil { goneAt = Date().addingTimeInterval(-5) }
                if let p = model.homePoke, Date().timeIntervalSince(p) < 1.5 { poke() }
                // For the build's film: News chosen on Home's channel capsule (as its menu does it), then over to
                // Channels, whose editor has followed the choice.
                if ChumbyModel.pose == "homechdemo" && !demoed {
                    demoed = true
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000); model.playChannel("News", id: "homeChannel")
                        try? await Task.sleep(nanoseconds: 3_500_000_000); model.tab = 1
                    }
                }
                // For the build's film: the alarm rings, is snoozed, then stopped.
                if ChumbyModel.pose == "ringdemo" && !demoed {
                    demoed = true
                    Task {
                        try? await Task.sleep(nanoseconds: 3_500_000_000); model.ringSnooze()
                        try? await Task.sleep(nanoseconds: 4_000_000_000); model.ringOff()
                    }
                }
            }
            .onChange(of: model.homePoke) { _, _ in poke() }
    }
    // Under the device: when it was last seen, or what it's busy doing.
    @ViewBuilder var status: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let b = model.busy, b.until > ctx.date {
                Text(b.text)
            } else if model.unreachable {
                Text(model.seenAt.map { "last seen " + seenText($0) } ?? (model.dead ? "not answering" : "can’t reach it"))
            }
        }
        .font(.custom("Trebuchet MS", size: 16).weight(.bold)).foregroundStyle(ChumbyPalette.sub(dark))
        .padding(.top, 14)
        if let f = model.failed("screen") { FailNote(text: f).padding(.top, 8) }
    }
    var bubbleLayer: some View {
        let ceiling = bubbleCeiling
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: bubbles.isEmpty)) { ctx in
            ZStack {
                ForEach(bubbles) { b in
                    let p = (ctx.date.timeIntervalSince(b.born) - b.delay) / 1.7
                    let y = 10 - 190 * p * p
                    // Its top edge against the ceiling: gone over the last 14 pt, so none ever comes near the wordmark.
                    let room = (y - b.size * (1 + 0.3 * p) / 2 - ceiling) / 14
                    if p >= 0, p < 1, room > 0 {
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.95), .white.opacity(0.14), ChumbyPalette.hex(0x79bbff).opacity(0.28)], center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: b.size * 0.7))
                            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                            .frame(width: b.size, height: b.size)
                            .scaleEffect(1 + 0.3 * p)
                            .offset(x: (b.x - 0.5) * 92 + b.dx * p, y: y)
                            .opacity((1 - p * p) * min(room, 1))
                    }
                }
            }
        }
        // Cut off at the ceiling too, so not even a bubble's soft edge gets above it.
        .mask { Rectangle().frame(width: 2000, height: 2000).offset(y: 1000 + ceiling) }
        .allowsHitTesting(false)
    }
    var liveScreen: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05)
                if let i = model.shot { Image(platform: i).resizable().interpolation(.medium) }
                else if !model.unreachable { ProgressView().tint(.white) }
                // Gone quiet: soft static for a moment, then the screen goes dark.
                if let goneAt { ScreenStatic(since: goneAt) }
                LinearGradient(colors: [.white.opacity(0.17), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.5, y: 0.5)).allowsHitTesting(false)
                if let ink {
                    InkDrop().position(ink.0).id(ink.1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onTapGesture { p in
                guard !model.unreachable else { return }
                ink = (p, UUID())
                model.cmd("tap", "\(Int(p.x / geo.size.width * 319)),\(Int(p.y / geo.size.height * 239))", id: "screen")
                Task { try? await Task.sleep(nanoseconds: 350_000_000); _ = await model.refreshShot() }
            }
            .accessibilityLabel("The Chumby’s screen, live. Tap to touch it.")
        }
        .task(id: model.tab) {
            guard model.tab == 0 else { return }
            while !Task.isCancelled {
                let ok = model.running && !model.unreachable ? await model.refreshShot() : true
                try? await Task.sleep(nanoseconds: model.direct ? 10_000_000_000 : ok ? 1_000_000_000 : 3_000_000_000)
            }
        }
    }
    func spec(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.custom("Trebuchet MS", size: 15).weight(.bold)).gridColumnAlignment(.trailing)
            Text(v).font(.custom("Trebuchet MS", size: 15)).foregroundStyle(ChumbyPalette.sub(dark)).gridColumnAlignment(.leading)
        }
    }
    var name: String { Bundle.main.object(forInfoDictionaryKey: "ChumbyName") as? String ?? "" }
    var serial: String { Bundle.main.object(forInfoDictionaryKey: "ChumbySerial") as? String ?? "" }
    var about: some View {
        VStack(spacing: 0) {
            Text("Chumby Classic").font(.custom("Trebuchet MS", size: 30).weight(.bold))
            Text("Black, 3.5-inch, 2008").font(.custom("Trebuchet MS", size: 15)).foregroundStyle(ChumbyPalette.sub(dark)).padding(.top, 2).padding(.bottom, 16)
            Grid(horizontalSpacing: 12, verticalSpacing: 5) {
                if !name.isEmpty { spec("Name", name) }
                spec("Chip", "Freescale i.MX21, ARM926EJ-S")
                spec("Memory", "64 MB")
                spec("Display", "3.5-inch, 320 × 240, touch")
                if !serial.isEmpty { spec("Serial number", serial) }
                spec("Software", "1.7.2 (build 1830)")
            }
            if !wide {
                Button(moreInfo ? "Less Info…" : "More Info…") { withAnimation(.spring(duration: 0.4, bounce: 0.3)) { moreInfo.toggle() } }
                    .font(.custom("Trebuchet MS", size: 16).weight(.bold)).buttonStyle(.glass).padding(.top, 16)
            }
            // Said the first time only.
            if !welcomed {
                Text("Welcome. Tap the screen to touch it; tap the octopus to say hi.").font(.custom("Trebuchet MS", size: 15)).foregroundStyle(ChumbyPalette.sub(dark)).multilineTextAlignment(.center).padding(.top, 12).padding(.horizontal, 16)
                    .onDisappear { welcomed = true }
            }
            Color.clear.frame(height: 20)
        }
    }
    var memoryUsed: Double { model.sys.memTotal > 0 ? 1 - Double(model.sys.memFree) / Double(model.sys.memTotal) : 0 }
    // The same meters, colours and percentages as the widgets, a little thicker.
    var more: some View {
        VStack(spacing: 0) {
            infoRow("Awake for", duration(model.sys.up))
            infoRow("Load", String(format: "%.2f", model.sys.load))
            MeterRow(label: "Memory", text: "\(Int((memoryUsed * 100).rounded()))%", value: memoryUsed, color: memoryUsed > 0.92 ? .red : memoryUsed > 0.8 ? .orange : ChumbyPalette.oct(dark))
            if model.sys.wifi >= 0 { MeterRow(label: "Wi-Fi", text: "\(model.sys.wifi)%", value: Double(model.sys.wifi) / 100, color: ChumbyPalette.oct(dark)) }
            else { infoRow("Wi-Fi", "Not connected") }
            infoRow("Flash storage", "\(model.sys.pspFree) KB free", warn: model.sys.pspFree > 0 && model.sys.pspFree < 400)
            infoRow("Power", model.sys.wall == 1 ? "Wall power" : "Battery")
            infoRow("Unfroze itself", model.sys.resets == 0 ? "Never" : "\(model.sys.resets)× · last " + Date(timeIntervalSince1970: Double(model.sys.resetAt)).formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        }
        .padding(.vertical, 6)
        .card().padding(.bottom, 20)
    }
    func infoRow(_ k: String, _ v: String, warn: Bool = false) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(ChumbyPalette.sub(dark))).multilineTextAlignment(.trailing) }
            .padding(.horizontal, 18).frame(minHeight: 44)
    }
    // Home in the order he uses it (Richard, 2026-11-05: "next alarm and right now like that whole section is too close
    // together … idek what right now means make the home screen make more sense"; 2026-11-09: "a bit cluttered"): the
    // Chumby; right under it one row of its own controls (day or night, and the channel it's showing, whose menu also
    // steps through the widgets); the next alarm, with Skip; what it's playing, only while it plays; then the about. One
    // spacing scale: 32 pt between sections, 12 between the rows of one, and the controls 24 under the device they belong to.
    static let sectionGap: CGFloat = 32, rowGap: CGFloat = 12, underDevice: CGFloat = 24
    // Open in portrait the column is the Duo's whole width; the controls keep a phone's measure, centred.
    static let column: CGFloat = 480
    // One row, two pills of one height: day or night, and what the screen is showing. Stepping through the channel's
    // widgets lives in the channel's menu, with the channels (it was two more keys on a row of its own; Richard,
    // 2026-11-09: "the chumby app start screen is a bit cluttered").
    var remote: some View {
        VStack(spacing: 10) {
            HStack(spacing: Self.rowGap) {
                NightButton()
                if !model.state.channelNames.isEmpty { channelRow }
            }
            .disabled(model.unreachable).opacity(model.unreachable ? 0.45 : 1)
            if let f = model.failed("remote") { FailNote(text: f) }
            if let f = model.failed("homeChannel") { FailNote(text: f) }
        }
    }
    // The channel the Chumby is showing, named as one (Channels calls it that too), and changed right here. The choice is
    // the model's, so the Channels editor moves to it as well.
    var channelName: String { !model.state.channel.isEmpty ? model.state.channel : model.sys.chan }
    // Named only from a recent reading, or his own tap: the kept copy can be from last night, when the Chumby's own
    // schedule had another channel up, and a name that then changes in front of him reads as the switcher failing.
    var channelSettled: Bool { model.stateConfirmed || model.chosenChannel != nil }
    var channelRow: some View {
        // Buttons, not a picker: a picker sends nothing when the one tapped is the one it thinks is on, and with a stale
        // reading that was the channel he wanted, so the tap did nothing. Every tap goes to the Chumby; the tick marks
        // the one showing.
        Menu {
            // The widget before and after this one, then the channels; the tick marks the one showing.
            Section {
                Button("Next widget", systemImage: "forward.fill") { model.cmd("next", id: "remote") }
                Button("Previous widget", systemImage: "backward.fill") { model.cmd("prev", id: "remote") }
            }
            Section("Channel") {
                ForEach(model.state.channelNames, id: \.self) { name in
                    Button { model.playChannel(name, id: "homeChannel") } label: {
                        if name == channelName { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "tv").font(.system(size: 20, weight: .semibold)).foregroundStyle(ChumbyPalette.acc(dark)).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Channel").font(.custom("Trebuchet MS", size: 13).weight(.bold)).foregroundStyle(ChumbyPalette.sub(dark))
                    Text(channelName.isEmpty ? "Choose one" : channelName).font(.custom("Trebuchet MS", size: 19).weight(.bold))
                        .foregroundStyle(ChumbyPalette.ink(dark)).lineLimit(1)
                        .contentTransition(.opacity)
                        .opacity(channelSettled ? 1 : 0)
                        .animation(.easeIn(duration: 0.25), value: channelSettled)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.bold)).foregroundStyle(ChumbyPalette.sub(dark))
            }
            .padding(.leading, 16).padding(.trailing, 16)
            .frame(height: HomeKey.size).frame(maxWidth: .infinity)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Channel, \(channelName)")
        .accessibilityHint("Choose a channel, or step to the next widget")
        .animation(.easeInOut(duration: 0.2), value: channelName)
    }
    // What it's playing, only while it plays: the same panel as Sounds' Now, with Stop and the volume. With nothing playing
    // there's nothing here to stop or turn down, so it isn't here; the volume always lives in Sounds.
    @ViewBuilder var playing: some View {
        // Only from a recent reading: the kept copy can say music was playing when the app was last open, and a Playing
        // card that shows for a beat and then goes reads as the app settling in front of him (build 185's film).
        if model.state.musicPlaying && !model.unreachable && model.stateConfirmed {
            NowPlaying(tab: 0, failID: "homeVolume")
                .padding(.horizontal, 18).padding(.vertical, 10)
                .card()
                .padding(.top, Self.sectionGap)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }
    // A Chumby too old to skip still says when it next rings; tapped, it opens Alarms. (One that can skip says it on the
    // Skip card, so it's never said twice.)
    @ViewBuilder var plainNext: some View {
        if model.stateKnown, !model.state.skipKnown, let n = model.nextRing() {
            Button { model.tab = 2 } label: {
                HStack(spacing: 14) {
                    Image(systemName: "alarm.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(ChumbyPalette.orange).frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next alarm").font(.custom("Trebuchet MS", size: 13).weight(.bold)).foregroundStyle(ChumbyPalette.sub(dark))
                        Text(n.at.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.custom("Trebuchet MS", size: 19).weight(.bold))
                    }
                    Spacer(minLength: 8)
                    Text(n.at, style: .relative).font(.custom("Trebuchet MS", size: 15)).foregroundStyle(ChumbyPalette.sub(dark)).lineLimit(1)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, Self.sectionGap)
        }
    }
    // The controls under the device, in both layouts and in this order.
    @ViewBuilder var controls: some View {
        if model.sys.ringing != nil { RingingCard().card().padding(.bottom, Self.underDevice).transition(.ringCard) }
        remote
        SkipCard().padding(.top, Self.sectionGap)
        plainNext
        playing
    }
    var wordmark: some View {
        ArtShape(art: ChumbyArt.word, box: ChumbyArt.wordBox).fill(ChumbyPalette.word(dark), style: FillStyle(eoFill: true))
            .frame(height: 30).frame(maxWidth: .infinity).accessibilityLabel("chumby")
    }
    var body: some View {
        Group {
            if wide {
                // Each side scrolls on its own, so the octopus stays put while you use the controls.
                FoldSplit {
                    // The wordmark is part of the stage, so it is spaced off the octopus the same way in both layouts.
                    ScrollView { VStack(spacing: 0) { stage; status; about.padding(.top, Self.sectionGap) }.padding(.horizontal, 12) }.roomyIndicators()
                } right: {
                    ScrollView {
                        VStack(spacing: 0) {
                            // The same top line as the left pane's first thing, the wordmark, rather than a guessed gap.
                            Color.clear.frame(height: Self.wordTop)
                            controls
                            more.padding(.top, Self.sectionGap)
                        }.padding(.horizontal, 12)
                    }.roomyIndicators()
                }
            } else {
                ScrollViewReader { scroll in
                ScrollView {
                    // The wordmark is drawn by the stage itself. The remote sits right under the device, within reach of the thumb; a ringing alarm above even that.
                    VStack(spacing: 0) {
                        stage; status
                        VStack(spacing: 0) { controls }
                            .frame(maxWidth: Self.column)
                            .padding(.top, Self.underDevice)
                        Color.clear.frame(height: 1).id("homebar")
                        about.padding(.top, Self.sectionGap)
                        if moreInfo { more.frame(maxWidth: Self.column) }
                    }.padding(.horizontal, 16)
                }.roomyIndicators()
                // For the build's shot: Home scrolled so the device's caption sits right at the tab bar, where Richard saw
                // "Chumby Classic" through it.
                .task {
                    guard ChumbyModel.pose == "homebar" else { return }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    scroll.scrollTo("homebar", anchor: .bottom)
                }
                }
            }
        }
        .animation(ChumbyModel.ringChange(to: model.sys.ringing), value: model.sys.ringing)
        // Music starting or stopping brings the Playing card in or out, and what's under it moves with it.
        .animation(.spring(duration: 0.4, bounce: 0.15), value: model.state.musicPlaying)
    }
}

// The screen of a Chumby that's gone quiet: grain that fades to black over a second and a half.
struct ScreenStatic: View {
    let since: Date
    @State private var done = false
    var body: some View {
        if done { Color.black.allowsHitTesting(false) } else { grain }
    }
    var grain: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in
            let p = min(ctx.date.timeIntervalSince(since) / 1.5, 1)
            ZStack {
                Canvas { c, size in
                    var g = SystemRandomNumberGenerator()
                    let cell: CGFloat = 4
                    for y in stride(from: 0, to: size.height, by: cell) {
                        for x in stride(from: 0, to: size.width, by: cell) {
                            c.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(.white.opacity(Double.random(in: 0...0.35, using: &g))))
                        }
                    }
                }
                .opacity(1 - p)
                Color.black.opacity(0.35 + 0.65 * p)
            }
        }
        .allowsHitTesting(false)
        .task(id: since) {
            let left = 1.6 - Date().timeIntervalSince(since)
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            done = true
        }
    }
}

struct InkDrop: View {
    @State private var on = false
    var body: some View {
        Circle().fill(RadialGradient(colors: [ChumbyPalette.hex(0x2c5bae).opacity(0.8), ChumbyPalette.hex(0x79bbff).opacity(0.1)], center: .center, startRadius: 0, endRadius: 22))
            .frame(width: 44, height: 44).scaleEffect(on ? 1.8 : 0.2).opacity(on ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.6)) { on = true } }
            .allowsHitTesting(false)
    }
}

func duration(_ s: Int) -> String {
    let d = s / 86400, h = s / 3600 % 24, m = s / 60 % 60
    return (d > 0 ? "\(d)d " : "") + (h > 0 ? "\(h)h " : "") + "\(m)m"
}

struct MeterRow: View {
    let label: String, text: String
    let value: Double, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(label); Spacer(); Text(text).fontWeight(.bold).monospacedDigit() }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.14))
                    Capsule().fill(color).frame(width: max(8, g.size.width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
    }
}

// Home's controls are one height, so the channel, the day/night pill and the widget keys line up as one block.
enum HomeKey { static let size: CGFloat = 64 }
// A round glass key the height of its row.
// The night style chosen in Tinker: what night looks like on the Chumby. Kept on the Chumby as the kind its nightly time
// switches to (ChumbyState.nightStyle), so the widget nights the same way; remembered here too for a Chumby with no
// nightly time.
let nightStyles = [("on", "Clock"), ("dim", "Dim"), ("dark", "Dark")]
extension ChumbyModel {
    var nightStyle: String { state.nightStyle ?? UserDefaults.standard.string(forKey: "nightKind") ?? "on" }
}

// A press that starts the moment a finger lands and ends when it lifts or wanders more than 16 pt (a scroll), never
// delayed by an enclosing scroll view.
#if canImport(UIKit)
struct PressCatcher: UIViewRepresentable {
    let began: () -> Void, ended: () -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.backgroundColor = .clear
        let g = PressRecognizer(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        g.delegate = context.coordinator
        v.addGestureRecognizer(g)
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PressCatcher
        init(_ p: PressCatcher) { parent = p }
        @objc func changed(_ g: UIGestureRecognizer) {
            switch g.state {
            case .began: parent.began()
            case .ended, .cancelled, .failed: parent.ended()
            default: break
            }
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    }
    final class PressRecognizer: UIGestureRecognizer {
        private var start: CGPoint = .zero
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touches.count == 1, let t = touches.first else { state = .failed; return }
            start = t.location(in: view); state = .began
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let t = touches.first else { return }
            let p = t.location(in: view)
            state = hypot(p.x - start.x, p.y - start.y) > 16 ? .cancelled : .changed
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .ended }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    }
}
#else
struct PressCatcher: View {
    let began: () -> Void, ended: () -> Void
    var body: some View {
        Circle().fill(.clear).contentShape(Circle())
            .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 16) {} onPressingChanged: { p in if p { began() } else { ended() } }
    }
}
#endif
// Drawn since 2026-11-05 as a labelled pill, not a circle: the mode in words with its sun or moon, and "Hold for night" or
// "Hold for day" under it; the hold fills the pill from its leading end with the colour it's going to.
// One button for day and night that works like the Lock Screen's flashlight (Richard, 2026-11-05: "a single botton with two
// actions that u press like u would a flashlight on lockscrene in terms of haptics and such that toggles simply night mode
// and screen"). It shows the mode the Chumby is really in, a sun by day and a moon by night. Press and hold: a light tick on
// touch, ticks that firm up as the pill fills and swells, and at half a second a heavy thunk as it commits, the
// glyph turning over. Let go early and it springs back having done nothing. Night is the style chosen in Tinker; day ends
// night mode and brings the screen back up. There's no menu on it any more: one button, two actions.
struct NightButton: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.colorScheme) private var scheme
    static let hold = 0.5
    @State private var pressing = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var progress: CGFloat = 0
    @State private var committed = false
    @State private var ticks: Task<Void, Never>?
    @State private var turned = 0
    var on: Bool { model.sys.night == 1 }
    var amber: Color { ChumbyPalette.hex(0xe59a2e) }
    var moon: Color { ChumbyPalette.hex(0xa4b7d6) }

    func begin() {
        guard !pressing else { return }
        pressing = true
        committed = false
        holdTimer?.cancel()
        holdTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.hold * 1_000_000_000))
            guard !Task.isCancelled, pressing, !committed else { return }
            commit()
        }
        #if canImport(UIKit)
        Haptics.light.impactOccurred(intensity: 0.45); Haptics.light.prepare(); Haptics.heavy.prepare()
        #endif
        withAnimation(.linear(duration: Self.hold)) { progress = 1 }
        // The pressure building: two firmer ticks on the way to the thunk.
        ticks?.cancel()
        ticks = Task { @MainActor in
            for k in [0.6, 0.8] as [CGFloat] {
                try? await Task.sleep(nanoseconds: 170_000_000)
                guard !Task.isCancelled else { return }
                #if canImport(UIKit)
                Haptics.medium.impactOccurred(intensity: k); Haptics.medium.prepare()
                #endif
            }
        }
    }
    func release() {
        pressing = false
        holdTimer?.cancel()
        ticks?.cancel()
        guard !committed else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.45)) { progress = 0 }
    }
    func commit() {
        ticks?.cancel()
        committed = true
        #if canImport(UIKit)
        Haptics.heavy.impactOccurred(); Haptics.heavy.prepare()
        #endif
        turned += 1
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) { model.setNight(on ? "off" : model.nightStyle) }
        withAnimation(.spring(duration: 0.45, bounce: 0.5)) { progress = 0 }
    }
    // Night: the slab in the Skip card's night navy, the moon pale. Day: plain glass, the sun amber.
    var navy: [Color] { [ChumbyPalette.hex(0x34508f), ChumbyPalette.hex(0x1f2f5c)] }
    var dark: Bool { scheme == .dark }
    // The words and glyph, in the given inks: drawn once in the mode's own colours, and again in white over the hold's fill.
    func row(title: Color, sub: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(on ? Color.white.opacity(0.14) : amber.opacity(dark ? 0.22 : 0.18))
                Image(systemName: on ? "moon.fill" : "sun.max.fill").font(.system(size: 21, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
                    .symbolEffect(.bounce, value: turned)
                    .foregroundStyle(on ? moon : amber)
            }
            .frame(width: 42, height: 42)
            // The mode it's in, in words, and what holding it does: never a mystery circle (Richard, 2026-11-05: "i dont
            // like the night / display on button").
            VStack(alignment: .leading, spacing: 1) {
                Text(on ? "Night" : "Day").font(.custom("Trebuchet MS", size: 19).weight(.bold)).foregroundStyle(title)
                Text(on ? "Hold for day" : "Hold for night").font(.custom("Trebuchet MS", size: 13).weight(.bold)).foregroundStyle(sub)
            }
            .contentTransition(.opacity)
            .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.leading, 11).padding(.trailing, 16)
        .frame(height: HomeKey.size).frame(maxWidth: .infinity)
    }
    var body: some View {
        let shape = Capsule()
        row(title: on ? .white : ChumbyPalette.ink(dark), sub: on ? Color.white.opacity(0.72) : ChumbyPalette.sub(dark))
        // Over the fill the words are white, cut to the fill's width, so dark ink never sits on the navy as it passes
        // under them (light mode: ink on navy was illegible). Elsewhere they keep the mode's ink.
            .overlay {
                if progress > 0.01 {
                    row(title: .white, sub: Color.white.opacity(0.8))
                        .mask(alignment: .leading) {
                            GeometryReader { g in Rectangle().frame(width: max(g.size.height, g.size.width * progress)) }
                        }
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        .background {
            ZStack(alignment: .leading) {
                // Night's slab, faded in over the glass rather than swapped, so the change is a crossfade.
                shape.fill(LinearGradient(colors: navy, startPoint: .top, endPoint: .bottom)).opacity(on ? 1 : 0)
                // The hold: the mode it's going to fills in from the leading end, under the words, round at both ends.
                GeometryReader { g in
                    shape.fill(on ? amber.opacity(0.5) : navy[0].opacity(0.85))
                        .frame(width: max(g.size.height, g.size.width * progress))
                        .opacity(progress > 0.01 ? 1 : 0)
                }
            }
            .clipShape(shape)
        }
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(on ? 0.22 : 0), lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: on)
        .scaleEffect(still ? 1 : 1 + 0.04 * progress)
        .overlay {
            // The press is read by UIKit straight away, so the first tick lands at touch-down even inside Home's scroll
            // view (whose own delay would hold a SwiftUI press back while it decides whether he's scrolling).
            PressCatcher(began: begin, ended: release)
                .clipShape(shape).contentShape(shape)
                .accessibilityElement()
                .accessibilityLabel(on ? "Night" : "Day")
                .accessibilityHint(on ? "Hold for day" : "Hold for night")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { commit() }
        }
        // For the build's shot: the pill held halfway, so the mid-hold state can be judged.
        .onAppear { if ChumbyModel.pose == "nighthold" { progress = 0.55 } }
    }
}
// MARK: - Channels
struct EditorRow: Identifiable, Equatable { let id: String; var name: String; var on: Bool; var secs: Int; var own: Int }
let widgetTimes = [10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600]
func timeText(_ t: Int) -> String { t < 60 ? "\(t) sec" : "\(t / 60) min" }

struct ChannelsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var picked = ""
    @State private var saveQueue: Task<Void, Never>?
    // The drag handles only while reordering, so a scroll that starts on one can't pick a widget up.
    @State private var reordering = false
    @State private var rows: [EditorRow] = []
    @State private var saveTask: Task<Void, Never>?
    @State private var unsent: (rows: [EditorRow], id: String)?
    @State private var edited: [String: [EditorRow]] = [:]   // what was saved here, until the Chumby's own list catches up
    @State private var switching = false
    @State private var categories: [(String, String)] = []
    @State private var category = ""
    @State private var catalog: [(String, String)] = []
    @State private var page = 1
    @State private var more = false
    @State private var busy = false
    @State private var justAdded: String?
    // The Add widgets picker: a sheet folded, the right pane open (nothing sits across the fold).
    @State private var adding = false
    @State private var offered: [MoreItem] = []
    @State private var lastAdded: String?
    @Environment(\.paneLayout) private var wide
    @Environment(\.colorScheme) private var scheme

    var channels: [ChannelList.Channel] { model.channelData?.channels ?? [] }
    func title(_ c: ChannelList.Channel) -> String { c.list.first.flatMap { $0.count > 1 ? $0[1] : nil } ?? "Channel" }
    var allWidgets: [[String]] {
        var m: [String: [String]] = [:]
        for n in model.channelData?.names ?? [] where n.count > 1 { m[n[0]] = [n[0], n[1], "0"] }
        for c in channels { for l in c.list where l.first != "#" && l.count > 1 { m[l[0]] = l } }
        return m.values.sorted { $0[1].localizedCaseInsensitiveCompare($1[1]) == .orderedAscending }
    }

    // What the channel holds, as his list. On the Chumby a widget that's "off" in a channel (on=0 in its .conf, chedit/hook.sc)
    // is simply left out of the rotation: there's no state of being in a channel but not shown. So off is removed, and the
    // list shows only what plays (Richard, 2026-11-05: "not have unadded widgets shown under my widgets"). Removed ones stay
    // in `rows` as off, so a widget that came with the channel is sent as on=0 and doesn't come back by itself.
    var shown: [EditorRow] { rows.filter(\.on) }
    // Every widget the Chumby knows by id that this channel doesn't play, for the Add widgets picker.
    var notHere: [[String]] { allWidgets.filter { w in !rows.contains { $0.id == w[0] && $0.on } } }
    // Joins the channel at the end of what plays, at the widget's own time. The list scrolls to it once the picker closes.
    func add(id: String, name: String, own: Int) {
        withAnimation(.snappy) {
            if let i = rows.firstIndex(where: { $0.id == id }) {
                guard !rows[i].on else { return }
                var r = rows.remove(at: i); r.on = true
                rows.insert(r, at: rows.lastIndex(where: \.on).map { $0 + 1 } ?? 0)
            } else {
                rows.insert(EditorRow(id: id, name: name, on: true, secs: 0, own: own), at: rows.lastIndex(where: \.on).map { $0 + 1 } ?? 0)
            }
        }
        lastAdded = id
        changed()
        // Open, the channel's list is beside the picker: the new widget lands there at once, glowing.
        if adding && wide {
            withAnimation(.snappy) { justAdded = id }
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if justAdded == id { withAnimation(.easeOut(duration: 0.6)) { justAdded = nil } }
            }
        }
    }
    func remove(_ id: String) {
        withAnimation(.snappy) { if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].on = false } }
        if lastAdded == id { lastAdded = nil }
        changed()
    }
    // Back from the picker, the list goes to the last widget added, which glows a moment.
    func reveal(_ scroll: ScrollViewProxy) {
        guard let id = lastAdded, shown.contains(where: { $0.id == id }) else { return }
        lastAdded = nil
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.snappy) { scroll.scrollTo(id, anchor: .center); justAdded = id }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if justAdded == id { withAnimation(.easeOut(duration: 0.6)) { justAdded = nil } }
        }
    }
    func openAdd() {
        flush()
        // Kept as it was on opening, so a row he adds stays under his finger, ticked, rather than leaving the list.
        offered = notHere.map { MoreItem(id: $0[0], name: $0[1], own: $0.count > 2 ? Int($0[2]) ?? 0 : 0) }
        model.tick()
        withAnimation(.snappy) { adding = true }
    }
    func closeAdd(_ scroll: ScrollViewProxy) {
        withAnimation(.snappy) { adding = false }
        reveal(scroll)
    }

    func pick() {
        flush()
        // Filling the rows isn't an edit, so it mustn't look like one to the change handlers.
        switching = true
        Task { try? await Task.sleep(nanoseconds: 200_000_000); switching = false }
        if let mine = edited[picked] { rows = mine; return }
        guard let ch = channels.first(where: { $0.id == picked }) else { rows = []; return }
        let all = ch.list.filter { $0.first != "#" && $0.count > 1 }
        var seen = Set<String>(), out: [EditorRow] = []
        for f in ch.conf where f.count > 2 {
            if let w = all.first(where: { $0[0] == f[0] }) ?? allWidgets.first(where: { $0[0] == f[0] }) {
                seen.insert(f[0])
                out.append(EditorRow(id: f[0], name: w[1], on: f[1] == "1", secs: Int(f[2]) ?? 0, own: w.count > 2 ? Int(w[2]) ?? 0 : 0))
            }
        }
        for w in all where !seen.contains(w[0]) && w.count > 1 {
            out.append(EditorRow(id: w[0], name: w[1], on: true, secs: 0, own: w.count > 2 ? Int(w[2]) ?? 0 : 0))
        }
        rows = out
    }
    // Each save restarts the channel for about 30 seconds, so edits gather until 5 quiet seconds have passed, or until
    // the editor is left, whichever comes first.
    func changed() {
        guard !switching else { return }
        saveTask?.cancel()
        unsent = (rows, picked)
        edited[picked] = rows
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            flush()
        }
    }
    // Sends a waiting edit now, so moving to another channel or tab can't lose it.
    func flush() {
        guard let u = unsent else { return }
        saveTask?.cancel()
        unsent = nil
        // Saves go one after another, so an older list can never land on the Chumby after a newer one.
        let before = saveQueue
        saveQueue = Task {
            await before?.value
            var o: [(String, String)] = [("n", "\(u.rows.count)")]
            for (i, w) in u.rows.enumerated() { o += [("\(i)_id", w.id), ("\(i)_on", w.on ? "1" : "0"), ("\(i)_secs", "\(w.secs)")] }
            do {
                let j = try await model.api?.post("chedit", extra: "&p=" + ChumbyAPI.enc(u.id), body: ChumbyAPI.form(o))
                // The Chumby always says how many it couldn't fetch, so only a real one is worth a word. A plain save says
                // nothing: the switch or picker already shows the change.
                if let n = j?["missing"] as? Int, n > 0 { model.fail("chedit", n == 1 ? "One widget couldn’t be downloaded to the Chumby." : "\(n) widgets couldn’t be downloaded to the Chumby.") }
            } catch { model.fail("chedit", "Couldn’t save that. \(AlarmWriter.explain(error))"); edited[u.id] = nil }
        }
    }
    func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
    func matches(_ pattern: String, _ text: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) else { return nil }
            return (String(text[a]), decode(String(text[b])))
        }
    }
    func loadCategories() async {
        guard categories.isEmpty, let t = try? await model.api?.text("a=cat") else { return }
        var seen = Set<String>()
        categories = matches(#"/guide/([0-9A-F-]+)/category"><img alt="([^"]*)""#, t).filter { seen.insert($0.0).inserted }
    }
    func loadCatalog() async {
        guard !category.isEmpty else { return }
        busy = true; defer { busy = false }
        guard let t = try? await model.api?.text("a=cat&c=\(category)&p=\(page)") else { model.fail("catalog", "Couldn’t reach the catalog."); return }
        var seen = Set(catalog.map { $0.0 })
        catalog += matches(#"/guide/([0-9A-F-]+)/widget">([^<]+)</a>"#, t).filter { seen.insert($0.0).inserted }
        more = t.contains("category?page=\(page + 1)")
    }
    // Choosing what plays, here or on Home (model.chosenChannel), also selects it on the editing side. Changing `picked`
    // runs pick(), which sends any waiting edit first. The reverse never happens: picking a channel to edit doesn't touch
    // what plays.
    func channelID(named name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return channels.first { title($0).trimmingCharacters(in: .whitespacesAndNewlines) == n }?.id
    }
    // A row's setting looked up by id each time, so a list that changed underneath can't be read out of range.
    func rowBinding<T>(_ id: String, _ key: WritableKeyPath<EditorRow, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { rows.first { $0.id == id }?[keyPath: key] ?? fallback },
                set: { v in if let i = rows.firstIndex(where: { $0.id == id }) { rows[i][keyPath: key] = v } })
    }
    func followPlaying(_ name: String) {
        guard let id = channelID(named: name), id != picked else { return }
        picked = id
    }
    // From what was kept last time, so the editor is whole from the first frame: the channel chosen or playing, if known.
    func startFromCache() {
        guard picked.isEmpty else { return }
        picked = model.chosenChannel.flatMap { channelID(named: $0.name) } ?? channelID(named: model.state.channel) ?? (model.channelData?.cur ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if picked.isEmpty { picked = channels.first?.id ?? "" }
        pick()
    }
    // What the picker lists: the Chumby's own widgets this channel doesn't play, or a catalog category's.
    struct MoreItem { let id: String, name: String, own: Int }
    // One picker row, tapped anywhere: + to add, and once added a tick (tap again to take it back out).
    func pickRow(_ w: MoreItem) -> some View {
        let isIn = rows.contains { $0.id == w.id && $0.on }
        return Button {
            model.tick()
            if isIn { remove(w.id) } else { add(id: w.id, name: w.name, own: w.own) }
        } label: {
            HStack(spacing: 14) {
                Text(w.name).lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle.fill").font(.system(size: 24))
                    .foregroundStyle(isIn ? ChumbyPalette.on : ChumbyPalette.acc(scheme == .dark))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isIn ? "\(w.name), in this channel" : "Add \(w.name)")
    }
    var catalogItems: [MoreItem] { catalog.map { MoreItem(id: $0.0, name: $0.1, own: 0) } }
    // One Done for the picker, folded or open: the same glass capsule in the page's ink.
    func doneButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text("Done").font(.custom("Trebuchet MS", size: 17).weight(.bold)).padding(.horizontal, 6) }
            .buttonStyle(.glass).foregroundStyle(ChumbyPalette.ink(scheme == .dark))
    }
    var pickedTitle: String { channels.first { $0.id == picked }.map(title) ?? "this channel" }
    // The picker's sections: his Chumby's own widgets first, then the catalog by category.
    @ViewBuilder var addSections: some View {
        Section {
            if offered.isEmpty { Text("Every widget on your Chumby is in this channel.").foregroundStyle(.secondary) }
            ForEach(offered, id: \.id) { pickRow($0) }
        } header: { Text("On your Chumby").font(.custom("Trebuchet MS", size: 16).weight(.bold)).textCase(nil) }
        Section {
            Picker("Category", selection: $category) {
                Text("Choose one").tag("")
                ForEach(categories, id: \.0) { Text($0.1).tag($0.0) }
            }
            .onChange(of: category) { _, _ in catalog = []; page = 1; more = false; Task { await loadCatalog() } }
            ForEach(catalogItems, id: \.id) { pickRow($0) }
            if busy { ProgressView().frame(maxWidth: .infinity) }
            if !category.isEmpty && more && !busy { Button("Load more") { page += 1; Task { await loadCatalog() } }.foregroundStyle(.tint) }
            if let f = model.failed("catalog") { FailNote(text: f) }
        } header: { Text("From the catalog").font(.custom("Trebuchet MS", size: 16).weight(.bold)).textCase(nil) }
    }
    // A widget in the channel: its name, and its time on screen on the right, well clear of it. Swipe (or hold) to remove.
    func widgetRow(_ w: EditorRow) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(w.name).lineLimit(1)
            Spacer(minLength: 16)
            Menu {
                Picker("Time on screen", selection: rowBinding(w.id, \.secs, w.secs)) {
                    Text(w.own > 0 ? "Auto (\(w.own)s)" : "Auto").tag(0)
                    ForEach(widgetTimes, id: \.self) { Text(timeText($0)).tag($0) }
                }
                // Taking it out lives with its other choice, not behind a swipe that slides the row off its card.
                Divider()
                Button("Remove from \(pickedTitle)", systemImage: "minus.circle", role: .destructive) { remove(w.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                    Text(w.secs == 0 ? (w.own > 0 ? "Auto · \(w.own)s" : "Auto") : timeText(w.secs))
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel("Time on screen")
            .onChange(of: w.secs) { _, _ in changed() }
        }
        .padding(.vertical, 4)
        .contextMenu { Button("Remove from \(pickedTitle)", systemImage: "minus.circle", role: .destructive) { remove(w.id) } }
        .listRowBackground(GlassRow().overlay(ChumbyPalette.acc(scheme == .dark).opacity(justAdded == w.id ? 0.22 : 0)))
    }
    // The end of the list: one row, tapped anywhere, that opens the picker.
    var addRow: some View {
        Button { openAdd() } label: {
            Label("Add widgets", systemImage: "plus.circle.fill").font(.body.weight(.semibold))
                .foregroundStyle(ChumbyPalette.acc(scheme == .dark))
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .moveDisabled(true).deleteDisabled(true)
    }
    // For the build: a channel chosen in Now playing (chsync); then the picker opened and a widget added (chdemo), or the
    // picker left open for its shot (chadd).
    @State private var posed = false

    var body: some View {
        ScrollViewReader { scroll in
        TwoPane(rightTitle: adding && wide ? "Add to \(pickedTitle)" : " ",
                rightTrailing: adding && wide ? AnyView(doneButton { closeAdd(scroll) }) : nil) {
            PageTitle("Channels")
            ReachRow()
            Section {
                Picker("Channel", selection: Binding(get: { model.state.channel }, set: { model.playChannel($0, id: "nowPlaying") })) {
                    ForEach(model.state.channelNames, id: \.self) { Text($0).tag($0) }
                    if !model.state.channelNames.contains(model.state.channel) { Text(model.state.channel).tag(model.state.channel) }
                }
                Menu("Jump to a widget") {
                    ForEach(model.state.widgetNames.sorted(), id: \.self) { n in Button(n) { model.cmd("widget", n, id: "nowPlaying") } }
                }.foregroundStyle(.tint)
                Toggle("Shuffle", isOn: Binding(get: { model.state.shuffle == 1 }, set: { on in model.state.shuffle = on ? 1 : 0; model.cmd("shuffle", on ? "1" : "0", id: "nowPlaying") }))
                if let f = model.failed("nowPlaying") { FailNote(text: f) }
            } header: {
                // Open, as tall as the channel header across the fold, so the two panes' cards start level (r27: ~15 px apart).
                Text("Now playing").font(.custom("Trebuchet MS", size: 16).weight(.bold)).textCase(nil)
                    .frame(minHeight: wide ? 32 : 0, alignment: .bottomLeading)
            }
            // Adding, open: what's already in the channel stays in view on this side, and each add lands here live.
            if adding && wide {
                Section {
                    if shown.isEmpty { Text("Nothing in this channel yet.").foregroundStyle(.secondary) }
                    ForEach(shown, id: \.id) { w in
                        HStack {
                            Text(w.name).lineLimit(1)
                            Spacer(minLength: 12)
                            Text(w.secs == 0 ? (w.own > 0 ? "Auto · \(w.own)s" : "Auto") : timeText(w.secs)).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 34)
                        .listRowBackground(GlassRow().overlay(ChumbyPalette.acc(scheme == .dark).opacity(justAdded == w.id ? 0.22 : 0)))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                } header: {
                    Text("In \(pickedTitle)").font(.custom("Trebuchet MS", size: 16).weight(.bold)).textCase(nil)
                }
            }
        } right: {
            if adding && wide {
                addSections
            } else {
            Section {
                if shown.isEmpty && !picked.isEmpty { Text("Nothing in this channel yet.").foregroundStyle(.secondary) }
                // By id, never by index: following the playing channel swaps `rows` under the list.
                ForEach(shown, id: \.id) { widgetRow($0) }
                    .onMove { from, to in
                        var on = shown
                        on.move(fromOffsets: from, toOffset: to)
                        rows = on + rows.filter { !$0.on }
                        changed()
                    }
                    .deleteDisabled(true)
                if !picked.isEmpty && !reordering { addRow }
                if let f = model.failed("chedit") { FailNote(text: f) }
            } header: {
                // The channel being edited is the header itself, so there's one "Default" here, not two.
                HStack(alignment: .firstTextBaseline) {
                    Menu {
                        Picker("Editing", selection: $picked) { ForEach(channels, id: \.id) { Text(title($0)).tag($0.id) } }
                    } label: {
                        HStack(spacing: 6) {
                            Text(channels.first { $0.id == picked }.map(title) ?? "Choose a channel").font(.custom("Trebuchet MS", size: 22).weight(.bold)).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Channel to edit")
                    Spacer()
                    if shown.count > 1 {
                        Button(reordering ? "Done" : "Reorder") { withAnimation(.snappy) { reordering.toggle() } }
                            .font(.body.weight(.semibold)).foregroundStyle(.tint)
                    }
                }
                .textCase(nil)
                .frame(minHeight: 32, alignment: .bottom)
            } footer: {
                if model.state.shuffle == 1 { Text("Shuffle is on, so your order won’t show until you turn it off.") }
            }
            }
        }
        .sheet(isPresented: Binding(get: { adding && !wide }, set: { if !$0 { closeAdd(scroll) } })) {
            NavigationStack {
                List { addSections.listRowBackground(GlassRow()) }
                    .seaList().background { SeaBackground().ignoresSafeArea() }
                    .navigationTitle("Add to \(pickedTitle)").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .principal) { Text("Add to \(pickedTitle)").font(.custom("Trebuchet MS", size: 18).weight(.bold)).lineLimit(1) }
                        ToolbarItem(placement: .confirmationAction) { doneButton { closeAdd(scroll) } }
                    }
            }
            .tint(ChumbyPalette.acc(scheme == .dark))
            .foregroundStyle(ChumbyPalette.ink(scheme == .dark))
            .environment(\.colorScheme, scheme)
        }
        .onChange(of: picked) { _, _ in if adding { withAnimation(.snappy) { adding = false } } }
        .onChange(of: wide) { _, _ in adding = false }
        .onAppear {
            startFromCache()
            guard !posed, ["chsync", "chdemo", "chadd"].contains(ChumbyModel.pose) else { return }
            posed = true
            Task {
                if ChumbyModel.pose == "chadd" { try? await Task.sleep(nanoseconds: 1_500_000_000); openAdd(); return }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let n = model.state.channelNames.first(where: { $0 != model.state.channel }) { model.playChannel(n, id: "nowPlaying") }
                guard ChumbyModel.pose == "chdemo" else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000); openAdd()
                try? await Task.sleep(nanoseconds: 1_500_000_000); if let w = offered.first { add(id: w.id, name: w.name, own: w.own) }
                try? await Task.sleep(nanoseconds: 1_500_000_000); closeAdd(scroll)
            }
        }
        }
        .seaList()
        .dragToReorder(reordering)
        .onChange(of: picked) { _, _ in pick() }
        .onChange(of: model.chosenChannel) { _, c in if let c { followPlaying(c.name) } }
        .task { await model.loadChannels(); if rows.isEmpty { startFromCache(); if rows.isEmpty { pick() } }; await loadCategories() }
        .onDisappear { flush() }
        .refreshable { flush(); edited = [:]; await model.loadChannels(); await model.loadState(); pick() }
    }
}

// MARK: - Sounds
// What the Chumby is playing, and what his alarms play. It used to be a volume, a toggle, a list of Pandora station names
// that did nothing when tapped and a list of streams (Richard, 2026-11-05: "aou ds tab which is rn almost useless and so
// confusing"). Now, left: what's playing now with Stop and the volume, AirPlay, and the songs that woke him. Right: each
// alarm with what it plays, chosen right there from his tones, radio streams and Pandora stations; how loud they ring; and
// those sources themselves, which exist to be chosen there.
// What the Chumby is playing: the cover or a stand-in, the song when Pandora's history names it, Stop while something plays,
// and the Chumby's volume. One panel, so Sounds' Now and Home's Playing card are the same thing drawn the same way.
// `tab`: the tab it's on; while that tab is up and something plays, the history is read often, so the song shown is the
// one playing.
struct NowPlaying: View {
    @EnvironmentObject var model: ChumbyModel
    @ObservedObject private var art = SongArt.shared
    @AppStorage("lastVolume") private var lastVolume = 4
    @State private var volume = 0.0
    @State private var dragging = false
    let tab: Int
    let failID: String
    func set(_ v: Int) { volume = Double(v); model.cmd("volume", String(v), id: failID) }
    // The song playing, when the Chumby says its player is going and Pandora's history has a song from the last few
    // minutes; otherwise nothing is named rather than an old song.
    var nowSong: Song? {
        guard model.state.musicPlaying, let s = model.songs.max(by: { $0.t < $1.t }), Date().timeIntervalSince1970 - s.t < 8 * 60 else { return nil }
        return s
    }
    var body: some View {
        let song = nowSong
        let f = song.flatMap { art.found[SongArt.key($0)] }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                // The stand-in stays underneath and the cover fades in over it when it arrives, never a swap in one frame.
                ZStack {
                    ZStack {
                        ChumbyPalette.hex(0x2c5bae).opacity(model.state.musicPlaying ? 1 : 0.45)
                        if model.state.musicPlaying { Image(systemName: "music.note").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white) }
                        else { OctopusMark(color: .white.opacity(0.85), eyes: ChumbyPalette.hex(0x2c5bae), blink: 0.08).padding(14) }
                    }
                    if let i = f?.image { Image(platform: i).resizable().scaledToFill().transition(.opacity) }
                }
                .animation(.easeInOut(duration: 0.35), value: f?.image != nil)
                .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    if let song {
                        Text(song.title).font(.custom("Trebuchet MS", size: 19).weight(.bold)).lineLimit(1)
                        Text(song.artist).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(model.state.musicPlaying ? "Playing" : "Nothing playing").font(.custom("Trebuchet MS", size: 19).weight(.bold))
                    }
                }
                Spacer(minLength: 8)
                // Stop only while something plays: with nothing to stop, it's a dead button.
                if model.state.musicPlaying {
                    Button { model.cmd("stopmusic", id: failID) } label: { Image(systemName: "stop.fill").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44) }
                        .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Stop")
                }
            }
            // Asked again whenever the song changes: it's often nil on first appearance, before state and history arrive.
            .task(id: song.map(SongArt.key)) { if let song { art.look(song) } }
            HStack(spacing: 12) {
                Button {
                    if volume > 0 { lastVolume = Int(volume); set(0) } else { set(lastVolume > 0 ? lastVolume : 4) }
                } label: { Image(systemName: volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill").frame(width: 26) }
                .buttonStyle(.borderless).accessibilityLabel(volume > 0 ? "Mute" : "Unmute")
                Slider(value: $volume, in: 0...100, step: 1) { e in
                    dragging = e
                    if !e { if volume > 0 { lastVolume = Int(volume) }; model.cmd("volume", String(Int(volume)), id: failID) }
                }.accessibilityLabel("Volume").tint(ChumbyPalette.orange)
                Text("\(Int(volume))%").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
            }
            if let f = model.failed(failID) { FailNote(text: f) }
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: model.state.musicPlaying)
        .task(id: model.sys.vol) { if !dragging && model.sys.vol >= 0 { volume = Double(model.sys.vol) } }
        .task(id: model.tab == tab && model.state.musicPlaying) {
            while model.tab == tab && !Task.isCancelled {
                await model.loadSongs(force: model.state.musicPlaying)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }
}

struct SoundsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @ObservedObject private var wake = CalendarWake.shared
    @Environment(\.colorScheme) private var scheme
    @State private var alarmVolume = 100.0
    @State private var addStream = false
    @State private var streamURL = ""
    @State private var streamName = ""
    @State private var pendingRemoval: Stream?
    var dark: Bool { scheme == .dark }

    var scanNote: String? {
        switch model.state.pandoraScan.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "waiting": return "Listening for 4 minutes. On the Chumby, open Music, then Pandora Radio."
        case "timeout": return "Didn’t see the station list. Tap again, then open Pandora on the Chumby."
        case "error": return "That didn’t work. Try again."
        default: return nil
        }
    }
    // His own alarms still to come, in time order: a one-off that has already gone off has nothing left to play.
    var mine: [Alarm] {
        let now = Int(Date().timeIntervalSince1970 / 60)
        return model.state.alarms.filter { !$0.isPlaceholder && !$0.isHelper && !$0.isCalendar && !($0.when == "once" && (Int($0.time) ?? 0) <= now) }
            .sorted { $0.localMinutes < $1.localMinutes }
    }
    // How calendar alarms ring: the saved set, else how the first one rings now.
    var calendarSound: Alarm? {
        guard wake.rules.enabled || model.state.alarms.contains(where: \.isCalendar) else { return nil }
        return model.state.calTpl ?? wake.storedSettings ?? model.state.alarms.first(where: \.isCalendar)
    }

    // One alarm and what it plays, chosen from the same sources the editor offers, sent the careful way.
    func soundRow(_ title: String, _ detail: String, _ a: Alarm, mark: String?, choose: @escaping (Alarm) -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).lineLimit(1)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Menu {
                Picker("Plays", selection: Binding(get: { a.soundTag(streams: model.state.streams) }, set: { t in
                    var b = a; b.setSound(t, streams: model.state.streams, stations: model.pandoraStations); choose(b)
                })) {
                    Section("Tones") { ForEach(model.state.tones, id: \.self) { Text($0).tag("beep:" + $0) } }
                    if !model.state.streams.isEmpty { Section("Radio") { ForEach(model.state.streams, id: \.key) { Text($0.name.isEmpty ? $0.url : $0.name).tag("stream:" + $0.key) } } }
                    if !model.pandoraStations.isEmpty { Section("Pandora") { ForEach(model.pandoraStations) { Text($0.name).tag("pandora:" + $0.id) } } }
                    Text("Silent").tag("none")
                    if a.soundTag(streams: model.state.streams).isEmpty { Text(a.soundText).tag("") }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(a.soundText).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel("What \(title) plays")
            .overlay(alignment: .top) { if let mark { LandBubble(mark: mark) } }
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        TwoPane {
            PageTitle("Sounds")
            ReachRow()
            Section { NowPlaying(tab: 3, failID: "sounds") } header: { SectionHead(icon: "speaker.wave.2.fill", text: "Now", color: ChumbyPalette.sub(dark)) }
            Section {
                Toggle(isOn: Binding(get: { model.sys.airplayOn }, set: { on in model.sys.airplayOn = on; model.cmd("airplay", on ? "1" : "0", id: "airplay") })) {
                    Label("AirPlay to Chumby", systemImage: "airplayaudio")
                }
                if let f = model.failed("airplay") { FailNote(text: f) }
            }
            WokeUpTo()
        } right: {
            Section {
                // A row arriving with a fresher reading slides into its place rather than reshuffling the list in a frame.
                ForEach(mine, id: \.key) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        soundRow("\(a.clock) \(a.meridiem)", [a.name, a.whenUnlessNamed].filter { !$0.isEmpty }.joined(separator: " · "), a, mark: a.key) { b in
                            model.change(.replace(a, b))
                        }
                        MarkNote(mark: a.key)
                    }
                }
                if let c = calendarSound {
                    soundRow("Calendar alarms", "Every one your calendar sets", c, mark: nil) { b in
                        Task { if let why = await model.saveCalendarTemplate(b) { model.fail("calsound", why) } }
                    }
                    if let f = model.failed("calsound") { FailNote(text: f) }
                }
                if mine.isEmpty && calendarSound == nil { Text("No alarms yet.").foregroundStyle(.secondary) }
                // How loud they ring: saved the careful way, and marked here if it doesn't reach the Chumby.
                // Named in words, so it's never mistaken for the music's volume under Now.
                // Only once the Chumby has said how loud: a slider at a guessed value would save the guess.
                if model.state.volume >= 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Alarm volume").font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        Image(systemName: "alarm.waves.left.and.right.fill").frame(width: 26)
                        Slider(value: $alarmVolume, in: 0...100, step: 5) { e in
                            if !e { model.change(.volume(Int(alarmVolume))) }
                        }.accessibilityLabel("Alarm volume").tint(ChumbyPalette.orange)
                            .overlay(alignment: .trailing) { LandBubble(mark: "alarmVolume") }
                        Text("\(Int(alarmVolume))%").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
                    }
                }
                MarkNote(mark: "alarmVolume")
                }
                Picker("Fade in", selection: Binding(get: { model.state.fade }, set: { model.change(.fade($0)) })) {
                    ForEach([(-1, "Chumby default"), (0, "Off"), (5, "5 seconds"), (15, "15 seconds"), (30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes")], id: \.0) { Text($0.1).tag($0.0) }
                }
                MarkNote(mark: "fade")
            } header: { SectionHead(icon: "alarm", text: "Alarms play", color: ChumbyPalette.sub(dark)) }
            .animation(.snappy, value: mine.map(\.key))
            Section {
                ForEach(model.state.streams, id: \.key) { s in
                    HStack(spacing: 12) {
                        Label(s.name.isEmpty ? s.url : s.name, systemImage: "dot.radiowaves.left.and.right").lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RowRemove(label: "Remove \(s.name.isEmpty ? "this stream" : s.name)") { pendingRemoval = s }
                    }
                        // The question hangs off the row it came from, so it points at what's going.
                        .confirmationDialog("Remove \(s.name.isEmpty ? "this stream" : s.name)?", isPresented: .init(get: { pendingRemoval?.key == s.key }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
                            Button("Remove", role: .destructive) {
                                model.state.streams.removeAll { $0.key == s.key }; Task { await model.saveStreams() }
                            }
                        }
                }
                Button { addStream = true } label: { Label("Add a radio stream", systemImage: "plus.circle.fill") }.foregroundStyle(.tint)
                if let f = model.failed("streams") { FailNote(text: f) }
                // Pandora's stations come from the Chumby itself, once Pandora has been opened there.
                Button {
                    Task {
                        do { try await model.api?.post("pscan"); model.state.pandoraScan = "waiting" }
                        catch { model.fail("pscan", "Couldn’t start listening. \(AlarmWriter.explain(error))") }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Label(model.state.pandora.isEmpty ? "Get my Pandora stations" : "Pandora · \(model.state.pandora.count) station\(model.state.pandora.count == 1 ? "" : "s")", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer(minLength: 8)
                        if !model.state.pandora.isEmpty { Text("Update").font(.subheadline.weight(.semibold)).foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(model.state.pandora.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                if let f = model.failed("pscan") { FailNote(text: f) }
            } header: { SectionHead(icon: "radio", text: "Stations", color: ChumbyPalette.sub(dark)) } footer: { if let scanNote { Text(scanNote) } }
        }
        .seaList()
        .task(id: model.state.volume) { if model.state.volume >= 0 { alarmVolume = Double(model.state.volume) } }
        .refreshable { await model.loadSys(); await model.loadState(); await model.loadSongs(force: true) }
        .alert("Add a radio stream", isPresented: $addStream) {
            TextField("MP3 stream address", text: $streamURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("Station name", text: $streamName)
            Button("Add") {
                guard streamURL.hasPrefix("http://") || streamURL.hasPrefix("https://") else { model.fail("streams", "That isn’t a web address. It should start with http://"); return }
                model.state.streams.append(Stream(name: streamName.isEmpty ? streamURL : streamName, url: streamURL))
                streamURL = ""; streamName = ""
                Task { await model.saveStreams() }
            }
            Button("Cancel", role: .cancel) { streamURL = ""; streamName = "" }
        }
    }
}

// MARK: - Tinker
// One settings page he reads at a glance. The title stays "Enjoy tinkering?" (Richard, 2026-11-05: "no enjoy tinkering is
// fun"). Nothing here is taken away by a swipe: a swipe slid the row's time off the card and left a square Delete inside
// the rounded card ("looks fucked", 2026-11-05), so every removal is a control in the row itself.
struct TinkerTab: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.colorScheme) private var scheme
    @State private var newAccount = ""
    @State private var confirm: String?
    @State private var address = ""
    @State private var connection = false
    var dark: Bool { scheme == .dark }
    func connect() {
        model.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.api != nil { model.needsAddress = false; model.start(); connection = false } else { model.fail("connect", "That isn’t an address the app can use.") }
    }
    // The X widget's accounts, saved the moment one is added or taken out: no Save row.
    func saveAccounts(_ list: [String]) {
        let before = model.sys.tw
        model.tick()
        model.sys.tw = list
        model.hold(8)
        Task {
            do { try await model.api?.post("twset", body: ChumbyAPI.form([("v", list.joined(separator: ", "))])) }
            catch { model.sys.tw = before; model.fail("twset", "Couldn’t save. \(AlarmWriter.explain(error))") }
        }
    }
    func addAccount() {
        let h = newAccount.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        newAccount = ""
        guard !h.isEmpty, !model.sys.tw.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) else { return }
        saveAccounts(model.sys.tw + [h])
    }
    var host: String { URL(string: model.address)?.host ?? model.address }

    var body: some View {
        TwoPane {
            PageTitle("Enjoy tinkering?")
            ReachRow()
            NightSettings()
            Section {
                ForEach(model.sys.tw, id: \.self) { h in
                    HStack(spacing: 12) {
                        Text("@" + h).lineLimit(1)
                        Spacer(minLength: 8)
                        RowRemove(label: "Stop showing @\(h)") { saveAccounts(model.sys.tw.filter { $0 != h }) }
                    }
                }
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(ChumbyPalette.acc(dark))
                    TextField("Add an account", text: $newAccount).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done).onSubmit(addAccount)
                }
                if let f = model.failed("twset") { FailNote(text: f) }
            } header: { SectionHead(icon: "bubble.left.and.text.bubble.right.fill", text: "X widget", color: ChumbyPalette.sub(dark)) }
            } right: {
            Section {
                Button { confirm = "restart" } label: {
                    SettingRow(icon: "arrow.clockwise", tile: ChumbyPalette.hex(0x2c5bae), title: "Restart widgets", detail: "The screen’s back in about 2 minutes")
                }
                .buttonStyle(.plain)
                .confirmationDialog("Restart the widgets? The screen goes away for about two minutes.", isPresented: .init(get: { confirm == "restart" }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                    Button("Restart", role: .destructive) { model.restart(false) }
                }
                if let f = model.failed("restart") { FailNote(text: f) }
                Button { confirm = "reboot" } label: {
                    SettingRow(icon: "power", tile: ChumbyPalette.hex(0xd9483b), title: "Reboot the Chumby", detail: "Back in a few minutes")
                }
                .buttonStyle(.plain)
                .confirmationDialog("Reboot the Chumby? It takes a few minutes to come back.", isPresented: .init(get: { confirm == "reboot" }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                    Button("Reboot", role: .destructive) { model.restart(true) }
                }
                if let f = model.failed("reboot") { FailNote(text: f) }
            } header: { SectionHead(icon: "wrench.and.screwdriver.fill", text: "The Chumby", color: ChumbyPalette.sub(dark)) }
            // The connection, folded away while it works: one line saying so. Open by itself when it doesn't.
            Section {
                DisclosureGroup(isExpanded: $connection) {
                    TextField("http://chumby.local", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { connect() }
                    Button("Connect") { connect() }.disabled(address.isEmpty || address == model.address)
                    if let f = model.failed("connect") { FailNote(text: f) }
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(model.unreachable ? Color.red : ChumbyPalette.on).frame(width: 9, height: 9)
                        Text(model.unreachable ? "Can’t reach it" : "Connected")
                        Spacer(minLength: 8)
                        Text(host).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } header: { SectionHead(icon: "network", text: "Connection", color: ChumbyPalette.sub(dark)) }
            Text("Black Chumby photo: Edward Yanquen, Wikimedia Commons, CC BY 2.0, cut out and retouched. Octopus and wordmark: Chumby’s own artwork, from this device.").font(.caption2).foregroundStyle(.secondary).listRowBackground(Color.clear)
        }
        .seaList()
        .onAppear { address = model.address; if model.unreachable { connection = true } }
        .onChange(of: model.unreachable) { _, gone in if gone { withAnimation(.snappy) { connection = true } } }
        .refreshable { await model.loadSys(); await model.loadState() }
    }
}

// A settings row that does one thing: a coloured tile with its glyph, what it does, and what to expect.
struct SettingRow: View {
    let icon: String, tile: Color, title: String, detail: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// Taking a row out, in the row: a control he can see, never a swipe that slides the row off its card.
struct RowRemove: View {
    let label: String
    var icon = "minus.circle.fill"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 21)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

// Night, in one place: what night looks like (the style Home's day/night button and the widget use), and the times the
// Chumby switches by itself every day. These were "Daily schedule" on Alarms, among the alarms but not alarms, with a footer
// saying they run with the phone away; he found the Alarms tab confusing (2026-11-05), so they live here now.
struct NightSettings: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.colorScheme) private var scheme
    @AppStorage("nightKind") private var kind = "on"
    // Each time says what happens then, in words. Night here is always the chosen style, so a time set to Night never
    // disagrees with the button.
    var actions: [(String, String)] {
        [("night:night", "Night starts"), ("night:off", "Day starts"), ("screen:bright", "Screen bright"), ("screen:dim", "Screen dims"), ("screen:off", "Screen off")]
            + model.state.channelNames.map { ("channel:" + $0, "Channel: " + $0) }
    }
    func tag(_ e: ScheduleItem) -> String { e.cmd == "night" ? (e.val == "off" ? "night:off" : "night:night") : e.cmd + ":" + e.val }
    func words(_ e: ScheduleItem) -> String { actions.first { $0.0 == tag(e) }?.1 ?? (e.cmd + " " + e.val) }
    // A new style is used everywhere at once: the Chumby's own nightly times, and the Chumby itself if it's night now.
    func choose(_ style: String) {
        kind = style
        var changed = false
        for i in model.state.schedule.indices where model.state.schedule[i].cmd == "night" && model.state.schedule[i].val != "off" && model.state.schedule[i].val != style {
            model.state.schedule[i].val = style; changed = true
        }
        if changed { Task { await model.saveSchedule() } }
        if model.sys.night == 1 { model.setNight(style) }
    }
    func remove(_ id: Int) {
        model.tick()
        withAnimation(.snappy) { model.state.schedule.removeAll { $0.id == id }; model.state.reindex() }
        Task { await model.saveSchedule() }
    }
    var body: some View {
        Section {
            // What night looks like, shown rather than named: the Chumby's screen as each style leaves it.
            HStack(spacing: 12) {
                ForEach(nightStyles, id: \.0) { st in
                    NightStyleTile(style: st.0, name: st.1, chosen: model.nightStyle == st.0) { model.tick(); choose(st.0) }
                }
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
            ForEach($model.state.schedule) { $e in
                HStack(spacing: 12) {
                    Image(systemName: e.cmd == "night" ? (e.val == "off" ? "sun.max.fill" : "moon.fill") : e.cmd == "screen" ? "sun.min" : "tv")
                        .font(.body.weight(.semibold)).frame(width: 24)
                        .foregroundStyle(e.cmd == "night" && e.val == "off" ? ChumbyPalette.hex(0xe59a2e) : ChumbyPalette.hex(0xa4b7d6))
                    // In the accent, so the time reads as something to tap, not a grey chip saying when (Richard, 2026-11-09:
                    // "i should be able to delete an entry for the night time thing or edit it").
                    DatePicker("Time", selection: Binding(get: { NightSettings.date(e.time) }, set: { e.time = NightSettings.hhmm($0); model.saveScheduleSoon() }), displayedComponents: .hourAndMinute).labelsHidden()
                        .tint(ChumbyPalette.acc(scheme == .dark))
                    Spacer(minLength: 8)
                    // What happens at that time, and taking the time out, in one menu.
                    Menu {
                        Picker("What happens", selection: Binding(get: { tag(e) }, set: { v in
                            let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                            e.cmd = parts[0]; e.val = parts.count > 1 ? (parts[1] == "night" ? model.nightStyle : parts[1]) : ""
                            Task { await model.saveSchedule() }
                        })) {
                            ForEach(actions, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Divider()
                        Button("Remove this time", systemImage: "trash", role: .destructive) { remove(e.id) }
                    } label: {
                        HStack(spacing: 5) {
                            Text(words(e)).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                    }
                    .accessibilityLabel("At \(e.time): \(words(e))")
                    // Taking a time out is a control he can see in the row, as on the X widget's rows; it was only at the
                    // foot of the menu (Richard, 2026-11-09: "i should be able to delete an entry for the night time thing").
                    RowRemove(label: "Remove the \(words(e).lowercased()) time") { remove(e.id) }
                }
            }
            Button {
                var e = ScheduleItem(); e.val = model.nightStyle
                model.state.schedule.append(e); model.state.reindex(); Task { await model.saveSchedule() }
            } label: { Label("Add a time", systemImage: "plus.circle.fill") }.foregroundStyle(.tint)
            if let f = model.failed("schedule") { FailNote(text: f) }
        } header: { SectionHead(icon: "moon.fill", text: "Night", color: ChumbyPalette.sub(scheme == .dark)) }
    }
    static func date(_ s: String) -> Date {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 22, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }
    static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

// A night style as the Chumby's screen looks in it: the night clock, the clock dimmed, or the screen dark. The one chosen
// carries the accent ring and its name in the accent.
struct NightStyleTile: View {
    @Environment(\.colorScheme) private var scheme
    let style: String, name: String, chosen: Bool
    let action: () -> Void
    var body: some View {
        let acc = ChumbyPalette.acc(scheme == .dark)
        let screen = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            VStack(spacing: 7) {
                screen.fill(Color(red: 0.04, green: 0.04, blue: 0.06))
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if style != "dark" {
                            Text("10:41").font(.custom("Trebuchet MS", size: 20).weight(.bold)).monospacedDigit()
                                .foregroundStyle(.white.opacity(style == "dim" ? 0.32 : 0.95))
                        }
                    }
                    .overlay(screen.strokeBorder(chosen ? acc : .white.opacity(0.18), lineWidth: chosen ? 2.5 : 1))
                    .frame(maxWidth: 104)
                Text(name).font(.custom("Trebuchet MS", size: 14).weight(.bold))
                    .foregroundStyle(chosen ? acc : ChumbyPalette.sub(scheme == .dark))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Night looks like: \(name)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .animation(.easeInOut(duration: 0.2), value: chosen)
    }
}

extension View {
    @ViewBuilder func dragToReorder(_ on: Bool) -> some View {
        #if os(iOS)
        self.environment(\.editMode, .constant(on ? .active : .inactive))
        #else
        self
        #endif
    }
}

// Home's big skip, in the Chumby's own look: a fat gel button in the logo's blue, white Trebuchet, and the octopus on
// it. One tap lets the next alarm pass; once skipped the gel turns night navy and the octopus sleeps, with Undo, until the
// time passes.
struct SkipCard: View {
    @EnvironmentObject var model: ChumbyModel
    static let day: [UInt32] = [0x5584d6, 0x2b5cad], night: [UInt32] = [0x34508f, 0x1f2f5c]
    private func label(_ name: String) -> String {
        let n = name.hasPrefix("Calendar: ") ? String(name.dropFirst(10)) : name
        return n.isEmpty ? "Alarm" : n
    }
    private func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    private func day(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "Today" : Calendar.current.isDateInTomorrow(d) ? "Tomorrow" : d.formatted(.dateTime.weekday(.wide))
    }
    // A skip whose time has gone is over, even before the Chumby's next answer says so (a kept copy on opening, say).
    private var skipped: SkippedAlarm? { model.state.skipped.flatMap { $0.date > Date() ? $0 : nil } }
    // What the card shows, moved in one explicit transaction so the colour, the heading and the strike change together
    // (left to the model's change, the slab and strike cut in a single frame).
    @State private var shown: Bool?
    // Between a tap and the Chumby's answer: the card shows what was asked for at once (the model does), and a small
    // mark beside the heading says the Chumby is still being told; the controls themselves never turn into a spinner.
    // Undo is there the moment it's skipped, so he never waits to take it back. Taps are sent in the order he made
    // them: an Undo tapped while the skip is still on its way goes after it, so the Chumby is never left skipped by an
    // undo that got there first. The model puts the state back if the Chumby refuses, so a skip it wouldn't take comes
    // back visibly, with the reason under the card.
    @State private var inflight = 0
    @State private var queue: Task<Void, Never>?
    @State private var lastAsked: Bool?
    private var pending: Bool { inflight > 0 }
    // The skip that a "just this once" stands behind: undone, both go (the usual time rings again, the one-off is removed).
    // On the card it's that alarm moved for one ring, never a skip: the day gel, the new time, the usual one in words,
    // and "Back to 6:45 AM" (Richard, 2026-11-08: "i dont like that it shows as a skip").
    private var movedOne: JustOnceNow? { model.state.justOnce().flatMap { $0.pinned ? $0 : nil } }
    private var moved: Date? { movedOne?.at }
    private var usual: Date? { movedOne?.usual }
    private func send(_ skip: Bool) {
        // The same ask twice in a row (two taps on Undo) is one ask.
        if pending && lastAsked == skip { return }
        lastAsked = skip
        inflight += 1
        let before = queue
        queue = Task {
            await before?.value
            if skip { await model.skipNext() }
            else if moved != nil { if let why = await model.undoJustOnce() { model.fail("skip", why) } }
            else { await model.unskip() }
            inflight -= 1
        }
    }
    // The time and its line stay put; only the heading changes (the old one out before the new one in), and the
    // strike draws across the time, left to right. The time never wraps: in a narrow pane (open, beside Undo) it
    // shrinks a little, and the day line gives way before it (2026-11-07: "6:45 A / M" open in landscape).
    private func lines(_ at: Date, _ name: String, struck: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                ZStack(alignment: .leading) {
                    if struck { Text("Skipped").transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.12).delay(0.12)), removal: .opacity.animation(.easeOut(duration: 0.12)))) }
                    else { Text(moved != nil ? "Just this once" : "Skip next alarm").transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.12).delay(0.12)), removal: .opacity.animation(.easeOut(duration: 0.12)))) }
                }
                .font(.custom("Trebuchet MS", size: 15).weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                if pending { ProgressView().controlSize(.mini).tint(.white.opacity(0.85)).transition(.opacity) }
            }
            Text(time(at)).font(.custom("Trebuchet MS", size: 30).weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .overlay { StrikeLine(progress: struck ? 1 : 0) }
            Text("\(day(at)) · \(label(name))" + (moved != nil ? usual.map { " · usually \(time($0))" } ?? "" : "")).font(.custom("Trebuchet MS", size: 14)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundStyle(.white)
    }
    // "Back to 6:45 AM", the way back from a ring moved just this once: the skip taken back, then the one-off removed.
    private func backCapsule(_ at: Date) -> some View {
        Button { send(false) } label: {
            Text("Back to \(usual.map(time) ?? "usual")").font(.custom("Trebuchet MS", size: 16).weight(.bold)).foregroundStyle(ChumbyPalette.hex(0x1f2f5c))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.white, in: Capsule())
        }
        .buttonStyle(GelPress())
        .accessibilityLabel("Back to the usual \(usual.map(time) ?? "") alarm")
    }
    var body: some View {
        if model.stateKnown && model.state.skipKnown && !model.unreachable && model.sys.ringing == nil,
           let next = movedOne.flatMap({ j in j.original.map { (j.at, $0.name) } }) ?? skipped.map({ ($0.date, $0.name) }) ?? model.nextRing().map({ ($0.at, $0.alarm.name) }) {
            // Moved for one ring, the card stays awake: it isn't a skip.
            let asleep = (shown ?? (skipped != nil)) && moved == nil
            VStack(alignment: .leading, spacing: 8) {
                // One slab that only changes colour, night laid over day, so it never thins to the sea between states;
                // only what's written on it crossfades.
                // Awake, the whole slab is the button; asleep it does nothing, and only Undo (laid on it, not inside it)
                // answers.
                Button { if !asleep && !pending && moved == nil { send(true) } } label: {
                ZStack {
                    ChumbyGel(colors: Self.day, rim: 0x1f4589)
                    ChumbyGel(colors: Self.night, rim: 0x172447).opacity(asleep ? 1 : 0)
                    // Moved for one ring, "Back to 6:45 AM" is a row of its own under the words: beside them it
                    // squeezed the heading, time and day to "Just this on… / 6:55… / Today · Wo…" folded and open
                    // (build 218).
                    VStack(alignment: .trailing, spacing: moved != nil ? 10 : 0) {
                        HStack(spacing: 14) {
                            SleepyOctopus(asleep: asleep, tint: .white)
                            lines(next.0, next.1, struck: asleep)
                            Spacer(minLength: 8)
                            Image(systemName: "forward.end.fill").font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                                .opacity(asleep || moved != nil ? 0 : 1)
                                // Room for Undo, which sits over this end of the slab.
                                .frame(minWidth: moved != nil ? 0 : asleep ? 92 : 0, alignment: .trailing)
                        }
                        if moved != nil { backCapsule(next.0) }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                }
                .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .buttonStyle(GelPress(enabled: !asleep && moved == nil))
                .disabled(asleep || moved != nil)
                .accessibilityLabel(moved != nil ? "Just this once, \(time(next.0)) alarm" : asleep ? "Skipped, \(time(next.0)) alarm" : "Skip the \(time(next.0)) alarm, \(day(next.0))")
                .overlay(alignment: .trailing) {
                    if asleep && moved == nil {
                        Button { send(false) } label: {
                            Text("Undo").font(.custom("Trebuchet MS", size: 18).weight(.bold)).foregroundStyle(ChumbyPalette.hex(0x1f2f5c))
                                .padding(.horizontal, 20).padding(.vertical, 11)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(GelPress())
                        .padding(.trailing, 18)
                        .accessibilityLabel("Undo the skip, so the \(time(next.0)) alarm rings")
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                if let f = model.failed("skip") { FailNote(text: f) }
                // Later or another sound for that one ring, under the slab it belongs to.
                JustOnceMenu().padding(.leading, 18)
            }
            .animation(.easeOut(duration: 0.12), value: pending)
            .onChange(of: skipped != nil) { _, now in withAnimation(.easeInOut(duration: 0.35)) { shown = now } }
            .onAppear { shown = skipped != nil }
            // For the build's film: skip the next alarm, then undo it.
            .task {
                guard ChumbyModel.pose == "skipdemo", !Self.demoed else { return }
                Self.demoed = true
                try? await Task.sleep(nanoseconds: 3_000_000_000); send(true)
                try? await Task.sleep(nanoseconds: 4_000_000_000); send(false)
            }
        }
    }
    @MainActor static var demoed = false
}

// A line drawn across a skipped time, left to right, and taken back right to left on undo.
struct StrikeLine: View, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    var body: some View {
        GeometryReader { g in
            Path { p in p.move(to: CGPoint(x: 0, y: g.size.height / 2)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2)) }
                .trim(from: 0, to: progress)
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

// The Chumby's own button: a rounded slab of colour with a glossy cap and a darker rim, like its control panel's. In the
// logo's own blue family, so it reads as kin to the wordmark and octopus above it.
struct ChumbyGel: View {
    let colors: [UInt32]
    var rim: UInt32
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        shape.fill(LinearGradient(colors: colors.map(ChumbyPalette.hex), startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                // The gloss: a soft sheen that ends at the big digits' cap line, as on the panel's own buttons, so it never
                // cuts through a number or a strikethrough.
                shape.fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    .padding(3)
                    .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.30), .init(color: .clear, location: 0.40)], startPoint: .top, endPoint: .bottom))
            }
            .overlay(shape.strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .overlay(shape.inset(by: 0.5).stroke(LinearGradient(colors: [.clear, ChumbyPalette.hex(rim)], startPoint: .center, endPoint: .bottom), lineWidth: 1.5))
            .shadow(color: ChumbyPalette.hex(rim).opacity(0.35), radius: 10, y: 5)
    }
}

// Pressed, it squashes a little and springs back, like pressing the Chumby's soft body.
struct GelPress: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && enabled ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
// The octopus, in white on the button: eyes open while there's an alarm to skip; asleep, eyes shut to two little arcs
// and a slow "z" rising over its head.
struct SleepyOctopus: View {
    let asleep: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var still
    // Closed eyes, in the drawing's own coordinates: a smile-shaped lid across each eye.
    static let lids: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -20, y: -28)); p.addQuadCurve(to: CGPoint(x: 0, y: -28), control: CGPoint(x: -10, y: -19))
        p.move(to: CGPoint(x: 17, y: -30)); p.addQuadCurve(to: CGPoint(x: 35, y: -30), control: CGPoint(x: 26, y: -22))
        return p
    }()
    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                ArtShape(art: ChumbyArt.octBody, box: ChumbyArt.octBox).fill(tint, style: FillStyle(eoFill: true))
                ArtShape(art: ChumbyArt.octEyes, box: ChumbyArt.octBox).fill(ChumbyPalette.hex(0x2b5cad), style: FillStyle(eoFill: true))
                    .opacity(asleep ? 0 : 1)
                ArtShape(art: Self.lids, box: ChumbyArt.octBox).stroke(ChumbyPalette.hex(0x1f2f5c), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .opacity(asleep ? 1 : 0)
            }
            .frame(width: 56, height: 44)
            .padding(.top, 8)
            if asleep {
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: still)) { ctx in
                    let k = still ? 0.5 : (ctx.date.timeIntervalSinceReferenceDate / 2.4).truncatingRemainder(dividingBy: 1)
                    // Fully white at its peak, with a navy edge, so it reads over the gloss rather than as a grey smudge.
                    Text("z").font(.custom("Trebuchet MS", size: 15).weight(.bold)).foregroundStyle(tint)
                        .shadow(color: ChumbyPalette.hex(0x1f2f5c), radius: 1)
                        // 3 pt clear of the head even at its lowest.
                        .offset(x: 4 + 3 * k, y: -5 - 8 * k)
                        .opacity(0.85 * min(1, 1.6 * sin(.pi * k)))
                }
                .transition(.opacity)
            }
        }
        .frame(width: 60, height: 52)
        .accessibilityHidden(true)
    }
}
