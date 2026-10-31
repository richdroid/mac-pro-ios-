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
                .onChange(of: phase) { _, p in if p == .active { model.start() } else { model.stop() } }
                .onAppear { model.start() }
        }
    }
}

// MARK: - The sea, the ghost, the glass
struct SeaBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        let c = ChumbyPalette.sea(scheme == .dark)
        GeometryReader { g in
            let m = max(g.size.width, g.size.height)
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: still)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    c[0]
                    blob(c[1], m * 0.70, -0.30, -0.28, 26, 0, t, m)
                    blob(c[2], m * 0.46, 0.34, -0.10, 33, 7, t, m)
                    blob(c[3], m * 0.50, -0.22, 0.32, 29, 13, t, m)
                    blob(c[4], m * 0.32, 0.26, 0.32, 37, 3, t, m)
                }
                .frame(width: g.size.width, height: g.size.height)
                .drawingGroup()
            }
        }
    }
    func blob(_ color: Color, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ period: Double, _ delay: Double, _ t: Double, _ m: CGFloat) -> some View {
        let p = 0.5 - 0.5 * cos(2 * .pi * (t + delay) / (period * 2))
        return Circle().fill(color).frame(width: size, height: size).blur(radius: 60).opacity(0.9)
            .scaleEffect(1 + 0.14 * p)
            .offset(x: m * x + size * (-0.05 + 0.12 * p), y: m * y + size * (-0.03 + 0.09 * p))
    }
}

struct GhostOctopus: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: still)) { ctx in
                let p = 0.5 - 0.5 * cos(2 * .pi * ctx.date.timeIntervalSinceReferenceDate / 28)
                ArtShape(art: ChumbyArt.octBody, box: ChumbyArt.octBox)
                    .fill(scheme == .dark ? ChumbyPalette.hex(0x79bbff).opacity(0.08) : Color.white.opacity(0.34), style: FillStyle(eoFill: true))
                    .frame(width: min(g.size.width, g.size.height) * 1.5)
                    .rotationEffect(.degrees(-3 + 6 * p))
                    .offset(y: -8 + 22 * p)
                    .position(x: g.size.width / 2, y: g.size.height * 0.42)
            }
        }
        .allowsHitTesting(false)
    }
}

struct GlassFill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let shape: AnyShape
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content.background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(LinearGradient(colors: dark ? [Color(red: 0.12, green: 0.24, blue: 0.47).opacity(0.56), Color(red: 0.04, green: 0.12, blue: 0.29).opacity(0.46)] : [.white.opacity(0.62), .white.opacity(0.26)], startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.46 : 0.95), .white.opacity(dark ? 0.2 : 0.5)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: (dark ? Color.black.opacity(0.42) : Color(red: 0.04, green: 0.2, blue: 0.47).opacity(0.2)), radius: 17, y: 12)
        }
    }
}
extension AnyShape {
    func strokeBorder<S: ShapeStyle>(_ s: S, lineWidth: CGFloat) -> some View { self.stroke(s, lineWidth: lineWidth) }
}
extension View {
    func glass(_ radius: CGFloat = 26) -> some View { modifier(GlassFill(shape: AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))) }
    func glassCircle() -> some View { modifier(GlassFill(shape: AnyShape(Circle()))) }
    func seaList() -> some View { self.scrollContentBackground(.hidden).listSectionSpacing(14) }
}
struct GlassRow: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(.ultraThinMaterial).overlay(LinearGradient(colors: scheme == .dark ? [Color(red: 0.12, green: 0.24, blue: 0.47).opacity(0.5), Color(red: 0.04, green: 0.12, blue: 0.29).opacity(0.4)] : [.white.opacity(0.55), .white.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
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
        .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 0, trailing: 6))
    }
}

// MARK: - The shell
struct RootView: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.colorScheme) private var scheme
    static let tabs: [(String, String)] = [("my chumby", ""), ("channels", "tv"), ("alarms", "alarm"), ("sounds", "music.note"), ("tinker", "wrench.adjustable")]
    var body: some View {
        ZStack {
            SeaBackground().ignoresSafeArea()
            GhostOctopus().ignoresSafeArea()
            pane(0) { HomeTab() }
            pane(1) { ChannelsTab() }
            pane(2) { AlarmsTab() }
            pane(3) { SoundsTab() }
            pane(4) { TinkerTab() }
        }
        .tint(ChumbyPalette.acc(scheme == .dark))
        .foregroundStyle(ChumbyPalette.ink(scheme == .dark))
        .safeAreaInset(edge: .bottom) { tabBar }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).font(.custom("Trebuchet MS", size: 15).weight(.bold)).multilineTextAlignment(.center).padding(.horizontal, 18).padding(.vertical, 11).glass(22)
                    .padding(.bottom, 96).padding(.horizontal, 20)
                    .transition(.scale(scale: 0.9).combined(with: .move(edge: .bottom)).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if model.offline {
                Label("Can’t reach the Chumby. Is Tailscale on?", systemImage: "wifi.exclamationmark").font(.footnote.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8).background(.red.opacity(0.85), in: Capsule()).padding(.top, 4)
            }
        }
        .animation(.spring(duration: 0.42, bounce: 0.45), value: model.toast)
        .sheet(isPresented: $model.needsAddress) { ConnectionView().environmentObject(model).interactiveDismissDisabled(model.api == nil) }
    }
    func pane<C: View>(_ i: Int, @ViewBuilder _ c: () -> C) -> some View {
        c().opacity(model.tab == i ? 1 : 0).offset(y: model.tab == i ? 0 : 14).scaleEffect(model.tab == i ? 1 : 0.985)
            .allowsHitTesting(model.tab == i).accessibilityHidden(model.tab != i)
            .animation(.spring(duration: 0.45, bounce: 0.3), value: model.tab)
    }
    var tabBar: some View {
        GeometryReader { g in
            let w = (g.size.width - 8) / 5
            ZStack(alignment: .leading) {
                Capsule().fill(scheme == .dark ? .white.opacity(0.2) : .white.opacity(0.75)).overlay(Capsule().stroke(.white.opacity(scheme == .dark ? 0.3 : 0.8), lineWidth: 1))
                    .frame(width: w).padding(.vertical, 4).offset(x: 4 + w * CGFloat(model.tab))
                    .animation(.spring(duration: 0.5, bounce: 0.5), value: model.tab)
                HStack(spacing: 0) {
                    ForEach(Self.tabs.indices, id: \.self) { i in
                        Button {
                            model.tab = i; UserDefaults.standard.set(i, forKey: "tab")
                        } label: {
                            VStack(spacing: 2) {
                                if i == 0 { OctopusMark(color: .primary, eyes: .clear).frame(width: 26, height: 24) }
                                else { Image(systemName: Self.tabs[i].1 + (model.tab == i && i < 3 ? ".fill" : "")).font(.system(size: 19)).frame(height: 24) }
                                Text(Self.tabs[i].0).font(.custom("Trebuchet MS", size: 10.5).weight(.bold))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                            .foregroundStyle(model.tab == i ? ChumbyPalette.acc(scheme == .dark) : ChumbyPalette.ink(scheme == .dark))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 4)
            }
        }
        .frame(height: 66).frame(maxWidth: 520)
        .glass(33)
        .padding(.horizontal, 12).padding(.bottom, 4)
    }
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
    let squishedAt: Date?
    var body: some View {
        TimelineView(.animation(paused: still)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let bob = -7 * (0.5 - 0.5 * cos(2 * .pi * t / 4.2))
            let wave = sin(2 * .pi * t / 3)
            let lift = 0.5 + 0.5 * wave
            let cycle = t.truncatingRemainder(dividingBy: 5.3) / 5.3
            let blink: CGFloat = cycle > 0.94 ? (cycle < 0.97 ? 1 - (cycle - 0.94) / 0.03 * 0.94 : 0.06 + (cycle - 0.97) / 0.03 * 0.94) : 1
            let (sx, sy, dy) = squish(at: ctx.date)
            OctopusMark(color: ChumbyPalette.oct(scheme == .dark), blink: blink)
                .scaleEffect(x: 1, y: 1 + 0.035 * lift, anchor: UnitPoint(x: 0.5, y: 0.16))
                .modifier(SkewEffect(skew: CGFloat(wave) * 4.5 * .pi / 180, anchorY: 0.16))
                .scaleEffect(x: sx, y: sy, anchor: UnitPoint(x: 0.5, y: 0.9))
                .offset(y: bob + dy)
                .shadow(color: Color(red: 0.02, green: 0.09, blue: 0.26).opacity(0.3), radius: 3, y: 6)
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

// MARK: - My Chumby
struct HomeTab: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.horizontalSizeClass) private var size
    @Environment(\.colorScheme) private var scheme
    @State private var moreInfo = false
    @State private var say: String?
    @State private var line = 0
    @State private var squishedAt: Date?
    @State private var ink: (CGPoint, UUID)?
    @State private var bubbles: [Bubble] = []
    @State private var settings = false
    private static let lines = ["chumbalicious!", "welcome back.", "enjoy tinkering?", "wake up to your internet life", "eight arms, one job", "squeeze me!", "blub.", "i run on 175 MHz and vibes"]
    var dark: Bool { scheme == .dark }

    func poke() {
        squishedAt = Date()
        withAnimation(.spring(duration: 0.38, bounce: 0.6)) { say = Self.lines[line % Self.lines.count] }
        line += 1
        let now = Date()
        bubbles += (0..<7).map { _ in Bubble(x: .random(in: 0...1), size: .random(in: 8...28), dx: .random(in: -40...40), delay: .random(in: 0...0.25), born: now) }
        Task {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if Date().timeIntervalSince(now) >= 1.85 { withAnimation(.spring(duration: 0.3)) { say = nil } }
            try? await Task.sleep(nanoseconds: 300_000_000)
            bubbles.removeAll { Date().timeIntervalSince($0.born) > 2 }
        }
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
            .overlay(alignment: .top) {
                ZStack {
                    LiveOctopus(squishedAt: squishedAt).frame(width: 92, height: 72)
                        .contentShape(Rectangle())
                        .onTapGesture { poke() }
                        .accessibilityLabel("Octopus").accessibilityAddTraits(.isButton)
                    if let say {
                        Text(say).font(.custom("Trebuchet MS", size: 14).weight(.bold)).lineLimit(1).fixedSize().padding(.horizontal, 15).padding(.vertical, 7).glass(18)
                            .offset(y: -50).transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                    bubbleLayer
                }
                .offset(y: -58)
            }
            .frame(maxWidth: 380)
            .padding(.top, 64)
    }
    var bubbleLayer: some View {
        TimelineView(.animation(paused: bubbles.isEmpty)) { ctx in
            ZStack {
                ForEach(bubbles) { b in
                    let p = (ctx.date.timeIntervalSince(b.born) - b.delay) / 1.7
                    if p >= 0, p < 1 {
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.95), .white.opacity(0.14), ChumbyPalette.hex(0x79bbff).opacity(0.28)], center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: b.size * 0.7))
                            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                            .frame(width: b.size, height: b.size)
                            .scaleEffect(1 + 0.3 * p)
                            .offset(x: (b.x - 0.5) * 92 + b.dx * p, y: 10 - 190 * p * p)
                            .opacity(1 - p * p)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
    var liveScreen: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05)
                if let i = model.shot { Image(platform: i).resizable().interpolation(.medium) }
                else { ProgressView().tint(.white) }
                LinearGradient(colors: [.white.opacity(0.17), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.5, y: 0.5)).allowsHitTesting(false)
                if let ink {
                    InkDrop().position(ink.0).id(ink.1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onTapGesture { p in
                ink = (p, UUID())
                model.cmd("tap", "\(Int(p.x / geo.size.width * 319)),\(Int(p.y / geo.size.height * 239))")
                Task { try? await Task.sleep(nanoseconds: 350_000_000); _ = await model.refreshShot() }
            }
            .accessibilityLabel("The Chumby’s screen, live. Tap to touch it.")
        }
        .task(id: model.tab) {
            guard model.tab == 0 else { return }
            while !Task.isCancelled {
                let ok = await model.refreshShot()
                try? await Task.sleep(nanoseconds: ok ? 1_000_000_000 : 3_000_000_000)
            }
        }
    }
    func spec(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.custom("Trebuchet MS", size: 14).weight(.bold)).gridColumnAlignment(.trailing)
            Text(v).font(.custom("Trebuchet MS", size: 14)).foregroundStyle(ChumbyPalette.sub(dark)).gridColumnAlignment(.leading)
        }
    }
    var name: String { Bundle.main.object(forInfoDictionaryKey: "ChumbyName") as? String ?? "" }
    var serial: String { Bundle.main.object(forInfoDictionaryKey: "ChumbySerial") as? String ?? "" }
    var about: some View {
        VStack(spacing: 0) {
            stage
            Text("Chumby Classic").font(.custom("Trebuchet MS", size: 30).weight(.bold)).padding(.top, 20)
            Text("Black, 3.5-inch, 2008").font(.custom("Trebuchet MS", size: 14)).foregroundStyle(ChumbyPalette.sub(dark)).padding(.top, 2).padding(.bottom, 16)
            Grid(horizontalSpacing: 12, verticalSpacing: 5) {
                if !name.isEmpty { spec("Name", name) }
                spec("Chip", "Freescale i.MX21, ARM926EJ-S")
                spec("Memory", "64 MB")
                spec("Display", "3.5-inch, 320 × 240, touch")
                if !serial.isEmpty { spec("Serial number", serial) }
                spec("Software", "1.7.2 (build 1830)")
                spec("Playing", model.offline ? "Can’t reach the Chumby" : !model.sys.lock.isEmpty ? "Busy: \(model.sys.lock)" : model.sys.chan.isEmpty ? "Awake" : model.sys.chan)
            }
            Button(moreInfo ? "Less Info…" : "More Info…") { withAnimation(.spring(duration: 0.4, bounce: 0.3)) { moreInfo.toggle() } }
                .buttonStyle(GlassButton()).padding(.top, 16)
            Text("Welcome back. Tap the screen to touch it; tap the octopus to say hi.").font(.custom("Trebuchet MS", size: 13)).foregroundStyle(ChumbyPalette.sub(dark)).multilineTextAlignment(.center).padding(.top, 12).padding(.bottom, 20).padding(.horizontal, 16)
        }
    }
    var more: some View {
        VStack(spacing: 0) {
            infoRow("Awake for", duration(model.sys.up))
            infoRow("Load", String(format: "%.2f", model.sys.load))
            infoRow("Memory", "\(model.sys.memFree / 1024) MB free of \(model.sys.memTotal / 1024) MB")
            infoRow("Flash storage", "\(model.sys.pspFree) KB free")
            infoRow("Wi-Fi", model.sys.wifi >= 0 ? "\(model.sys.wifi) / 100" : "Not connected")
            infoRow("Power", model.sys.wall == 1 ? "Wall power" : "Battery")
            infoRow("Hardware", "3.8")
        }
        .glass().padding(.bottom, 20)
    }
    func infoRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(ChumbyPalette.sub(dark)).multilineTextAlignment(.trailing) }
            .padding(.horizontal, 18).frame(minHeight: 44)
    }
    var remote: some View {
        HStack(spacing: 12) {
            RemoteButton(icon: "moon.fill", label: "Night") { model.cmd("night", "on", "Goodnight") }
            RemoteButton(icon: "backward.fill", label: "Previous widget", big: true) { model.cmd("prev", nil, "Previous widget") }
            RemoteButton(icon: "forward.fill", label: "Next widget", big: true) { model.cmd("next", nil, "Next widget") }
            RemoteButton(icon: "sun.max.fill", label: "Wake") { model.cmd("night", "off"); model.cmd("screen", "bright", "Good morning") }
        }
        .padding(.bottom, 20)
    }
    var rightNow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("RIGHT NOW").font(.custom("Trebuchet MS", size: 12).weight(.bold)).kerning(1).foregroundStyle(ChumbyPalette.sub(dark)).padding(.leading, 18)
            VStack(spacing: 14) {
                Segments(title: "Night mode", options: [("Off", "off"), ("On", "on"), ("Dim", "dim"), ("Dark", "dark")]) { model.cmd("night", $0, "Night mode \($0)") }
                Segments(title: "Screen", options: [("Bright", "bright"), ("Dim", "dim"), ("Off", "off")]) { model.cmd("screen", $0, "Screen \($0)") }
            }
            .padding(14).glass()
        }
        .padding(.bottom, 20)
    }
    var word: some View {
        ZStack(alignment: .trailing) {
            ArtShape(art: ChumbyArt.word, box: ChumbyArt.wordBox).fill(ChumbyPalette.word(dark), style: FillStyle(eoFill: true))
                .frame(height: 30).frame(maxWidth: .infinity).accessibilityLabel("chumby")
            Button { settings = true } label: { Image(systemName: "gearshape").frame(width: 38, height: 38).glassCircle() }.accessibilityLabel("Connection")
        }
        .padding(.horizontal, 16).padding(.top, 6)
        .sheet(isPresented: $settings) { ConnectionView().environmentObject(model) }
    }
    var body: some View {
        ScrollView {
            word
            if size == .regular {
                HStack(alignment: .top, spacing: 28) {
                    about.frame(maxWidth: .infinity)
                    VStack(spacing: 0) { if moreInfo { more }; remote; rightNow }.frame(maxWidth: .infinity).padding(.top, 44)
                }.padding(.horizontal, 12)
            } else {
                VStack(spacing: 0) { about; if moreInfo { more }; remote; rightNow }.padding(.horizontal, 16)
            }
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

struct GlassButton: ButtonStyle {
    var circle = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.custom("Trebuchet MS", size: 15).weight(.bold)).padding(.horizontal, circle ? 0 : 22).padding(.vertical, circle ? 0 : 9)
            .modifier(GlassFill(shape: circle ? AnyShape(Circle()) : AnyShape(Capsule())))
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.7), value: configuration.isPressed)
    }
}

func duration(_ s: Int) -> String {
    let d = s / 86400, h = s / 3600 % 24, m = s / 60 % 60
    return (d > 0 ? "\(d)d " : "") + (h > 0 ? "\(h)h " : "") + "\(m)m"
}

struct RemoteButton: View {
    let icon: String, label: String
    var big = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: big ? 26 : 22)).frame(width: big ? 76 : 64, height: big ? 76 : 64)
        }
        .buttonStyle(GlassButton(circle: true)).accessibilityLabel(label)
    }
}

// The web app's segmented controls, with a pill that lands on your choice.
struct Segments: View {
    @Environment(\.colorScheme) private var scheme
    let title: String, options: [(String, String)]
    let action: (String) -> Void
    @State private var picked = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack(spacing: 0) {
                ForEach(options, id: \.1) { o in
                    Button {
                        withAnimation(.spring(duration: 0.3, bounce: 0.4)) { picked = o.1 }
                        action(o.1)
                    } label: {
                        Text(o.0).font(.custom("Trebuchet MS", size: 13).weight(picked == o.1 ? .bold : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background { if picked == o.1 { RoundedRectangle(cornerRadius: 15, style: .continuous).fill(scheme == .dark ? .white.opacity(0.2) : .white.opacity(0.75)) } }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(3).background(scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

// MARK: - Channels
struct EditorRow: Identifiable, Equatable { let id: String; var name: String; var on: Bool; var secs: Int; var own: Int }
let widgetTimes = [10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600]
func timeText(_ t: Int) -> String { t < 60 ? "\(t) sec" : "\(t / 60) min" }

struct ChannelsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var picked = ""
    @State private var rows: [EditorRow] = []
    @State private var saveTask: Task<Void, Never>?
    @State private var categories: [(String, String)] = []
    @State private var category = ""
    @State private var catalog: [(String, String)] = []
    @State private var page = 1
    @State private var more = false
    @State private var busy = false

    var channels: [ChannelList.Channel] { model.channelData?.channels ?? [] }
    func title(_ c: ChannelList.Channel) -> String { c.list.first.flatMap { $0.count > 1 ? $0[1] : nil } ?? "Channel" }
    var allWidgets: [[String]] {
        var m: [String: [String]] = [:]
        for n in model.channelData?.names ?? [] where n.count > 1 { m[n[0]] = [n[0], n[1], "0"] }
        for c in channels { for l in c.list where l.first != "#" && l.count > 1 { m[l[0]] = l } }
        return m.values.sorted { $0[1].localizedCaseInsensitiveCompare($1[1]) == .orderedAscending }
    }

    func pick() {
        guard let ch = channels.first(where: { $0.id == picked }) else { rows = []; return }
        let all = ch.list.filter { $0.first != "#" }
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
    func changed() {
        saveTask?.cancel()
        let snapshot = rows, id = picked
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            var o: [(String, String)] = [("n", "\(snapshot.count)")]
            for (i, w) in snapshot.enumerated() { o += [("\(i)_id", w.id), ("\(i)_on", w.on ? "1" : "0"), ("\(i)_secs", "\(w.secs)")] }
            do {
                let j = try await model.api?.post("chedit", extra: "&p=" + ChumbyAPI.enc(id), body: ChumbyAPI.form(o))
                model.say(j?["missing"] != nil ? "Saved, but a widget couldn’t be downloaded" : "Channel saved")
            } catch { model.say("Couldn’t: \(error.localizedDescription)") }
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
        guard let t = try? await model.api?.text("a=cat&c=\(category)&p=\(page)") else { model.say("Couldn’t reach the catalog"); return }
        var seen = Set(catalog.map { $0.0 })
        catalog += matches(#"/guide/([0-9A-F-]+)/widget">([^<]+)</a>"#, t).filter { seen.insert($0.0).inserted }
        more = t.contains("category?page=\(page + 1)")
    }

    var body: some View {
        List { Group {
            PageTitle("Channels")
            Section("Now playing") {
                Picker("Channel", selection: Binding(get: { model.state.channel }, set: { n in model.state.channel = n; model.cmd("channel", n, "Switching channel") })) {
                    ForEach(model.state.channelNames, id: \.self) { Text($0).tag($0) }
                    if !model.state.channelNames.contains(model.state.channel) { Text(model.state.channel).tag(model.state.channel) }
                }
                Menu("Jump to a widget") {
                    ForEach(model.state.widgetNames.sorted(), id: \.self) { n in Button(n) { model.cmd("widget", n, "Jumping") } }
                }
                Toggle("Shuffle", isOn: Binding(get: { model.state.shuffle == 1 }, set: { on in model.state.shuffle = on ? 1 : 0; model.cmd("shuffle", on ? "1" : "0", on ? "Shuffle on" : "Shuffle off") }))
            }
            Section {
                Picker("Edit channel", selection: $picked) { ForEach(channels, id: \.id) { Text(title($0)).tag($0.id) } }
                    .onChange(of: picked) { _, _ in pick() }
                ForEach($rows) { $w in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(w.name).lineLimit(1).opacity(w.on ? 1 : 0.45)
                            Spacer()
                            Toggle("On", isOn: $w.on).labelsHidden().onChange(of: w.on) { _, _ in changed() }
                        }
                        Picker("Time on screen", selection: $w.secs) {
                            Text(w.own > 0 ? "Auto (\(w.own)s)" : "Auto").tag(0)
                            ForEach(widgetTimes, id: \.self) { Text(timeText($0)).tag($0) }
                        }.font(.footnote).onChange(of: w.secs) { _, _ in changed() }
                    }
                    .swipeActions(edge: .leading) {
                        Button("To top") { if let i = rows.firstIndex(of: w) { rows.insert(rows.remove(at: i), at: 0); changed() } }.tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Up") { if let i = rows.firstIndex(of: w), i > 0 { rows.swapAt(i, i - 1); changed() } }.tint(.indigo)
                        Button("Down") { if let i = rows.firstIndex(of: w), i < rows.count - 1 { rows.swapAt(i, i + 1); changed() } }.tint(.teal)
                    }
                }
                Menu("Add a widget") {
                    ForEach(allWidgets.filter { w in !rows.contains { $0.id == w[0] } }, id: \.self) { w in
                        Button(w[1]) { rows.insert(EditorRow(id: w[0], name: w[1], on: true, secs: 0, own: w.count > 2 ? Int(w[2]) ?? 0 : 0), at: 0); changed() }
                    }
                }
            } header: { Text("Edit channel") } footer: {
                Text((model.state.shuffle == 1 ? "Shuffle is on, so your order won’t show until you turn it off. " : "") + "Swipe a widget to reorder it. New widgets go to the top, and changes apply within a few seconds.")
            }
            Section("Catalog") {
                Picker("Category", selection: $category) {
                    Text("Choose…").tag("")
                    ForEach(categories, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: category) { _, _ in catalog = []; page = 1; Task { await loadCatalog() } }
                if busy { ProgressView() }
                ForEach(catalog.filter { c in !rows.contains { $0.id == c.0 } }, id: \.0) { c in
                    Button(c.1) { rows.insert(EditorRow(id: c.0, name: c.1, on: true, secs: 0, own: 0), at: 0); changed() }
                }
                if more { Button("Load more") { page += 1; Task { await loadCatalog() } } }
            }
        } .listRowBackground(GlassRow()) }
        .seaList()
        .task { await model.loadChannels(); if picked.isEmpty { picked = (model.channelData?.cur ?? "").trimmingCharacters(in: .whitespacesAndNewlines); if picked.isEmpty { picked = channels.first?.id ?? "" }; pick() }; await loadCategories() }
        .refreshable { await model.loadChannels(); await model.loadState(); pick() }
    }
}

// MARK: - Alarms
struct AlarmsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var editing: EditTarget?
    struct EditTarget: Identifiable { let index: Int; var id: Int { index } }
    static let actions = [("night", "on", "Night mode on"), ("night", "dim", "Night mode dim"), ("night", "dark", "Night mode dark"), ("night", "off", "Night mode off"), ("screen", "bright", "Screen bright"), ("screen", "dim", "Screen dim"), ("screen", "off", "Screen off")]

    var body: some View {
        List { Group {
            PageTitle("Alarms") { Button { editing = EditTarget(index: -1) } label: { Image(systemName: "plus").font(.title2).frame(width: 44, height: 44).glassCircle() }.accessibilityLabel("Add alarm").disabled(model.state.alarms.count >= 16) }
            Section {
                let shown = model.state.alarms.enumerated().filter { !$0.element.isPlaceholder }.sorted { $0.element.localMinutes < $1.element.localMinutes }
                if shown.isEmpty { Text("No alarms yet. Tap + to add one.").foregroundStyle(.secondary) }
                ForEach(shown, id: \.element.id) { i, a in
                    HStack {
                        Button { editing = EditTarget(index: i) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text(a.clock).font(.custom("Trebuchet MS", size: 44)).monospacedDigit()
                                    Text(a.meridiem).font(.custom("Trebuchet MS", size: 20))
                                }
                                Text([a.name, a.whenText, a.soundText].filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .opacity(a.isOn ? 1 : 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Toggle("On", isOn: Binding(get: { a.isOn }, set: { on in
                            model.state.alarms[i].enabled = on ? "1" : "0"
                            Task { await model.saveAlarms(on ? "Alarm on" : "Alarm off") }
                        })).labelsHidden()
                    }
                }
            } header: {
                if let n = model.nextAlarm() { Text("Next: " + n.formatted(.dateTime.weekday(.wide).hour().minute())) } else { Text("No alarm set") }
            } footer: { if model.state.pending { Text("Updating the Chumby…") } }
            Section {
                ForEach($model.state.schedule) { $e in
                    HStack {
                        DatePicker("Time", selection: Binding(get: { Self.date(e.time) }, set: { e.time = Self.hhmm($0); Task { await model.saveSchedule() } }), displayedComponents: .hourAndMinute).labelsHidden()
                        Picker("Action", selection: Binding(get: { e.cmd + ":" + e.val }, set: { v in
                            let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                            e.cmd = parts[0]; e.val = parts.count > 1 ? parts[1] : ""
                            Task { await model.saveSchedule() }
                        })) {
                            ForEach(Self.actions, id: \.2) { Text($0.2).tag($0.0 + ":" + $0.1) }
                            ForEach(model.state.channelNames, id: \.self) { Text("Channel: " + $0).tag("channel:" + $0) }
                        }.labelsHidden()
                    }
                }
                .onDelete { model.state.schedule.remove(atOffsets: $0); Task { await model.saveSchedule() } }
                Button("Add a time") { model.state.schedule.append(ScheduleItem()); Task { await model.saveSchedule() } }
            } header: { Text("Daily schedule") } footer: { Text("Runs every day at these times, even with your phone away.") }
        } .listRowBackground(GlassRow()) }
        .seaList()
        .sheet(item: $editing) { t in AlarmEditor(index: t.index).environmentObject(model) }
        .refreshable { await model.loadState() }
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

struct AlarmEditor: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    let index: Int
    @State private var alarm = Alarm()
    @State private var time = Date()
    @State private var date = Date()
    @State private var repeatMode = "daily"
    @State private var day = 1
    @State private var kind = "beep"
    @State private var tone = "Beep"
    @State private var streamIndex = 0
    @State private var pandoraID = ""
    @State private var after = ""
    @State private var confirmDelete = false

    var stations: [NamedID] {
        var out = model.state.pandora
        for a in model.state.alarms where a.arg == "pandora" && !a.param.isEmpty {
            let p = a.param.components(separatedBy: "##")
            if !out.contains(where: { $0.id == p[0] }) { out.append(NamedID(id: p[0], name: p.count > 1 ? p[1] : a.param_description)) }
        }
        return out
    }
    var afterOptions: [(String, String)] {
        var o = [("", "Return to what was on screen"), ("nightmode|on", "Night mode on"), ("nightmode|off", "Night mode off"), ("bright|bright", "Screen bright"), ("bright|dim", "Screen dim"), ("bright|off", "Screen off")]
        for c in model.state.channels { o.append(("profile|" + c.id, "Switch channel to “\(c.name)”")) }
        let cur = alarm.action.isEmpty ? "" : alarm.action + "|" + alarm.action_param
        if !cur.isEmpty && !o.contains(where: { $0.0 == cur }) { o.append((cur, alarm.action == "profile" ? "Switch channel (set on the Chumby)" : cur)) }
        return o
    }

    var body: some View {
        NavigationStack {
            Form { Group {
                Section { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity) }
                Section("Repeat") {
                    Picker("Repeat", selection: $repeatMode) {
                        Text("Once").tag("once"); Text("Daily").tag("daily"); Text("Weekdays").tag("weekday"); Text("Weekends").tag("weekend"); Text("One day").tag("day")
                    }
                    if repeatMode == "day" {
                        Picker("Day", selection: $day) { ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) } }
                    }
                    if repeatMode == "once" { DatePicker("Date", selection: $date, displayedComponents: .date) }
                    TextField("Label", text: $alarm.name)
                }
                Section("Sound") {
                    Picker("Plays", selection: $kind) {
                        Text("Tone").tag("beep"); Text("Radio").tag("stream"); Text("Pandora").tag("pandora"); Text("Silent").tag("none")
                        if kind == "keep" { Text("Current").tag("keep") }
                    }
                    if kind == "beep" {
                        Picker("Tone", selection: $tone) { ForEach(model.state.tones, id: \.self) { Text($0).tag($0) } }
                        Button("Play on the Chumby") {
                            Task { do { try await model.api?.post("test", extra: "&tone=" + ChumbyAPI.enc(tone)); model.say("Playing on the Chumby") } catch { model.say("Couldn’t play: \(error.localizedDescription)") } }
                        }
                    }
                    if kind == "stream" {
                        if model.state.streams.isEmpty { Text("Add a radio stream on the Sounds tab first.").foregroundStyle(.secondary) }
                        else { Picker("Station", selection: $streamIndex) { ForEach(model.state.streams.indices, id: \.self) { i in Text(model.state.streams[i].name.isEmpty ? model.state.streams[i].url : model.state.streams[i].name).tag(i) } } }
                    }
                    if kind == "pandora" {
                        if stations.isEmpty { Text("No Pandora stations on the Chumby yet.").foregroundStyle(.secondary) }
                        else { Picker("Station", selection: $pandoraID) { ForEach(stations) { Text($0.name).tag($0.id) } } }
                    }
                    if kind == "keep" { LabeledContent("Plays", value: alarm.soundText) }
                    if kind != "none" {
                        Picker("Plays for", selection: $alarm.duration) {
                            ForEach([("1", "1 minute"), ("5", "5 minutes"), ("10", "10 minutes"), ("15", "15 minutes"), ("30", "30 minutes"), ("60", "1 hour"), ("120", "2 hours"), ("-1", "Until stopped")], id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                    Picker("Snooze", selection: $alarm.snooze) {
                        ForEach(["1", "3", "5", "9", "10", "15", "20", "30", "60"], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Toggle("Stop on its own", isOn: Binding(get: { alarm.auto_dismiss == "1" }, set: { alarm.auto_dismiss = $0 ? "1" : "0" }))
                }
                Section("Afterwards") {
                    Picker("Then", selection: $after) { ForEach(afterOptions, id: \.0) { Text($0.1).tag($0.0) } }
                    Toggle("Backup beep", isOn: Binding(get: { alarm.backup == "1" }, set: { alarm.backup = $0 ? "1" : "0" }))
                    if alarm.backup == "1" {
                        Picker("Backup after", selection: $alarm.backupDelay) { ForEach(["1", "2", "5", "10", "15", "30"], id: \.self) { Text("\($0) min").tag($0) } }
                    }
                }
                if index >= 0 { Section { Button("Delete Alarm", role: .destructive) { confirmDelete = true } } }
            } .listRowBackground(GlassRow()) }
            .seaList().background { SeaBackground().ignoresSafeArea() }
            .navigationTitle(index >= 0 ? "Edit Alarm" : "Add Alarm").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stopTest(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .confirmationDialog("Delete this alarm?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Alarm", role: .destructive) {
                    model.state.alarms.remove(at: index); dismiss()
                    Task { await model.saveAlarms("Alarm deleted") }
                }
            }
            .onAppear { load(); model.editingAlarm = true }
            .onDisappear { model.editingAlarm = false }
        }
    }
    func stopTest() { Task { try? await model.api?.post("test", extra: "&stop=1") } }

    func load() {
        if index >= 0, model.state.alarms.indices.contains(index) { alarm = model.state.alarms[index] }
        let m = alarm.localMinutes
        time = Calendar.current.date(bySettingHour: m / 60 % 24, minute: m % 60, second: 0, of: Date()) ?? Date()
        if let d = Alarm.dayKeys.firstIndex(of: alarm.when) { day = d; repeatMode = "day" } else { repeatMode = alarm.when }
        if alarm.when == "once" { date = Date(timeIntervalSince1970: (Double(alarm.time) ?? 0) * 60) }
        kind = alarm.type == "beep" ? "beep" : alarm.type == "none" ? "none" : alarm.arg == "directurl" ? "stream" : alarm.arg == "pandora" ? "pandora" : "keep"
        tone = model.state.tones.contains(alarm.arg) ? alarm.arg : (model.state.tones.first ?? "Beep")
        if kind == "stream", let k = model.state.streams.firstIndex(where: { (!$0.id.isEmpty && alarm.param.contains($0.id)) || alarm.param.contains($0.url.replacingOccurrences(of: "&", with: "&amp;")) }) { streamIndex = k }
        pandoraID = kind == "pandora" ? (alarm.param.components(separatedBy: "##").first ?? "") : (stations.first?.id ?? "")
        after = alarm.action.isEmpty ? "" : alarm.action + "|" + alarm.action_param
    }

    func save() {
        var a = alarm
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let h = c.hour ?? 7, m = c.minute ?? 0
        if repeatMode == "once" {
            guard let when = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: date), when > Date() else { model.say("That time has already passed"); return }
            a.when = "once"; a.time = String(Int((when.timeIntervalSince1970 / 60).rounded()))
        } else {
            a.when = repeatMode == "day" ? Alarm.dayKeys[day] : repeatMode
            a.time = String(h * 60 + m)
        }
        a.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "beep": a.type = "beep"; a.arg = tone; a.param = ""; a.param_description = tone
        case "none": a.type = "none"; a.arg = ""; a.param = ""; a.param_description = "None"
        case "stream":
            guard model.state.streams.indices.contains(streamIndex) else { model.say("Add a radio stream first"); return }
            let s = model.state.streams[streamIndex]
            func esc(_ v: String) -> String { v.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
            a.type = "audio"; a.arg = "directurl"; a.param_description = s.name.isEmpty ? s.url : s.name
            a.param = "<stream url=\"\(esc(s.url))\" id=\"\(esc(s.id))\" mimetype=\"\(esc(s.mimetype))\" name=\"\(esc(s.name.isEmpty ? s.url : s.name))\" />"
        case "pandora":
            guard !pandoraID.isEmpty else { model.say("No Pandora station to pick"); return }
            let name = stations.first { $0.id == pandoraID }?.name ?? "Pandora"
            a.type = "audio"; a.arg = "pandora"; a.param = pandoraID + "##" + name; a.param_description = name
        default: break
        }
        if kind == "none" { a.duration = "0" }
        let parts = after.components(separatedBy: "|")
        a.action = parts.first ?? ""; a.action_param = parts.count > 1 ? parts[1] : ""
        a.enabled = "1"
        if index < 0 {
            guard model.state.alarms.count < 16 else { model.say("The Chumby holds 16 alarms at most"); return }
            model.state.alarms.append(a)
        } else { model.state.alarms[index] = a }
        stopTest(); dismiss()
        Task { await model.saveAlarms(index < 0 ? "Alarm added" : "Alarm saved") }
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

    func set(_ v: Int, _ msg: String?) { volume = Double(v); model.cmd("volume", String(v), msg) }
    var scanNote: String? {
        switch model.state.pandoraScan.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "waiting": return "Listening for 4 minutes. On the Chumby, open Music, then Pandora Radio."
        case "timeout": return "Didn’t see the station list. Tap again, then open Pandora on the Chumby."
        case "error": return "That didn’t work. Try again."
        default: return nil
        }
    }

    var body: some View {
        List { Group {
            PageTitle("Sounds")
            Section("Now") {
                LabeledContent("Volume", value: "\(Int(volume))%")
                Slider(value: $volume, in: 0...100, step: 1) { e in
                    dragging = e
                    if !e { if volume > 0 { lastVolume = Int(volume) }; model.cmd("volume", String(Int(volume))) }
                }.accessibilityLabel("Volume").tint(ChumbyPalette.orange)
                HStack {
                    Button("Mute") { if volume > 0 { lastVolume = Int(volume) }; set(0, "Muted") }
                    Spacer()
                    Button("Unmute") { set(lastVolume > 0 ? lastVolume : 4, "Unmuted") }
                    Spacer()
                    Button("Stop music") { model.cmd("stopmusic", nil, "Music stopped") }
                }.buttonStyle(.bordered)
                Toggle("AirPlay receiver", isOn: Binding(get: { model.sys.airplayOn }, set: { on in model.sys.airplayOn = on; model.cmd("airplay", on ? "1" : "0", on ? "AirPlay on" : "AirPlay off") }))
            }
            Section {
                ForEach(model.state.pandora) { Text($0.name) }
                Button(model.state.pandora.isEmpty ? "Get my stations" : "Update station list") {
                    Task {
                        do { try await model.api?.post("pscan"); model.state.pandoraScan = "waiting"; model.say("Now open Pandora on the Chumby") }
                        catch { model.say("Couldn’t: \(error.localizedDescription)") }
                    }
                }
            } header: { Text("Pandora") } footer: { if let scanNote { Text(scanNote) } }
            Section("Alarm sound") {
                LabeledContent("Alarm volume", value: "\(Int(alarmVolume))%")
                Slider(value: $alarmVolume, in: 0...100, step: 5) { e in
                    if !e { model.state.volume = Int(alarmVolume); Task { await model.saveAlarms("Volume saved") } }
                }.accessibilityLabel("Alarm volume").tint(ChumbyPalette.orange)
                Picker("Fade in", selection: Binding(get: { model.state.fade }, set: { model.state.fade = $0; Task { await model.saveAlarms("Fade saved") } })) {
                    ForEach([(-1, "Chumby default"), (0, "Off"), (5, "5 seconds"), (15, "15 seconds"), (30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes")], id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Section("Radio streams") {
                ForEach(model.state.streams, id: \.key) { s in
                    HStack {
                        Text(s.name.isEmpty ? s.url : s.name).lineLimit(1)
                        Spacer()
                        Button("Remove", role: .destructive) { pendingRemoval = s }.buttonStyle(.borderless)
                    }
                }
                Button("Add a stream…") { addStream = true }
            }
        } .listRowBackground(GlassRow()) }
        .seaList()
        .task(id: model.sys.vol) { if !dragging && model.sys.vol >= 0 { volume = Double(model.sys.vol) } }
        .task(id: model.state.volume) { alarmVolume = Double(model.state.volume) }
        .refreshable { await model.loadSys(); await model.loadState() }
        .alert("Add a stream", isPresented: $addStream) {
            TextField("MP3 stream address", text: $streamURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("Station name", text: $streamName)
            Button("Add") {
                guard streamURL.hasPrefix("http://") || streamURL.hasPrefix("https://") else { model.say("That isn’t a web address"); return }
                model.state.streams.append(Stream(name: streamName.isEmpty ? streamURL : streamName, url: streamURL))
                streamURL = ""; streamName = ""
                Task { await model.saveStreams() }
            }
            Button("Cancel", role: .cancel) { streamURL = ""; streamName = "" }
        }
        .confirmationDialog("Remove \(pendingRemoval?.name ?? "this stream")?", isPresented: .init(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let p = pendingRemoval { model.state.streams.removeAll { $0.key == p.key }; Task { await model.saveStreams() } }
            }
        }
    }
}

// MARK: - Tinker
struct TinkerTab: View {
    @EnvironmentObject var model: ChumbyModel
    @State private var accounts = ""
    @State private var edited = false
    @State private var confirm: String?

    func romName(_ f: String) -> String { f.replacingOccurrences(of: ".nes.gz", with: "").replacingOccurrences(of: ".nes", with: "").replacingOccurrences(of: "_", with: " ") }

    var body: some View {
        List { Group {
            PageTitle("Enjoy tinkering?")
            Section {
                TextField("NASA, BBCBreaking", text: $accounts).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: accounts) { _, n in edited = n != model.sys.tw.joined(separator: ", ") }
                Button("Save") {
                    Task {
                        do { try await model.api?.post("twset", body: ChumbyAPI.form([("v", accounts)])); model.say("Saved. Applies from its next turn"); edited = false; await model.loadSys() }
                        catch { model.say("Couldn’t: \(error.localizedDescription)") }
                    }
                }.disabled(!edited)
            } header: { Text("X (Twitter) accounts") }
            Section("NES") {
                ForEach(model.sys.roms, id: \.self) { f in
                    HStack { Text(romName(f)); Spacer(); Button("Play") { model.cmd("nes", f, "Starting on the Chumby") }.buttonStyle(.borderless) }
                }
                Button("Stop game", role: .destructive) { model.cmd("nesstop", nil, "Back to the channel") }
            }
            Section("Time on screen: your widgets") {
                ForEach(model.state.mine) { w in
                    Picker(w.name, selection: Binding(get: { w.secs }, set: { s in
                        Task {
                            do { try await model.api?.post("wtime", extra: "&w=" + ChumbyAPI.enc(w.name) + "&s=\(s)"); model.say(w.name + ": saved"); await model.loadState() }
                            catch { model.say("Couldn’t: \(error.localizedDescription)") }
                        }
                    })) {
                        ForEach(widgetTimes.contains(w.secs) ? widgetTimes : (widgetTimes + [w.secs]).sorted(), id: \.self) { Text(timeText($0)).tag($0) }
                    }
                }
            }
            Section("The Chumby itself") {
                Button("Restart channel") { confirm = "restart" }
                Button("Reboot", role: .destructive) { confirm = "reboot" }
            }
            Text("Black Chumby photo: Edward Yanquen, Wikimedia Commons, CC BY 2.0, cut out and retouched. Octopus and wordmark: Chumby’s own artwork, from this device.").font(.caption2).foregroundStyle(.secondary).listRowBackground(Color.clear)
        } .listRowBackground(GlassRow()) }
        .seaList()
        .task(id: model.sys.tw) { if !edited { accounts = model.sys.tw.joined(separator: ", ") } }
        .refreshable { await model.loadSys(); await model.loadState() }
        .confirmationDialog(confirm == "reboot" ? "Reboot the Chumby? It takes a few minutes to come back." : "Restart the channel? The screen goes away for about two minutes.", isPresented: .init(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm == "reboot" ? "Reboot" : "Restart", role: .destructive) {
                let c = confirm ?? ""
                model.cmd(c, nil, c == "reboot" ? "Rebooting" : "Restarting")
            }
        }
    }
}
