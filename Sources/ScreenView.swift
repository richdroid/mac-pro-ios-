import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// What the phone sends for a Mac's keys. These are what this Mac's Screen Sharing answers to.
enum MacKey {
    static let command: UInt32 = 0xffeb, option: UInt32 = 0xffe9, control: UInt32 = 0xffe3, shift: UInt32 = 0xffe1
    static let esc: UInt32 = 0xff1b, tab: UInt32 = 0xff09, returnKey: UInt32 = 0xff0d, delete: UInt32 = 0xff08
    static let left: UInt32 = 0xff51, up: UInt32 = 0xff52, right: UInt32 = 0xff53, down: UInt32 = 0xff54
    static let space: UInt32 = 0x20, f4: UInt32 = 0xffc1, f11: UInt32 = 0xffc8
    static let modifiers: Set<UInt32> = [command, option, control, shift]
}

// A Mac trackpad's own gestures, as the phone's surfaces recognise them.
enum MacSwipe { case up, down, left, right, back, forward, launchpad, desktop, notifications }

// The Mac's screen as a small MacBook, shaped by how the Duo is held (the system gives the posture, never the angle):
//  - Laptop (partly folded, the crease across) and open flat upright share one plan: the picture on the lid, set on
//    the hinge; below it a function row, a full Mac keyboard and a trackpad, so folding between them moves nothing.
//  - Closed: the picture whole under the camera, then the function row, a row of modifiers and arrows, the trackpad.
//  - Book (the crease down the middle): picture and keys on the left page, the right page all trackpad.
//  - Landscape, closed or open flat: the picture pinned to the top, its dock in the black under it.
// The picture is never cropped and never letterboxed inside its own space: the space is the Mac's shape, and what's
// left goes to the controls. Every part keeps its identity across postures and moves there in one spring.
struct RemoteScreenView: View {
    let model: AppModel
    init(model: AppModel) {
        self.model = model
        observed = model.screen
        _keys = StateObject(wrappedValue: MacKeyboard(screen: model.screen))
    }
    private var screen: RemoteScreen { model.screen }
    @ObservedObject private var observed: RemoteScreen
    @StateObject private var keys: MacKeyboard
    @Environment(\.scenePhase) private var scene
    @State private var signingIn = false
    @State private var zoom: CGFloat = 1
    // The picture fills the space it's given, the sides cropped and the view following the pointer, rather than fitting
    // whole with black bands above and below (Richard, 2026-11-06: "i told u to fill the top screen"). Fit is a tap away.
    @AppStorage("screenFill") private var filling = true
    // Only where there's a trackpad: where the picture itself is touched to click and drag, a filled (zoomed) picture
    // would take a finger as a pan instead, so it fits whole there.
    @State private var padLayout = false
    @State private var zoomBase: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panBase = CGSize.zero
    @State private var canvasSize = CGSize.zero
    @State private var typing = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var dockOpen = true
    @State private var loginPassword = ""
    @State private var loggingIn = false
    @State private var loginFail: String?
    @State private var copyState = ClipState.idle
    @State private var pasteState = ClipState.idle
    @State private var clipClear: [Bool: Task<Void, Never>] = [:]
    // Checked without reading the clipboard, so no paste prompt appears just for opening the screen.
    @State private var phoneHasText = true
    @AppStorage("screenGesturesSeen") private var gesturesSeen = false
    @State private var rate = (frames: 0, updates: 0)
    // Touch bookkeeping that changes on every sample, kept out of SwiftUI's state so a moving finger never rebuilds the view.
    @State private var pad = TrackpadBox()
    // The build's way to shoot a posture the simulator can't fold into.
    @State private var postureOverride = UserDefaults.standard.string(forKey: "screenPosture")

    enum ClipState: Equatable {
        case idle, working, done, failed(String)
        var failed: Bool { if case .failed = self { return true }; return false }
    }
    static let posture = Animation.spring(duration: 0.35, bounce: 0)

    var body: some View {
        // The whole display: the cover has no side bar of its own, so the picture gets that room too. The system
        // keyboard slides over the controls rather than squeezing them.
        GeometryReader { full in
            let (f, force) = effectiveFold(fold(full), full.size)
            let insets = ScreenInsets.current
            let p = Self.plan(area: full.size, fold: f, aspect: aspect, top: insets.top, bottom: insets.bottom,
                              keyboard: typing ? keyboardHeight : 0, force: force)
            stage(p, area: full.size)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            screen.heldModifiers = []
            switch model.pose {
            case "screen", "transitions", "screenhint", "screenfold": screen.showSample()
            case "screentyping": screen.showSample(); typing = true
            case "screenzoomed":
                screen.showSample()
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); zoom = 2.2; pan = clampedPan(.zero) }
            case "screenmodlock": screen.showSample(); keys.demoLatches()
            case "screencursor":
                screen.showSample()
                pad.lastTouch = .greatestFiniteMagnitude
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); screen.moveCoalesced(to: CGPoint(x: screen.size.width * 0.42, y: screen.size.height * 0.38)) }
            case "screentrace": screen.showSample(); ScreenTrace.write()
            case "screenclip":
                screen.showSample()
                copyState = .done; pasteState = .failed("Couldn’t reach the Mac")
            case "screenlogin": screen.showNeedsLogin()
            default: screen.open(base: model.api.base)
            }
            if model.pose == "screenfold" { foldDemo() }
            keepAwake(true)
            checkPhoneClipboard()
            ScreenHaptics.prepare()
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in checkPhoneClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }.first ?? end.maxY
            withAnimation(Self.posture) { keyboardHeight = max(0, screenHeight - end.minY) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(Self.posture) { keyboardHeight = 0 }
        }
        #endif
        .onDisappear {
            keys.releaseAll()
            screen.close()
            keepAwake(false)
            loginPassword = ""
        }
        .onChange(of: scene) { _, p in
            if p == .background { keys.releaseAll(); screen.enteredBackground() }
            if p == .active { screen.enteredForeground(); checkPhoneClipboard() }
        }
        .sheet(isPresented: $signingIn) {
            LoginSheet { u, p in
                screen.fillLogin(username: u, password: p)
                return nil
            }
        }
    }
    var aspect: CGFloat { screen.size.width > 0 ? screen.size.height / screen.size.width : 0.625 }

    // Where the hinge runs, in this view's own space, and whether the Duo is partly folded there (the region is active)
    // or open flat.
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
    // Only for the build's shots and film: a posture made up in whatever display the simulator has.
    func effectiveFold(_ f: Fold, _ area: CGSize) -> (Fold, ScreenPlan.Kind?) {
        switch postureOverride {
        // Only where the display could really fold that way: the outer display has no hinge, so there it's left as it is.
        case "laptop" where area.height >= 600: return (Fold(crease: CGRect(x: 0, y: (area.height * 0.478).rounded(), width: area.width, height: 40), folded: true), nil)
        case "book" where area.width >= 600: return (Fold(crease: CGRect(x: (area.width * 0.478).rounded(), y: 0, width: 40, height: area.height), folded: true), nil)
        case "closedLandscape": return (Fold(), .closedLandscape)
        default: return (f, nil)
        }
    }
    func foldDemo() {
        Task {
            for next in ["laptop", "", "book", ""] {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation(Self.posture) { postureOverride = next.isEmpty ? nil : next }
            }
        }
    }

    // MARK: The plan
    // Every part's place for a display size and posture, worked out in one go, so a change of posture is one change of
    // value that every part springs to together.
    static func plan(area: CGSize, fold: Fold, aspect: CGFloat, top: CGFloat, bottom: CGFloat, keyboard: CGFloat, force: ScreenPlan.Kind? = nil) -> ScreenPlan {
        let w = area.width, h = area.height, air: CGFloat = 6, side: CGFloat = 10
        func fitWidth(_ width: CGFloat, maxHeight: CGFloat) -> CGSize {
            let ph = width * aspect
            return ph <= maxHeight ? CGSize(width: width, height: ph) : CGSize(width: maxHeight / aspect, height: maxHeight)
        }
        let kind: ScreenPlan.Kind
        if let force { kind = force }
        else if fold.folded, let c = fold.crease { kind = c.width >= c.height ? .laptop : .book }
        else if force == nil, fold.crease == nil, w < 600, h > w { kind = .closed }
        else if w > h { kind = w >= 800 ? .flatLandscape : .closedLandscape }
        else if w >= 600 { kind = .laptop }
        else { kind = .closed }
        var p = ScreenPlan(kind: kind)
        switch kind {
        case .laptop:
            // The lid: the picture as wide as the display, set down on the hinge, the camera in the black above it.
            let c = fold.crease.flatMap { $0.width >= $0.height ? $0 : nil } ?? CGRect(x: 0, y: (h * 0.478).rounded(), width: w, height: 40)
            let lid = fitWidth(w, maxHeight: max(c.minY - air - top, 1))
            p.picture = CGRect(x: (w - lid.width) / 2, y: c.minY - air - lid.height, width: lid.width, height: lid.height)
            // The base: function row, the keyboard, and a trackpad centred under it like a MacBook's.
            let y0 = c.maxY + 8, base = h - bottom - 8 - y0
            p.fnRow = CGRect(x: side, y: y0, width: w - side * 2, height: 32)
            let kbHeight = min(190, base - 32 - 8 - 10 - 110)
            if kbHeight >= 130 {
                p.keyboard = CGRect(x: side, y: p.fnRow.maxY + 8, width: w - side * 2, height: kbHeight)
            } else {
                p.modRow = CGRect(x: side, y: p.fnRow.maxY + 6, width: w - side * 2, height: 40)
            }
            let above = max(p.keyboard.maxY, p.modRow.maxY, p.fnRow.maxY) + 10
            // 16:10 and no wider than 72 % of the keys, as in the book posture: spare width is margin, never pad (r21: a 3.5:1
            // slab). Height first, as the base allows; centred in what's left.
            let room = max(h - bottom - 8 - above, 60), capW = ((w - side * 2) * 0.72).rounded()
            let padW = min(capW, (room * 16 / 10).rounded()), padH = min(room, (padW * 10 / 16).rounded())
            p.trackpad = CGRect(x: (w - padW) / 2, y: above + (room - padH) / 2, width: padW, height: padH)
        case .closed:
            let pic = fitWidth(w, maxHeight: h * 0.5)
            p.picture = CGRect(x: (w - pic.width) / 2, y: top, width: pic.width, height: pic.height)
            p.fnRow = CGRect(x: side, y: p.picture.maxY + 8, width: w - side * 2, height: 32)
            p.modRow = CGRect(x: side, y: p.fnRow.maxY + 6, width: w - side * 2, height: 40)
            p.trackpad = CGRect(x: side, y: p.modRow.maxY + 10, width: w - side * 2, height: max(h - bottom - 8 - p.modRow.maxY - 10, 60))
            // Typing: the system keyboard comes up over the trackpad and the modifiers and arrows ride on top of it.
            if keyboard > 0 { p.modRow.origin.y = max(p.fnRow.maxY + 6, h - keyboard - 46) }
        case .book:
            // A MacBook opened across the fold: the left page is the screen alone, as large as the page allows; the right
            // page is the base, the function row, the full keyboard and a 16:10 trackpad centred under it. Both pages keep
            // one outer margin on every side, and neither has a dead band. Without a crease there's no book, only the closed
            // layout.
            guard let c = fold.crease else {
                return plan(area: area, fold: Fold(), aspect: aspect, top: top, bottom: bottom, keyboard: keyboard, force: .closed)
            }
            let head = top + side, foot = h - bottom - side, tall = max(foot - head, 1)
            // The screen: fitted to the left page inside the margin, whichever way it binds, centred.
            let page = c.minX - air
            let pic = fitWidth(max(page - side * 2, 1), maxHeight: tall)
            p.picture = CGRect(x: (page - pic.width) / 2, y: head + (tall - pic.height) / 2, width: pic.width, height: pic.height)
            // The base on the right page, stacked: function row, keyboard, trackpad.
            let left = c.maxX + air + side, width = max(w - side - left, 1)
            let fn: CGFloat = 32, gap: CGFloat = 8, padGap: CGFloat = 12
            // Five rows of keys at 34 pt with their gaps, shrinking to 30 pt rows before giving up the full keyboard.
            let kbFull: CGFloat = 190, kbMin: CGFloat = 170
            var padW = (width * 0.62).rounded(), padH = (padW * 10 / 16).rounded()
            let minPadH: CGFloat = 110
            var kbH = min(kbFull, tall - fn - gap - padGap - padH)
            if kbH < kbMin {
                // Smaller trackpad first, down to its floor, so the keyboard keeps its rows.
                padH = max(minPadH, tall - fn - gap - padGap - kbMin)
                padW = min(width, (padH * 16 / 10).rounded())
                kbH = min(kbFull, tall - fn - gap - padGap - padH)
            }
            var deck: CGFloat
            if kbH >= kbMin {
                // Room left grows the trackpad only up to about 72 % of the keyboard's width, so it reads as a MacBook's and
                // never outweighs the keys; anything more becomes even margin above and below the deck.
                let spare = tall - fn - gap - kbH - padGap - padH
                let capW = (width * 0.72).rounded()
                if spare > 0 { padH = min(padH + spare, (capW * 10 / 16).rounded()); padW = (padH * 16 / 10).rounded() }
                deck = fn + gap + kbH + padGap + padH
                let y0 = head + max(tall - deck, 0) / 2
                p.fnRow = CGRect(x: left, y: y0, width: width, height: fn)
                p.keyboard = CGRect(x: left, y: p.fnRow.maxY + gap, width: width, height: kbH)
                p.trackpad = CGRect(x: left + (width - padW) / 2, y: p.keyboard.maxY + padGap, width: padW, height: padH)
            } else {
                // Too short for the full keyboard: the modifier and arrow row, and the trackpad takes the rest.
                let mod: CGFloat = 40
                padH = min(tall - fn - gap - mod - padGap, (width * 10 / 16).rounded())
                padW = (padH * 16 / 10).rounded()
                deck = fn + gap + mod + padGap + padH
                let y0 = head + max(tall - deck, 0) / 2
                p.fnRow = CGRect(x: left, y: y0, width: width, height: fn)
                p.modRow = CGRect(x: left, y: p.fnRow.maxY + gap, width: width, height: mod)
                p.trackpad = CGRect(x: left + (width - padW) / 2, y: p.modRow.maxY + padGap, width: padW, height: max(padH, 60))
            }
        case .closedLandscape, .flatLandscape:
            // The dock lives in the black under the picture, never over the Mac's own Dock.
            let dock: CGFloat = 52
            let pic = fitWidth(w, maxHeight: kind == .closedLandscape ? h - dock - 4 : h)
            p.picture = CGRect(x: (w - pic.width) / 2, y: 0, width: pic.width, height: pic.height)
            let room = h - pic.height
            p.dock = room >= dock + 4
                ? CGRect(x: 0, y: pic.height + (room - dock) / 2, width: w, height: dock)
                : CGRect(x: 0, y: h - dock - 6 - bottom, width: w, height: dock)
            p.crease = kind == .flatLandscape ? fold.crease : nil
        }
        return p
    }

    @ViewBuilder func stage(_ p: ScreenPlan, area: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            place(canvas(always: p.kind != .flatLandscape && p.kind != .closedLandscape), p.picture)
            place(functionRow, p.fnRow)
            place(MacKeyboardView(keys: keys), p.keyboard)
            place(modifierRow, p.modRow)
            place(trackpad, p.trackpad)
            place(dock(area.width, crease: p.crease), p.dock)
            // The one field the system keyboard types into, wherever its button is.
            KeyCatcher(active: $typing, onText: typeText, onDelete: { keys.tap(MacKey.delete) })
                .frame(width: 1, height: 1).opacity(0.01)
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .animation(Self.posture, value: p)
    }
    func place<V: View>(_ v: V, _ r: CGRect) -> some View {
        v.frame(width: max(r.width, 0), height: max(r.height, 0))
            .opacity(r.isEmpty ? 0 : 1)
            .allowsHitTesting(!r.isEmpty)
            .position(x: r.midX, y: r.midY)
    }

    // MARK: The function row
    // Where a MacBook's function keys are: the Mac's own shortcuts on the left, this screen's tools and Done on the right.
    var functionRow: some View {
        HStack(spacing: 5) {
            fnKey("esc", nil, "Escape") { keys.tap(MacKey.esc) }
            fnKey("", "rectangle.3.group", "Mission Control") { keys.tap(MacKey.up, with: [MacKey.control]) }
            fnKey("", "macwindow", "App Exposé") { keys.tap(MacKey.down, with: [MacKey.control]) }
            fnKey("", "magnifyingglass", "Spotlight") { keys.tap(MacKey.space, with: [MacKey.command]) }
            fnKey("", "square.grid.3x1.below.line.grid.1x2", "Switch apps") { keys.switchApps() }
            Spacer(minLength: 6)
            toolButton(typing ? "keyboard.chevron.compact.down" : "keyboard", typing ? "Hide keyboard" : "Dictate or type", on: typing, compact: true) { typing.toggle() }
            clipButton(paste: false, compact: true)
            clipButton(paste: true, compact: true)
            toolButton("key.fill", "Sign in to the Mac", compact: true) { signingIn = true }
            if zoomed || fillZoom > 1.01 { toolButton(fitIcon, fitLabel, compact: true) { fitScreen() } }
            toolButton("xmark", "Done", on: true, compact: true) { model.screenOpen = false }
        }
    }
    func fnKey(_ label: String, _ icon: String?, _ a11y: String, action: @escaping () -> Void) -> some View {
        Button { tick(.light); action() } label: {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                else { Text(label).font(.system(size: 12, weight: .semibold)) }
            }
            .frame(minWidth: 30, maxWidth: 44, minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(MacKeyStyle()).accessibilityLabel(a11y)
    }
    // A round tool on a dark glass, the size of the row it sits in.
    func toolButton(_ icon: String, _ a11y: String, on: Bool = false, tint: Color = .white, compact: Bool = false, action: @escaping () -> Void) -> some View {
        let side: CGFloat = compact ? 32 : 44
        return Button { tick(.light); action() } label: {
            Image(systemName: icon).font(.system(size: compact ? 14 : 17, weight: .semibold))
                .frame(width: side, height: side)
                .background(Circle().fill(.white.opacity(on ? 0.24 : compact ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(tint).accessibilityLabel(a11y).accessibilityAddTraits(on ? .isSelected : [])
    }
    var zoomed: Bool { zoom > 1.01 }
    // The zoom that fills the space: the Mac's picture covers it edge to edge, cropped along one side.
    var fillZoom: CGFloat {
        guard padLayout, screen.size.width > 0, screen.size.height > 0, canvasSize.width > 0, fit > 0 else { return 1 }
        return max(1, max(canvasSize.width / screen.size.width, canvasSize.height / screen.size.height) / fit)
    }
    // Filled again whenever the space or the Mac's picture changes size, with the pointer kept in view.
    func applyFill() {
        guard filling else { pan = clampedPan(pan); return }
        if abs(zoom - fillZoom) > 0.001 { zoom = fillZoom }
        pan = clampedPan(pan)
        keepPointerInView()
    }
    // Fill and fit, in turn: the button shows whichever isn't on now.
    func fitScreen() {
        withAnimation(Motion.quick) {
            if filling || zoom > fillZoom + 0.01 { filling = false; zoom = 1; pan = .zero }
            else { filling = true; applyFill() }
        }
    }
    var fitIcon: String { zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right" }
    var fitLabel: String { zoomed ? "Fit the whole screen" : "Fill the space" }

    // MARK: Clipboard
    // Copy and Paste carry text between the two clipboards. Done is a tick on the button itself, for a moment; a failure
    // says why, right at the button.
    func clipButton(paste: Bool, compact: Bool = false) -> some View {
        let state = paste ? pasteState : copyState
        let icon: String
        switch state {
        case .done: icon = "checkmark"
        case .failed: icon = "exclamationmark.triangle"
        default: icon = paste ? "doc.on.clipboard" : "doc.on.doc"
        }
        // Nothing on this iPhone's clipboard isn't a failure: Paste just sits dimmed until there is.
        let empty = paste && !phoneHasText
        return toolButton(icon, paste ? "Paste the iPhone’s clipboard on the Mac" : "Copy from the Mac to the iPhone",
                          tint: state == .done ? macBlue : state.failed ? .red : .white, compact: compact) {
            if paste { pasteFromPhone() } else { copyToPhone() }
        }
        .disabled(empty)
        .opacity(state == .working || empty ? 0.45 : 1)
        .contentTransition(.symbolEffect(.replace))
        .animation(Motion.quick, value: state)
        // Centred above its button, nudged in only as far as it takes to stay 12 pt clear of the display's edges.
        .overlay(alignment: .top) {
            if case .failed(let message) = state {
                EdgeClamped {
                    Text(message).font(.caption.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.red.opacity(0.9), in: Capsule())
                        .fixedSize()
                }
                .offset(y: -48)
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
    func checkPhoneClipboard() {
        #if canImport(UIKit)
        phoneHasText = UIPasteboard.general.hasStrings || model.pose == "screenclip"
        #endif
    }
    // This iPhone's clipboard onto the Mac's, then ⌘V.
    func pasteFromPhone() {
        guard pasteState != .working else { return }
        #if canImport(UIKit)
        guard UIPasteboard.general.hasStrings else { phoneHasText = false; return }
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
    // Scale that fits the Mac in the space, before any zoom. The space is the Mac's own shape, so this fills it.
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
    // Measured only for the build's shot: how many pictures reach the display, and how many the Mac sent, each second.
    var measuring: Bool { model.pose == "screenfps" || UserDefaults.standard.bool(forKey: "showFPS") }
    var showHint: Bool { model.pose == "screenhint" || (model.pose.isEmpty && !gesturesSeen) }

    // `always`: the pointer stays in view, as on a laptop, where there's a trackpad. Touched directly, it shows for a
    // moment after each touch.
    func canvas(always: Bool) -> some View {
        Color.black
            .overlay {
                // Drawn from the space it's actually given, not from a remembered size, so a new posture never leaves it
                // blank. The layer takes each new picture on the next display refresh.
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
                // The Mac's own pointer, drawn here at once rather than waiting for it to come back in the picture.
                if screen.hasPicture {
                    CursorOverlay(screen: screen, pad: pad,
                                  map: CursorMap(scale: fit * zoom, pan: pan, canvas: canvasSize, mac: screen.size, always: always),
                                  image: observed.cursorImage, hotspot: observed.cursorHotspot)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                TouchSurface(
                    mode: .picture,
                    onTap: { p in
                        bump()
                        screen.click(x: Int(macPoint(p).x), y: Int(macPoint(p).y))
                        keys.consume()
                        tick(.light)
                    },
                    onTwoFingerTap: { p in
                        bump()
                        screen.click(x: Int(macPoint(p).x), y: Int(macPoint(p).y), right: true)
                        keys.consume()
                        tick(.medium)
                    },
                    onSmartZoom: { p in smartZoom(around: p) },
                    onLongPress: { p in
                        bump()
                        screen.click(x: Int(macPoint(p).x), y: Int(macPoint(p).y), right: true)
                        keys.consume()
                        tick(.medium)
                    },
                    onDrag: { phase, location, delta in directDrag(phase, location, delta) },
                    onScroll: { d, step in scroll(d, step, onPicture: true) },
                    onPinch: { phase, scale, center in pinch(phase, scale, center) },
                    onSwipe: { swipe($0) }
                )
            }
            .overlay { status }
            .overlay(alignment: .topLeading) { if measuring { rateBadge } }
            .overlay { if showHint, screen.hasPicture { gestureHint } }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0; applyFill() }
            .onChange(of: always, initial: true) { _, a in
                padLayout = a
                if !a, filling, zoom > 1.001 { zoom = 1; pan = .zero } else { applyFill() }
            }
            .onChange(of: screen.size) { _, _ in applyFill() }
    }
    var rateBadge: some View {
        let rtt = observed.pingRTT.map { " · \(Int($0.rounded())) ms" } ?? ""
        return Text("\(rate.frames) fps shown · \(rate.updates) sent by the Mac · \(RemoteScreen.pipeline) in flight\(rtt) · \(observed.movesPerSecond) moves/s")
            .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
    }
    // A finger on the picture: moves the view when zoomed in, and otherwise holds the mouse down and drags, from where
    // the finger first landed.
    func directDrag(_ phase: TouchPhase, _ location: CGPoint, _ delta: CGSize) {
        if zoom > 1.001 {
            if phase == .changed { pan = clampedPan(CGSize(width: pan.width + delta.width, height: pan.height + delta.height)) }
            return
        }
        switch phase {
        case .began:
            bump(); screen.move(to: macPoint(location)); screen.hold(true); tick(.light)
        case .changed:
            bump(); screen.moveCoalesced(to: macPoint(location))
        case .ended:
            screen.hold(false); keys.consume()
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
            // Let go near the fill, it settles on it; pinched out to the whole screen, the fill is off until asked for.
            if abs(zoom - fillZoom) < 0.08 { withAnimation(Motion.quick) { filling = true; zoom = fillZoom; pan = clampedPan(pan) } }
            else if zoom < fillZoom { filling = false; if zoom < 1.05 { withAnimation(Motion.quick) { zoom = 1; pan = .zero } } }
        }
    }
    // Two fingers tapped twice on the picture: in on that spot, or back out, as smart zoom does on a Mac.
    func smartZoom(around p: CGPoint) {
        tick(.light)
        withAnimation(Motion.quick) {
            if zoom > max(1, filling ? fillZoom : 1) + 0.05 {
                zoom = filling ? fillZoom : 1; pan = clampedPan(filling ? pan : .zero)
            } else {
                let next: CGFloat = 2.2
                let cx = p.x - canvasSize.width / 2, cy = p.y - canvasSize.height / 2
                let k = next / zoom
                let target = CGSize(width: cx - (cx - pan.width) * k, height: cy - (cy - pan.height) * k)
                zoom = next
                pan = clampedPan(target)
            }
        }
    }
    // Two fingers move the page with them, in points and with their phases, as a Mac's own trackpad sends them: 1:1,
    // rubber-banding at the ends, swiping between pages, and gliding on as momentum after a flick. On the picture exactly
    // as far as the fingers went over it; on the trackpad about as far as a Mac's own, which adds its own acceleration.
    func scroll(_ d: CGSize, _ step: ScrollStep, onPicture: Bool) {
        bump()
        let perPoint = onPicture ? 1 / max(fit * zoom, 0.05) : max(screen.size.width, 1) / max(pad.width, 1) * 0.9
        let k = Double(perPoint) * (MacPrefs.naturalScroll ? 1 : -1)
        let dx = Double(d.width) * k, dy = Double(d.height) * k
        switch step {
        case .began: screen.pixelScroll(dx: dx, dy: dy, phase: .began, momentum: .none)
        case .changed: screen.pixelScroll(dx: dx, dy: dy, phase: .changed, momentum: .none)
        case .ended: screen.pixelScroll(dx: 0, dy: 0, phase: .ended, momentum: .none); keys.used()
        case .momentumBegan: screen.pixelScroll(dx: dx, dy: dy, phase: .none, momentum: .began)
        case .momentum: screen.pixelScroll(dx: dx, dy: dy, phase: .none, momentum: .changed)
        case .momentumEnded: screen.pixelScroll(dx: 0, dy: 0, phase: .none, momentum: .ended); keys.consume()
        }
        if step == .ended { keys.consume() }
    }
    // Three fingers, four, and two in from the edge: the Mac's own gestures, as its keyboard shortcuts.
    func swipe(_ s: MacSwipe) {
        bump(); tick(.medium)
        switch s {
        case .up: keys.tap(MacKey.up, with: [MacKey.control])
        case .down: keys.tap(MacKey.down, with: [MacKey.control])
        // Fingers to the left bring in the space on the right, as on the Mac.
        case .left: keys.tap(MacKey.right, with: [MacKey.control])
        case .right: keys.tap(MacKey.left, with: [MacKey.control])
        case .back: keys.tap(0x5b, with: [MacKey.command])
        case .forward: keys.tap(0x5d, with: [MacKey.command])
        case .desktop: keys.tap(MacKey.f11)
        case .notifications:
            let api = model.api
            Task { try? await api.action("notification-center") }
        case .launchpad:
            // Launchpad (Apps on Tahoe) has no shortcut a remote key reaches, so the Mac opens it; F4 if it can't.
            let api = model.api
            Task {
                do { try await api.action("show-apps") } catch { screen.key(MacKey.f4) }
            }
        }
    }
    // One finger on the trackpad, as GestureClassifier reads it.
    func track(_ o: GestureClassifier.Out) {
        switch o {
        case .move(let d):
            bump()
            screen.moveCoalesced(to: CGPoint(x: screen.cursor.x + d.width, y: screen.cursor.y + d.height))
        case .button(let down):
            bump(); screen.hold(down)
            if !down { keys.consume() }
        case .rightClick:
            bump(); screen.clickHere(right: true); keys.consume()
        case .haptic(let h): tick(h)
        }
    }
    // A touch: the pointer shows (where it isn't always shown), and comes back into view if zoomed in.
    func bump() {
        pad.lastTouch = Date().timeIntervalSinceReferenceDate
        keepPointerInView()
    }
    // Zoomed or filling, the view slides so the pointer stays at least 40 pt inside it.
    func keepPointerInView() {
        guard zoom > 1.001 else { return }
        let at = viewPoint(screen.cursor), margin: CGFloat = 40
        var next = pan
        if at.x < margin { next.width += margin - at.x }
        if at.x > canvasSize.width - margin { next.width -= at.x - (canvasSize.width - margin) }
        if at.y < margin { next.height += margin - at.y }
        if at.y > canvasSize.height - margin { next.height -= at.y - (canvasSize.height - margin) }
        let clamped = clampedPan(next)
        if abs(clamped.width - pan.width) > 0.5 || abs(clamped.height - pan.height) > 0.5 { pan = clamped }
    }
    func tick(_ style: ScreenHaptic) { ScreenHaptics.play(style) }

    // MARK: First use
    // Once, the first time the screen opens: what the fingers do, in the Mac's own words. Gone for good on Got it.
    var gestureHint: some View {
        let rows: [(String, String, String)] = [
            ("hand.draw", "Two fingers", "Scroll"),
            ("hand.tap", "Tap with two fingers", "Right click"),
            ("hand.point.up.left", "Tap, then drag", "Drag"),
            ("hand.point.down", "Press and hold, then move", "Click and drag"),
            ("rectangle.3.group", "Three or four fingers up", "Mission Control"),
            ("macwindow", "Three or four fingers down", "App Exposé"),
            ("rectangle.split.3x1", "Three or four fingers sideways", "Switch spaces"),
            ("arrow.left.arrow.right", "Two fingers sideways", "Back and forward"),
            ("bell", "Two fingers in from the right edge", "Notification Centre"),
            ("square.grid.3x3", "Thumb and three fingers together", "Launchpad"),
            ("menubar.dock.rectangle", "Thumb and three fingers apart", "Show the desktop"),
            ("plus.magnifyingglass", "Pinch, or double-tap with two fingers", "Zoom"),
        ]
        let columns = canvasSize.width >= 600 ? 2 : 1
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .leading), count: columns), alignment: .leading, spacing: 8) {
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
        return VStack(alignment: .leading, spacing: 12) {
            Text("Trackpad gestures").font(.headline).foregroundStyle(.white)
            // Folded, the half display is shorter than the list: the rows scroll and Got it stays at the card's foot.
            ViewThatFits(in: .vertical) {
                grid
                ScrollView { grid }.scrollIndicators(.visible)
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
        // A dark layer over the glass, so the picture behind only part of the card doesn't show as a patch of other blur.
        .background(Color(white: 0.07).opacity(0.82), in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .padding(10)
        .frame(maxHeight: max(canvasSize.height, 1))
        .transition(.opacity)
    }

    // MARK: Trackpad and keys
    var trackpad: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return TouchSurface(
            mode: .trackpad,
            macWidth: screen.size.width,
            edgeBack: !observed.pixelScrollAvailable,
            onTrack: { track($0) },
            onScroll: { d, step in scroll(d, step, onPicture: false) },
            // Pinching the trackpad zooms around the pointer.
            onPinch: { phase, scale, _ in pinch(phase, scale, viewPoint(screen.cursor)) },
            onSwipe: { swipe($0) }
        )
        .background(Color.clear.glassEffect(.regular.tint(.white.opacity(0.04)), in: shape))
        // A hairline of light along its top edge, as on the aluminium.
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 1).allowsHitTesting(false))
        .clipShape(shape)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pad.width = $0 }
        .accessibilityLabel("Trackpad")
    }
    // ⌃ ⌥ ⌘ ⇧ and the arrows, where there's no room for the whole keyboard.
    var modifierRow: some View {
        HStack(spacing: 5) {
            MacKeyCap(label: "⌃", sym: MacKey.control, keys: keys, a11y: "Control", size: 16)
            MacKeyCap(label: "⌥", sym: MacKey.option, keys: keys, a11y: "Option", size: 16)
            MacKeyCap(label: "⌘", sym: MacKey.command, keys: keys, a11y: "Command", size: 16)
            MacKeyCap(label: "⇧", sym: MacKey.shift, keys: keys, a11y: "Shift", size: 16)
            Color.clear.frame(width: 4, height: 1)
            MacKeyCap(label: "", icon: "arrow.left", sym: MacKey.left, keys: keys, a11y: "Left arrow")
            MacKeyCap(label: "", icon: "arrow.up", sym: MacKey.up, keys: keys, a11y: "Up arrow")
            MacKeyCap(label: "", icon: "arrow.down", sym: MacKey.down, keys: keys, a11y: "Down arrow")
            MacKeyCap(label: "", icon: "arrow.right", sym: MacKey.right, keys: keys, a11y: "Right arrow")
        }
    }
    func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            if scalar == "\n" { keys.tap(MacKey.returnKey); continue }
            keys.tap(scalar.value < 256 ? scalar.value : 0x0100_0000 | scalar.value)
        }
    }
    func keyButton(_ label: String, icon: String? = nil, _ a11y: String, action: @escaping () -> Void) -> some View {
        Button { tick(.light); action() } label: {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 15, weight: .semibold)) }
                else { Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8) }
            }
            .frame(minWidth: 40, minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(MacKeyStyle()).accessibilityLabel(a11y)
    }
    // Landscape, the picture has the room, so the keys sit in one dock under it: 40 pt keys, 4 pt apart. Where the
    // hinge crosses it, it splits in two, one capsule each side of the fold, so no key sits on the crease.
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
        MacKeyCap(label: "⌘", sym: MacKey.command, keys: keys, a11y: "Command", size: 16).frame(width: 44, height: 40)
        keyButton("esc", "Escape") { keys.tap(MacKey.esc) }
        keyButton("", icon: "square.grid.3x1.below.line.grid.1x2", "Switch apps") { keys.switchApps() }
        keyButton("", icon: "magnifyingglass", "Spotlight") { keys.tap(MacKey.space, with: [MacKey.command]) }
        keyButton("", icon: "rectangle.3.group", "Mission Control") { keys.tap(MacKey.up, with: [MacKey.control]) }
        ForEach([(MacKey.left, "arrow.left", "Left arrow"), (MacKey.up, "arrow.up", "Up arrow"), (MacKey.down, "arrow.down", "Down arrow"), (MacKey.right, "arrow.right", "Right arrow")], id: \.0) { k in
            MacKeyCap(label: "", icon: k.1, sym: k.0, keys: keys, a11y: k.2).frame(width: 40, height: 40)
        }
    }
    // Right of the fold: ⌫ ⏎, the tools and Done.
    @ViewBuilder var dockTools: some View {
        if dockOpen {
            MacKeyCap(label: "", icon: "delete.left", sym: MacKey.delete, keys: keys, a11y: "Delete").frame(width: 40, height: 40)
            MacKeyCap(label: "", icon: "return", sym: MacKey.returnKey, keys: keys, a11y: "Return").frame(width: 40, height: 40)
            toolButton(typing ? "keyboard.chevron.compact.down" : "keyboard", typing ? "Hide keyboard" : "Show keyboard", on: typing) { typing.toggle() }
            if zoomed || fillZoom > 1.01 { toolButton(fitIcon, fitLabel) { fitScreen() } }
            toolButton("key.fill", "Sign in to the Mac") { signingIn = true }
            clipButton(paste: false)
            clipButton(paste: true)
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
        toolButton("xmark", "Done", on: true) { model.screenOpen = false }
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

// Where each part of the screen goes, for one size and posture.
struct ScreenPlan: Equatable {
    enum Kind: Equatable { case laptop, closed, book, closedLandscape, flatLandscape }
    var kind: Kind
    var picture = CGRect.zero
    var fnRow = CGRect.zero
    var keyboard = CGRect.zero
    var modRow = CGRect.zero
    var trackpad = CGRect.zero
    var dock = CGRect.zero
    var crease: CGRect?
}

// The window's own insets (the camera at the top, the home bar at the foot), which the screen's plan keeps clear of
// itself, since the view runs edge to edge.
enum ScreenInsets {
    @MainActor static var current: (top: CGFloat, bottom: CGFloat) {
        #if os(iOS)
        let w = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return (w?.safeAreaInsets.top ?? 0, w?.safeAreaInsets.bottom ?? 0)
        #else
        return (0, 0)
        #endif
    }
}

// Touch bookkeeping that changes on every sample: kept in a box, not in SwiftUI state, so nothing rebuilds per touch.
final class TrackpadBox {
    var width: CGFloat = 1
    // When a finger last touched, for showing the pointer a moment after a direct touch.
    var lastTouch: Double = 0
}

enum ScreenHaptic { case light, medium, soft }
// One of each feedback, made once and kept warm, so a tick lands with the touch, not after it.
enum ScreenHaptics {
    #if canImport(UIKit)
    @MainActor static let light = UIImpactFeedbackGenerator(style: .light)
    @MainActor static let medium = UIImpactFeedbackGenerator(style: .medium)
    @MainActor static let soft = UIImpactFeedbackGenerator(style: .soft)
    #endif
    @MainActor static func prepare() {
        #if canImport(UIKit)
        light.prepare(); medium.prepare(); soft.prepare()
        #endif
    }
    @MainActor static func play(_ h: ScreenHaptic) {
        #if canImport(UIKit)
        guard MacPrefs.haptics else { return }
        switch h {
        case .light: light.impactOccurred(); light.prepare()
        case .medium: medium.impactOccurred(); medium.prepare()
        case .soft: soft.impactOccurred(intensity: 0.5); soft.prepare()
        }
        #endif
    }
}

// MARK: - Keys
// The phone's Mac keyboard, as a Mac's keys behave: each key goes down when the finger lands and up when it lifts, so
// the Mac repeats a held key itself. Modifiers: a tap holds one for the next key, click or scroll; a quick second tap
// locks it until tapped again; held while something else is pressed, it's a chord. They reach the Mac through the
// screen's heldModifiers, which it presses around every key, click and scroll.
@MainActor final class MacKeyboard: ObservableObject {
    enum Latch: Equatable { case once, locked, held }
    @Published private(set) var latched: [UInt32: Latch] = [:]
    let screen: RemoteScreen
    private var pressing: [UInt32: (was: Latch?, used: Bool)] = [:]
    private var tapped: [UInt32: Date] = [:]
    private var keyMods: [UInt32: [UInt32]] = [:]
    // ⌘ held down by ⌘Tab while the app switcher is open; let go when he's done browsing.
    private var switching = false
    private var switcherClose: Task<Void, Never>?
    init(screen: RemoteScreen) { self.screen = screen }
    var shifted: Bool { latched[MacKey.shift] != nil }

    private func sync() { screen.heldModifiers = latched.keys.sorted().filter { !(switching && $0 == MacKey.command) } }
    func press(_ sym: UInt32) {
        if MacKey.modifiers.contains(sym) {
            let was = latched[sym]
            if was == nil { latched[sym] = .held; sync() }
            pressing[sym] = (was, false)
            return
        }
        used()
        if switching, sym != MacKey.tab { closeSwitcher() }
        let mods = screen.heldModifiers
        for m in mods { screen.keyDown(m) }
        screen.keyDown(sym)
        keyMods[sym] = mods
    }
    func release(_ sym: UInt32) {
        if MacKey.modifiers.contains(sym) { releaseModifier(sym); return }
        guard let mods = keyMods.removeValue(forKey: sym) else { return }
        screen.keyUp(sym)
        for m in mods.reversed() { screen.keyUp(m) }
        consume()
    }
    private func releaseModifier(_ m: UInt32) {
        guard let p = pressing.removeValue(forKey: m) else { return }
        if p.used {
            // A chord: it was held while something else was pressed.
            latched[m] = p.was; sync(); return
        }
        switch p.was {
        case nil:
            latched[m] = .once; tapped[m] = Date()
        case .once:
            if let t = tapped[m], Date().timeIntervalSince(t) < 0.4 { latched[m] = .locked } else { off(m) }
        case .locked, .held:
            off(m)
        }
        sync()
    }
    private func off(_ m: UInt32) {
        latched[m] = nil
        if m == MacKey.command, switching { closeSwitcher() }
        sync()
    }
    // A key or shortcut from a button, pressed and let go at once, with what's latched and the shortcut's own modifiers.
    func tap(_ sym: UInt32, with extra: [UInt32] = []) {
        used()
        if switching { closeSwitcher() }
        screen.key(sym, with: screen.heldModifiers + extra.filter { !screen.heldModifiers.contains($0) })
        consume()
    }
    // Something else was pressed while a modifier is held: that modifier is now a chord.
    func used() { for k in pressing.keys { pressing[k]?.used = true } }
    // A one-use modifier is used up by the key, click or scroll it went with.
    func consume() {
        for (m, l) in latched where l == .once && pressing[m] == nil { latched[m] = nil }
        sync()
    }
    // ⌘Tab with ⌘ kept down, so another tap goes on to the next app; a moment's pause, or any other key, picks it.
    func switchApps() {
        if !switching {
            switching = true
            screen.keyDown(MacKey.command)
            sync()
        }
        screen.key(MacKey.tab)
        switcherClose?.cancel()
        switcherClose = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { closeSwitcher() }
        }
    }
    private func closeSwitcher() {
        guard switching else { return }
        switching = false
        switcherClose?.cancel()
        screen.keyUp(MacKey.command)
        if latched[MacKey.command] == .once { latched[MacKey.command] = nil }
        sync()
    }
    // Nothing stays down on the Mac once the screen goes away.
    func releaseAll() {
        for (sym, mods) in keyMods { screen.keyUp(sym); for m in mods.reversed() { screen.keyUp(m) } }
        keyMods = [:]; pressing = [:]
        closeSwitcher()
        latched = [:]; sync()
    }
    // For the build's shot: ⌘ locked and ⇧ held for one key.
    func demoLatches() { latched = [MacKey.command: .locked, MacKey.shift: .once]; sync() }
}

// One key: down on touch-down, up on lift, and up if the touch is cancelled or the key goes away.
struct MacKeyCap: View {
    let label: String
    var icon: String? = nil
    let sym: UInt32
    @ObservedObject var keys: MacKeyboard
    let a11y: String
    var size: CGFloat = 13
    @GestureState private var pressing = false
    var body: some View {
        let latch = keys.latched[sym]
        let lit = latch != nil && MacKey.modifiers.contains(sym)
        Group {
            if let icon { Image(systemName: icon).font(.system(size: size, weight: .semibold)) }
            else { Text(keys.shifted && label.count == 1 ? label.uppercased() : label).font(.system(size: size, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(lit ? .black : .white)
        .background(lit ? Color.white.opacity(latch == .locked ? 1 : 0.82) : Color.white.opacity(pressing ? 0.3 : 0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        // Locked shows a small light, as Caps Lock does.
        .overlay(alignment: .bottom) { if latch == .locked { Capsule().fill(macBlue).frame(width: 10, height: 3).padding(.bottom, 3) } }
        .scaleEffect(pressing ? 0.94 : 1)
        .animation(Motion.press, value: pressing)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).updating($pressing) { _, s, _ in s = true })
        .onChange(of: pressing) { _, down in
            if down { ScreenHaptics.play(.light); keys.press(sym) } else { keys.release(sym) }
        }
        .onDisappear { if pressing { keys.release(sym) } }
        .accessibilityLabel(a11y).accessibilityAddTraits(.isButton)
    }
}

// A Mac's keyboard in five rows, every key where a MacBook has it.
struct MacKeyboardView: View {
    @ObservedObject var keys: MacKeyboard
    struct K { var label: String; var sym: UInt32; var weight: CGFloat = 1; var icon: String? = nil; var a11y: String? = nil }
    static func chars(_ s: String) -> [K] { s.map { K(label: String($0), sym: $0.unicodeScalars.first!.value) } }
    static let rows: [[K]] = [
        chars("`1234567890-=") + [K(label: "", sym: MacKey.delete, weight: 1.5, icon: "delete.left", a11y: "Delete")],
        [K(label: "tab", sym: MacKey.tab, weight: 1.5, a11y: "Tab")] + chars("qwertyuiop[]\\"),
        chars("asdfghjkl;'") + [K(label: "return", sym: MacKey.returnKey, weight: 1.75, a11y: "Return")],
        [K(label: "⇧", sym: MacKey.shift, weight: 2.25, a11y: "Shift")] + chars("zxcvbnm,./") + [K(label: "⇧", sym: MacKey.shift, weight: 2.25, a11y: "Shift")],
    ]
    var body: some View {
        GeometryReader { g in
            let gap: CGFloat = 5, rowHeight = max((g.size.height - gap * 4) / 5, 0)
            VStack(spacing: gap) {
                ForEach(Self.rows.indices, id: \.self) { i in row(Self.rows[i], width: g.size.width, gap: gap).frame(height: rowHeight) }
                bottomRow(width: g.size.width, gap: gap).frame(height: rowHeight)
            }
        }
    }
    func cap(_ k: K, width: CGFloat) -> some View {
        MacKeyCap(label: k.label, icon: k.icon, sym: k.sym, keys: keys, a11y: k.a11y ?? k.label, size: k.label.count > 1 ? 11 : 15)
            .frame(width: max(width, 0))
    }
    func row(_ ks: [K], width: CGFloat, gap: CGFloat) -> some View {
        let unit = max((width - gap * CGFloat(ks.count - 1)) / ks.reduce(0) { $0 + $1.weight }, 0)
        return HStack(spacing: gap) { ForEach(ks.indices, id: \.self) { j in cap(ks[j], width: unit * ks[j].weight) } }
    }
    // ⌃ ⌥ ⌘ space ⌘ ⌥, then the arrows as an inverted T with ↑ and ↓ halved.
    func bottomRow(width: CGFloat, gap: CGFloat) -> some View {
        let ks = [K(label: "⌃", sym: MacKey.control, a11y: "Control"), K(label: "⌥", sym: MacKey.option, a11y: "Option"),
                  K(label: "⌘", sym: MacKey.command, weight: 1.25, a11y: "Command"), K(label: "", sym: MacKey.space, weight: 5, a11y: "Space"),
                  K(label: "⌘", sym: MacKey.command, weight: 1.25, a11y: "Command"), K(label: "⌥", sym: MacKey.option, a11y: "Option")]
        let total = ks.reduce(0) { $0 + $1.weight } + 3
        let unit = max((width - gap * CGFloat(ks.count + 2)) / total, 0)
        return HStack(spacing: gap) {
            ForEach(ks.indices, id: \.self) { j in cap(ks[j], width: unit * ks[j].weight) }
            cap(K(label: "", sym: MacKey.left, icon: "arrowtriangle.left.fill", a11y: "Left arrow"), width: unit)
            VStack(spacing: 2) {
                cap(K(label: "", sym: MacKey.up, icon: "arrowtriangle.up.fill", a11y: "Up arrow"), width: unit)
                cap(K(label: "", sym: MacKey.down, icon: "arrowtriangle.down.fill", a11y: "Down arrow"), width: unit)
            }
            cap(K(label: "", sym: MacKey.right, icon: "arrowtriangle.right.fill", a11y: "Right arrow"), width: unit)
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
// Two fingers' scroll, with the phases a Mac's trackpad sends: the fingers' own, then the glide's.
enum ScrollStep: Equatable { case began, changed, ended, momentumBegan, momentum, momentumEnded }

// MARK: - The trackpad's one finger
// One finger on the trackpad as a Mac reads it: the pointer, with a Mac's acceleration; a tap clicks, holding the
// button up a moment in case a drag follows (tap, then drag); a still press clicks and holds, with a firmer tick;
// two fingers tapped together right-click at once. A thumb resting at the pad's edge doesn't count as a finger. Pure:
// touches and times in, what to send out, so the build can run scripted touches through it and check the result.
struct GestureClassifier {
    enum Out: Equatable { case move(CGSize), button(down: Bool), rightClick, haptic(ScreenHaptic) }
    struct Touch { var start: CGPoint; var at: CGPoint; var began: Double; var moved: CGFloat = 0; var palm: Bool? }
    private(set) var touches: [Int: Touch] = [:]
    var pad = CGSize(width: 400, height: 250)
    var macWidth: CGFloat = 1680
    private var gestureBegan: Double = 0
    private var maxFingers = 0
    private var gestureMoved: CGFloat = 0
    private var pendingUp: Double?
    private var follower: Int?
    private var holding = false
    private var pressed = false
    private var samples: [(t: Double, p: CGPoint)] = []
    static let tapWindow = 0.28, pressDelay = 0.35, edge: CGFloat = 16

    // Fingers known to be fingers; a touch at the edge waits 150 ms (or until it moves) to be judged.
    var fingers: Int { touches.values.filter { $0.palm == false }.count }
    var palms: Int { touches.values.filter { $0.palm == true }.count }
    var undecided: Int { touches.values.filter { $0.palm == nil }.count }
    var idle: Bool { touches.isEmpty && pendingUp == nil && !holding }

    static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
    // Mac pixels per point of finger travel, for a finger moving at v points a second: slow is precise enough for a
    // 3-pixel window edge, a flick crosses the screen.
    static func gain(speed v: CGFloat, macWidth: CGFloat, padWidth: CGFloat) -> CGFloat {
        let k = macWidth / max(padWidth, 1) * 0.55
        return k * (0.45 + 2.1 * smoothstep(60, 1500, v))
    }

    mutating func began(_ id: Int, at p: CGPoint, t: Double) -> [Out] {
        if touches.isEmpty { gestureBegan = t; maxFingers = 0; gestureMoved = 0; samples = [] }
        let atEdge = p.y > pad.height - Self.edge || p.x < Self.edge || p.x > pad.width - Self.edge
        touches[id] = Touch(start: p, at: p, began: t, palm: atEdge ? nil : false)
        if pendingUp != nil, follower == nil { follower = id }
        maxFingers = max(maxFingers, fingers)
        return []
    }
    mutating func moved(_ id: Int, to p: CGPoint, t: Double) -> [Out] {
        guard var touch = touches[id] else { return [] }
        let d = CGSize(width: p.x - touch.at.x, height: p.y - touch.at.y)
        touch.at = p
        touch.moved = max(touch.moved, hypot(p.x - touch.start.x, p.y - touch.start.y))
        if touch.palm == nil, touch.moved > 6 { touch.palm = false }
        touches[id] = touch
        gestureMoved = max(gestureMoved, touch.moved)
        maxFingers = max(maxFingers, fingers)
        // Only one finger moves the pointer; two or more are a scroll or a gesture, which the recognisers have.
        guard touch.palm == false, fingers == 1 else { samples = []; return [] }
        // A finger that landed while a tap's button was still held, and moves: that's a drag with the same press.
        if follower == id, pendingUp != nil, touch.moved > 4 { pendingUp = nil; holding = true }
        samples.append((t, p))
        if samples.count > 4 { samples.removeFirst() }
        let g = Self.gain(speed: speed(), macWidth: macWidth, padWidth: pad.width)
        return [.move(CGSize(width: d.width * g, height: d.height * g))]
    }
    // Finger speed in points a second, over the last three intervals.
    private func speed() -> CGFloat {
        guard let a = samples.first, let b = samples.last, b.t > a.t else { return 0 }
        return hypot(b.p.x - a.p.x, b.p.y - a.p.y) / CGFloat(b.t - a.t)
    }
    mutating func ended(_ id: Int, t: Double) -> [Out] {
        guard let touch = touches.removeValue(forKey: id) else { return [] }
        guard touches.isEmpty else { return [] }
        defer { follower = nil; samples = [] }
        if holding {
            holding = false
            if pressed { pressed = false; return [.button(down: false), .haptic(.soft)] }
            return [.button(down: false)]
        }
        let quick = t - gestureBegan < 0.25
        if maxFingers == 2, quick, gestureMoved < 8 { return [.rightClick, .haptic(.medium)] }
        if maxFingers <= 1, touch.palm != true, quick, gestureMoved < 6 {
            if pendingUp != nil {
                // A second tap in time: the first click's up, then a whole second click, which the Mac counts as a double.
                pendingUp = nil
                return [.button(down: false), .button(down: true), .button(down: false), .haptic(.light)]
            }
            pendingUp = t + Self.tapWindow
            return [.button(down: true), .haptic(.light)]
        }
        return []
    }
    mutating func cancelled(_ id: Int) -> [Out] {
        touches.removeValue(forKey: id)
        guard touches.isEmpty else { return [] }
        follower = nil; samples = []
        if holding { holding = false; pressed = false; return [.button(down: false)] }
        return []
    }
    mutating func tick(t: Double) -> [Out] {
        var out: [Out] = []
        for (id, var touch) in touches where touch.palm == nil && t - touch.began >= 0.15 {
            touch.palm = touch.moved < 6
            touches[id] = touch
        }
        maxFingers = max(maxFingers, fingers)
        if let due = pendingUp, t >= due, !holding { pendingUp = nil; follower = nil; out.append(.button(down: false)) }
        let still = touches.values.filter { $0.palm == false }
        if !holding, pendingUp == nil, maxFingers <= 1, still.count == 1, let only = still.first, only.moved < 4, t - only.began >= Self.pressDelay {
            // Press to click: held still, the button goes down with a firmer tick, and moving now drags.
            holding = true; pressed = true
            out += [.button(down: true), .haptic(.medium)]
        }
        return out
    }
}

// MARK: - Two to five fingers
// What several fingers mean, settled by how many came down and where: two scroll (mostly one axis, as on a Mac), or from
// an edge go back, forward or to Notification Centre; three or four swipe once; four pinched in or spread out are
// Launchpad and the desktop. A finger that lands a moment late still counts, until the hand has really moved. Pure:
// fingers, positions and movement in, scrolls and swipes out, so the build can run scripted hands through it.
struct MultiFingerClassifier {
    enum Out: Equatable { case scroll(CGSize, ScrollStep), swipe(MacSwipe), glide(CGPoint) }
    enum Mode: Equatable { case none, scroll, edge(back: Bool), three, four }
    private(set) var mode = Mode.none
    private(set) var fingers = 0
    private var travel = CGPoint.zero
    private var fired = false
    private var startSpread: CGFloat = 0
    private var axis = 0                 // 0 not yet, 1 sideways, 2 up and down, 3 both
    private(set) var scrolling = false
    // Whether the left edge goes back (only while smooth scrolling can't carry the swipe between pages itself).
    var edgeBack = false
    static let edge: CGFloat = 22

    mutating func began() { mode = .none; fingers = 0; travel = .zero; fired = false; axis = 0; scrolling = false }
    // `count` is real fingers (less a resting thumb); `touches` all of them; `spread` their mean distance from their centre.
    mutating func changed(count: Int, touches: Int, at: CGPoint, width: CGFloat, delta: CGSize, spread: CGFloat, pinching: Bool) -> [Out] {
        travel.x += delta.width; travel.y += delta.height
        settle(count: count, at: at, width: width, spread: spread)
        var out: [Out] = []
        step(delta, touches: touches, spread: spread, pinching: pinching, into: &out)
        return out
    }
    mutating func ended(velocity: CGPoint, completed: Bool, pinching: Bool) -> [Out] {
        var out: [Out] = []
        if scrolling {
            scrolling = false
            out.append(.scroll(.zero, .ended))
            // A flick glides on, along the axis it was locked to.
            if mode == .scroll, completed, !pinching {
                var v = velocity
                if axis == 1 { v.y = 0 } else if axis == 2 { v.x = 0 }
                if hypot(v.x, v.y) > 180 { out.append(.glide(v)) }
            }
        }
        mode = .none; fingers = 0
        return out
    }
    private mutating func settle(count: Int, at: CGPoint, width: CGFloat, spread: CGFloat) {
        fingers = max(fingers, count)
        let moved = hypot(travel.x, travel.y)
        switch mode {
        case .none:
            guard fingers >= 2 else { return }
            if fingers >= 4 { mode = .four; startSpread = spread }
            else if fingers == 3 { mode = .three }
            else if at.x > width - Self.edge { mode = .edge(back: false) }
            else if at.x < Self.edge, edgeBack { mode = .edge(back: true) }
            else { mode = .scroll }
        case .scroll, .edge:
            if fingers >= 3, moved < 36, !scrolling { mode = fingers >= 4 ? .four : .three; if fingers >= 4 { startSpread = spread } }
        case .three:
            if fingers >= 4, !fired, moved < 36 { mode = .four; startSpread = spread }
        case .four: break
        }
    }
    private func locked(_ d: CGSize) -> CGSize {
        axis == 1 ? CGSize(width: d.width, height: 0) : axis == 2 ? CGSize(width: 0, height: d.height) : d
    }
    private mutating func step(_ d: CGSize, touches: Int, spread: CGFloat, pinching: Bool, into out: inout [Out]) {
        switch mode {
        case .scroll:
            guard !pinching else { return }
            if axis == 0, hypot(travel.x, travel.y) > 10 {
                axis = abs(travel.x) > abs(travel.y) * 1.7 ? 1 : abs(travel.y) > abs(travel.x) * 1.7 ? 2 : 3
            }
            if scrolling { out.append(.scroll(locked(d), .changed)) } else { scrolling = true; out.append(.scroll(locked(d), .began)) }
        case .edge(let back):
            // Sideways from the edge, inwards, is the edge's gesture; anything else was a scroll that began near it.
            let inward = back ? travel.x : -travel.x
            if abs(travel.y) > 24 && abs(travel.y) > abs(travel.x) || inward < -20 {
                mode = .scroll
                step(CGSize(width: travel.x, height: travel.y), touches: touches, spread: spread, pinching: pinching, into: &out)
            } else if !fired, inward > 64 {
                fired = true
                out.append(.swipe(back ? .back : edgeBack ? .forward : .notifications))
            }
        case .three:
            swipeOnce(into: &out)
        case .four:
            guard !fired, startSpread > 0, touches >= 4 else { return }
            let s = spread / startSpread
            if s < 0.72 { fired = true; out.append(.swipe(.launchpad)) }
            else if s > 1.38 { fired = true; out.append(.swipe(.desktop)) }
            // Four fingers moving together, not spreading, swipe as three do.
            else if (0.85...1.15).contains(s) { swipeOnce(into: &out) }
        case .none: break
        }
    }
    private mutating func swipeOnce(into out: inout [Out]) {
        guard !fired, hypot(travel.x, travel.y) > 44 else { return }
        fired = true
        if abs(travel.y) >= abs(travel.x) { out.append(.swipe(travel.y < 0 ? .up : .down)) }
        else { out.append(.swipe(travel.x < 0 ? .left : .right)) }
    }
}

// A flick's glide: slows as a scroll view does and stops under 30 pt a second. Pure, so the build can run it.
struct Glide {
    var velocity: CGPoint
    mutating func step(_ dt: Double) -> CGSize? {
        let decay = CGFloat(pow(0.998, dt * 1000))
        velocity.x *= decay; velocity.y *= decay
        if hypot(velocity.x, velocity.y) < 30 { return nil }
        return CGSize(width: velocity.x * CGFloat(dt), height: velocity.y * CGFloat(dt))
    }
}

// The build's check of the trackpad: scripted touches through GestureClassifier, one JSON line per thing it sends,
// written where the build collects it. Gestures can't be filmed; this is how they're seen.
enum ScreenTrace {
    struct Step { var t: Double; var kind: String; var id = 0; var p = CGPoint.zero }
    static let scripts: [(String, [Step])] = [
        ("tap", [Step(t: 0, kind: "down", p: CGPoint(x: 200, y: 120)), Step(t: 0.1, kind: "up")] + ticks(0.15, 0.6)),
        ("tap-then-drag", [Step(t: 0, kind: "down", p: CGPoint(x: 200, y: 120)), Step(t: 0.1, kind: "up"),
                           Step(t: 0.2, kind: "down", id: 1, p: CGPoint(x: 200, y: 120))]
            + (1...10).map { Step(t: 0.2 + Double($0) * 0.02, kind: "move", id: 1, p: CGPoint(x: 200 + CGFloat($0) * 4, y: 120)) }
            + [Step(t: 0.5, kind: "up", id: 1)] + ticks(0.55, 0.9)),
        ("double-tap", [Step(t: 0, kind: "down", p: CGPoint(x: 200, y: 120)), Step(t: 0.08, kind: "up"),
                        Step(t: 0.18, kind: "down", id: 1, p: CGPoint(x: 201, y: 121)), Step(t: 0.26, kind: "up", id: 1)] + ticks(0.3, 0.7)),
        ("two-finger-tap", [Step(t: 0, kind: "down", p: CGPoint(x: 180, y: 120)), Step(t: 0.01, kind: "down", id: 1, p: CGPoint(x: 230, y: 120)),
                            Step(t: 0.12, kind: "up"), Step(t: 0.13, kind: "up", id: 1)] + ticks(0.15, 0.5)),
        ("thumb-at-edge-and-pointer", [Step(t: 0, kind: "down", id: 9, p: CGPoint(x: 220, y: 245)), Step(t: 0.05, kind: "down", p: CGPoint(x: 150, y: 100))]
            + (1...10).map { Step(t: 0.2 + Double($0) * 0.016, kind: "move", p: CGPoint(x: 150 + CGFloat($0) * 6, y: 100)) }
            + ticks(0.16, 0.2) + [Step(t: 0.5, kind: "up"), Step(t: 0.6, kind: "up", id: 9)] + ticks(0.65, 1.0)),
        ("press-to-click-and-drag", [Step(t: 0, kind: "down", p: CGPoint(x: 200, y: 120))] + ticks(0.05, 0.45)
            + (1...8).map { Step(t: 0.45 + Double($0) * 0.02, kind: "move", p: CGPoint(x: 200, y: 120 + CGFloat($0) * 5)) }
            + [Step(t: 0.7, kind: "up")]),
    ]
    static func ticks(_ from: Double, _ to: Double) -> [Step] {
        stride(from: from, through: to, by: 0.05).map { Step(t: $0, kind: "tick") }
    }
    static func run() -> [String] {
        var lines: [String] = []
        for (name, steps) in scripts {
            var c = GestureClassifier()
            c.pad = CGSize(width: 446, height: 250); c.macWidth = 1680
            for s in steps.sorted(by: { $0.t < $1.t }) {
                let outs: [GestureClassifier.Out]
                switch s.kind {
                case "down": outs = c.began(s.id, at: s.p, t: s.t)
                case "move": outs = c.moved(s.id, to: s.p, t: s.t)
                case "up": outs = c.ended(s.id, t: s.t)
                default: outs = c.tick(t: s.t)
                }
                for o in outs { lines.append(#"{"case":"\#(name)","t":\#(Int(s.t * 1000)),"out":"\#(describe(o))"}"#) }
            }
        }
        // The pointer's curve: Mac pixels per point at ten speeds, on a 446 pt pad driving a 1680 px Mac.
        for v in [0, 30, 60, 150, 300, 500, 800, 1100, 1500, 2500] as [CGFloat] {
            lines.append(#"{"case":"pointer-curve","speed":\#(Int(v)),"gain":\#(String(format: "%.3f", GestureClassifier.gain(speed: v, macWidth: 1680, padWidth: 446)))}"#)
        }
        lines += runHands()
        return lines
    }

    // MARK: Several fingers
    // Scripted hands through MultiFingerClassifier and Glide, as the touch surface feeds them, each with what a Mac would
    // have to do for it to pass. A line with "pass":false is a failure the build reports.
    struct Hand { var t: Double; var count: Int; var at = CGPoint(x: 223, y: 125); var delta = CGSize.zero; var spread: CGFloat = 60; var touches: Int? = nil }
    struct HandScript { var name: String; var hands: [Hand]; var release: CGPoint = .zero; var landAfter: Int? = nil; var check: ([String]) -> (Bool, String) }
    static func strokes(_ n: Int, count: Int, from t0: Double = 0, d: CGSize, at: CGPoint = CGPoint(x: 223, y: 125), spread: (Int) -> CGFloat = { _ in 60 }, touches: Int? = nil) -> [Hand] {
        (0..<n).map { Hand(t: t0 + Double($0) * 0.016, count: count, at: at, delta: d, spread: spread($0), touches: touches) }
    }
    static func count(_ outs: [String], _ prefix: String) -> Int { outs.filter { $0.hasPrefix(prefix) }.count }
    static let handScripts: [HandScript] = [
        HandScript(name: "two-finger-scroll", hands: strokes(12, count: 2, d: CGSize(width: 1, height: -6)), release: CGPoint(x: 0, y: -60)) { o in
            let changed = o.filter { $0.hasPrefix("scroll changed") }
            let ok = o.first?.hasPrefix("scroll began") == true && o.last?.hasPrefix("scroll ended") == true && changed.count >= 10
                && changed.allSatisfy { $0.hasPrefix("scroll changed 0.0 ") }
                && count(o, "momentum") == 0 && count(o, "swipe") == 0
            return (ok, "began, changed, ended; locked to up and down; no glide from a slow lift")
        },
        HandScript(name: "scroll-momentum", hands: strokes(10, count: 2, d: CGSize(width: 0, height: -14)), release: CGPoint(x: 0, y: -1400)) { o in
            let ended = o.lastIndex { $0.hasPrefix("scroll ended") } ?? -1, began = o.firstIndex(of: "momentum began") ?? -1
            let ok = ended >= 0 && began > ended && count(o, "momentum changed") >= 20 && o.last?.hasPrefix("momentum ended") == true
            return (ok, "scroll ended, then momentum began, changed, ended, as the Mac's own glide")
        },
        HandScript(name: "momentum-finger-lands", hands: strokes(10, count: 2, d: CGSize(width: 0, height: -14)), release: CGPoint(x: 0, y: -1400), landAfter: 8) { o in
            let ok = count(o, "momentum changed") == 8 && o.last?.hasPrefix("momentum ended") == true
            return (ok, "a finger landing mid-glide ends the momentum at once")
        },
        HandScript(name: "three-up", hands: strokes(10, count: 3, d: CGSize(width: 0, height: -8))) { o in
            (o == ["swipe up"], "three fingers up: Mission Control, exactly once, no scroll")
        },
        HandScript(name: "three-sideways", hands: strokes(10, count: 3, d: CGSize(width: -8, height: 1))) { o in
            (o == ["swipe left"], "three fingers sideways: switch space, exactly once")
        },
        HandScript(name: "four-swipe", hands: strokes(10, count: 4, d: CGSize(width: 9, height: 0))) { o in
            (o == ["swipe right"], "four fingers together sideways swipe as three, exactly once")
        },
        HandScript(name: "four-spread", hands: strokes(10, count: 4, d: .zero, spread: { 60 + CGFloat($0) * 4 })) { o in
            (o == ["swipe desktop"], "thumb and three fingers spreading: show the desktop, exactly once")
        },
        HandScript(name: "right-edge-in", hands: strokes(10, count: 2, d: CGSize(width: -9, height: 0), at: CGPoint(x: 438, y: 125))) { o in
            (o == ["swipe notifications"], "two fingers in from the right edge: Notification Centre, exactly once, no scroll")
        },
        HandScript(name: "resting-thumb-and-finger", hands: strokes(12, count: 1, d: CGSize(width: 5, height: -3), touches: 2)) { o in
            (o.isEmpty, "a resting thumb plus one moving finger is the pointer, never a scroll or a swipe")
        },
    ]
    static func describe(_ o: MultiFingerClassifier.Out) -> String {
        switch o {
        case .scroll(let d, let step): return String(format: "scroll \(step == .began ? "began" : step == .ended ? "ended" : "changed") %.1f %.1f", d.width, d.height)
        case .swipe(let s): return "swipe \(s)"
        case .glide(let v): return String(format: "glide %.0f %.0f", v.x, v.y)
        }
    }
    static func runHands() -> [String] {
        var lines: [String] = []
        for script in handScripts {
            var c = MultiFingerClassifier()
            var outs: [String] = []
            c.began()
            var events: [MultiFingerClassifier.Out] = []
            for h in script.hands {
                events += c.changed(count: h.count, touches: h.touches ?? h.count, at: h.at, width: 446, delta: h.delta, spread: h.spread, pinching: false)
            }
            events += c.ended(velocity: script.release, completed: true, pinching: false)
            for e in events {
                if case .glide(let v) = e {
                    // As the touch surface does: momentum begins, steps at 60 Hz until it stops or a finger lands.
                    outs.append("momentum began")
                    var g = Glide(velocity: v), n = 0
                    while let d = g.step(1.0 / 60) {
                        if let land = script.landAfter, n >= land { break }
                        outs.append(String(format: "momentum changed %.1f %.1f", d.width, d.height)); n += 1
                    }
                    outs.append(String(format: "momentum ended after %.2f s", Double(n) / 60))
                } else { outs.append(describe(e)) }
            }
            for line in outs { lines.append(#"{"case":"\#(script.name)","out":"\#(line)"}"#) }
            let (pass, what) = script.check(outs)
            lines.append(#"{"case":"\#(script.name)","assert":"\#(what)","pass":\#(pass)}"#)
        }
        return lines
    }
    static func describe(_ o: GestureClassifier.Out) -> String {
        switch o {
        case .move(let d): return String(format: "move %.1f %.1f", d.width, d.height)
        case .button(let down): return down ? "button down" : "button up"
        case .rightClick: return "right click"
        case .haptic(let h): return "haptic \(h)"
        }
    }
    static func write() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? (run().joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("screen-input-trace.jsonl"), atomically: true, encoding: .utf8)
    }
}

// Where the pointer is drawn: the picture's scale and offset in its space, and whether it's always shown.
struct CursorMap: Equatable {
    var scale: CGFloat
    var pan: CGSize
    var canvas: CGSize
    var mac: CGSize
    var always: Bool
    func point(_ m: CGPoint) -> CGPoint {
        CGPoint(x: (m.x - mac.width / 2) * scale + canvas.width / 2 + pan.width,
                y: (m.y - mac.height / 2) * scale + canvas.height / 2 + pan.height)
    }
}

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

// The Mac's pointer, drawn on the phone where the phone has just put it: the Mac's own cursor image (an I-beam over
// text, a hand over a link) when the Mac sends it, a standard arrow until then, so there's never no pointer. It moves
// on the screen's cursorChanged, a layer move with no SwiftUI rebuild.
struct CursorOverlay: UIViewRepresentable {
    let screen: RemoteScreen
    let pad: TrackpadBox
    var map: CursorMap
    var image: CGImage?
    var hotspot: CGPoint
    func makeUIView(context: Context) -> CursorView {
        let v = CursorView()
        v.isUserInteractionEnabled = false
        v.pad = pad
        screen.cursorChanged = { [weak v] p in v?.place(p) }
        return v
    }
    func updateUIView(_ v: CursorView, context: Context) {
        v.map = map; v.image = image; v.hotspot = hotspot
        v.place(screen.cursor)
        screen.cursorChanged = { [weak v] p in v?.place(p) }
    }
    static func dismantleUIView(_ v: CursorView, coordinator: ()) { v.stop() }

    final class CursorView: UIView {
        var map = CursorMap(scale: 1, pan: .zero, canvas: .zero, mac: .zero, always: true)
        var image: CGImage? { didSet { if image !== oldValue { setImage() } } }
        var hotspot = CGPoint.zero
        weak var pad: TrackpadBox?
        private let pointer = CALayer()
        private var hideTimer: Timer?
        private static let arrow: CGImage? = {
            // A symbol is drawn, not a bitmap, so it's drawn once into one.
            let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            guard let symbol = UIImage(systemName: "cursorarrow", withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
            return UIGraphicsImageRenderer(size: symbol.size).image { _ in symbol.draw(at: .zero) }.cgImage
        }()
        override init(frame: CGRect) {
            super.init(frame: frame)
            pointer.shadowColor = UIColor.black.cgColor
            pointer.shadowOpacity = 0.55; pointer.shadowRadius = 1.5; pointer.shadowOffset = CGSize(width: 0, height: 1)
            pointer.magnificationFilter = .linear
            layer.addSublayer(pointer)
            setImage()
        }
        required init?(coder: NSCoder) { return nil }
        private func setImage() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pointer.contents = image ?? Self.arrow
            CATransaction.commit()
        }
        func place(_ m: CGPoint) {
            let at = map.point(m)
            let size: CGSize, hot: CGPoint
            if let image {
                // The Mac's cursor in its own pixels, at the picture's scale.
                size = CGSize(width: CGFloat(image.width) * map.scale, height: CGFloat(image.height) * map.scale)
                hot = CGPoint(x: hotspot.x * map.scale, y: hotspot.y * map.scale)
            } else {
                size = CGSize(width: 16, height: 20); hot = CGPoint(x: 3, y: 2)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pointer.frame = CGRect(x: at.x - hot.x, y: at.y - hot.y, width: size.width, height: size.height)
            CATransaction.commit()
            show()
        }
        // Always there beside a trackpad; touched directly, it fades a moment after the last touch.
        private func show() {
            if pointer.opacity < 1 { pointer.opacity = 1 }
            hideTimer?.invalidate()
            guard !map.always else { return }
            let last = pad?.lastTouch ?? 0
            let left = max(0.05, 1.5 - (Date().timeIntervalSinceReferenceDate - last))
            hideTimer = Timer.scheduledTimer(withTimeInterval: left, repeats: false) { [weak self] _ in
                guard let self else { return }
                if Date().timeIntervalSinceReferenceDate - (self.pad?.lastTouch ?? 0) >= 1.45 { self.pointer.opacity = 0 }
            }
        }
        func stop() { hideTimer?.invalidate() }
    }
}

// The picture and the trackpad, each read as a Mac's trackpad would be, which SwiftUI's own gestures can't do.
//  - On the picture: a tap clicks there, two fingers right-click, a held finger right-clicks, a finger drags (from where
//    it landed), two fingers scroll and pinch, three and four are the Mac's gestures.
//  - On the trackpad: one finger is GestureClassifier's (pointer, taps, drags, press to click), read from the raw
//    touches with no dead zone; two to five fingers scroll, pinch and swipe.
struct TouchSurface: UIViewRepresentable {
    enum Mode { case picture, trackpad }
    var mode: Mode
    var macWidth: CGFloat = 0
    // Two fingers in from the left edge go back, from the right forward, only while scrolling can't carry the swipe
    // between pages itself; with smooth scrolling, the right edge brings in Notification Centre, as on a Mac.
    var edgeBack = true
    var onTap: (CGPoint) -> Void = { _ in }
    var onTwoFingerTap: (CGPoint) -> Void = { _ in }
    var onSmartZoom: (CGPoint) -> Void = { _ in }
    var onLongPress: (CGPoint) -> Void = { _ in }
    var onDrag: (TouchPhase, CGPoint, CGSize) -> Void = { _, _, _ in }
    var onTrack: (GestureClassifier.Out) -> Void = { _ in }
    var onScroll: (CGSize, ScrollStep) -> Void
    var onPinch: (TouchPhase, CGFloat, CGPoint) -> Void
    var onSwipe: (MacSwipe) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        let c = context.coordinator
        v.coordinator = c
        var recognizers: [UIGestureRecognizer] = []
        if mode == .picture {
            let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
            let two = UITapGestureRecognizer(target: c, action: #selector(Coordinator.twoTap(_:)))
            two.numberOfTouchesRequired = 2
            let twoTwice = UITapGestureRecognizer(target: c, action: #selector(Coordinator.smartZoom(_:)))
            twoTwice.numberOfTouchesRequired = 2; twoTwice.numberOfTapsRequired = 2
            // On the picture a two-finger tap waits a moment to tell a right click from smart zoom.
            two.require(toFail: twoTwice)
            let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.long(_:)))
            long.minimumPressDuration = 0.55
            long.allowableMovement = 6
            let drag = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.drag(_:)))
            drag.minimumNumberOfTouches = 1; drag.maximumNumberOfTouches = 1
            recognizers += [tap, two, twoTwice, long, drag]
        }
        let multi = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.multi(_:)))
        multi.minimumNumberOfTouches = 2; multi.maximumNumberOfTouches = 5
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        multi.delegate = c; pinch.delegate = c
        // On the trackpad a lift goes straight to the one-finger reading, not held back while these decide.
        if mode == .trackpad { multi.delaysTouchesEnded = false; pinch.delaysTouchesEnded = false }
        recognizers += [multi, pinch]
        for g in recognizers { v.addGestureRecognizer(g) }
        return v
    }
    func updateUIView(_ uiView: TouchView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ uiView: TouchView, coordinator: Coordinator) { coordinator.stopGlide(); coordinator.stopTicking() }

    final class TouchView: UIView {
        weak var coordinator: Coordinator?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator?.raw(.began, touches, event, in: self)
            super.touchesBegan(touches, with: event)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator?.raw(.moved, touches, event, in: self)
            super.touchesMoved(touches, with: event)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator?.raw(.ended, touches, event, in: self)
            super.touchesEnded(touches, with: event)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator?.raw(.cancelled, touches, event, in: self)
            super.touchesCancelled(touches, with: event)
        }
        // Three fingers here are the Mac's gestures, not the system's undo and copy.
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchSurface
        private var classifier = GestureClassifier()
        // Every surface, so a touch on either stops a glide started on the other.
        private static let all = NSHashTable<Coordinator>.weakObjects()
        static func touched() { for c in all.allObjects { c.stopGlide() } }
        init(_ parent: TouchSurface) { self.parent = parent; super.init(); Self.all.add(self) }
        // Two fingers can pinch and scroll at once, and whichever is really happening wins by distance.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }

        // MARK: Raw touches
        enum Raw { case began, moved, ended, cancelled }
        func raw(_ phase: Raw, _ touches: Set<UITouch>, _ event: UIEvent?, in v: UIView) {
            if phase == .began {
                // A finger coming down stops a glide at once, as it does on a Mac, and warms the feedback for the touch.
                Self.touched()
                ScreenHaptics.prepare()
                longFired = false
            }
            guard parent.mode == .trackpad else { return }
            classifier.pad = v.bounds.size
            classifier.macWidth = max(parent.macWidth, 1)
            for t in touches {
                let id = ObjectIdentifier(t).hashValue
                switch phase {
                case .began: emit(classifier.began(id, at: t.location(in: v), t: t.timestamp))
                case .moved:
                    // Every sample the display took, not only the last, so a quick finger moves the pointer smoothly.
                    for s in event?.coalescedTouches(for: t) ?? [t] {
                        emit(classifier.moved(id, to: s.location(in: v), t: s.timestamp))
                    }
                case .ended: emit(classifier.ended(id, t: t.timestamp))
                case .cancelled: emit(classifier.cancelled(id))
                }
            }
            if classifier.idle { stopTicking() } else { startTicking() }
        }
        private func emit(_ outs: [GestureClassifier.Out]) { for o in outs { parent.onTrack(o) } }
        private var ticker: CADisplayLink?
        private func startTicking() {
            guard ticker == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(ticked(_:)))
            l.add(to: .main, forMode: .common)
            ticker = l
        }
        func stopTicking() { ticker?.invalidate(); ticker = nil }
        @objc private func ticked(_ l: CADisplayLink) {
            emit(classifier.tick(t: CACurrentMediaTime()))
            if classifier.idle { stopTicking() }
        }

        // MARK: The picture's own gestures
        private var longFired = false
        private var ignoringDrag = false
        @objc func tap(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onTap(g.location(in: g.view)) } }
        @objc func twoTap(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onTwoFingerTap(g.location(in: g.view)) } }
        @objc func smartZoom(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onSmartZoom(g.location(in: g.view)) } }
        @objc func long(_ g: UILongPressGestureRecognizer) { if g.state == .began { longFired = true; parent.onLongPress(g.location(in: g.view)) } }
        @objc func drag(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            let at = g.location(in: g.view), delta = CGSize(width: t.x, height: t.y)
            switch g.state {
            case .began:
                // A held finger already right-clicked; moving it after doesn't also drag.
                ignoringDrag = longFired
                guard !ignoringDrag else { return }
                // The press goes down where the finger first landed, not where it had got to once the pan began.
                let start = CGPoint(x: at.x - t.x, y: at.y - t.y)
                parent.onDrag(.began, start, .zero); parent.onDrag(.changed, at, delta)
            case .changed: if !ignoringDrag { parent.onDrag(.changed, at, delta) }
            case .ended, .cancelled, .failed:
                if !ignoringDrag { parent.onDrag(.ended, at, .zero) }
                ignoringDrag = false
            default: break
            }
        }

        // MARK: Two to five fingers
        // What they mean is settled by how many came down and where: two scroll, or (from an edge) go back, forward or to
        // Notification Centre; three or four swipe; four pinch. A finger that lands a moment late still counts, until the
        // hand has really moved. A thumb resting at the trackpad's edge isn't one of them.
        // The two-to-five-finger rules live in MultiFingerClassifier, pure, so the build can run them; this feeds it.
        private var multiC = MultiFingerClassifier()
        private var pinching = false
        private var pinchAmount: CGFloat = 0

        private func spread(_ g: UIGestureRecognizer) -> CGFloat {
            let n = g.numberOfTouches
            guard n > 1, let v = g.view else { return 0 }
            var points: [CGPoint] = []
            for i in 0..<n { points.append(g.location(ofTouch: i, in: v)) }
            let cx = points.reduce(0) { $0 + $1.x } / CGFloat(n), cy = points.reduce(0) { $0 + $1.y } / CGFloat(n)
            return points.reduce(0) { $0 + hypot($1.x - cx, $1.y - cy) } / CGFloat(n)
        }
        // Touches that are really fingers: on the trackpad, less any resting thumb.
        private func count(_ g: UIGestureRecognizer) -> Int {
            parent.mode == .trackpad ? g.numberOfTouches - classifier.palms - classifier.undecided : g.numberOfTouches
        }
        @objc func multi(_ g: UIPanGestureRecognizer) {
            multiC.edgeBack = parent.edgeBack
            switch g.state {
            case .began, .changed:
                if g.state == .began { stopGlide(); multiC.began() }
                let t = g.translation(in: g.view)
                g.setTranslation(.zero, in: g.view)
                apply(multiC.changed(count: count(g), touches: g.numberOfTouches, at: g.location(in: g.view), width: g.view?.bounds.width ?? 0,
                                     delta: CGSize(width: t.x, height: t.y), spread: spread(g), pinching: pinching))
            case .ended, .cancelled, .failed:
                apply(multiC.ended(velocity: g.velocity(in: g.view), completed: g.state == .ended, pinching: pinching))
            default: break
            }
        }
        private func apply(_ outs: [MultiFingerClassifier.Out]) {
            for o in outs {
                switch o {
                case .scroll(let d, let step): parent.onScroll(d, step)
                case .swipe(let s): parent.onSwipe(s)
                case .glide(let v): glide(v)
                }
            }
        }

        // MARK: Momentum
        // After a flick the page keeps going and slows as a scroll view does, sent as the Mac's own momentum, until a
        // finger touches down again.
        private var link: CADisplayLink?
        private var coast = Glide(velocity: .zero)
        private var last: CFTimeInterval = 0
        private var gliding = false
        private func glide(_ v: CGPoint) {
            stopGlide()
            coast = Glide(velocity: v)
            last = CACurrentMediaTime()
            gliding = true
            parent.onScroll(.zero, .momentumBegan)
            let l = CADisplayLink(target: self, selector: #selector(glideTick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        @objc private func glideTick(_ l: CADisplayLink) {
            let now = CACurrentMediaTime()
            let dt = max(0, min(now - last, 0.05)); last = now
            guard let d = coast.step(dt) else { stopGlide(); return }
            parent.onScroll(d, .momentum)
        }
        func stopGlide() {
            link?.invalidate(); link = nil
            if gliding { gliding = false; parent.onScroll(.zero, .momentumEnded) }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            let at = g.location(in: g.view)
            // Three or more fingers are a gesture of their own, never a zoom.
            if g.numberOfTouches > 2 || multiC.fingers >= 3 {
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
struct CursorOverlay: View {
    let screen: RemoteScreen
    let pad: TrackpadBox
    var map: CursorMap
    var image: CGImage?
    var hotspot: CGPoint
    var body: some View { Color.clear }
}
struct TouchSurface: View {
    enum Mode { case picture, trackpad }
    var mode: Mode
    var macWidth: CGFloat = 0
    var edgeBack = true
    var onTap: (CGPoint) -> Void = { _ in }
    var onTwoFingerTap: (CGPoint) -> Void = { _ in }
    var onSmartZoom: (CGPoint) -> Void = { _ in }
    var onLongPress: (CGPoint) -> Void = { _ in }
    var onDrag: (TouchPhase, CGPoint, CGSize) -> Void = { _, _, _ in }
    var onTrack: (GestureClassifier.Out) -> Void = { _ in }
    var onScroll: (CGSize, ScrollStep) -> Void
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

// Shifted sideways just enough to keep its whole width on the display, with a 12 pt margin.
struct EdgeClamped<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var shift: CGFloat = 0
    var body: some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                let width = EdgeClamped.displayWidth, base = f.minX - shift
                let want = base < 12 ? 12 - base : (base + f.width > width - 12 ? width - 12 - (base + f.width) : 0)
                if abs(want - shift) > 0.5 { shift = want }
            }
            .offset(x: shift)
    }
    @MainActor static var displayWidth: CGFloat {
        #if os(iOS)
        return UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.width ?? 400
        #else
        return 10_000
        #endif
    }
}
