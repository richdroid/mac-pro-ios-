import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// What the phone sends for a Mac's keys. These are what this Mac's Screen Sharing answers to.
enum MacKey {
    static let command: UInt32 = 0xffeb, option: UInt32 = 0xffe9, control: UInt32 = 0xffe3, shift: UInt32 = 0xffe1
    static let esc: UInt32 = 0xff1b, tab: UInt32 = 0xff09, returnKey: UInt32 = 0xff0d, delete: UInt32 = 0xff08
    static let left: UInt32 = 0xff51, up: UInt32 = 0xff52, right: UInt32 = 0xff53, down: UInt32 = 0xff54
}

// The Mac's screen, shaped by how the Duo is held.
//  - Open and turned so the fold runs across: a laptop. Screen above the fold, trackpad and keys below.
//  - Open flat: the whole screen, touched directly, with a dock floating over it.
//  - Closed: the screen across the top and the trackpad under your thumb.
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
    @State private var typing = false
    @State private var modifiers = Set<UInt32>()
    @State private var showCursor = false
    @State private var cursorHide: Task<Void, Never>?
    @State private var scrollX: CGFloat = 0
    @State private var scrollY: CGFloat = 0
    @State private var dragging = false
    @State private var lastTap = Date.distantPast
    @State private var lastMove = Date.distantPast
    @State private var dockOpen = true

    var body: some View {
        GeometryReader { g in
            let laptop = g.size.width >= 600 && g.size.height > g.size.width
            let wide = g.size.width > g.size.height
            Group {
                if laptop {
                    // The fold is the middle of the display, so each half keeps clear of it.
                    VStack(spacing: 18) {
                        canvas.frame(height: (g.size.height - 18) / 2)
                        deck
                    }
                } else if wide {
                    ZStack(alignment: .bottom) {
                        canvas
                        dock.padding(.bottom, 10)
                    }
                } else {
                    VStack(spacing: 10) {
                        canvas.frame(height: fittedHeight(g.size.width))
                        deck
                    }
                }
            }
            .overlay(alignment: .topLeading) { closeButton(wide: wide) }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if UserDefaults.standard.string(forKey: "pose") == "screen" { screen.showSample() } else { screen.open(base: model.api.base) }
            keepAwake(true)
        }
        .onDisappear {
            screen.close()
            keepAwake(false)
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

    func fittedHeight(_ width: CGFloat) -> CGFloat {
        guard screen.size.width > 0 else { return width * 0.65 }
        return width * screen.size.height / screen.size.width
    }

    func closeButton(wide: Bool) -> some View {
        Button { model.screenOpen = false } label: {
            Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 34, height: 34).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.white).glassEffect(.regular.interactive(), in: Circle())
        .padding(8).accessibilityLabel("Done")
    }

    // MARK: The picture
    // Scale that fits the Mac in the space, before any zoom.
    var fit: CGFloat {
        guard screen.size.width > 0, canvasSize.width > 0 else { return 1 }
        return min(canvasSize.width / screen.size.width, canvasSize.height / screen.size.height)
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
    var canvas: some View {
        // The space sets the size and the picture fits inside it, never the other way round.
        Color.black
            .overlay {
                if let image = screen.image, canvasSize.width > 0 {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(zoom > 2 ? .medium : .high)
                        .frame(width: screen.size.width * fit, height: screen.size.height * fit)
                        .scaleEffect(zoom)
                        .offset(pan)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if showCursor, screen.image != nil {
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                        .background(Circle().fill(Color.accentColor.opacity(0.3)))
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
                    onLongPress: { p in
                        bump()
                        screen.click(x: Int(macPoint(p).x), y: Int(macPoint(p).y), right: true)
                        tick(.medium)
                    },
                    onDrag: { phase, location, delta in directDrag(phase, location, delta) },
                    onScroll: { d in scrollBy(d) },
                    onPinch: { phase, scale, center in pinch(phase, scale, center) }
                )
            }
            .overlay { status }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0; pan = clampedPan(pan) }
    }
    // A finger on the picture: moves the view when zoomed in, and otherwise holds the mouse down and drags.
    func directDrag(_ phase: TouchPhase, _ location: CGPoint, _ delta: CGSize) {
        if zoom > 1 {
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
            let next = max(1, min(8, zoomBase * scale))
            // The spot between the fingers stays where it is.
            let cx = center.x - canvasSize.width / 2, cy = center.y - canvasSize.height / 2
            let k = next / zoomBase
            zoom = next
            pan = clampedPan(CGSize(width: cx - (cx - panBase.width) * k, height: cy - (cy - panBase.height) * k))
        case .ended:
            if zoom < 1.05 { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { zoom = 1; pan = .zero } }
        }
    }
    func scrollBy(_ d: CGSize) {
        bump()
        scrollY += d.height; scrollX += d.width
        while abs(scrollY) >= 9 { screen.scroll(up: scrollY > 0); scrollY -= scrollY > 0 ? 9 : -9 }
        while abs(scrollX) >= 16 { screen.scroll(left: scrollX > 0); scrollX -= scrollX > 0 ? 16 : -16 }
    }
    // Shows the pointer for a moment, and brings it back into view if zoomed in.
    func bump() {
        if !showCursor { withAnimation(.easeOut(duration: 0.12)) { showCursor = true } }
        cursorHide?.cancel()
        cursorHide = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.4)) { showCursor = false } }
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
        UIImpactFeedbackGenerator(style: style == .light ? .light : .medium).impactOccurred()
        #endif
    }
    enum Haptic { case light, medium }

    // MARK: Trackpad and keys
    var deck: some View {
        VStack(spacing: 8) {
            keyStrip
            modifierRow
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
                onLongPress: { _ in },
                onDrag: { phase, _, delta in trackpadDrag(phase, delta) },
                onScroll: { d in scrollBy(d) },
                onPinch: { phase, scale, center in
                    // Pinching the trackpad zooms around the pointer.
                    pinch(phase, scale, viewPoint(screen.cursor))
                }
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
    func keyButton(_ label: String, icon: String? = nil, _ a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 15, weight: .semibold)) }
                else { Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1) }
            }
            .frame(minWidth: 40, minHeight: 36).padding(.horizontal, 3).contentShape(Rectangle())
        }
        .buttonStyle(MacKeyStyle()).accessibilityLabel(a11y)
    }
    var keyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyButton("esc", "Escape") { send(MacKey.esc) }
                keyButton("tab", "Tab") { send(MacKey.tab) }
                keyButton("", icon: "square.grid.3x1.below.line.grid.1x2", "Switch apps") { send(MacKey.tab, [MacKey.command]) }
                keyButton("", icon: "magnifyingglass", "Spotlight") { send(0x20, [MacKey.command]) }
                keyButton("", icon: "rectangle.3.group", "Mission Control") { send(MacKey.up, [MacKey.control]) }
                keyButton("", icon: "arrow.left", "Left arrow") { send(MacKey.left) }
                keyButton("", icon: "arrow.down", "Down arrow") { send(MacKey.down) }
                keyButton("", icon: "arrow.up", "Up arrow") { send(MacKey.up) }
                keyButton("", icon: "arrow.right", "Right arrow") { send(MacKey.right) }
                keyButton("", icon: "delete.left", "Delete") { send(MacKey.delete) }
                keyButton("", icon: "return", "Return") { send(MacKey.returnKey) }
                keyButton("copy", "Copy") { send(0x63, [MacKey.command]) }
                keyButton("paste", "Paste") { send(0x76, [MacKey.command]) }
                keyButton("", icon: "key.fill", "Sign in to the Mac") { signingIn = true }
                keyButton("", icon: "arrow.down.right.and.arrow.up.left", "Fit the screen") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { zoom = 1; pan = .zero }
                }
            }
        }
    }
    func modifierKey(_ label: String, _ sym: UInt32, _ a11y: String) -> some View {
        let on = modifiers.contains(sym)
        return Button {
            tick(.light)
            if on { modifiers.remove(sym) } else { modifiers.insert(sym) }
        } label: {
            Text(label).font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
        }
        .buttonStyle(MacKeyStyle(on: on)).accessibilityLabel(a11y).accessibilityAddTraits(on ? .isSelected : [])
    }
    var modifierRow: some View {
        HStack(spacing: 6) {
            modifierKey("⌃", MacKey.control, "Control")
            modifierKey("⌥", MacKey.option, "Option")
            modifierKey("⌘", MacKey.command, "Command")
            modifierKey("⇧", MacKey.shift, "Shift")
            Button { tick(.light); typing.toggle() } label: {
                Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard").font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(MacKeyStyle(on: typing)).accessibilityLabel(typing ? "Hide keyboard" : "Show keyboard")
            .background { KeyCatcher(active: $typing, onText: typeText, onDelete: { send(MacKey.delete) }).frame(width: 1, height: 1).opacity(0.01) }
        }
    }
    func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            if scalar == "\n" { send(MacKey.returnKey); continue }
            let sym = scalar.value < 256 ? scalar.value : 0x0100_0000 | scalar.value
            if modifiers.isEmpty { screen.key(sym) } else { send(sym) }
        }
    }
    // Open flat the picture has the room, so the trackpad is a touch away instead of always there.
    var dock: some View {
        HStack(spacing: 6) {
            if dockOpen {
                modifierKey("⌘", MacKey.command, "Command").frame(width: 44)
                keyButton("esc", "Escape") { send(MacKey.esc) }
                keyButton("", icon: "square.grid.3x1.below.line.grid.1x2", "Switch apps") { send(MacKey.tab, [MacKey.command]) }
                keyButton("", icon: "magnifyingglass", "Spotlight") { send(0x20, [MacKey.command]) }
                keyButton("", icon: "rectangle.3.group", "Mission Control") { send(MacKey.up, [MacKey.control]) }
                keyButton("", icon: "delete.left", "Delete") { send(MacKey.delete) }
                keyButton("", icon: "return", "Return") { send(MacKey.returnKey) }
                keyButton("", icon: "key.fill", "Sign in to the Mac") { signingIn = true }
                keyButton("", icon: "arrow.down.right.and.arrow.up.left", "Fit the screen") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { zoom = 1; pan = .zero }
                }
                Button { tick(.light); typing.toggle() } label: {
                    Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard").font(.system(size: 15, weight: .semibold))
                        .frame(minWidth: 44, minHeight: 36).contentShape(Rectangle())
                }
                .buttonStyle(MacKeyStyle(on: typing)).accessibilityLabel(typing ? "Hide keyboard" : "Show keyboard")
                .background { KeyCatcher(active: $typing, onText: typeText, onDelete: { send(MacKey.delete) }).frame(width: 1, height: 1).opacity(0.01) }
            }
            Button {
                tick(.light)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dockOpen.toggle() }
            } label: {
                Image(systemName: dockOpen ? "chevron.down" : "chevron.up").font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).accessibilityLabel(dockOpen ? "Hide the keys" : "Show the keys")
        }
        .padding(6)
        .glassEffect(.regular, in: Capsule())
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
        case .needsLogin: Text("Log in to this Mac on the Control tab first.").foregroundStyle(.white).padding()
        case .failed(let m):
            VStack(spacing: 10) {
                Text(m).foregroundStyle(.white)
                Button("Try Again") { screen.connect(base: model.api.base) }.buttonStyle(.borderedProminent)
            }.padding()
        default: EmptyView()
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
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

enum TouchPhase { case began, changed, ended }

#if os(iOS)
// One finger, two fingers and pinch, which SwiftUI's own gestures can't tell apart reliably.
struct TouchSurface: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onTwoFingerTap: (CGPoint) -> Void
    var onLongPress: (CGPoint) -> Void
    var onDrag: (TouchPhase, CGPoint, CGSize) -> Void
    var onScroll: (CGSize) -> Void
    var onPinch: (TouchPhase, CGFloat, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        let c = context.coordinator
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let two = UITapGestureRecognizer(target: c, action: #selector(Coordinator.twoTap(_:)))
        two.numberOfTouchesRequired = 2
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.long(_:)))
        long.minimumPressDuration = 0.55
        let drag = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.drag(_:)))
        drag.minimumNumberOfTouches = 1; drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        scroll.delegate = c; pinch.delegate = c
        for g in [tap, two, long, drag, scroll, pinch] as [UIGestureRecognizer] { v.addGestureRecognizer(g) }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchSurface
        init(_ parent: TouchSurface) { self.parent = parent }
        // Two fingers can pinch and scroll at once, and whichever is really happening wins by distance.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }
        @objc func tap(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onTap(g.location(in: g.view)) } }
        @objc func twoTap(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onTwoFingerTap(g.location(in: g.view)) } }
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
        private var pinchDistance: CGFloat = 0
        @objc func scroll(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            // Fingers spreading apart are a pinch, not a scroll.
            if pinchDistance < 0.08, g.state == .changed { parent.onScroll(CGSize(width: t.x, height: t.y)) }
        }
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            pinchDistance = abs(g.scale - 1)
            let at = g.location(in: g.view)
            switch g.state {
            case .began: parent.onPinch(.began, 1, at)
            case .changed: if pinchDistance >= 0.08 { parent.onPinch(.changed, g.scale, at) }
            case .ended, .cancelled, .failed: pinchDistance = 0; parent.onPinch(.ended, g.scale, at)
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
struct TouchSurface: View {
    var onTap: (CGPoint) -> Void
    var onTwoFingerTap: (CGPoint) -> Void
    var onLongPress: (CGPoint) -> Void
    var onDrag: (TouchPhase, CGPoint, CGSize) -> Void
    var onScroll: (CGSize) -> Void
    var onPinch: (TouchPhase, CGFloat, CGPoint) -> Void
    var body: some View { Color.clear }
}
struct KeyCatcher: View {
    @Binding var active: Bool
    var onText: (String) -> Void
    var onDelete: () -> Void
    var body: some View { Color.clear }
}
#endif
