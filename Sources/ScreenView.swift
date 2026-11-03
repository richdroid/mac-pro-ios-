import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// What the phone sends for a Mac's keys. These are what this Mac's Screen Sharing answers to.
enum MacKey {
    static let command: UInt32 = 0xffeb, option: UInt32 = 0xffe9, control: UInt32 = 0xffe3, shift: UInt32 = 0xffe1
    static let esc: UInt32 = 0xff1b, tab: UInt32 = 0xff09, returnKey: UInt32 = 0xff0d, delete: UInt32 = 0xff08
    static let left: UInt32 = 0xff51, up: UInt32 = 0xff52, right: UInt32 = 0xff53, down: UInt32 = 0xff54
    static let f4: UInt32 = 0xffc1, f11: UInt32 = 0xffc8
}

// A Mac trackpad's own gestures, as the phone's surfaces recognise them.
enum MacSwipe { case up, down, left, right, back, forward, launchpad, desktop }

// The Mac's screen, shaped by how the Duo is held.
//  - Closed: the Mac's screen fills the top half, the trackpad and keys the bottom half.
//  - Partly folded like a laptop (the crease across): the screen above the fold, the controls below it.
//  - Partly folded like a book (the crease down the middle): the screen on the left page, the controls on the right.
//  - Open and upright: the screen across the full width at the top, the controls under it, clear of the fold.
//  - Open flat: the whole screen, touched directly, with a dock under it, or over it when there's no room.
// Done and the screen's own controls sit together on the right, as Back does on every other page: at the trailing end of
// the glass bar above the keys, or of the dock when it's open flat.
struct RemoteScreenView: View {
    let model: AppModel
    init(model: AppModel) { self.model = model; observed = model.screen }
    private var screen: RemoteScreen { model.screen }
    @ObservedObject private var observed: RemoteScreen
    @Environment(\.scenePhase) private var scene
    @State private var signingIn = false
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panBase = CGSize.zero
    @State private var canvasSize = CGSize.zero
    // The picture starts filling its space where that only trims the sides; once he zooms himself, it's his.
    @State private var fillWanted = false
    @State private var userZoomed = false
    @State private var typing = false
    @State private var modifiers = Set<UInt32>()
    @State private var showCursor = false
    @State private var cursorHide: Task<Void, Never>?
    @State private var scrollX: CGFloat = 0
    @State private var scrollY: CGFloat = 0
    @State private var dragging = false
    @State private var lastTap = Date.distantPast
    @State private var dockOpen = true
    @State private var loginPassword = ""
    @State private var loggingIn = false
    @State private var loginFail: String?
    @State private var copyState = ClipState.idle
    @State private var pasteState = ClipState.idle
    @State private var clipClear: [Bool: Task<Void, Never>] = [:]
    @AppStorage("screenGesturesSeen") private var gesturesSeen = false
    @State private var rate = (frames: 0, updates: 0)

    enum ClipState: Equatable { case idle, working, done, failed(String) }
    // A line of a Mac's scroll view, in its pixels: what one wheel step moves.
    static let lineHeight: CGFloat = 10

    var body: some View {
        // The whole display: the cover has no side bar of its own, so the picture gets that room too.
        GeometryReader { full in
            layout(full.size, fold: fold(full))
        }
        .ignoresSafeArea(.container)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            switch model.pose {
            case "screen", "transitions", "screenhint": screen.showSample()
            case "screenclip":
                screen.showSample()
                copyState = .done; pasteState = .failed("Nothing to paste on this iPhone")
            case "screenlogin": screen.showNeedsLogin()
            default: screen.open(base: model.api.base)
            }
            keepAwake(true)
        }
        .onDisappear {
            screen.close()
            keepAwake(false)
            loginPassword = ""
        }
        .onChange(of: scene) { _, p in
            if p == .background { screen.enteredBackground() }
            if p == .active { screen.enteredForeground() }
        }
        .sheet(isPresented: $signingIn) {
            LoginSheet { u, p in
                screen.fillLogin(username: u, password: p)
                return nil
            }
        }
    }

    // Where the hinge runs, in this view's own space, and whether the Duo is partly folded there (the region is active)
    // or open flat. The system gives the posture, not an angle, so the layout answers to the posture.
    struct Fold { var crease: CGRect?; var folded = false }
    func fold(_ g: GeometryProxy) -> Fold {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            return Fold(crease: g.reservedRegions(kind: .division, options: .includeInactive).first?.frame,
                        folded: !g.reservedRegions(kind: .division).isEmpty)
        }
        #endif
        return Fold()
    }

    @ViewBuilder func layout(_ area: CGSize, fold: Fold) -> some View {
        let wide = area.width > area.height
        // Clear of the crease on both sides, so nothing sits on the fold.
        let air: CGFloat = 6
        if fold.folded, let c = fold.crease, c.width >= c.height {
            // A laptop: the Mac's screen above the fold, the keys and trackpad below it.
            VStack(spacing: 0) {
                canvas(fill: false).frame(height: max(0, c.minY - air))
                Color.clear.frame(height: c.height + air * 2)
                deck.frame(maxHeight: .infinity)
            }
        } else if fold.folded, let c = fold.crease {
            // A book: the Mac's screen on the left page, the controls on the right, where the Duo's controls live.
            HStack(spacing: 0) {
                canvas(fill: false).frame(width: max(0, c.minX - air))
                Color.clear.frame(width: c.width + air * 2)
                deck.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if wide {
            let picture = min(fittedHeight(area.width), area.height)
            if area.height - picture >= 64 {
                // Room under the picture: the dock sits in the black there, clear of the Mac's own Dock.
                VStack(spacing: 8) {
                    canvas(fill: false).frame(height: picture)
                    dock(area.width, crease: fold.crease)
                }
                .frame(maxHeight: .infinity)
            } else {
                ZStack(alignment: .bottom) {
                    canvas(fill: false)
                    dock(area.width, crease: fold.crease)
                }
            }
        } else if area.width >= 600 {
            // Open and upright: the picture as wide as the display, the controls under it. Where the fold crosses just
            // under the picture, the controls start below the fold rather than on it.
            let picture = fittedHeight(area.width)
            let below = fold.crease.map { c in c.width >= c.height && c.minY < picture + 64 && c.maxY > picture ? c.maxY + air - picture : 0 } ?? 0
            VStack(spacing: 0) {
                canvas(fill: false).frame(height: picture)
                Color.clear.frame(height: max(10, below))
                deck
            }
        } else {
            // Closed: the Mac's screen fills the top half, the controls the bottom half.
            VStack(spacing: 8) {
                canvas(fill: true).frame(height: (area.height / 2).rounded())
                deck
            }
        }
    }

    func fittedHeight(_ width: CGFloat) -> CGFloat {
        guard screen.size.width > 0 else { return width * 0.65 }
        return width * screen.size.height / screen.size.width
    }

    // MARK: The rail
    func railButton(_ icon: String, _ a11y: String, on: Bool = false, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button { tick(.light); action() } label: {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(on ? 0.24 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(tint).accessibilityLabel(a11y).accessibilityAddTraits(on ? .isSelected : [])
    }
    @ViewBuilder var railItems: some View {
        railButton(typing ? "keyboard.chevron.compact.down" : "keyboard", typing ? "Hide keyboard" : "Show keyboard", on: typing) { typing.toggle() }
            .background { KeyCatcher(active: $typing, onText: typeText, onDelete: { send(MacKey.delete) }).frame(width: 1, height: 1).opacity(0.01) }
        railButton("arrow.down.right.and.arrow.up.left", "Fit the screen") {
            userZoomed = true
            withAnimation(Motion.quick) { zoom = 1; pan = .zero }
        }
        railButton("key.fill", "Sign in to the Mac") { signingIn = true }
        clipButton(paste: false)
        clipButton(paste: true)
    }
    // The screen's controls in one glass bar, Done last, at its right-hand end.
    var controlBar: some View {
        HStack(spacing: 4) {
            railItems
            Capsule().fill(.white.opacity(0.18)).frame(width: 1, height: 24).padding(.horizontal, 2)
            railButton("xmark", "Done", on: true) { model.screenOpen = false }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
    }

    // MARK: Clipboard
    // Copy and Paste carry text between the two clipboards. Done is a tick on the button itself, for a moment; a failure
    // says why, right at the button.
    func clipButton(paste: Bool) -> some View {
        let state = paste ? pasteState : copyState
        let icon: String
        switch state {
        case .done: icon = "checkmark"
        case .failed: icon = "exclamationmark"
        default: icon = paste ? "doc.on.clipboard" : "doc.on.doc"
        }
        return railButton(icon, paste ? "Paste the iPhone’s clipboard on the Mac" : "Copy from the Mac to the iPhone",
                          tint: state == .done ? macBlue : .white) {
            if paste { pasteFromPhone() } else { copyToPhone() }
        }
        .opacity(state == .working ? 0.45 : 1)
        .contentTransition(.symbolEffect(.replace))
        .animation(Motion.quick, value: state)
        // Above the button, its right edge on the button's, so it grows leftwards and never runs off the display.
        .overlay(alignment: .topTrailing) {
            if case .failed(let message) = state {
                Text(message).font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.red.opacity(0.9), in: Capsule())
                    .fixedSize()
                    .offset(y: -40)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }
    func setClip(_ paste: Bool, _ state: ClipState) {
        if paste { pasteState = state } else { copyState = state }
        clipClear[paste]?.cancel()
        guard state != .working, state != .idle, model.pose != "screenclip" else { return }
        let wait: UInt64 = state == .done ? 1_400_000_000 : 3_500_000_000
        clipClear[paste] = Task {
            try? await Task.sleep(nanoseconds: wait)
            if !Task.isCancelled { if paste { pasteState = .idle } else { copyState = .idle } }
        }
    }
    // ⌘C on the Mac, then what it copied onto this iPhone.
    func copyToPhone() {
        guard copyState != .working else { return }
        setClip(false, .working)
        let api = model.api
        Task {
            let before: String
            do { before = try await api.clipboard() } catch { setClip(false, .failed("Couldn’t reach the Mac")); return }
            screen.key(0x63, with: [MacKey.command])
            // The Mac takes a moment to copy; the first change is the copy, or, if nothing changes, the same text again.
            var text = before
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let t = try? await api.clipboard(), t != before { text = t; break }
            }
            guard !text.isEmpty else { setClip(false, .failed("Nothing was copied on the Mac")); return }
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            #endif
            tick(.light)
            setClip(false, .done)
        }
    }
    // This iPhone's clipboard onto the Mac's, then ⌘V.
    func pasteFromPhone() {
        guard pasteState != .working else { return }
        #if canImport(UIKit)
        guard UIPasteboard.general.hasStrings else { setClip(true, .failed("Nothing to paste on this iPhone")); return }
        guard let text = UIPasteboard.general.string, !text.isEmpty else { setClip(true, .failed("Paste wasn’t allowed")); return }
        #else
        let text = ""
        #endif
        setClip(true, .working)
        let api = model.api
        Task {
            do {
                try await api.setClipboard(text)
                screen.key(0x76, with: [MacKey.command])
                tick(.light)
                setClip(true, .done)
            } catch { setClip(true, .failed("Couldn’t reach the Mac")) }
        }
    }

    // MARK: The picture
    // Scale that fits the Mac in the space, before any zoom.
    var fit: CGFloat {
        guard screen.size.width > 0, canvasSize.width > 0 else { return 1 }
        return min(canvasSize.width / screen.size.width, canvasSize.height / screen.size.height)
    }
    // The zoom at which the picture fills the space. Only ever trims the sides, so the menu bar and the Dock stay in view.
    var fillZoom: CGFloat {
        guard screen.size.width > 0, canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        let sx = canvasSize.width / screen.size.width, sy = canvasSize.height / screen.size.height
        return sy > sx ? min(sy / sx, 2) : 1
    }
    var baseZoom: CGFloat { fillWanted ? fillZoom : 1 }
    func settleZoom(fill: Bool) {
        fillWanted = fill
        if !userZoomed { zoom = baseZoom; pan = .zero }
        pan = clampedPan(pan)
    }
    func macPoint(_ p: CGPoint) -> CGPoint {
        let s = fit * zoom
        guard s > 0 else { return .zero }
        return CGPoint(x: (p.x - canvasSize.width / 2 - pan.width) / s + screen.size.width / 2,
                       y: (p.y - canvasSize.height / 2 - pan.height) / s + screen.size.height / 2)
    }
    func viewPoint(_ m: CGPoint) -> CGPoint {
        let s = fit * zoom
        return CGPoint(x: (m.x - screen.size.width / 2) * s + canvasSize.width / 2 + pan.width,
                       y: (m.y - screen.size.height / 2) * s + canvasSize.height / 2 + pan.height)
    }
    func clampedPan(_ p: CGSize) -> CGSize {
        let overW = max(0, screen.size.width * fit * zoom - canvasSize.width) / 2
        let overH = max(0, screen.size.height * fit * zoom - canvasSize.height) / 2
        return CGSize(width: max(-overW, min(overW, p.width)), height: max(-overH, min(overH, p.height)))
    }
    // Measured only for the build's shot: how many pictures reach the display, and how many the Mac sent, each second.
    var measuring: Bool { model.pose == "screenfps" || UserDefaults.standard.bool(forKey: "showFPS") }
    var showHint: Bool { model.pose == "screenhint" || (model.pose.isEmpty && !gesturesSeen) }

    func canvas(fill: Bool) -> some View {
        // The space sets the size and the picture fits inside it, never the other way round.
        Color.black
            .overlay {
                // Drawn from the space it's actually given, not from a remembered size, so a new layout (unfolding, the
                // dock moving) never leaves it blank. The layer takes each new picture on the next display refresh.
                GeometryReader { geo in
                    if screen.hasPicture, screen.size.width > 0, geo.size.width > 0 {
                        let f = min(geo.size.width / screen.size.width, geo.size.height / screen.size.height)
                        ScreenLayer(screen: screen, onRate: measuring ? { frames, updates in rate = (frames, updates) } : nil)
                            .frame(width: screen.size.width * f, height: screen.size.height * f)
                            .scaleEffect(zoom)
                            .offset(pan)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            .allowsHitTesting(false)
                    }
                }
            }
            .overlay {
                if showCursor, screen.hasPicture {
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                        .background(Circle().fill(macBlue.opacity(0.3)))
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .position(viewPoint(screen.cursor))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                TouchSurface(
                    onTap: { p in
                        bump()
                        screen.click(x: Int(macPoint(p).x), y: Int(macPoint(p).y))
                        tick(.light)
                    },
                    onTwoFingerTap: { p in
                        bump()
                        screen.click(x: Int(macPoint(p).x), y: Int(macPoint(p).y), right: true)
                        tick(.medium)
                    },
                    onSmartZoom: { p in smartZoom(around: p) },
                    onLongPress: { p in
                        bump()
                        screen.click(x: Int(macPoint(p).x), y: Int(macPoint(p).y), right: true)
                        tick(.medium)
                    },
                    onDrag: { phase, location, delta in directDrag(phase, location, delta) },
                    onScroll: { d, speed in scrollBy(d, speed: speed, onPicture: true) },
                    onPinch: { phase, scale, center in pinch(phase, scale, center) },
                    onSwipe: { swipe($0) }
                )
            }
            .overlay { status }
            .overlay(alignment: .topLeading) { if measuring { rateBadge } }
            .overlay { if showHint, screen.hasPicture { gestureHint } }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0; settleZoom(fill: fill) }
            .onChange(of: screen.size) { _, _ in settleZoom(fill: fill) }
            .onChange(of: fill) { _, f in settleZoom(fill: f) }
    }
    var rateBadge: some View {
        Text("\(rate.frames) fps shown · \(rate.updates) sent by the Mac · \(RemoteScreen.pipeline) in flight")
            .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
    }
    // A finger on the picture: moves the view when zoomed in, and otherwise holds the mouse down and drags.
    func directDrag(_ phase: TouchPhase, _ location: CGPoint, _ delta: CGSize) {
        if zoom > 1.001 {
            if phase == .changed { pan = clampedPan(CGSize(width: pan.width + delta.width, height: pan.height + delta.height)) }
            return
        }
        switch phase {
        case .began:
            bump(); screen.move(to: macPoint(location)); screen.hold(true); tick(.light)
        case .changed:
            bump(); screen.move(to: macPoint(location))
        case .ended:
            screen.hold(false)
        }
    }
    func pinch(_ phase: TouchPhase, _ scale: CGFloat, _ center: CGPoint) {
        switch phase {
        case .began: zoomBase = zoom; panBase = pan
        case .changed:
            userZoomed = true
            let next = max(1, min(8, zoomBase * scale))
            // The spot between the fingers stays where it is.
            let cx = center.x - canvasSize.width / 2, cy = center.y - canvasSize.height / 2
            let k = next / zoomBase
            zoom = next
            pan = clampedPan(CGSize(width: cx - (cx - panBase.width) * k, height: cy - (cy - panBase.height) * k))
        case .ended:
            if zoom < 1.05 { withAnimation(Motion.quick) { zoom = 1; pan = .zero } }
        }
    }
    // Two fingers tapped twice: in on that spot, or back out to where it started, as smart zoom does on a Mac.
    func smartZoom(around p: CGPoint) {
        tick(.light)
        withAnimation(Motion.quick) {
            if zoom > baseZoom * 1.05 {
                userZoomed = false
                zoom = baseZoom; pan = clampedPan(.zero)
            } else {
                userZoomed = true
                let next = min(8, baseZoom * 2.2)
                let cx = p.x - canvasSize.width / 2, cy = p.y - canvasSize.height / 2
                let k = next / zoom
                let target = CGSize(width: cx - (cx - pan.width) * k, height: cy - (cy - pan.height) * k)
                zoom = next
                pan = clampedPan(target)
            }
        }
    }
    // Two fingers move the page with them, as on a Mac trackpad with natural scrolling: on the picture exactly as far
    // as the fingers went over it, on the trackpad about as far as on a Mac's own. Faster fingers go further, the way
    // macOS accelerates a real trackpad, and a flick keeps gliding after the fingers lift (TouchSurface's momentum).
    func scrollBy(_ d: CGSize, speed: CGFloat, onPicture: Bool) {
        bump()
        let perPoint: CGFloat = onPicture ? 1 / max(fit * zoom, 0.05) : 2.4
        let gain = perPoint * (1 + min(max(speed - 300, 0) / 600, 3)) * (MacPrefs.naturalScroll ? 1 : -1)
        scrollY += d.height * gain; scrollX += d.width * gain
        let lines = Int(scrollY / Self.lineHeight), columns = Int(scrollX / Self.lineHeight)
        guard lines != 0 || columns != 0 else { return }
        scrollY -= CGFloat(lines) * Self.lineHeight; scrollX -= CGFloat(columns) * Self.lineHeight
        screen.scroll(lines: lines, columns: columns)
    }
    // Three fingers, four, and two in from the edge: the Mac's own gestures, as its keyboard shortcuts.
    func swipe(_ s: MacSwipe) {
        bump(); tick(.medium)
        switch s {
        case .up: screen.key(MacKey.up, with: [MacKey.control])
        case .down: screen.key(MacKey.down, with: [MacKey.control])
        // Fingers to the left bring in the space on the right, as on the Mac.
        case .left: screen.key(MacKey.right, with: [MacKey.control])
        case .right: screen.key(MacKey.left, with: [MacKey.control])
        case .back: screen.key(0x5b, with: [MacKey.command])
        case .forward: screen.key(0x5d, with: [MacKey.command])
        case .desktop: screen.key(MacKey.f11)
        case .launchpad:
            // Launchpad (Apps on Tahoe) has no shortcut a remote key reaches, so the Mac opens it; F4 if it can't.
            let api = model.api
            Task {
                do { try await api.action("show-apps") } catch { screen.key(MacKey.f4) }
            }
        }
    }
    // Shows the pointer for a moment, and brings it back into view if zoomed in.
    func bump() {
        if !showCursor { withAnimation(Motion.fade) { showCursor = true } }
        cursorHide?.cancel()
        cursorHide = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.3)) { showCursor = false } }
        }
        guard zoom > 1 else { return }
        let at = viewPoint(screen.cursor), margin: CGFloat = 40
        var next = pan
        if at.x < margin { next.width += margin - at.x }
        if at.x > canvasSize.width - margin { next.width -= at.x - (canvasSize.width - margin) }
        if at.y < margin { next.height += margin - at.y }
        if at.y > canvasSize.height - margin { next.height -= at.y - (canvasSize.height - margin) }
        pan = clampedPan(next)
    }
    func tick(_ style: Haptic) {
        #if canImport(UIKit)
        if MacPrefs.haptics { UIImpactFeedbackGenerator(style: style == .light ? .light : .medium).impactOccurred() }
        #endif
    }
    enum Haptic { case light, medium }

    // MARK: First use
    // Once, the first time the screen opens: what the fingers do, in the Mac's own words. Gone for good on Got it.
    var gestureHint: some View {
        let rows: [(String, String, String)] = [
            ("hand.draw", "Two fingers", "Scroll"),
            ("hand.tap", "Tap with two fingers", "Right click"),
            ("hand.point.up.left", "Tap, then drag", "Drag"),
            ("rectangle.3.group", "Three fingers up", "Mission Control"),
            ("macwindow", "Three fingers down", "App Exposé"),
            ("rectangle.split.3x1", "Three fingers sideways", "Switch spaces"),
            ("arrow.left.arrow.right", "Two fingers in from an edge", "Back and forward"),
            ("square.grid.3x3", "Thumb and three fingers together", "Launchpad"),
            ("menubar.dock.rectangle", "Thumb and three fingers apart", "Show the desktop"),
            ("plus.magnifyingglass", "Pinch, or double-tap with two", "Zoom"),
        ]
        let columns = canvasSize.width >= 600 ? 2 : 1
        return VStack(alignment: .leading, spacing: 12) {
            Text("Trackpad gestures").font(.headline).foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .leading), count: columns), alignment: .leading, spacing: 8) {
                ForEach(rows.indices, id: \.self) { i in
                    let (icon, gesture, does) = rows[i]
                    HStack(spacing: 10) {
                        Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(macBlue).frame(width: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(does).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                            Text(gesture).font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button {
                withAnimation(Motion.quick) { gesturesSeen = true }
            } label: {
                Text("Got it").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent).tint(macBlue)
        }
        .padding(16)
        .frame(maxWidth: columns == 2 ? 620 : 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .padding(10)
        .transition(.opacity)
    }

    // MARK: Trackpad and keys
    var deck: some View {
        VStack(spacing: 8) {
            HStack { Spacer(minLength: 0); controlBar }
            keyRows
            trackpad
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }
    var trackpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.07))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)) }
            Text("Trackpad").font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.18)).allowsHitTesting(false)
            TouchSurface(
                onTap: { _ in
                    bump(); lastTap = Date()
                    screen.clickHere(); tick(.light)
                },
                onTwoFingerTap: { _ in bump(); screen.clickHere(right: true); tick(.medium) },
                // Smart zoom on the trackpad zooms where the pointer is.
                onSmartZoom: { _ in smartZoom(around: viewPoint(screen.cursor)) },
                onLongPress: { _ in },
                onDrag: { phase, _, delta in trackpadDrag(phase, delta) },
                onScroll: { d, speed in scrollBy(d, speed: speed, onPicture: false) },
                onPinch: { phase, scale, _ in
                    // Pinching the trackpad zooms around the pointer.
                    pinch(phase, scale, viewPoint(screen.cursor))
                },
                onSwipe: { swipe($0) }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(minHeight: 60)
    }
    // A tap then a drag holds the button, as on a Mac trackpad with drag on.
    func trackpadDrag(_ phase: TouchPhase, _ delta: CGSize) {
        switch phase {
        case .began:
            if Date().timeIntervalSince(lastTap) < 0.3 { dragging = true; screen.hold(true); tick(.light) }
        case .changed:
            let speed = hypot(delta.width, delta.height)
            let gain = (1.0 + min(speed / 12, 2.2)) * max(screen.size.width, 1) / 1000
            bump()
            screen.move(to: CGPoint(x: screen.cursor.x + delta.width * gain, y: screen.cursor.y + delta.height * gain))
        case .ended:
            if dragging { dragging = false; screen.hold(false) }
        }
    }
    func send(_ sym: UInt32, _ extra: [UInt32] = []) {
        screen.key(sym, with: extra + modifiers.sorted())
        tick(.light)
        modifiers = []
    }
    func keyButton(_ label: String, icon: String? = nil, _ a11y: String, flexible: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 15, weight: .semibold)) }
                else { Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8) }
            }
            .frame(minWidth: flexible ? 30 : 40, maxWidth: flexible ? .infinity : nil, minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(MacKeyStyle()).accessibilityLabel(a11y)
    }
    var arrows: some View {
        HStack(spacing: 6) {
            keyButton("", icon: "arrow.left", "Left arrow", flexible: true) { send(MacKey.left) }
            keyButton("", icon: "arrow.up", "Up arrow", flexible: true) { send(MacKey.up) }
            keyButton("", icon: "arrow.down", "Down arrow", flexible: true) { send(MacKey.down) }
            keyButton("", icon: "arrow.right", "Right arrow", flexible: true) { send(MacKey.right) }
        }
    }
    var modifierRow: some View {
        HStack(spacing: 6) {
            modifierKey("⌃", MacKey.control, "Control")
            modifierKey("⌥", MacKey.option, "Option")
            modifierKey("⌘", MacKey.command, "Command")
            modifierKey("⇧", MacKey.shift, "Shift")
        }
    }
    // Every key in view at once and every row the same width: nothing scrolls or is cut off. The arrows stay together,
    // ← ↑ ↓ →, beside the modifiers when there's room and under them when there isn't.
    var keyRows: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                keyButton("esc", "Escape", flexible: true) { send(MacKey.esc) }
                keyButton("tab", "Tab", flexible: true) { send(MacKey.tab) }
                keyButton("", icon: "square.grid.3x1.below.line.grid.1x2", "Switch apps", flexible: true) { send(MacKey.tab, [MacKey.command]) }
                keyButton("", icon: "magnifyingglass", "Spotlight", flexible: true) { send(0x20, [MacKey.command]) }
                keyButton("", icon: "rectangle.3.group", "Mission Control", flexible: true) { send(MacKey.up, [MacKey.control]) }
                keyButton("", icon: "delete.left", "Delete", flexible: true) { send(MacKey.delete) }
                keyButton("", icon: "return", "Return", flexible: true) { send(MacKey.returnKey) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { modifierRow; Color.clear.frame(width: 6, height: 1); arrows }
                VStack(spacing: 6) { arrows; modifierRow }
            }
        }
    }
    func modifierKey(_ label: String, _ sym: UInt32, _ a11y: String) -> some View {
        let on = modifiers.contains(sym)
        return Button {
            tick(.light)
            if on { modifiers.remove(sym) } else { modifiers.insert(sym) }
        } label: {
            Text(label).font(.system(size: 16, weight: .semibold)).frame(minWidth: 40, maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(MacKeyStyle(on: on)).accessibilityLabel(a11y).accessibilityAddTraits(on ? .isSelected : [])
    }
    func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            if scalar == "\n" { send(MacKey.returnKey); continue }
            let sym = scalar.value < 256 ? scalar.value : 0x0100_0000 | scalar.value
            if modifiers.isEmpty { screen.key(sym) } else { send(sym) }
        }
    }
    // Open flat the picture has the room, so the trackpad is a touch away instead of always there.
    // Every key and control in one row that fits the open display: 40 pt keys, 4 pt apart. Where the hinge crosses the
    // row it splits in two, one capsule each side of the fold, so no key sits on the crease.
    @ViewBuilder func dock(_ width: CGFloat, crease: CGRect?) -> some View {
        if let crease, crease.minX > 0, crease.maxX < width {
            // Half the fold, never under 20 pt, plus a little air.
            let half = max(20, crease.width / 2) + 6
            HStack(spacing: 0) {
                Group { if dockOpen { capsule { dockKeys } } }
                    .frame(width: max(0, crease.midX - half), alignment: .trailing)
                Color.clear.frame(width: half * 2, height: 1)
                capsule { dockTools }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: width)
        } else {
            capsule { if dockOpen { dockKeys }; dockTools }
        }
    }
    func capsule<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 4) { content() }
            .padding(6)
            .glassEffect(.regular, in: Capsule())
    }
    // Left of the fold: ⌘ through →.
    @ViewBuilder var dockKeys: some View {
        modifierKey("⌘", MacKey.command, "Command").frame(width: 44)
        keyButton("esc", "Escape") { send(MacKey.esc) }
        keyButton("", icon: "square.grid.3x1.below.line.grid.1x2", "Switch apps") { send(MacKey.tab, [MacKey.command]) }
        keyButton("", icon: "magnifyingglass", "Spotlight") { send(0x20, [MacKey.command]) }
        keyButton("", icon: "rectangle.3.group", "Mission Control") { send(MacKey.up, [MacKey.control]) }
        keyButton("", icon: "arrow.left", "Left arrow") { send(MacKey.left) }
        keyButton("", icon: "arrow.up", "Up arrow") { send(MacKey.up) }
        keyButton("", icon: "arrow.down", "Down arrow") { send(MacKey.down) }
        keyButton("", icon: "arrow.right", "Right arrow") { send(MacKey.right) }
    }
    // Right of the fold: ⌫ ⏎, the tools and Done.
    @ViewBuilder var dockTools: some View {
        if dockOpen {
            keyButton("", icon: "delete.left", "Delete") { send(MacKey.delete) }
            keyButton("", icon: "return", "Return") { send(MacKey.returnKey) }
            railItems
        }
        Button {
            tick(.light)
            withAnimation(Motion.quick) { dockOpen.toggle() }
        } label: {
            Image(systemName: dockOpen ? "chevron.down" : "chevron.up").font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).accessibilityLabel(dockOpen ? "Hide the keys" : "Show the keys")
        // Done stays, at the right-hand end, even with the keys tucked away.
        railButton("xmark", "Done", on: true) { model.screenOpen = false }
    }

    // Watching doesn't count as touching, so keep the iPhone's display on while the Mac's screen is open.
    private func keepAwake(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    @ViewBuilder private var status: some View {
        switch screen.phase {
        case .connecting: ProgressView("Connecting…").tint(.white).foregroundStyle(.white)
        case .reconnecting:
            VStack {
                Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath").font(.footnote.weight(.medium)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.65), in: Capsule()).padding(.top, 10)
                Spacer()
            }
            .allowsHitTesting(false)
        case .needsLogin: loginCard
        case .failed(let m):
            VStack(spacing: 10) {
                Text(m).foregroundStyle(.white)
                Button("Try Again") { screen.connect(base: model.api.base) }.buttonStyle(.borderedProminent)
            }.padding()
        default: EmptyView()
        }
    }
}

extension RemoteScreenView {
    // The screen can't be shown until the Mac is logged in, so logging in happens right here, then it connects.
    var loginCard: some View {
        // Compact, so it fits the picture's space on the closed Duo without being cut off.
        VStack(alignment: .leading, spacing: 10) {
            Label("Log in to see the Mac’s screen", systemImage: "lock.fill").font(.headline).foregroundStyle(.white).lineLimit(2)
            SecureField("Mac password", text: $loginPassword)
                .textContentType(.password)
                .submitLabel(.go).onSubmit(logIn)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button(action: logIn) {
                Group { if loggingIn { ProgressView() } else { Text("Log in") } }.frame(maxWidth: .infinity, minHeight: 24)
            }
            // Never a black hole while there's nothing typed yet: the same blue, softened, and the tap does nothing.
            .buttonStyle(.borderedProminent).tint(macBlue)
            .opacity(loginPassword.isEmpty ? 0.5 : 1)
            .allowsHitTesting(!loginPassword.isEmpty && !loggingIn)
            if let loginFail { FailText(loginFail) }
        }
        .padding(16)
        .frame(maxWidth: 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .padding(8)
    }
    func logIn() {
        guard !loginPassword.isEmpty, !loggingIn else { return }
        let p = loginPassword; loginPassword = ""
        loggingIn = true; loginFail = nil
        Task {
            let e = await model.runSealed("mac-login", secret: p)
            loggingIn = false
            if let e { loginFail = e } else { screen.connect(base: model.api.base) }
        }
    }
}

struct MacKeyStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(on ? .black : .white)
            .background(on ? Color.white : Color.white.opacity(configuration.isPressed ? 0.28 : 0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

enum TouchPhase { case began, changed, ended }

#if os(iOS)
// The Mac's picture, as a plain layer: each new picture is set on it at the next display refresh, never through
// SwiftUI, so a scrolling page on the Mac moves as smoothly as the Mac sends it.
struct ScreenLayer: UIViewRepresentable {
    let screen: RemoteScreen
    var onRate: ((Int, Int) -> Void)?
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.screen = screen; v.onRate = onRate
        return v
    }
    func updateUIView(_ v: LayerView, context: Context) { v.screen = screen; v.onRate = onRate }
    static func dismantleUIView(_ v: LayerView, coordinator: ()) { v.stop() }

    final class LayerView: UIView {
        weak var screen: RemoteScreen?
        var onRate: ((Int, Int) -> Void)?
        private var link: CADisplayLink?
        private var shown = ScreenLayerMark()
        private var frames = 0, since: CFTimeInterval = 0, updatesThen = 0
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .black
            layer.contentsGravity = .resize
            layer.minificationFilter = .linear
            layer.magnificationFilter = .linear
        }
        required init?(coder: NSCoder) { return nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { start() } else { stop() }
        }
        func start() {
            guard link == nil else { return }
            let l = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
            since = CACurrentMediaTime()
        }
        func stop() { link?.invalidate(); link = nil }
        func tick() {
            guard let screen else { return }
            if let image = screen.newerPicture(than: &shown) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.contents = image
                CATransaction.commit()
                frames += 1
            }
            guard let onRate else { return }
            let now = CACurrentMediaTime()
            if now - since >= 1 {
                let updates = screen.updates
                onRate(Int((Double(frames) / (now - since)).rounded()), Int((Double(max(0, updates - updatesThen)) / (now - since)).rounded()))
                frames = 0; since = now; updatesThen = updates
            }
        }
    }
    // A display link holds its target, so it holds this rather than the view.
    final class Ticker: NSObject {
        weak var view: LayerView?
        init(_ view: LayerView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) { view?.tick() }
    }
}

// One finger, two, three, four, and pinch, which SwiftUI's own gestures can't tell apart reliably.
struct TouchSurface: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onTwoFingerTap: (CGPoint) -> Void
    var onSmartZoom: (CGPoint) -> Void
    var onLongPress: (CGPoint) -> Void
    var onDrag: (TouchPhase, CGPoint, CGSize) -> Void
    var onScroll: (CGSize, CGFloat) -> Void
    var onPinch: (TouchPhase, CGFloat, CGPoint) -> Void
    var onSwipe: (MacSwipe) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        let c = context.coordinator
        v.onTouchDown = { Coordinator.touched() }
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let two = UITapGestureRecognizer(target: c, action: #selector(Coordinator.twoTap(_:)))
        two.numberOfTouchesRequired = 2
        let twoTwice = UITapGestureRecognizer(target: c, action: #selector(Coordinator.smartZoom(_:)))
        twoTwice.numberOfTouchesRequired = 2; twoTwice.numberOfTapsRequired = 2
        // A Mac waits the same moment to tell a right click from smart zoom.
        two.require(toFail: twoTwice)
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.long(_:)))
        long.minimumPressDuration = 0.55
        let drag = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.drag(_:)))
        drag.minimumNumberOfTouches = 1; drag.maximumNumberOfTouches = 1
        let multi = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.multi(_:)))
        multi.minimumNumberOfTouches = 2; multi.maximumNumberOfTouches = 5
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        multi.delegate = c; pinch.delegate = c
        for g in [tap, two, twoTwice, long, drag, multi, pinch] as [UIGestureRecognizer] { v.addGestureRecognizer(g) }
        return v
    }
    func updateUIView(_ uiView: TouchView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ uiView: TouchView, coordinator: Coordinator) { coordinator.stopGlide() }

    final class TouchView: UIView {
        var onTouchDown: (() -> Void)?
        // A finger coming down stops a glide at once, as it does on a Mac.
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            onTouchDown?()
            super.touchesBegan(touches, with: event)
        }
        // Three fingers here are the Mac's gestures, not the system's undo and copy.
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchSurface
        // Every surface, so a touch on either stops a glide started on the other.
        private static let all = NSHashTable<Coordinator>.weakObjects()
        static func touched() { for c in all.allObjects { c.stopGlide() } }
        init(_ parent: TouchSurface) { self.parent = parent; super.init(); Self.all.add(self) }
        // Two fingers can pinch and scroll at once, and whichever is really happening wins by distance.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }
        @objc func tap(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onTap(g.location(in: g.view)) } }
        @objc func twoTap(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onTwoFingerTap(g.location(in: g.view)) } }
        @objc func smartZoom(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onSmartZoom(g.location(in: g.view)) } }
        @objc func long(_ g: UILongPressGestureRecognizer) { if g.state == .began { parent.onLongPress(g.location(in: g.view)) } }
        @objc func drag(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            let at = g.location(in: g.view), delta = CGSize(width: t.x, height: t.y)
            switch g.state {
            case .began: parent.onDrag(.began, at, .zero); parent.onDrag(.changed, at, delta)
            case .changed: parent.onDrag(.changed, at, delta)
            case .ended, .cancelled, .failed: parent.onDrag(.ended, at, .zero)
            default: break
            }
        }

        // MARK: Two to five fingers
        // What they mean is settled by how many came down and where: two scroll, or go back and forward from an edge;
        // three swipe; four pinch. A finger that lands a moment late still counts, until the hand has really moved.
        private enum Mode: Equatable { case none, scroll, edge(back: Bool), three, four }
        private var mode = Mode.none
        private var fingers = 0
        private var travel = CGPoint.zero
        private var fired = false
        private var startSpread: CGFloat = 0
        private var axis = 0                 // 0 not yet, 1 sideways, 2 up and down, 3 both
        private var pinching = false
        private var pinchAmount: CGFloat = 0
        private static let edge: CGFloat = 36

        private func spread(_ g: UIGestureRecognizer) -> CGFloat {
            let n = g.numberOfTouches
            guard n > 1, let v = g.view else { return 0 }
            var points: [CGPoint] = []
            for i in 0..<n { points.append(g.location(ofTouch: i, in: v)) }
            let cx = points.reduce(0) { $0 + $1.x } / CGFloat(n), cy = points.reduce(0) { $0 + $1.y } / CGFloat(n)
            return points.reduce(0) { $0 + hypot($1.x - cx, $1.y - cy) } / CGFloat(n)
        }
        private func settle(_ g: UIPanGestureRecognizer) {
            fingers = max(fingers, g.numberOfTouches)
            let moved = hypot(travel.x, travel.y)
            switch mode {
            case .none:
                if fingers >= 4 { mode = .four; startSpread = spread(g) }
                else if fingers == 3 { mode = .three }
                else {
                    let at = g.location(in: g.view), width = g.view?.bounds.width ?? 0
                    mode = at.x < Self.edge ? .edge(back: true) : at.x > width - Self.edge ? .edge(back: false) : .scroll
                }
            case .scroll, .edge:
                if fingers >= 3, moved < 36 { mode = fingers >= 4 ? .four : .three; if fingers >= 4 { startSpread = spread(g) } }
            case .three:
                if fingers >= 4, !fired, moved < 36 { mode = .four; startSpread = spread(g) }
            case .four: break
            }
        }
        @objc func multi(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began, .changed:
                if g.state == .began { stopGlide(); mode = .none; fingers = 0; travel = .zero; fired = false; axis = 0 }
                let t = g.translation(in: g.view)
                g.setTranslation(.zero, in: g.view)
                travel.x += t.x; travel.y += t.y
                settle(g)
                step(g, CGSize(width: t.x, height: t.y))
            case .ended, .cancelled, .failed:
                if mode == .scroll, g.state == .ended, !pinching { glide(g.velocity(in: g.view)) }
                mode = .none; fingers = 0
            default: break
            }
        }
        private func locked(_ d: CGSize) -> CGSize {
            axis == 1 ? CGSize(width: d.width, height: 0) : axis == 2 ? CGSize(width: 0, height: d.height) : d
        }
        private func step(_ g: UIPanGestureRecognizer, _ d: CGSize) {
            switch mode {
            case .scroll:
                guard !pinching else { return }
                // Mostly up and down stays up and down, as on a Mac trackpad; a diagonal moves both ways.
                if axis == 0, hypot(travel.x, travel.y) > 10 {
                    axis = abs(travel.x) > abs(travel.y) * 1.7 ? 1 : abs(travel.y) > abs(travel.x) * 1.7 ? 2 : 3
                }
                let v = g.velocity(in: g.view)
                parent.onScroll(locked(d), hypot(v.x, v.y))
            case .edge(let back):
                // Sideways from the edge, inwards, is back or forward; anything else was a scroll that began near it.
                let inward = back ? travel.x : -travel.x
                if abs(travel.y) > 24 && abs(travel.y) > abs(travel.x) || inward < -20 {
                    mode = .scroll
                    step(g, CGSize(width: travel.x, height: travel.y))
                } else if !fired, inward > 64 {
                    fired = true
                    parent.onSwipe(back ? .back : .forward)
                }
            case .three:
                guard !fired, hypot(travel.x, travel.y) > 44 else { return }
                fired = true
                if abs(travel.y) >= abs(travel.x) { parent.onSwipe(travel.y < 0 ? .up : .down) }
                else { parent.onSwipe(travel.x < 0 ? .left : .right) }
            case .four:
                guard !fired, startSpread > 0, g.numberOfTouches >= 4 else { return }
                let s = spread(g) / startSpread
                if s < 0.72 { fired = true; parent.onSwipe(.launchpad) }
                else if s > 1.38 { fired = true; parent.onSwipe(.desktop) }
            case .none: break
            }
        }

        // MARK: Momentum
        // After a flick the page keeps going and slows as a scroll view does, until a finger touches down again.
        private var link: CADisplayLink?
        private var velocity = CGPoint.zero
        private var last: CFTimeInterval = 0
        private func glide(_ v: CGPoint) {
            var v = v
            if axis == 1 { v.y = 0 } else if axis == 2 { v.x = 0 }
            guard hypot(v.x, v.y) > 180 else { return }
            stopGlide()
            velocity = v
            last = CACurrentMediaTime()
            let l = CADisplayLink(target: self, selector: #selector(gliding(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        @objc private func gliding(_ l: CADisplayLink) {
            let now = CACurrentMediaTime()
            let dt = max(0, min(now - last, 0.05)); last = now
            let decay = CGFloat(pow(0.998, dt * 1000))
            velocity.x *= decay; velocity.y *= decay
            let speed = hypot(velocity.x, velocity.y)
            if speed < 30 { stopGlide(); return }
            parent.onScroll(CGSize(width: velocity.x * CGFloat(dt), height: velocity.y * CGFloat(dt)), speed)
        }
        func stopGlide() { link?.invalidate(); link = nil }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            let at = g.location(in: g.view)
            // Three or more fingers are a gesture of their own, never a zoom.
            if g.numberOfTouches > 2 || fingers >= 3 {
                if pinching { pinching = false; parent.onPinch(.ended, g.scale, at) }
                return
            }
            switch g.state {
            case .began: pinchAmount = 0; parent.onPinch(.began, 1, at)
            case .changed:
                // Fingers spreading apart are a pinch, not a scroll.
                pinchAmount = max(pinchAmount, abs(g.scale - 1))
                if pinchAmount >= 0.08 {
                    if !pinching { pinching = true; stopGlide() }
                    parent.onPinch(.changed, g.scale, at)
                }
            case .ended, .cancelled, .failed:
                pinching = false; pinchAmount = 0
                parent.onPinch(.ended, g.scale, at)
            default: break
            }
        }
    }
}

// Types straight into the Mac as each key is pressed, with nothing to compose first.
struct KeyCatcher: UIViewRepresentable {
    @Binding var active: Bool
    var onText: (String) -> Void
    var onDelete: () -> Void
    final class Field: UIView, UIKeyInput {
        var onText: ((String) -> Void)?
        var onDelete: (() -> Void)?
        var hasText: Bool { true }
        override var canBecomeFirstResponder: Bool { true }
        // While typing, three fingers are still the Mac's gestures, not the system's undo.
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
        func insertText(_ text: String) { onText?(text) }
        func deleteBackward() { onDelete?() }
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    }
    func makeUIView(context: Context) -> Field { Field() }
    func updateUIView(_ v: Field, context: Context) {
        v.onText = onText
        v.onDelete = onDelete
        DispatchQueue.main.async {
            if active, !v.isFirstResponder { v.becomeFirstResponder() }
            if !active, v.isFirstResponder { v.resignFirstResponder() }
        }
    }
}
#else
struct ScreenLayer: View {
    let screen: RemoteScreen
    var onRate: ((Int, Int) -> Void)?
    var body: some View { Color.black }
}
struct TouchSurface: View {
    var onTap: (CGPoint) -> Void
    var onTwoFingerTap: (CGPoint) -> Void
    var onSmartZoom: (CGPoint) -> Void
    var onLongPress: (CGPoint) -> Void
    var onDrag: (TouchPhase, CGPoint, CGSize) -> Void
    var onScroll: (CGSize, CGFloat) -> Void
    var onPinch: (TouchPhase, CGFloat, CGPoint) -> Void
    var onSwipe: (MacSwipe) -> Void
    var body: some View { Color.clear }
}
struct KeyCatcher: View {
    @Binding var active: Bool
    var onText: (String) -> Void
    var onDelete: () -> Void
    var body: some View { Color.clear }
}
#endif
