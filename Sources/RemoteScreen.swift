import Compression
import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// A native Screen Sharing client. The dashboard's bridge signs in to the Mac, so this side speaks plain RFB over
// a WebSocket with no login of its own. It asks for ZRLE, which is far smaller than raw pixels over a slow link.
// The picture's memory, shared with the image drawn from it, so a new image doesn't copy 15 MB each time.
// It carries its own dimensions, so a picture is always drawn at the size its memory was made for.
final class FrameBuffer {
    let bytes: UnsafeMutableRawPointer
    let width: Int, height: Int
    var size: Int { width * height * 4 }
    init(width: Int, height: Int) { self.width = max(width, 0); self.height = max(height, 0); bytes = calloc(max(self.width * self.height * 4, 1), 1) }
    deinit { free(bytes) }
    func provider() -> CGDataProvider? {
        CGDataProvider(dataInfo: Unmanaged.passRetained(self).toOpaque(), data: bytes, size: size) { info, _, _ in
            if let info { Unmanaged<FrameBuffer>.fromOpaque(info).release() }
        }
    }
}

@MainActor
final class RemoteScreen: ObservableObject {
    enum Phase: Equatable { case idle, connecting, reconnecting, connected, needsLogin, failed(String) }
    @Published var phase = Phase.idle
    // "Reconnecting…" only once a reconnect has taken over 1.5 s: coming back to the app, the picture is back within about a
    // second and the banner flashed for nothing, and it showed while the Mac could already be used (Richard, 2026-11-06).
    @Published private(set) var slowReconnect = false
    private var slowTimer: Task<Void, Never>?
    // Whether there's a picture to show. The pictures themselves never pass through SwiftUI: the screen's own layer
    // takes the newest one on each display refresh (see ScreenLayer).
    @Published private(set) var hasPicture = false
    @Published var size = CGSize.zero
    // Where the Mac's pointer should be. Not published: it changes at the touch rate, and a published value redrew the
    // whole screen view on every sample. Whoever draws the pointer listens through `cursorChanged` instead.
    var cursor = CGPoint.zero { didSet { if cursor != oldValue { cursorChanged?(cursor) } } }
    var cursorChanged: ((CGPoint) -> Void)?
    // The Mac's own pointer picture and its hotspot (in Mac pixels), from the Cursor pseudo-encoding, to be drawn on the
    // phone at `cursor` with no round trip. Nil until the Mac sends one, or while it hides the pointer.
    @Published private(set) var cursorImage: CGImage?
    @Published private(set) var cursorHotspot = CGPoint.zero
    // True once the bridge says it can post smooth pixel scrolls on the Mac (its input helper is trusted); until then,
    // scrolling goes as wheel steps.
    @Published private(set) var pixelScrollAvailable = false
    // For the measuring badge: the WebSocket round trip, and how many pointer moves went out in the last second.
    @Published private(set) var pingRTT: Double?
    @Published private(set) var movesPerSecond = 0
    // Modifier keys held for the next pointer action: click, hold and pixelScroll press them around what they send.
    var heldModifiers: [UInt32] = []

    private var socket: URLSessionWebSocketTask?
    // Reading the stream and painting the picture happen off the main thread, so touches never wait on a frame.
    private var decoder: ScreenDecoder?
    // The build's stand-in picture, when there's no Mac to connect to.
    private var sample: CGImage?
    // Nothing is drawn while the screen is closed: the layer that draws it is gone, and with it its display link.
    var paused = false
    private var width = 0, height = 0
    private var buttons: UInt8 = 0
    private var running = false
    // How many picture requests are kept in flight. One at a time waits a whole round trip for every picture, which over
    // Tailscale caps it near 1 / RTT; a few ahead let the Mac send each change as soon as it happens. The build's
    // measuring shot sets "screenPipeline" to 1 to film the old way beside the new.
    static var pipeline: Int { let v = UserDefaults.standard.integer(forKey: "screenPipeline"); return v > 0 ? min(v, 8) : 4 }
    // Pictures the Mac has sent on this connection, for the measuring overlay.
    var updates: Int { decoder?.snapshot().1 ?? 0 }
    private var base: URL?
    private var wanted = false          // someone wants the screen, so a drop means reconnect
    private var attempts = 0
    private var retry: Task<Void, Never>?
    private var closeLater: Task<Void, Never>?
    #if canImport(UIKit)
    private var background = UIBackgroundTaskIdentifier.invalid
    #endif

    // Keeps showing the last picture throughout, so a drop looks like nothing happened.
    func open(base: URL) {
        closeLater?.cancel()
        wanted = true
        self.base = base
        if running, socket != nil { return }
        attempts = 0
        connect(base: base)
    }
    // Leaving the view keeps the connection for a moment, so popping back is instant.
    func close() {
        closeLater?.cancel()
        closeLater = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if !Task.isCancelled { self?.wanted = false; self?.disconnect() }
        }
    }
    // Out of the app, the connection is kept for iOS's grace time so a quick trip away costs nothing, but nothing new is
    // ever opened there: a reconnect started in the background was suspended with the app before it could answer the
    // Mac, so the Mac woke its display for a phone that never spoke, and the session died at the bridge's first ping. His
    // log on 2026-11-06 held 16 of those, minutes apart, all night ("down 12 up 0"), each waking the Mac's display.
    private var inBackground = false
    private var backgrounded: Bool {
        #if canImport(UIKit)
        return inBackground || UIApplication.shared.applicationState == .background
        #else
        return inBackground
        #endif
    }
    func enteredBackground() {
        inBackground = true
        retry?.cancel()
        #if canImport(UIKit)
        // iOS gives a little time before it suspends the network. When it's up, the session is closed with a goodbye,
        // so the Mac lets it go at once rather than at its next ping, and coming back opens a fresh one straight away.
        endBackground()
        background = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in self?.leaveForNow(); self?.endBackground() }
        }
        #endif
    }
    private func endBackground() {
        #if canImport(UIKit)
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
        #endif
    }
    // Closes the session while the app is away, keeping the last picture to show on return.
    private func leaveForNow() {
        guard backgrounded else { return }
        retry?.cancel()
        stopMeasuring()
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if phase == .connected || phase == .connecting { phase = hasPicture ? .reconnecting : .idle }
        // The return starts its own 1.5 s before any "Reconnecting…".
        slowTimer?.cancel(); slowTimer = nil; slowReconnect = false
    }
    func enteredForeground() {
        inBackground = false
        endBackground()
        guard wanted, let base else { return }
        attempts = 0
        retry?.cancel()
        if !running || socket == nil { connect(base: base) }
        else if phase == .connected { checkAlive(); request(incremental: false) }
    }
    // A socket iOS killed while the app was away often takes a send without complaint, so the Mac is asked to answer a
    // ping: no answer in 2 s and a fresh connection starts at once, with no back-off.
    private var liveCheck: Task<Void, Never>?
    private var answeredCheck = 0
    private var checks = 0
    private func checkAlive() {
        guard let task = socket else { return }
        checks += 1
        let check = checks
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                if error == nil { self.answeredCheck = check } else { self.reconnectNow() }
            }
        }
        liveCheck?.cancel()
        liveCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, self.socket === task, self.answeredCheck < check else { return }
            self.reconnectNow()
        }
    }
    private func reconnectNow() {
        guard wanted, let base, !backgrounded else { return }
        attempts = 0
        connect(base: base)
    }
    func dropConnection() { socket?.cancel(with: .abnormalClosure, reason: nil) }

    private func watchSlowReconnect() {
        guard slowTimer == nil || slowTimer!.isCancelled else { return }
        slowTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.slowTimer = nil
            if self.phase == .reconnecting { self.slowReconnect = true }
        }
    }
    private func scheduleRetry() {
        guard wanted, let base else { return }
        // Away from the app the retry waits for the return (enteredForeground connects at once).
        if backgrounded { phase = hasPicture ? .reconnecting : .idle; slowTimer?.cancel(); slowTimer = nil; slowReconnect = false; return }
        attempts += 1
        let wait = min(Double(attempts), 5)
        phase = .reconnecting
        watchSlowReconnect()
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if !Task.isCancelled, let self, self.wanted, !self.backgrounded { self.connect(base: base) }
        }
    }

    func connect(base: URL) {
        retry?.cancel()
        liveCheck?.cancel()
        self.base = base
        guard !backgrounded else { return }
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        self.base = base
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = "/novnc/ws/vnc"
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 32 << 20
        socket = task
        let decoder = ScreenDecoder(socket: task, pipeline: Self.pipeline)
        self.decoder = decoder
        running = true; phase = hasPicture ? .reconnecting : .connecting
        watchSlowReconnect()
        task.resume()
        // A connection that hasn't started the picture in 14 s is given up and tried again, rather than left waiting for
        // good: one stuck that way kept "Reconnecting…" up until the screen was closed and opened (2026-11-06). Not
        // sooner: waking a sleeping display and signing in takes the bridge up to about 8 s (6.9 s seen 2026-11-07), and
        // an 8 s limit cut those off just before their picture, every time.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard let self, self.socket === task, !self.backgrounded, self.phase == .connecting || self.phase == .reconnecting else { return }
            task.cancel(with: .abnormalClosure, reason: nil)
        }
        Task.detached(priority: .userInitiated) { [weak self] in await Self.receiveLoop(task, decoder: decoder, owner: self) }
    }

    func disconnect() {
        running = false
        liveCheck?.cancel()
        stopMeasuring()
        flushTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if phase != .needsLogin { phase = .idle }
    }

    // Reads and paints entirely off the main thread, one message at a time, in order. A new picture only bumps the
    // decoder's count, which the display link picks up; the main thread hears only of a change of state.
    nonisolated private static func receiveLoop(_ task: URLSessionWebSocketTask, decoder: ScreenDecoder, owner screen: RemoteScreen?) async {
        weak var owner = screen
        var told = false
        while true {
            let data: Data
            do {
                switch try await task.receive() {
                case .data(let d): data = d
                // Text frames are the bridge's own notes (what it can do), never part of the Mac's stream.
                case .string(let s):
                    guard let owner, await owner.bridgeSaid(s, on: task) else { return }
                    continue
                @unknown default: continue
                }
            } catch {
                let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                await owner?.dropped(task, code: code)
                return
            }
            let events = decoder.feed(data)
            let state = events.filter { !$0.isDrawing }
            let firstPicture = !told && events.contains { $0.isDrawing }
            if !state.isEmpty || firstPicture {
                if firstPicture { told = true }
                guard let owner, await owner.handle(task, events: state, drew: told) else { return }
            }
            if decoder.stopped { return }
        }
    }
    // False once this socket is no longer the one wanted.
    private func handle(_ task: URLSessionWebSocketTask, events: [ScreenEvent], drew: Bool) -> Bool {
        guard running, socket === task else { return false }
        for e in events { apply(e) }
        if drew, !hasPicture { hasPicture = true }
        // A picture from this connection is the proof it's up: whatever the handshake's events said, the banner goes.
        // "Reconnecting…" stayed up over a live, working screen (Richard, 2026-11-07: "reconnecting still shows when im
        // connected").
        if drew {
            if phase == .reconnecting || phase == .connecting { phase = .connected }
            if slowReconnect || slowTimer != nil { slowTimer?.cancel(); slowTimer = nil; slowReconnect = false }
        }
        return running && socket === task
    }
    // {"pixelScroll":true} when the bridge's input helper can post smooth scrolls. False once this socket isn't wanted.
    private func bridgeSaid(_ text: String, on task: URLSessionWebSocketTask) -> Bool {
        guard running, socket === task else { return false }
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let on = o["pixelScroll"] as? Bool {
            pixelScrollAvailable = on
        }
        return true
    }
    private func dropped(_ task: URLSessionWebSocketTask, code: Int) {
        guard running, socket === task else { return }
        stopMeasuring()
        pixelScrollAvailable = false
        running = false
        socket = nil
        if code == 409 { phase = .needsLogin; return }
        // Dropped: try again quietly. Only say so if it keeps failing.
        if attempts >= 8 && !hasPicture { phase = .failed("Can’t reach the Mac’s screen."); return }
        scheduleRetry()
    }

    // The newest picture, if it's newer than the one on screen; asked on every display refresh. A new connection's
    // picture only takes over once it has drawn something, so a reconnect never flashes black.
    func newerPicture(than shown: inout ScreenLayerMark) -> CGImage? {
        if let d = decoder {
            let id = ObjectIdentifier(d)
            guard let (frame, gen) = d.next(after: shown.generation, fresh: shown.source != id),
                  frame.width > 0, frame.height > 0, let provider = frame.provider() else { return nil }
            shown = ScreenLayerMark(source: id, generation: gen)
            return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        if let sample, shown.generation != -1 { shown = ScreenLayerMark(source: nil, generation: -1); return sample }
        return nil
    }

    private func send(_ bytes: [UInt8]) {
        // Nothing of ours goes out until the handshake is done: a touch or key sent mid-handshake landed where the bridge
        // expected the phone's version, and the Mac ended the session at once ("mac side error … up 644", 2026-11-06).
        guard phase == .connected else { return }
        let task = socket
        task?.send(.data(Data(bytes))) { [weak self] error in
            // A send on a socket iOS already killed fails here; the receive loop reconnects, but nudge it.
            if error != nil { Task { @MainActor in if self?.socket === task { self?.dropConnection() } } }
        }
    }
    private func apply(_ e: ScreenEvent) {
        switch e {
        case .opened(let w, let h):
            width = w; height = h
            size = CGSize(width: w, height: h)
            cursor = CGPoint(x: w / 2, y: h / 2)
            phase = .connected
            slowTimer?.cancel(); slowReconnect = false
            attempts = 0
            // Tells the bridge this end speaks its extras; it answers in a text frame. A plain RFB bridge would pass the
            // message on to the Mac, which ignores a type it doesn't know only if it never sees one, so only ask ours.
            send([251, 0, 0, 0])
            startMeasuring()
        case .cursor(let image, let hotspot):
            cursorImage = image; cursorHotspot = hotspot
        case .resized(let w, let h):
            width = w; height = h
            size = CGSize(width: w, height: h)
        case .drew: break
        case .failed(let message): phase = .failed(message); running = false
        }
    }

    private func request(incremental: Bool) {
        send([3, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)])
    }

    // MARK: Input
    func pointer(x: Int, y: Int, buttons mask: UInt8) {
        // A pending move goes first, so a press never lands where the pointer was a frame ago.
        if pendingMove { pendingMove = false }
        buttons = mask
        sendPointer(x: x, y: y, mask: mask)
    }
    private func sendPointer(x: Int, y: Int, mask: UInt8) {
        send([5, mask, UInt8((x >> 8) & 255), UInt8(x & 255), UInt8((y >> 8) & 255), UInt8(y & 255)])
        movesThisSecond += 1
    }
    func click(x: Int, y: Int, right: Bool = false) {
        let mask: UInt8 = right ? 4 : 1
        cursor = CGPoint(x: x, y: y)
        let mods = heldModifiers
        for m in mods { keyEvent(m, down: true) }
        pointer(x: x, y: y, buttons: 0); pointer(x: x, y: y, buttons: mask); pointer(x: x, y: y, buttons: 0)
        for m in mods.reversed() { keyEvent(m, down: false) }
    }
    // Moves the pointer now, keeping whatever button is held.
    func move(to p: CGPoint) {
        cursor = clamped(p)
        pointer(x: Int(cursor.x), y: Int(cursor.y), buttons: buttons)
    }
    // Moves the pointer at most once per display refresh: touches arrive faster than that, and each one sent on its own
    // queues up behind the others over a slow link. The newest position wins; presses and keys flush it first.
    func moveCoalesced(to p: CGPoint) {
        cursor = clamped(p)
        pendingMove = true
        scheduleFlush()
    }
    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(max(size.width - 1, 0), p.x)), y: max(0, min(max(size.height - 1, 0), p.y)))
    }
    private var pendingMove = false
    private func flushMove() {
        guard pendingMove else { return }
        pendingMove = false
        sendPointer(x: Int(cursor.x), y: Int(cursor.y), mask: buttons)
    }
    #if canImport(UIKit)
    private final class Ticker: NSObject {
        let fire: () -> Void
        init(_ fire: @escaping () -> Void) { self.fire = fire }
        @objc func tick() { fire() }
    }
    private var flushTimer: CADisplayLink? { didSet { oldValue?.invalidate() } }
    private func scheduleFlush() {
        guard flushTimer == nil else { flushTimer?.isPaused = false; return }
        let link = CADisplayLink(target: Ticker { [weak self] in self?.displayTick() }, selector: #selector(Ticker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        flushTimer = link
    }
    private func displayTick() {
        if pendingMove { flushMove() } else { flushTimer?.isPaused = true }
    }
    #else
    private var flushTimer: Bool? = nil
    private func scheduleFlush() { DispatchQueue.main.async { [weak self] in self?.flushMove() } }
    #endif
    // Presses the button down (or lets it go) where the pointer is, with any held modifiers pressed around the hold.
    private var holdModifiers: [UInt32] = []
    func hold(_ down: Bool) {
        flushMove()
        if down {
            holdModifiers = heldModifiers
            for m in holdModifiers { keyEvent(m, down: true) }
            pointer(x: Int(cursor.x), y: Int(cursor.y), buttons: 1)
        } else {
            pointer(x: Int(cursor.x), y: Int(cursor.y), buttons: 0)
            for m in holdModifiers.reversed() { keyEvent(m, down: false) }
            holdModifiers = []
        }
    }
    func clickHere(right: Bool = false) { flushMove(); click(x: Int(cursor.x), y: Int(cursor.y), right: right) }
    // Wheel steps, as many as the fingers have earned, in one message. Positive is up (or left): the content comes
    // down (or right). A held button stays held throughout, so scrolling mid-drag doesn't drop what's being dragged.
    func scroll(lines: Int, columns: Int) {
        flushMove()
        let x = Int(cursor.x), y = Int(cursor.y)
        func event(_ mask: UInt8) -> [UInt8] { [5, mask, UInt8((x >> 8) & 255), UInt8(x & 255), UInt8((y >> 8) & 255), UInt8(y & 255)] }
        var bytes: [UInt8] = []
        let up = lines > 0, left = columns > 0
        for _ in 0..<min(abs(lines), 40) { bytes += event(buttons | (up ? 8 : 16)) + event(buttons) }
        for _ in 0..<min(abs(columns), 40) { bytes += event(buttons | (left ? 32 : 64)) + event(buttons) }
        if !bytes.isEmpty { send(bytes) }
    }

    // MARK: Smooth scrolling
    // A trackpad's scroll, as the Mac's own trackpad sends it: in points, with the phase of the fingers (began, changed,
    // ended) and then of the glide after they lift (momentum began, changed, ended). With those, apps scroll 1:1,
    // rubber-band at the ends and swipe between pages, as they do on the Mac itself.
    enum ScrollPhase { case none, began, changed, ended }
    enum MomentumPhase { case none, began, changed, ended }
    private var scrollRemainder = CGSize.zero
    private var wheelRemainder = CGSize.zero
    static let wheelLine: Double = 10
    // dx and dy are Mac points, in the direction the content moves: positive dy brings what's above into view.
    func pixelScroll(dx: Double, dy: Double, phase: ScrollPhase, momentum: MomentumPhase) {
        flushMove()
        guard pixelScrollAvailable else {
            // Without the bridge's helper: wheel steps, keeping the part of a step not yet earned, with the held
            // modifiers pressed around them.
            if phase == .began || momentum == .began { wheelRemainder = .zero }
            wheelRemainder.width += dx; wheelRemainder.height += dy
            let lines = Int(wheelRemainder.height / Self.wheelLine), columns = Int(wheelRemainder.width / Self.wheelLine)
            wheelRemainder.height -= Double(lines) * Self.wheelLine; wheelRemainder.width -= Double(columns) * Self.wheelLine
            guard lines != 0 || columns != 0 else { return }
            let mods = heldModifiers
            for m in mods { keyEvent(m, down: true) }
            scroll(lines: lines, columns: columns)
            for m in mods.reversed() { keyEvent(m, down: false) }
            return
        }
        if phase == .began || momentum == .began { scrollRemainder = .zero }
        scrollRemainder.width += dx; scrollRemainder.height += dy
        let x = Int(scrollRemainder.width.rounded(.towardZero)), y = Int(scrollRemainder.height.rounded(.towardZero))
        scrollRemainder.width -= Double(x); scrollRemainder.height -= Double(y)
        // The phase changes always go, even with nothing to move: an end with no distance still ends the gesture.
        let marks = phase != .changed && phase != .none || momentum != .changed && momentum != .none
        guard x != 0 || y != 0 || marks else { return }
        let sp: UInt8 = switch phase { case .none: 0; case .began: 1; case .changed: 2; case .ended: 4 }
        let mp: UInt8 = switch momentum { case .none: 0; case .began: 1; case .changed: 2; case .ended: 3 }
        let cx = Int16(clamping: x), cy = Int16(clamping: y)
        send([250, sp, mp, Self.modifierMask(heldModifiers),
              UInt8(UInt16(bitPattern: cx) >> 8), UInt8(UInt16(bitPattern: cx) & 255),
              UInt8(UInt16(bitPattern: cy) >> 8), UInt8(UInt16(bitPattern: cy) & 255)])
    }
    // The held modifiers as the bridge's helper wants them: 1 shift, 2 control, 4 option, 8 command.
    static func modifierMask(_ keys: [UInt32]) -> UInt8 {
        var m: UInt8 = 0
        for k in keys {
            switch k {
            case 0xffe1, 0xffe2: m |= 1
            case 0xffe3, 0xffe4: m |= 2
            case 0xffe9, 0xffea: m |= 4
            case 0xffe7, 0xffe8, 0xffeb, 0xffec: m |= 8
            default: break
            }
        }
        return m
    }

    // MARK: Keys
    func keyEvent(_ sym: UInt32, down: Bool) {
        flushMove()
        send([4, down ? 1 : 0, 0, 0, UInt8((sym >> 24) & 255), UInt8((sym >> 16) & 255), UInt8((sym >> 8) & 255), UInt8(sym & 255)])
    }
    // A key pressed on touch-down and let go on touch-up, so the Mac repeats a held key itself.
    func keyDown(_ sym: UInt32) { keyEvent(sym, down: true) }
    func keyUp(_ sym: UInt32) { keyEvent(sym, down: false) }
    func key(_ sym: UInt32) { keyEvent(sym, down: true); keyEvent(sym, down: false) }
    // A key with modifiers held around it.
    func key(_ sym: UInt32, with modifiers: [UInt32]) {
        for m in modifiers { keyEvent(m, down: true) }
        key(sym)
        for m in modifiers.reversed() { keyEvent(m, down: false) }
    }

    // MARK: Measuring
    // The WebSocket's own ping every two seconds (the bridge answers it at once), and the moves sent each second.
    private var measuring: Task<Void, Never>?
    private var movesThisSecond = 0
    private func startMeasuring() {
        measuring?.cancel()
        measuring = Task { [weak self] in
            var beat = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.movesPerSecond = self.movesThisSecond; self.movesThisSecond = 0
                beat += 1
                if beat % 2 == 0, let task = self.socket {
                    let sent = Date()
                    task.sendPing { [weak self] error in
                        let ms = Date().timeIntervalSince(sent) * 1000
                        Task { @MainActor in if error == nil, self?.socket === task { self?.pingRTT = ms } }
                    }
                }
            }
        }
    }
    private func stopMeasuring() { measuring?.cancel(); measuring = nil; pingRTT = nil; movesPerSecond = 0 }
    // A stand-in picture, for the build's simulator shots, which have no Mac to connect to.
    func showSample() {
        wanted = false
        let w = 1680, h = 1050
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        c.setFillColor(CGColor(red: 0.12, green: 0.2, blue: 0.42, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)); c.fill(CGRect(x: 240, y: 200, width: 900, height: 620))
        c.setFillColor(CGColor(red: 0.78, green: 0.78, blue: 0.82, alpha: 1)); c.fill(CGRect(x: 240, y: 780, width: 900, height: 40))
        c.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.24, alpha: 0.9)); c.fill(CGRect(x: 0, y: 1020, width: w, height: 30))
        sample = c.makeImage(); hasPicture = true; size = CGSize(width: w, height: h); cursor = CGPoint(x: 700, y: 500); phase = .connected
    }
    // For the build's shot of the screen when the Mac isn't logged in.
    func showNeedsLogin() { wanted = false; sample = nil; hasPicture = false; phase = .needsLogin }
    func type(_ text: String) {
        for scalar in text.unicodeScalars { key(scalar.value < 256 ? scalar.value : 0x0100_0000 | scalar.value) }
    }
    func fillLogin(username: String, password: String) {
        if !username.isEmpty { type(username); key(0xff09) }
        type(password)
        key(0xff0d)
    }
}

// One zlib stream runs across a whole connection, and each rectangle is the next stretch of it.
final class ZRLEInflater {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var ready = false
    private var skipHeader = 2       // Apple's decoder takes raw deflate, without zlib's 2-byte header
    private var output = [UInt8](repeating: 0, count: 1 << 20)
    deinit { if ready { compression_stream_destroy(&stream) } }
    // The pixels stay valid until the next call.
    func inflate(_ source: UnsafeRawPointer, count: Int) -> UnsafeBufferPointer<UInt8>? {
        if !ready {
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
            ready = true
        }
        var src = source.assumingMemoryBound(to: UInt8.self), left = count
        if skipHeader > 0 {
            let skip = min(skipHeader, left)
            src += skip; left -= skip; skipHeader -= skip
        }
        stream.src_ptr = src
        stream.src_size = left
        var produced = 0
        while true {
            if output.count - produced < 1 << 18 { output.append(contentsOf: repeatElement(0, count: output.count)) }
            let room = output.count - produced
            let status: compression_status = output.withUnsafeMutableBufferPointer { b in
                stream.dst_ptr = b.baseAddress! + produced
                stream.dst_size = room
                return compression_stream_process(&stream, 0)
            }
            guard status != COMPRESSION_STATUS_ERROR else { return nil }
            let made = room - stream.dst_size
            produced += made
            // Input can run out with output still inside the decoder, so it's only done once it has nothing more to give.
            if status == COMPRESSION_STATUS_END || (stream.src_size == 0 && made == 0) { break }
        }
        return output.withUnsafeBufferPointer { UnsafeBufferPointer(start: $0.baseAddress, count: produced) }
    }
}

enum ScreenEvent {
    case opened(Int, Int), resized(Int, Int), drew, failed(String), cursor(CGImage?, CGPoint)
    var isDrawing: Bool { if case .drew = self { return true }; return false }
}
// Which picture the layer is showing: the connection it came from and its number on that connection.
struct ScreenLayerMark { var source: ObjectIdentifier?; var generation = 0 }

// The Mac's side of the connection: reads the RFB stream, inflates ZRLE and paints the picture's memory. Only ever used
// by one message at a time, in order, from the receive loop, and never from the main thread.
final class ScreenDecoder: @unchecked Sendable {
    let socket: URLSessionWebSocketTask
    private let pipeline: Int
    private(set) var frame = FrameBuffer(width: 0, height: 0) { didSet { lock.lock(); shared = frame; lock.unlock() } }
    // What the main thread reads: the memory and how many pictures it has held, only ever swapped together, under the lock.
    private let lock = NSLock()
    private var shared = FrameBuffer(width: 0, height: 0)
    private var generation = 0
    // Each finished picture, copied, waiting for a display refresh of its own. Pipelined answers often land two in one
    // refresh, and showing only the newest lost one in five; a short queue shows them all, one per refresh.
    private var ready: [(FrameBuffer, Int)] = []
    private var latest: (FrameBuffer, Int)?
    static let queued = 3
    func snapshot() -> (FrameBuffer, Int) { lock.lock(); defer { lock.unlock() }; return (shared, generation) }
    // The oldest picture not yet shown, or, for a layer that has shown nothing of this connection yet, the newest.
    func next(after shown: Int, fresh: Bool) -> (FrameBuffer, Int)? {
        lock.lock(); defer { lock.unlock() }
        if !ready.isEmpty { return ready.removeFirst() }
        if let latest, fresh || latest.1 != shown { return latest }
        return nil
    }
    private func finished() {
        // Copied here, off the main thread, so the layer gets a picture nothing writes into while it's on screen.
        let copy = FrameBuffer(width: frame.width, height: frame.height)
        memcpy(copy.bytes, frame.bytes, frame.size)
        lock.lock()
        generation += 1
        ready.append((copy, generation)); latest = (copy, generation)
        if ready.count > Self.queued { ready.removeFirst(ready.count - Self.queued) }
        lock.unlock()
    }
    var stopped: Bool { stage == .stopped }
    private var buffer = Data()
    private var inflater = ZRLEInflater()
    private var width = 0, height = 0
    private enum Stage { case version, security, result, serverInit, messages, stopped }
    private var stage = Stage.version
    private var events: [ScreenEvent] = []
    init(socket: URLSessionWebSocketTask, pipeline: Int = 4) { self.socket = socket; self.pipeline = max(1, pipeline) }
    func feed(_ data: Data) -> [ScreenEvent] {
        events = []
        guard stage != .stopped else { return [] }
        buffer.append(data)
        parse()
        return events
    }
    private func fail(_ message: String) { stage = .stopped; events.append(.failed(message)) }
    private func send(_ bytes: [UInt8]) { socket.send(.data(Data(bytes))) { _ in } }
    private func take(_ n: Int) -> Data? {
        guard buffer.count >= n else { return nil }
        let out = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return out
    }
    private func request(incremental: Bool) {
        send([3, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)])
    }
    private func be16(_ d: Data, _ i: Int) -> Int { Int(d[d.startIndex + i]) << 8 | Int(d[d.startIndex + i + 1]) }
    private func be32(_ d: Data, _ i: Int) -> Int { be16(d, i) << 16 | be16(d, i + 2) }

    private func parse() {
        while true {
            switch stage {
            case .stopped: return
            case .version:
                guard take(12) != nil else { return }
                socket.send(.data(Data("RFB 003.008\n".utf8))) { _ in }
                stage = .security
            case .security:
                guard let head = buffer.first, buffer.count >= 1 + Int(head), take(1 + Int(head)) != nil else { return }
                send([1])
                stage = .result
            case .result:
                guard let r = take(4) else { return }
                if be32(r, 0) != 0 { fail("Screen Sharing refused the connection."); return }
                send([1])
                stage = .serverInit
            case .serverInit:
                guard buffer.count >= 24 else { return }
                let nameLength = be32(buffer, 20)
                guard let head = take(24 + nameLength) else { return }
                width = be16(head, 0); height = be16(head, 2)
                frame = FrameBuffer(width: width, height: height)
                // 32-bit little-endian BGRA. ZRLE first, moved areas next, raw as the fallback, being told of a resize,
                // and the pointer's own picture (Cursor, -239), so the phone draws it where the finger is with no wait.
                send([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
                send([2, 0, 0, 5,  0, 0, 0, 16,  0, 0, 0, 1,  0, 0, 0, 0,  255, 255, 255, 33,  255, 255, 255, 17])
                // The whole picture first, then a few requests already waiting, so each change on the Mac is sent as
                // it happens instead of a round trip after the last one arrived.
                request(incremental: false)
                for _ in 1..<pipeline { request(incremental: true) }
                stage = .messages
                events.append(.opened(width, height))
            case .messages:
                guard let type = buffer.first else { return }
                switch type {
                case 0: if !readUpdate() { return }
                case 1:
                    guard buffer.count >= 6 else { return }
                    let n = be16(buffer, 4)
                    guard take(6 + n * 6) != nil else { return }
                case 2: _ = take(1)
                case 3:
                    guard buffer.count >= 8 else { return }
                    guard take(8 + be32(buffer, 4)) != nil else { return }
                default: buffer = Data(); return
                }
            }
        }
    }

    private func readUpdate() -> Bool {
        guard buffer.count >= 4 else { return false }
        let count = be16(buffer, 2)
        // Nothing is touched until the whole update has arrived.
        var at = 4
        for _ in 0..<count {
            guard buffer.count >= at + 12 else { return false }
            let w = be16(buffer, at + 4), h = be16(buffer, at + 6), encoding = Int32(truncatingIfNeeded: be32(buffer, at + 8))
            at += 12
            switch encoding {
            case 0: at += w * h * 4
            case 1: at += 4
            case 16:
                guard buffer.count >= at + 4 else { return false }
                at += 4 + be32(buffer, at)
            case -223: break
            case -239: at += w * h * 4 + (w + 7) / 8 * h
            default: fail("Unexpected screen data."); return false
            }
            guard buffer.count >= at else { return false }
        }
        var read = 4
        var resized = false, painted = false
        for _ in 0..<count {
            let x = be16(buffer, read), y = be16(buffer, read + 2), w = be16(buffer, read + 4), h = be16(buffer, read + 6)
            let encoding = Int32(truncatingIfNeeded: be32(buffer, read + 8))
            read += 12
            switch encoding {
            case -239:
                // The pointer's picture, x and y being its hotspot: BGRA pixels, then a bitmask of which ones show.
                let length = w * h * 4, maskRow = (w + 7) / 8
                let image = buffer.withUnsafeBytes { src in Self.cursorImage(src.baseAddress! + read, mask: src.baseAddress! + read + length, w: w, h: h, maskRow: maskRow) }
                events.append(.cursor(image, CGPoint(x: x, y: y)))
                read += length + maskRow * h
            case 0:
                painted = true
                let offset = read
                buffer.withUnsafeBytes { src in
                    for row in 0..<h where y + row < height && x + w <= width {
                        memcpy(frame.bytes + ((y + row) * width + x) * 4, src.baseAddress! + offset + row * w * 4, w * 4)
                    }
                }
                read += w * h * 4
            case 1:
                painted = true
                copyRect(fromX: be16(buffer, read), fromY: be16(buffer, read + 2), x: x, y: y, w: w, h: h)
                read += 4
            case 16:
                painted = true
                let length = be32(buffer, read)
                let offset = read + 4
                let ok = buffer.withUnsafeBytes { src -> Bool in
                    guard let pixels = inflater.inflate(src.baseAddress! + offset, count: length) else { return false }
                    return drawZRLE(pixels, x: x, y: y, w: w, h: h)
                }
                guard ok else { fail("Unexpected screen data."); return false }
                read = offset + length
            default:
                // The Mac changed resolution: a new picture follows.
                width = w; height = h
                frame = FrameBuffer(width: width, height: height)
                events.append(.resized(w, h))
                resized = true
            }
        }
        buffer = Data(buffer.dropFirst(read))
        // An update that only changed the pointer's picture leaves the screen's picture as it was.
        if painted || resized || count == 0 {
            finished()
            events.append(.drew)
        }
        // One answered, one more asked for, so the same number always wait. After a resize the whole new picture.
        request(incremental: !resized)
        return true
    }
    // BGRA (our pixel format) and a 1-bit mask, most significant bit first, into an image with real transparency.
    // An empty one (0 × 0) means the Mac hides its pointer.
    static func cursorImage(_ pixels: UnsafeRawPointer, mask: UnsafeRawPointer, w: Int, h: Int, maskRow: Int) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let px = pixels.assumingMemoryBound(to: UInt8.self), mk = mask.assumingMemoryBound(to: UInt8.self)
        for row in 0..<h {
            for col in 0..<w {
                let shows = mk[row * maskRow + col / 8] & (0x80 >> UInt8(col % 8)) != 0
                guard shows else { continue }
                let i = (row * w + col) * 4
                out[i] = px[i + 2]; out[i + 1] = px[i + 1]; out[i + 2] = px[i]; out[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    private func copyRect(fromX: Int, fromY: Int, x: Int, y: Int, w: Int, h: Int) {
        guard fromX + w <= width, fromY + h <= height, x + w <= width, y + h <= height else { return }
        // Bottom up when moving down, so an overlap isn't overwritten before it's read.
        let rows = y > fromY ? Array((0..<h).reversed()) : Array(0..<h)
        for row in rows {
            memmove(frame.bytes + ((y + row) * width + x) * 4, frame.bytes + ((fromY + row) * width + fromX) * 4, w * 4)
        }
    }
    // ZRLE: 64-pixel tiles in reading order, each solid, raw, palette or run-length, in 3-byte blue, green, red.
    private func drawZRLE(_ data: UnsafeBufferPointer<UInt8>, x: Int, y: Int, w: Int, h: Int) -> Bool {
        guard x + w <= width, y + h <= height else { return false }
        let out = frame.bytes.assumingMemoryBound(to: UInt32.self)
        var at = 0
        let end = data.count
        func pixel() -> UInt32? {
            guard at + 3 <= end else { return nil }
            defer { at += 3 }
            return UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | 0xff00_0000
        }
        var tileY = 0
        while tileY < h {
            let th = min(64, h - tileY)
            var tileX = 0
            while tileX < w {
                let tw = min(64, w - tileX)
                guard at < end else { return false }
                let kind = Int(data[at]); at += 1
                let origin = (y + tileY) * width + x + tileX
                let total = tw * th
                func put(_ i: Int, _ c: UInt32) { out[origin + (i / tw) * width + i % tw] = c }
                switch kind {
                case 0:
                    // Row by row, without a division per pixel: these are most of a picture that's moving.
                    guard at + total * 3 <= end else { return false }
                    for row in 0..<th {
                        let line = out + origin + row * width
                        for col in 0..<tw {
                            line[col] = UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | 0xff00_0000
                            at += 3
                        }
                    }
                case 1:
                    guard let c = pixel() else { return false }
                    for row in 0..<th { (out + origin + row * width).update(repeating: c, count: tw) }
                case 2...16:
                    var palette = [UInt32](); palette.reserveCapacity(kind)
                    for _ in 0..<kind { guard let c = pixel() else { return false }; palette.append(c) }
                    let bits = kind == 2 ? 1 : kind <= 4 ? 2 : 4
                    for row in 0..<th {
                        var byte = 0, left = 0
                        for col in 0..<tw {
                            if left == 0 { guard at < end else { return false }; byte = Int(data[at]); at += 1; left = 8 }
                            left -= bits
                            let index = (byte >> left) & ((1 << bits) - 1)
                            guard index < kind else { return false }
                            out[origin + row * width + col] = palette[index]
                        }
                    }
                case 128, 130...255:
                    var palette = [UInt32]()
                    if kind != 128 { for _ in 0..<(kind - 128) { guard let c = pixel() else { return false }; palette.append(c) } }
                    var i = 0
                    while i < total {
                        var color: UInt32, run = 1
                        if kind == 128 {
                            guard let c = pixel() else { return false }
                            color = c
                        } else {
                            guard at < end else { return false }
                            let v = Int(data[at]); at += 1
                            guard v & 127 < palette.count else { return false }
                            color = palette[v & 127]
                            if v & 128 == 0 { put(i, color); i += 1; continue }
                        }
                        // A run's length is 1 plus every following byte, up to and including the first under 255.
                        while true {
                            guard at < end else { return false }
                            let more = Int(data[at]); at += 1
                            run += more
                            if more != 255 { break }
                        }
                        guard i + run <= total else { return false }
                        for _ in 0..<run { put(i, color); i += 1 }
                    }
                default: return false
                }
                tileX += tw
            }
            tileY += th
        }
        return true
    }

}
