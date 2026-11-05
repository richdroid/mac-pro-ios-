import SwiftUI

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
                    if p == .active { model.start(); CalendarWake.shared.syncIfDue() } else { model.stop() }
                    #if os(iOS)
                    if p == .background { CalendarWake.shared.scheduleRefresh() }
                    #endif
                }
                .onAppear {
                    model.start()
                    // Calendar alarms follow the calendar from the start, not only once the Alarms tab has been opened.
                    if CalendarWake.shared.rules.enabled { CalendarWake.shared.startWatching() }
                    CalendarWake.shared.syncIfDue()
                    // "Woke up to" covers, from the kept list and then the fresh one, long before Alarms is opened.
                    SongArt.shared.prefetch(model.songs, model.state.alarms)
                    Task { await model.loadSongs(); SongArt.shared.prefetch(model.songs, model.state.alarms) }
                    TabTour.run([0, 1, 2, 3, 4]) { model.tab = $0 }
                }
                .onOpenURL { if $0.host == "tab", let t = Int($0.lastPathComponent) { model.tab = t } }
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

// MARK: - The sea, the ghost, the glass
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
                ZStack {
                    c[0]
                    blob(c[1], m * 1.05, -0.30, -0.28, 26, m, t)
                    blob(c[2], m * 0.75, 0.34, -0.10, 33, m, t)
                    blob(c[3], m * 0.80, -0.22, 0.32, 29, m, t)
                    blob(c[4], m * 0.55, 0.26, 0.32, 37, m, t)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .transaction { $0.animation = nil }
    }
    // The same ease in and out as before, back and forth over twice its period, as a sine of the time.
    func blob(_ color: Color, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ period: Double, _ m: CGFloat, _ t: Double) -> some View {
        let k = CGFloat(0.5 - 0.5 * cos(.pi * t / period))
        return Circle().fill(RadialGradient(colors: [color, color.opacity(0.75), color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .scaleEffect(1 + 0.14 * k)
            .offset(x: m * x + size * (-0.05 + 0.12 * k), y: m * y + size * (-0.03 + 0.09 * k))
    }
}

struct GhostOctopus: View {
    var active = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still || !active)) { ctx in
                let k = still ? 0.5 : 0.5 - 0.5 * cos(.pi * ctx.date.timeIntervalSinceReferenceDate / 14)
                ArtShape(art: ChumbyArt.octBody, box: ChumbyArt.octBox)
                    .fill(scheme == .dark ? ChumbyPalette.hex(0x79bbff).opacity(0.08) : Color.white.opacity(0.34), style: FillStyle(eoFill: true))
                    .frame(width: min(g.size.width, g.size.height) * 1.5)
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
    func seaList() -> some View { self.scrollContentBackground(.hidden).listSectionSpacing(14) }
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

extension View {
    // Each tab paints its own sea: the system tab view is opaque behind its content. Only the tab on screen drifts.
    func overSea(active: Bool = true, shown: Bool = true) -> some View {
        self.background { if shown { ZStack { SeaBackground(active: active); GhostOctopus(active: active) }.ignoresSafeArea() } }
    }
    // A tab's own page: its title is the first row, so no empty bar sits above it and every tab starts at the same height.
    func tabPage(_ tab: Int, _ model: ChumbyModel) -> some View {
        self.overSea(active: model.tab == tab).toolbar(.hidden, for: .navigationBar)
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
                // The Duo's side column (clock, Wi-Fi and the tab bar) is the trailing safe area; + goes in it on Alarms.
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
            // Add alarm, in the side column under the clock, where the system would put a bar button on the Duo. On a page
            // inside Alarms, Back takes the same slot alone. It sits out here, over the tabs, so it never slides with the page.
            .overlay {
                if model.tab == 2 && model.railWidth >= 44 {
                    // One glass circle whose glyph turns from + to Back: two glass buttons swapped in a single frame.
                    railButton(model.alarmsPage ? "chevron.left" : "plus", model.alarmsPage ? "Back" : "Add alarm") {
                        if model.alarmsPage { model.alarmsPage = false } else { model.addAlarm = Date() }
                    }
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.25), value: model.alarmsPage)
                    .frame(width: model.railWidth).padding(.top, 196)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .ignoresSafeArea()
                }
            }
        }
        .sheet(isPresented: $model.needsAddress) { ConnectionView().environmentObject(model).interactiveDismissDisabled(model.api == nil) }
    }
    // The rail's own glass circle, in the page's ink, the same for + and Back.
    func railButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).frame(width: 30, height: 30) }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .foregroundStyle(ChumbyPalette.ink(scheme == .dark))
            .accessibilityLabel(label)
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
                } header: { Text("Chumby address") } footer: {
                    Text("This is already set to your Chumby. Change it only if the address moves.")
                }
            }
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
            Text("Chumby Classic").font(.custom("Trebuchet MS", size: 30).weight(.bold)).padding(.top, 20)
            Text("Black, 3.5-inch, 2008").font(.custom("Trebuchet MS", size: 15)).foregroundStyle(ChumbyPalette.sub(dark)).padding(.top, 2).padding(.bottom, 16)
            Grid(horizontalSpacing: 12, verticalSpacing: 5) {
                if !name.isEmpty { spec("Name", name) }
                spec("Chip", "Freescale i.MX21, ARM926EJ-S")
                spec("Memory", "64 MB")
                spec("Display", "3.5-inch, 320 × 240, touch")
                if !serial.isEmpty { spec("Serial number", serial) }
                spec("Software", "1.7.2 (build 1830)")
                spec("Playing", model.unreachable ? "Can’t reach the Chumby" : !model.sys.lock.isEmpty ? "Busy: \(model.sys.lock)" : model.sys.chan.isEmpty ? "Awake" : model.sys.chan)
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
    var remote: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                NightButton()
                RemoteButton(icon: "backward.fill", label: "Previous widget", big: true) { model.cmd("prev", id: "remote") }
                RemoteButton(icon: "forward.fill", label: "Next widget", big: true) { model.cmd("next", id: "remote") }
                ScreenButton()
            }
            .disabled(model.unreachable).opacity(model.unreachable ? 0.45 : 1)
            if let f = model.failed("remote") { FailNote(text: f) }
        }
        .padding(.bottom, 20)
    }
    @State private var homeVolume = 0.0
    @State private var dragging = false
    // Nothing to show until the Chumby has said something: an empty card is a meaningless glass dot.
    var rightNowEmpty: Bool {
        !(model.stateKnown && !model.state.skipKnown && model.nextRing() != nil) && model.sys.vol < 0 && model.failed("homeVolume") == nil && model.state.channelNames.isEmpty
    }
    @ViewBuilder var rightNow: some View {
        if !rightNowEmpty { rightNowCard }
    }
    var rightNowCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Right now").font(.custom("Trebuchet MS", size: 16).weight(.semibold)).foregroundStyle(ChumbyPalette.sub(dark)).padding(.leading, 18)
            VStack(alignment: .leading, spacing: 14) {
                // The Skip card shows the next alarm when the Chumby can skip, so it's never said twice.
                if model.stateKnown, !model.state.skipKnown, let n = model.nextRing() {
                    Button { model.tab = 2 } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "alarm.fill").foregroundStyle(ChumbyPalette.orange)
                            Text(n.at.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            Spacer()
                            Text(n.at, style: .relative).font(.custom("Trebuchet MS", size: 15)).foregroundStyle(ChumbyPalette.sub(dark)).lineLimit(1)
                        }
                    }.buttonStyle(.plain)
                }
                // Not until the Chumby has said how loud it is: a slider at 0 would be a guess.
                if model.sys.vol >= 0 {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill").font(.footnote)
                    Slider(value: $homeVolume, in: 0...100, step: 1) { e in
                        dragging = e
                        if !e { model.cmd("volume", String(Int(homeVolume)), id: "homeVolume") }
                    }
                    .tint(ChumbyPalette.orange).accessibilityLabel("Volume")
                    Button { model.cmd("stopmusic", id: "homeVolume") } label: { Image(systemName: "stop.fill") }.buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("Stop music")
                }
                }
                if let f = model.failed("homeVolume") { FailNote(text: f) }
                if !model.state.channelNames.isEmpty {
                    Menu {
                        ForEach(model.state.channelNames, id: \.self) { n in Button(n) { model.playChannel(n, id: "homeChannel") } }
                    } label: {
                        HStack { Image(systemName: "tv"); Text(model.state.channel.isEmpty ? "Channel" : model.state.channel).lineLimit(1); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.footnote) }
                    }.foregroundStyle(.tint)
                    if let f = model.failed("homeChannel") { FailNote(text: f) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).card()
            .disabled(model.unreachable)
        }
        // Left-aligned however little the card holds, as on every other Home.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
        .task(id: model.sys.vol) { if !dragging && model.sys.vol >= 0 { homeVolume = Double(model.sys.vol) } }
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
                    ScrollView { VStack(spacing: 0) { stage; status; about }.padding(.horizontal, 12) }
                } right: {
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 40)
                            if model.sys.ringing != nil { RingingCard().card().padding(.bottom, 20).transition(.ringCard) }
                            remote
                            SkipCard().padding(.bottom, 20)
                            rightNow
                            more
                        }.padding(.horizontal, 12)
                    }
                }
            } else {
                ScrollView {
                    // The wordmark is drawn by the stage itself. The remote sits right under the device, within reach of the thumb; a ringing alarm above even that.
                    VStack(spacing: 0) {
                        stage; status
                        if model.sys.ringing != nil { RingingCard().card().padding(.top, 20).transition(.ringCard) }
                        remote.padding(.top, 20); SkipCard().padding(.top, 20); rightNow; about; if moreInfo { more }
                    }.padding(.horizontal, 16)
                }
            }
        }
        .animation(ChumbyModel.ringChange(to: model.sys.ringing), value: model.sys.ringing)
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

struct RemoteButton: View {
    let icon: String, label: String
    var big = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: big ? 24 : 20)).frame(width: big ? 52 : 40, height: big ? 52 : 40)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large).accessibilityLabel(label)
    }
}
// One button for night mode, showing the mode the Chumby is really in: the moon fills in while it's on. Tap to switch it;
// hold for which kind. The Chumby can't say which kind it's in, so that part is remembered from here.
struct NightButton: View {
    @EnvironmentObject var model: ChumbyModel
    @AppStorage("nightKind") private var kind = "on"
    static let kinds = [("on", "Clock"), ("dim", "Dim"), ("dark", "Dark")]
    var on: Bool { model.sys.night == 1 }
    var menu: some View {
        Menu {
            ForEach(Self.kinds, id: \.0) { k in
                Button { kind = k.0; model.setNight(k.0) } label: { if on && kind == k.0 { Label(k.1, systemImage: "checkmark") } else { Text(k.1) } }
            }
            if on { Divider(); Button("Night mode off") { model.setNight("off") } }
        } label: {
            Image(systemName: on ? "moon.fill" : "moon").font(.system(size: 20)).frame(width: 40, height: 40)
        } primaryAction: {
            model.setNight(on ? "off" : kind)
        }
        .buttonBorderShape(.circle).controlSize(.large)
        .accessibilityLabel(on ? "End night mode" : "Night mode").accessibilityHint("Hold for dim or dark")
    }
    var body: some View {
        if on { menu.buttonStyle(.glassProminent) } else { menu.buttonStyle(.glass) }
    }
}
// Brighten the screen with a tap; hold to dim it or turn it off.
struct ScreenButton: View {
    @EnvironmentObject var model: ChumbyModel
    var body: some View {
        Menu {
            Button("Screen dim") { model.cmd("screen", "dim", id: "remote") }
            Button("Screen off") { model.cmd("screen", "off", id: "remote") }
        } label: {
            Image(systemName: "sun.max").font(.system(size: 20)).frame(width: 40, height: 40)
        } primaryAction: {
            model.cmd("screen", "bright", id: "remote")
        }
        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        .accessibilityLabel("Brighten the screen").accessibilityHint("Hold to dim it or turn it off")
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
    @Environment(\.colorScheme) private var scheme

    var channels: [ChannelList.Channel] { model.channelData?.channels ?? [] }
    func title(_ c: ChannelList.Channel) -> String { c.list.first.flatMap { $0.count > 1 ? $0[1] : nil } ?? "Channel" }
    var allWidgets: [[String]] {
        var m: [String: [String]] = [:]
        for n in model.channelData?.names ?? [] where n.count > 1 { m[n[0]] = [n[0], n[1], "0"] }
        for c in channels { for l in c.list where l.first != "#" && l.count > 1 { m[l[0]] = l } }
        return m.values.sorted { $0[1].localizedCaseInsensitiveCompare($1[1]) == .orderedAscending }
    }

    // Every widget the Chumby knows by id that this channel doesn't hold, so it can be added in one tap.
    var notHere: [[String]] { allWidgets.filter { w in !rows.contains { $0.id == w[0] } } }
    // Joins the channel at the end, on, at the default time, and shows at once: the list scrolls to it and it glows a moment.
    func add(id: String, name: String, own: Int, scroll: ScrollViewProxy) {
        guard !rows.contains(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { rows.append(EditorRow(id: id, name: name, on: true, secs: 0, own: own)); justAdded = id }
        changed()
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.snappy) { scroll.scrollTo(id, anchor: .center) }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if justAdded == id { withAnimation(.easeOut(duration: 0.6)) { justAdded = nil } }
        }
    }
    func remove(_ id: String) {
        withAnimation(.snappy) { rows.removeAll { $0.id == id } }
        changed()
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
    // One + row, the same for the Chumby's own widgets and the catalog's.
    func moreRow(id: String, name: String, own: Int, scroll: ScrollViewProxy) -> some View {
        HStack(spacing: 14) {
            Text(name).font(.custom("Trebuchet MS", size: 17)).lineLimit(1)
            Spacer(minLength: 12)
            Button { add(id: id, name: name, own: own, scroll: scroll) } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .bold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .foregroundStyle(ChumbyPalette.acc(scheme == .dark))
            .accessibilityLabel("Add \(name) to this channel")
        }
        .padding(.vertical, 2)
    }
    // What "More widgets" lists: the Chumby's own that this channel lacks, or a catalog category's.
    struct MoreItem { let id: String, name: String, own: Int; var more: String { "more-" + id } }
    var moreList: [MoreItem] {
        if category.isEmpty { return notHere.filter { w in !rows.contains { $0.id == w[0] } }.map { MoreItem(id: $0[0], name: $0[1], own: $0.count > 2 ? Int($0[2]) ?? 0 : 0) } }
        return catalog.filter { c in !rows.contains { $0.id == c.0 } }.map { MoreItem(id: $0.0, name: $0.1, own: 0) }
    }
    // For the build: a channel chosen in Now playing (chsync), then a widget added with + (chdemo).
    @State private var posed = false
    @State private var demoAdd: Date?

    var body: some View {
        ScrollViewReader { scroll in
        TwoPane {
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
                // The same header as More widgets, so the page's sections read as one set.
                Text("Now playing").font(.custom("Trebuchet MS", size: 16).weight(.bold)).textCase(nil)
            }
        } right: {
            Section {
                // By id, never by index: following the playing channel swaps `rows` under a live switch, and an index
                // binding then reads past the end (it crashed choosing a channel).
                ForEach(rows, id: \.id) { w in
                    // The name and its time on the left, the switch alone on the right, so the two never crowd each other.
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(w.name).lineLimit(1).opacity(w.on ? 1 : 0.45)
                            Menu {
                                Picker("Time on screen", selection: rowBinding(w.id, \.secs, w.secs)) {
                                    Text(w.own > 0 ? "Auto (\(w.own)s)" : "Auto").tag(0)
                                    ForEach(widgetTimes, id: \.self) { Text(timeText($0)).tag($0) }
                                }
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
                            .disabled(!w.on).opacity(w.on ? 1 : 0.4)
                            .accessibilityLabel("Time on screen")
                            .onChange(of: w.secs) { _, _ in changed() }
                        }
                        Spacer(minLength: 12)
                        Toggle("On", isOn: rowBinding(w.id, \.on, w.on)).labelsHidden().onChange(of: w.on) { _, _ in changed() }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        Button("Remove", role: .destructive) { remove(w.id) }
                    }
                    .listRowBackground(GlassRow().overlay(ChumbyPalette.acc(scheme == .dark).opacity(justAdded == w.id ? 0.22 : 0)))
                }
                .onMove { rows.move(fromOffsets: $0, toOffset: $1); changed() }
                .deleteDisabled(true)
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
                    Button(reordering ? "Done" : "Reorder") { withAnimation(.snappy) { reordering.toggle() } }
                        .font(.body.weight(.semibold)).foregroundStyle(.tint)
                }
                .textCase(nil)
            } footer: {
                // Only what he couldn't guess: Reorder and swipe-to-remove explain themselves.
                if model.state.shuffle == 1 { Text("Shuffle is on, so your order won’t show until you turn it off.") }
            }
            // The one way to add a widget: the Chumby's own, or a catalog category's, each with the same +.
            if !picked.isEmpty {
                Section {
                    Picker("Category", selection: $category) {
                        Text("On the Chumby").tag("")
                        ForEach(categories, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: category) { _, _ in catalog = []; page = 1; more = false; Task { await loadCatalog() } }
                    // Its own ids, so an added widget fades out here and in above, rather than flying across as one row.
                    ForEach(moreList, id: \.more) { w in moreRow(id: w.id, name: w.name, own: w.own, scroll: scroll).transition(.opacity) }
                        .deleteDisabled(true).moveDisabled(true)
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    if category.isEmpty && notHere.isEmpty { Text("Every widget on the Chumby is in this channel.").foregroundStyle(.secondary) }
                    if !category.isEmpty && more && !busy { Button("Load more") { page += 1; Task { await loadCatalog() } }.foregroundStyle(.tint) }
                    if let f = model.failed("catalog") { FailNote(text: f) }
                } header: {
                    Text("More widgets").font(.custom("Trebuchet MS", size: 16).weight(.bold)).textCase(nil)
                }
            }
        }
        .onChange(of: demoAdd) { _, _ in if let w = moreList.first { add(id: w.id, name: w.name, own: w.own, scroll: scroll) } }
        }
        .seaList()
        .dragToReorder(reordering)
        .onAppear {
            startFromCache()
            guard !posed, ChumbyModel.pose == "chsync" || ChumbyModel.pose == "chdemo" else { return }
            posed = true
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let n = model.state.channelNames.first(where: { $0 != model.state.channel }) { model.playChannel(n, id: "nowPlaying") }
                guard ChumbyModel.pose == "chdemo" else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000); demoAdd = Date()
            }
        }
        .onChange(of: picked) { _, _ in pick() }
        .onChange(of: model.chosenChannel) { _, c in if let c { followPlaying(c.name) } }
        .task { await model.loadChannels(); if rows.isEmpty { startFromCache(); if rows.isEmpty { pick() } }; await loadCategories() }
        .onDisappear { flush() }
        .refreshable { flush(); edited = [:]; await model.loadChannels(); await model.loadState(); pick() }
    }
}

// MARK: - Sounds
struct SoundsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @AppStorage("lastVolume") private var lastVolume = 4
    @State private var volume = 0.0
    @State private var dragging = false
    @State private var alarmVolume = 100.0
    @State private var addStream = false
    @State private var streamURL = ""
    @State private var streamName = ""
    @State private var pendingRemoval: Stream?

    func set(_ v: Int) { volume = Double(v); model.cmd("volume", String(v), id: "sounds") }
    var scanNote: String? {
        switch model.state.pandoraScan.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "waiting": return "Listening for 4 minutes. On the Chumby, open Music, then Pandora Radio."
        case "timeout": return "Didn’t see the station list. Tap again, then open Pandora on the Chumby."
        case "error": return "That didn’t work. Try again."
        default: return nil
        }
    }

    var body: some View {
        TwoPane {
            PageTitle("Sounds")
            ReachRow()
            Section("Now") {
                VStack(spacing: 10) {
                    LabeledContent("Volume", value: "\(Int(volume))%")
                    HStack(spacing: 12) {
                        Button {
                            if volume > 0 { lastVolume = Int(volume); set(0) } else { set(lastVolume > 0 ? lastVolume : 4) }
                        } label: { Image(systemName: volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill").frame(width: 24) }
                        .buttonStyle(.borderless).accessibilityLabel(volume > 0 ? "Mute" : "Unmute")
                        Slider(value: $volume, in: 0...100, step: 1) { e in
                            dragging = e
                            if !e { if volume > 0 { lastVolume = Int(volume) }; model.cmd("volume", String(Int(volume)), id: "sounds") }
                        }.accessibilityLabel("Volume").tint(ChumbyPalette.orange)
                    }
                }
                Button("Stop music") { model.cmd("stopmusic", id: "sounds") }.foregroundStyle(.tint)
                Toggle("AirPlay receiver", isOn: Binding(get: { model.sys.airplayOn }, set: { on in model.sys.airplayOn = on; model.cmd("airplay", on ? "1" : "0", id: "sounds") }))
                if let f = model.failed("sounds") { FailNote(text: f) }
            }
            Section {
                ForEach(model.state.pandora) { Text($0.name) }
                Button(model.state.pandora.isEmpty ? "Get my stations" : "Update station list") {
                    Task {
                        do { try await model.api?.post("pscan"); model.state.pandoraScan = "waiting" }
                        catch { model.fail("pscan", "Couldn’t start listening. \(AlarmWriter.explain(error))") }
                    }
                }.foregroundStyle(.tint)
                if let f = model.failed("pscan") { FailNote(text: f) }
            } header: { Text("Pandora") } footer: { if let scanNote { Text(scanNote) } }
            } right: {
            // How loud the alarms ring: saved the careful way, and marked here if it doesn't reach the Chumby.
            Section("Alarms") {
                VStack(spacing: 10) {
                    LabeledContent("Volume", value: "\(Int(alarmVolume))%")
                    Slider(value: $alarmVolume, in: 0...100, step: 5) { e in
                        if !e { model.change(.volume(Int(alarmVolume))) }
                    }.accessibilityLabel("Alarm volume").tint(ChumbyPalette.orange)
                        .overlay(alignment: .trailing) { LandBubble(mark: "alarmVolume") }
                }
                MarkNote(mark: "alarmVolume")
                Picker("Fade in", selection: Binding(get: { model.state.fade }, set: { model.change(.fade($0)) })) {
                    ForEach([(-1, "Chumby default"), (0, "Off"), (5, "5 seconds"), (15, "15 seconds"), (30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes")], id: \.0) { Text($0.1).tag($0.0) }
                }
                MarkNote(mark: "fade")
            }
            Section {
                ForEach(model.state.streams, id: \.key) { s in
                    Text(s.name.isEmpty ? s.url : s.name).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .swipeActions { Button("Remove", role: .destructive) { pendingRemoval = s } }
                        // The question hangs off the row that was swiped, so it points at what's going.
                        .confirmationDialog("Remove \(s.name.isEmpty ? "this stream" : s.name)?", isPresented: .init(get: { pendingRemoval?.key == s.key }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
                            Button("Remove", role: .destructive) {
                                model.state.streams.removeAll { $0.key == s.key }; Task { await model.saveStreams() }
                            }
                        }
                }
                Button("Add a stream…") { addStream = true }.foregroundStyle(.tint)
                if let f = model.failed("streams") { FailNote(text: f) }
            } header: { Text("Radio streams") } footer: { if !model.state.streams.isEmpty { Text("Swipe a stream to remove it.") } }
        }
        .seaList()
        .task(id: model.sys.vol) { if !dragging && model.sys.vol >= 0 { volume = Double(model.sys.vol) } }
        .task(id: model.state.volume) { alarmVolume = Double(model.state.volume) }
        .refreshable { await model.loadSys(); await model.loadState() }
        .alert("Add a stream", isPresented: $addStream) {
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
struct TinkerTab: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var accounts = ""
    @State private var edited = false
    @State private var confirm: String?
    @State private var address = ""
    func connect() {
        model.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.api != nil { model.needsAddress = false; model.start() } else { model.fail("connect", "That isn’t an address the app can use.") }
    }

    var body: some View {
        TwoPane {
            PageTitle("Enjoy tinkering?")
            ReachRow()
            Section {
                TextField("NASA, BBCBreaking", text: $accounts).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: accounts) { _, n in edited = n != model.sys.tw.joined(separator: ", ") }
                Button("Save") {
                    Task {
                        do { try await model.api?.post("twset", body: ChumbyAPI.form([("v", accounts)])); edited = false; await model.loadSys() }
                        catch { model.fail("twset", "Couldn’t save. \(AlarmWriter.explain(error))") }
                    }
                }.disabled(!edited).foregroundStyle(edited ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                if let f = model.failed("twset") { FailNote(text: f) }
            } header: { Text("X (Twitter) accounts") }
            } right: {
            Section("The Chumby itself") {
                Button("Restart channel") { confirm = "restart" }.foregroundStyle(.tint).confirmationDialog(
                    "Restart the channel? The screen goes away for about two minutes.", isPresented: .init(get: { confirm == "restart" }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                    Button("Restart", role: .destructive) { model.restart(false) }
                }
                if let f = model.failed("restart") { FailNote(text: f) }
                Button("Reboot", role: .destructive) { confirm = "reboot" }.foregroundStyle(.red).confirmationDialog(
                    "Reboot the Chumby? It takes a few minutes to come back.", isPresented: .init(get: { confirm == "reboot" }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                    Button("Reboot", role: .destructive) { model.restart(true) }
                }
                if let f = model.failed("reboot") { FailNote(text: f) }
            }
            // The connection lives here, with the rest of the settings, at the foot of the side bar.
            Section {
                TextField("http://chumby.local", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { connect() }
                Button("Connect") { connect() }.disabled(address.isEmpty || address == model.address)
                if let f = model.failed("connect") { FailNote(text: f) }
            } header: { Text("Chumby address") } footer: { Text("Already set to your Chumby. Change it only if its address moves.") }
            Text("Black Chumby photo: Edward Yanquen, Wikimedia Commons, CC BY 2.0, cut out and retouched. Octopus and wordmark: Chumby’s own artwork, from this device.").font(.caption2).foregroundStyle(.secondary).listRowBackground(Color.clear)
        }
        .seaList()
        .task(id: model.sys.tw) { if !edited { accounts = model.sys.tw.joined(separator: ", ") } }
        .onAppear { address = model.address }
        .refreshable { await model.loadSys(); await model.loadState() }
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
    // The time and its line stay put; only the heading changes (the old one out before the new one in), and the
    // strike draws across the time, left to right.
    private func lines(_ at: Date, _ name: String, struck: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .leading) {
                if struck { Text("Skipped").transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.12).delay(0.12)), removal: .opacity.animation(.easeOut(duration: 0.12)))) }
                else { Text("Skip next alarm").transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.12).delay(0.12)), removal: .opacity.animation(.easeOut(duration: 0.12)))) }
            }
            .font(.custom("Trebuchet MS", size: 15).weight(.bold))
            Text(time(at)).font(.custom("Trebuchet MS", size: 30).weight(.bold))
                .overlay {
                    Capsule().fill(.white.opacity(0.75)).frame(height: 2.5)
                        .scaleEffect(x: struck ? 1 : 0, anchor: .leading)
                        .animation(.easeInOut(duration: 0.25), value: struck)
                }
            Text("\(day(at)) · \(label(name))").font(.custom("Trebuchet MS", size: 14)).lineLimit(1)
        }
        .foregroundStyle(.white)
    }
    var body: some View {
        if model.stateKnown && model.state.skipKnown && !model.unreachable && model.sys.ringing == nil, let next = skipped.map({ ($0.date, $0.name) }) ?? model.nextRing().map({ ($0.at, $0.alarm.name) }) {
            let asleep = skipped != nil
            VStack(alignment: .leading, spacing: 8) {
                // One slab that only changes colour, night laid over day, so it never thins to the sea between states;
                // only what's written on it crossfades.
                // Awake, the whole slab is the button; asleep it does nothing, and only Undo (laid on it, not inside it)
                // answers.
                Button { if !asleep { Task { await model.skipNext() } } } label: {
                ZStack {
                    ChumbyGel(colors: Self.day, rim: 0x1f4589)
                    ChumbyGel(colors: Self.night, rim: 0x172447).opacity(asleep ? 1 : 0)
                    HStack(spacing: 14) {
                        SleepyOctopus(asleep: asleep, tint: .white)
                        lines(next.0, next.1, struck: asleep)
                        Spacer(minLength: 8)
                        Image(systemName: "forward.end.fill").font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                            .opacity(asleep ? 0 : 1)
                            // Room for Undo, which sits over this end of the slab.
                            .frame(minWidth: asleep ? 92 : 0, alignment: .trailing)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                }
                .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .buttonStyle(GelPress(enabled: !asleep))
                .disabled(asleep)
                .accessibilityLabel(asleep ? "Skipped, \(time(next.0)) alarm" : "Skip the \(time(next.0)) alarm, \(day(next.0))")
                .overlay(alignment: .trailing) {
                    if asleep {
                        Button { Task { await model.unskip() } } label: {
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
            }
            .animation(.easeInOut(duration: 0.3), value: asleep)
            // For the build's film: skip the next alarm, then undo it.
            .task {
                guard ChumbyModel.pose == "skipdemo", !Self.demoed else { return }
                Self.demoed = true
                try? await Task.sleep(nanoseconds: 3_000_000_000); await model.skipNext()
                try? await Task.sleep(nanoseconds: 4_000_000_000); await model.unskip()
            }
        }
    }
    @MainActor static var demoed = false
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
                        .offset(x: 4 + 3 * k, y: -2 - 8 * k)
                        .opacity(min(1, 1.6 * sin(.pi * k)))
                }
                .transition(.opacity)
            }
        }
        .frame(width: 60, height: 52)
        .accessibilityHidden(true)
    }
}
