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
    // `cleared: false` for memory about to be written over in full, which needn't be cleared first.
    init(width: Int, height: Int, cleared: Bool = true) {
        self.width = max(width, 0); self.height = max(height, 0)
        let n = max(self.width * self.height * 4, 1)
        bytes = cleared ? calloc(n, 1) : malloc(n)
    }
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
    @Published private(set) var hasPicture = false { didSet { if !hasPicture, pictureShown { pictureShown = false } } }
    // The screen's layer has actually drawn a picture. Between a picture arriving and the layer's next refresh the
    // picture's space was black with only the pointer on it, for up to 0.3 s (the designer's fifth review): the waiting
    // sign stays until this.
    @Published private(set) var pictureShown = false
    func layerShowedPicture() { if !pictureShown { pictureShown = true } }
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
    // How long this connection took to sign in, show something and show the whole picture, for the measuring badge.
    var timings: ScreenTimings? { decoder?.timings() }
    // 32-bit colour when the link last measured fast enough that the whole first picture took under about half a
    // second at full colour (3 MB/s); 16-bit otherwise, and always until a link has been measured. The build can force
    // either with "screenDepth" (16 or 32).
    static var deepColour: Bool {
        let forced = UserDefaults.standard.integer(forKey: "screenDepth")
        if forced == 16 || forced == 32 { return forced == 32 }
        return UserDefaults.standard.double(forKey: "screenLinkSpeed") >= 3_000_000
    }
    // Keeps the link speed the first picture measured, for the next connection's choice of colour.
    private func remember(_ t: ScreenTimings) {
        guard let speed = t.throughput, !rememberedSpeed else { return }
        rememberedSpeed = true
        UserDefaults.standard.set(speed, forKey: "screenLinkSpeed")
        let f = { (v: Double?) in v.map { String(format: "%.2f s", $0) } ?? "–" }
        print("screen: \(t.deep ? 32 : 16)-bit, signed in \(f(t.signedIn)), first pixels \(f(t.firstPixels)), whole picture \(f(t.firstPicture)), \(t.firstBytes) bytes, \(Int(speed / 1024)) KB/s")
    }
    private var rememberedSpeed = false
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
        // Full colour only where the last picture came in fast (home Wi-Fi); otherwise 16-bit, less than half the bytes.
        // The new connection starts from the last picture, so it fills in over it, never over black.
        let decoder = ScreenDecoder(socket: task, pipeline: Self.pipeline, deep: Self.deepColour, seed: hasPicture ? self.decoder?.snapshot().0 : nil)
        self.decoder = decoder
        running = true; rememberedSpeed = false; phase = hasPicture ? .reconnecting : .connecting
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
        var told = false, toldWhole = false
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
            // And once more when the first picture is whole (the first may only have been its top), for its timing.
            let whole = !toldWhole && decoder.timings().firstPicture != nil
            if !state.isEmpty || firstPicture || whole {
                if firstPicture { told = true }
                if whole { toldWhole = true }
                guard let owner, await owner.handle(task, events: state, drew: told) else { return }
            }
            if decoder.stopped {
                // A stream that stopped making sense is closed and opened afresh, over the picture already there.
                if decoder.lostTrack { task.cancel(with: .abnormalClosure, reason: nil); await owner?.dropped(task, code: 0) }
                return
            }
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
            if let t = decoder?.timings(), t.firstPicture != nil { remember(t) }
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
            watchWhole()
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
    // The clock behind the whole picture, for as long as this connection lasts: four times a second at first, then once
    // a second. It asks the Mac again when that's due (an idle Mac sends nothing to prompt it). Nothing shows what
    // there is instead: a timeout that showed the parts so far was patches over black, his exact complaint, whenever
    // the whole picture was slow (the designer's fifth review). The waiting sign stays, and the asking goes on.
    private var wholeClock: Task<Void, Never>?
    private func watchWhole() {
        wholeClock?.cancel()
        guard let watched = decoder else { return }
        wholeClock = Task { [weak self] in
            var waited = 0.0
            while !Task.isCancelled {
                let step = waited < 5 ? 0.25 : 1.0
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000)); waited += step
                guard let self, !Task.isCancelled, self.running, self.decoder === watched else { return }
                if watched.wholeSettled { continue }
                watched.tickWhole()
            }
        }
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
    // How much of the first whole picture is in, for the wait before it's shown.
    var firstPictureProgress: Double? { decoder?.wholeProgress }
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

// Timings for one connection, in seconds from when it was opened, and the first full picture's size on the wire. For
// the measuring badge and the build's log: Richard, 2026-11-07, "takes too long to remote in like the screen draws slowly".
struct ScreenTimings: Sendable {
    var signedIn: Double?          // the Mac's first words (its ServerInit) reached the phone
    var firstPixels: Double?       // the first part of the picture was on screen
    var firstPicture: Double?      // the whole first picture was
    var firstBytes = 0             // what the first picture cost on the wire
    var deep = true                // 32-bit colour (or 16-bit)
    var throughput: Double?        // bytes a second while the first picture streamed in
}

// The Mac's side of the connection: reads the RFB stream, inflates ZRLE and paints the picture's memory. Only ever used
// by one message at a time, in order, from the receive loop, and never from the main thread.
//  - Colour: 16-bit unless the last connection showed a fast link. Apple's Screen Sharing sends the whole screen as one
//    ZRLE rectangle; 16-bit made the first one 0.77 MB against 1.82 MB at 32-bit on his Mac (2026-11-07), and on the
//    ~350 KB/s link his sessions showed that is 2.2 s against 5.2 s. It ignores Tight and JPEG, and an 8-bit format.
//  - Streaming: a rectangle is inflated and drawn tile by tile as its bytes arrive, and a big one is shown as it fills
//    in, top down, rather than only once its last byte is in.
//  - A reconnect starts from the last picture, so what's still to come is the old picture, never black.
final class ScreenDecoder: @unchecked Sendable {
    let socket: URLSessionWebSocketTask
    private let pipeline: Int
    // 4 bytes a pixel (32-bit, 3 on the wire in ZRLE) or 2 (16-bit, 5-6-5).
    let deep: Bool
    private var bytesPerPixel: Int { deep ? 4 : 2 }
    private var cpixel: Int { deep ? 3 : 2 }
    private let seed: FrameBuffer?
    private(set) var frame = FrameBuffer(width: 0, height: 0) { didSet { lock.lock(); shared = frame; lock.unlock() } }
    // What the main thread reads: the memory and how many pictures it has held, only ever swapped together, under the lock.
    private let lock = NSLock()
    private var shared = FrameBuffer(width: 0, height: 0)
    private var generation = 0
    // Each finished picture, copied, waiting for a display refresh of its own. Pipelined answers often land two in one
    // refresh, and showing only the newest lost one in five; a short queue shows them all, one per refresh.
    private var ready: [(FrameBuffer, Int)] = []
    private var latest: (FrameBuffer, Int)?
    // Two, not three: each one waiting is a display refresh (16 ms) between the Mac's change and the phone's pixels.
    static let queued = 2
    func snapshot() -> (FrameBuffer, Int) { lock.lock(); defer { lock.unlock() }; return (shared, generation) }
    // The oldest picture not yet shown, or, for a layer that has shown nothing of this connection yet, the newest.
    func next(after shown: Int, fresh: Bool) -> (FrameBuffer, Int)? {
        lock.lock(); defer { lock.unlock() }
        if !ready.isEmpty { return ready.removeFirst() }
        if let latest, fresh || latest.1 != shown { return latest }
        return nil
    }
    // Screen Sharing doesn't always answer the first request with the whole screen. Opened while the Mac's display is
    // asleep or still waking, it answers with a 2 × 2 rectangle and from then on sends only what changes, so the phone
    // showed black with a few live patches, or (on a reconnect) the old picture with a few new patches, until each part
    // of the Mac happened to redraw. Seen on every open from a dark display in three tries (2026-11-10), and asking
    // again got the whole picture 120 ms later each time. So: until a whole-screen rectangle has arrived on this
    // connection (and again after the Mac changes resolution), the whole screen is asked for again: at once when the
    // Mac's first answer wasn't it (when it's coming, it comes first), then every 2 s, and not at all once one
    // has begun to arrive, so a slow link is never made to carry the whole picture twice.
    private var haveWhole = false
    private var askedWhole = CFAbsoluteTimeGetCurrent()
    private var wholeAskGap = 0.3
    private var wholeBegun = false
    // With no earlier picture underneath, patches over black aren't shown: the first thing seen is the whole picture
    // filling in, however long that takes; it's asked for every 2 s until it comes.
    // Once the whole picture has begun to arrive it's waited for to its end, however long the link takes, and shown
    // in one piece: filling in top-down over black was still "stuff draws in so slowly" (Richard, 2026-11-10), and the
    // wait has a measure to show instead (`wholeProgress`).
    private var holdBack: Bool {
        !Self.noReask && !seeded && !haveWhole
    }
    // How much of the first whole picture has arrived, 0 to 1, while it's on its way; nil before and after.
    var wholeProgress: Double? { wholeLock.lock(); defer { wholeLock.unlock() }; return haveWhole ? nil : wholeFraction }
    private var wholeFraction: Double?
    private var askedFirst = CFAbsoluteTimeGetCurrent()
    // The build's way to film the old behaviour beside the new: "screenNoReask" never asks again and shows patches.
    static let noReask = UserDefaults.standard.bool(forKey: "screenNoReask")
    private var seeded = false
    // Whether the whole screen should be asked for again now, and if so the request to send. One gate for both
    // askers: the receive loop after each update, and the owner's clock (`tickWhole`), because a Mac sitting idle sends
    // no update to hang the asking on, and the phone would wait on black for as long as nothing on the Mac moved.
    private let wholeLock = NSLock()
    private var wholeRequest: [UInt8] = []
    private var paintedAny = false
    // Updates the Mac has finished sending since the whole screen was last asked for. One that wasn't the whole screen
    // is the sign it isn't coming (when it is, it comes first). With none at all, the Mac may simply not have answered
    // yet (on a slow link the whole picture is seconds in arriving), so the clock leaves it 4 s before asking again.
    private var updatesSinceAsk = 0
    private func takeWholeAsk() -> [UInt8]? {
        wholeLock.lock(); defer { wholeLock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        guard !haveWhole, !wholeBegun, !Self.noReask, !wholeRequest.isEmpty, now - askedWhole >= wholeAskGap,
              updatesSinceAsk > 0 || now - askedWhole >= 4 else { return nil }
        askedWhole = now; wholeAsks += 1; wholeAskGap = 2; updatesSinceAsk = 0
        return wholeRequest
    }
    private func whole(_ change: () -> Void) { wholeLock.lock(); change(); wholeLock.unlock() }
    private func askNext() {
        if let again = takeWholeAsk() { send(again) } else { request(incremental: true) }
    }
    // From the owner's clock, a few times a second: asks again when it's due, whether or not the Mac has sent anything.
    func tickWhole() { if let again = takeWholeAsk() { send(again) } }
    // True once a whole picture has arrived or begun to.
    var wholeSettled: Bool { wholeLock.lock(); defer { wholeLock.unlock() }; return haveWhole || wholeBegun }
    // How many times the whole picture had to be asked for again, for the measuring badge.
    private(set) var wholeAsks = 0
    // The stream stopped making sense (a message or encoding this doesn't know, or data that doesn't fit). What follows
    // can't be read, so nothing more is drawn from it and the owner opens a fresh connection over the last picture.
    // Before, an unknown message emptied the buffer and carried on, reading the middle of the next one as pixels.
    private(set) var lostTrack = false
    private func lose(_ why: String) { print("screen: lost track of the stream (\(why))"); lostTrack = true; stage = .stopped }

    // False when the picture was held back, and so nothing new is there to show.
    @discardableResult private func finished() -> Bool {
        // Copied here, off the main thread, so the layer gets a picture nothing writes into while it's on screen.
        // Nothing is shown of a first connection until its whole picture has begun: see `holdBack`.
        if holdBack { return false }
        let copy = FrameBuffer(width: frame.width, height: frame.height, cleared: false)
        memcpy(copy.bytes, frame.bytes, frame.size)
        lock.lock()
        generation += 1
        ready.append((copy, generation)); latest = (copy, generation)
        if ready.count > Self.queued { ready.removeFirst(ready.count - Self.queued) }
        lock.unlock()
        return true
    }
    // MARK: Timings
    private let opened = CFAbsoluteTimeGetCurrent()
    private var times = ScreenTimings()
    private var firstStreamStart: Double?
    func timings() -> ScreenTimings { lock.lock(); defer { lock.unlock() }; return times }
    private func mark(_ set: (inout ScreenTimings, Double) -> Void) {
        let t = CFAbsoluteTimeGetCurrent() - opened
        lock.lock(); set(&times, t); lock.unlock()
    }

    var stopped: Bool { stage == .stopped }
    private var buffer = Data()
    private var inflater = ZRLEInflater()
    private var width = 0, height = 0
    private enum Stage { case version, security, result, serverInit, messages, stopped }
    private var stage = Stage.version
    private var events: [ScreenEvent] = []
    init(socket: URLSessionWebSocketTask, pipeline: Int = 4, deep: Bool = true, seed: FrameBuffer? = nil) {
        self.socket = socket; self.pipeline = max(1, pipeline); self.deep = deep; self.seed = seed
        times.deep = deep
    }
    func feed(_ data: Data) -> [ScreenEvent] {
        events = []
        guard stage != .stopped else { return [] }
        buffer.append(data)
        if countingFirst { firstUpdateBytes += data.count }
        parse()
        return events
    }
    private func fail(_ message: String) { stage = .stopped; events.append(.failed(message)) }
    private func send(_ bytes: [UInt8]) { socket.send(.data(Data(bytes))) { _ in } }
    private func take(_ n: Int) -> Data? {
        guard buffer.count >= n else { return nil }
        let out = Data(buffer.prefix(n))
        drop(n)
        return out
    }
    private func drop(_ n: Int) { buffer.removeFirst(n); if buffer.isEmpty { buffer = Data() } }
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
                let fresh = FrameBuffer(width: width, height: height)
                if let seed, seed.width == width, seed.height == height { memcpy(fresh.bytes, seed.bytes, fresh.size); seeded = true }
                frame = fresh
                mark { $0.signedIn = $1 }
                // 32-bit little-endian BGRX, or 16-bit little-endian 5-6-5. ZRLE first, moved areas next, raw as the
                // fallback, being told of a resize, and the pointer's own picture (Cursor, -239), so the phone draws it
                // where the finger is with no wait.
                send(deep ? [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
                          : [0, 0, 0, 0, 16, 16, 0, 1, 0, 31, 0, 63, 0, 31, 11, 5, 0, 0, 0, 0])
                send([2, 0, 0, 5,  0, 0, 0, 16,  0, 0, 0, 1,  0, 0, 0, 0,  255, 255, 255, 33,  255, 255, 255, 17])
                // The whole picture first, then a few requests already waiting, so each change on the Mac is sent as
                // it happens instead of a round trip after the last one arrived.
                askedFirst = CFAbsoluteTimeGetCurrent()
                whole {
                    askedWhole = askedFirst
                    wholeRequest = [3, 0, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)]
                }
                request(incremental: false)
                for _ in 1..<pipeline { request(incremental: true) }
                stage = .messages
                events.append(.opened(width, height))
            case .messages:
                if inUpdate { if !continueUpdate() { return }; continue }
                guard let type = buffer.first else { return }
                switch type {
                case 0:
                    guard buffer.count >= 4 else { return }
                    rectsLeft = be16(buffer, 2)
                    // The first picture is counted from the first update until the whole screen has been painted once
                    // (the Mac may send the pointer, or nothing, before it).
                    if !sawFirstUpdate { sawFirstUpdate = true; countingFirst = true; firstUpdateBytes = buffer.count; firstStreamStart = CFAbsoluteTimeGetCurrent() }
                    drop(4)
                    inUpdate = true; painted = false; resized = false; empty = rectsLeft == 0
                case 1:
                    guard buffer.count >= 6 else { return }
                    let n = be16(buffer, 4)
                    guard take(6 + n * 6) != nil else { return }
                case 2: _ = take(1)
                case 3:
                    guard buffer.count >= 8 else { return }
                    guard take(8 + be32(buffer, 4)) != nil else { return }
                default: lose("message type \(type)"); return
                }
            }
        }
    }

    // MARK: Updates, read as they arrive
    private var inUpdate = false, rectsLeft = 0, painted = false, resized = false, empty = false
    private var sawFirstUpdate = false, countingFirst = false, firstUpdateBytes = 0, paintedArea = 0, wholeSeen = false
    private var bigStart: (Double, Int)?
    // The ZRLE rectangle being streamed: where it is, how much of its compressed data is still to come, which tile is
    // next, and what's been inflated but not yet drawn.
    private struct Streaming { var x, y, w, h: Int; var left: Int; var tileX = 0, tileY = 0 }
    private var streamingTotal = 1
    private var streaming: Streaming?
    private var inflated: [UInt8] = []
    private var inflatedAt = 0
    private var lastShown = 0.0
    private var shownRows = 0

    // Reads as much of the current update as has arrived. False when it needs more.
    private func continueUpdate() -> Bool {
        while rectsLeft > 0 {
            if streaming != nil {
                guard streamZRLE() else { return false }
                continue
            }
            guard buffer.count >= 12 else { return false }
            let x = be16(buffer, 0), y = be16(buffer, 2), w = be16(buffer, 4), h = be16(buffer, 6)
            let encoding = Int32(truncatingIfNeeded: be32(buffer, 8))
            switch encoding {
            case 16:
                guard buffer.count >= 16 else { return false }
                let length = be32(buffer, 12)
                guard x + w <= width, y + h <= height else { lose("a rectangle outside the screen"); return false }
                drop(16)
                painted = true; paintedArea += w * h
                whole { if w * h > 16 { paintedAny = true }; if w * h >= width * height * 3 / 4 { wholeBegun = true; wholeFraction = 0 } }
                streaming = Streaming(x: x, y: y, w: w, h: h, left: length)
                streamingTotal = max(length, 1)
                // The link's speed, from the first big rectangle streaming in: its bytes over the time they took.
                if countingFirst, w * h >= width * height / 4 { bigStart = (CFAbsoluteTimeGetCurrent(), length) }
                inflated.removeAll(keepingCapacity: true); inflatedAt = 0; shownRows = 0
            case 0:
                let length = w * h * bytesPerPixel
                guard buffer.count >= 12 + length else { return false }
                painted = true; paintedArea += w * h
                if w * h >= width * height * 3 / 4 { wholeSeen = true }
                whole { if w * h > 16 { paintedAny = true }; if w * h >= width * height * 3 / 4 { haveWhole = true; wholeBegun = true } }
                buffer.withUnsafeBytes { src in
                    let from = src.baseAddress! + 12
                    for row in 0..<h where y + row < height && x + w <= width {
                        let line = frame.bytes.assumingMemoryBound(to: UInt32.self) + (y + row) * width + x
                        if deep { memcpy(line, from + row * w * 4, w * 4) }
                        else { let p = (from + row * w * 2).assumingMemoryBound(to: UInt8.self); for col in 0..<w { line[col] = Self.wide(p[col * 2], p[col * 2 + 1]) } }
                    }
                }
                drop(12 + length); rectsLeft -= 1
            case 1:
                guard buffer.count >= 16 else { return false }
                painted = true
                copyRect(fromX: be16(buffer, 12), fromY: be16(buffer, 14), x: x, y: y, w: w, h: h)
                drop(16); rectsLeft -= 1
            case -239:
                // The pointer's picture, x and y being its hotspot: pixels, then a bitmask of which ones show.
                let length = w * h * bytesPerPixel, maskRow = (w + 7) / 8
                guard buffer.count >= 12 + length + maskRow * h else { return false }
                let image = buffer.withUnsafeBytes { src in Self.cursorImage(src.baseAddress! + 12, mask: src.baseAddress! + 12 + length, w: w, h: h, maskRow: maskRow, deep: deep) }
                events.append(.cursor(image, CGPoint(x: x, y: y)))
                drop(12 + length + maskRow * h); rectsLeft -= 1
            case -223:
                // The Mac changed resolution: a new picture follows.
                width = w; height = h
                frame = FrameBuffer(width: width, height: height)
                events.append(.resized(w, h))
                resized = true
                // The new size starts black: its whole picture is asked for until it comes, as on opening.
                // The picture already up stays until the new size's whole picture is in (3 s at most), rather than the
                // new size's patches over black: the Mac's display changing size with the Screen open (the bridge
                // making its own display, a monitor plugged in) looked like the drawing fault all over again.
                seeded = false; askedFirst = CFAbsoluteTimeGetCurrent()
                whole {
                    haveWhole = false; wholeBegun = false; wholeAskGap = 0.3; wholeFraction = nil
                    wholeRequest = [3, 0, 0, 0, 0, 0, UInt8(w >> 8), UInt8(w & 255), UInt8(h >> 8), UInt8(h & 255)]
                }
                drop(12); rectsLeft -= 1
            default:
                lose("encoding \(encoding)"); return false
            }
        }
        // The whole update is in.
        inUpdate = false
        // An update that only changed the pointer's picture leaves the screen's picture as it was.
        if painted || resized || empty, finished() {
            events.append(.drew)
            if countingFirst, painted { mark { t, now in if t.firstPixels == nil { t.firstPixels = now } } }
            // Whole once the full-screen answer is in: with requests already waiting, the Mac answers small changes (the
            // menu bar, its "being controlled" notice) before the whole screen, so painted area alone said whole too soon.
            if countingFirst, wholeSeen || paintedArea >= width * height * 3 {
                countingFirst = false
                let bytes = firstUpdateBytes - buffer.count, began = firstStreamStart
                mark { t, now in
                    t.firstPicture = now; t.firstBytes = bytes
                    if t.throughput == nil, let began { t.throughput = Double(bytes) / max(CFAbsoluteTimeGetCurrent() - began, 0.001) }
                }
            }
        }
        // One answered, one more asked for, so the same number always wait: the whole picture after a resize, and for as
        // long as this connection hasn't had one.
        if resized { whole { askedWhole = CFAbsoluteTimeGetCurrent(); updatesSinceAsk = 0 }; request(incremental: false) }
        else { whole { updatesSinceAsk += 1 }; askNext() }
        return true
    }

    // Inflates what has arrived of the current ZRLE rectangle and draws every tile that's complete. False when it needs more.
    private func streamZRLE() -> Bool {
        guard var s = streaming else { return true }
        let n = min(buffer.count, s.left)
        if n > 0 {
            let ok = buffer.withUnsafeBytes { src -> Bool in
                guard let out = inflater.inflate(src.baseAddress!, count: n) else { return false }
                inflated.append(contentsOf: out)
                return true
            }
            guard ok else { lose("data that wouldn't inflate"); return false }
            drop(n); s.left -= n
            if s.w * s.h >= width * height * 3 / 4 { let f = 1 - Double(s.left) / Double(streamingTotal); whole { if wholeFraction != nil { wholeFraction = f } } }
        }
        let result = inflated.withUnsafeBufferPointer { drawTiles($0, &s) }
        if result == .bad { lose("a tile that doesn't fit"); return false }
        // Drawn data is let go now and then, not on every tile.
        if inflatedAt > 1 << 18 { inflated.removeFirst(inflatedAt); inflatedAt = 0 }
        let done = s.tileY >= s.h
        if done {
            guard s.left == 0 else { lose("a rectangle longer than its picture"); return false }
            streaming = nil; rectsLeft -= 1
            if s.w * s.h >= width * height * 3 / 4 { wholeSeen = true; whole { haveWhole = true } }
            if let big = bigStart {
                bigStart = nil
                let span = CFAbsoluteTimeGetCurrent() - big.0
                lock.lock(); times.throughput = Double(big.1) / max(span, 0.001); lock.unlock()
            }
            return true
        }
        if s.left == 0 { lose("a rectangle shorter than its picture"); return false }
        streaming = s
        // A big rectangle (the first picture, a page scrolled on a slow link) is shown as it fills in, about 15 times a
        // second, rather than all at once after its last byte.
        if Self.progressive, s.w * s.h >= width * height / 4, s.tileY > shownRows {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastShown >= 0.066 {
                lastShown = now; shownRows = s.tileY
                guard finished() else { return false }
                events.append(.drew)
                if countingFirst { mark { t, at in if t.firstPixels == nil { t.firstPixels = at } } }
            }
        }
        return false
    }

    // The build's way to film the old behaviour beside the new: "screenNoStream" shows a picture only once it's whole.
    static let progressive = !UserDefaults.standard.bool(forKey: "screenNoStream")
    private enum TileResult { case drew, needMore, bad }
    // ZRLE: 64-pixel tiles in reading order, each solid, raw, palette or run-length, in compact pixels (3-byte blue,
    // green, red at 32-bit; 2-byte 5-6-5 at 16-bit). Draws every complete tile from where it left off; a tile whose data
    // isn't all in yet is drawn again from its start next time.
    private func drawTiles(_ data: UnsafeBufferPointer<UInt8>, _ s: inout Streaming) -> TileResult {
        while s.tileY < s.h {
            let th = min(64, s.h - s.tileY), tw = min(64, s.w - s.tileX)
            var at = inflatedAt
            switch drawTile(data, at: &at, x: s.x + s.tileX, y: s.y + s.tileY, tw: tw, th: th) {
            case .bad: return .bad
            case .needMore: return .needMore
            case .drew:
                inflatedAt = at
                s.tileX += tw
                if s.tileX >= s.w { s.tileX = 0; s.tileY += th }
            }
        }
        return .drew
    }
    private func drawTile(_ data: UnsafeBufferPointer<UInt8>, at: inout Int, x: Int, y: Int, tw: Int, th: Int) -> TileResult {
        let out = frame.bytes.assumingMemoryBound(to: UInt32.self)
        let end = data.count, size = cpixel, deep = self.deep
        @inline(__always) func color(_ i: Int) -> UInt32 {
            deep ? UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | 0xff00_0000 : Self.wide(data[i], data[i + 1])
        }
        guard at < end else { return .needMore }
        let kind = Int(data[at]); at += 1
        let origin = y * width + x
        let total = tw * th
        switch kind {
        case 0:
            // Row by row, without a division per pixel: these are most of a picture that's moving.
            guard at + total * size <= end else { return .needMore }
            for row in 0..<th {
                let line = out + origin + row * width
                for col in 0..<tw { line[col] = color(at); at += size }
            }
        case 1:
            guard at + size <= end else { return .needMore }
            let c = color(at); at += size
            for row in 0..<th { (out + origin + row * width).update(repeating: c, count: tw) }
        case 2...16:
            guard at + kind * size <= end else { return .needMore }
            var palette = [UInt32](); palette.reserveCapacity(kind)
            for _ in 0..<kind { palette.append(color(at)); at += size }
            let bits = kind == 2 ? 1 : kind <= 4 ? 2 : 4
            let rowBytes = (tw * bits + 7) / 8
            guard at + rowBytes * th <= end else { return .needMore }
            for row in 0..<th {
                var byte = 0, left = 0
                for col in 0..<tw {
                    if left == 0 { byte = Int(data[at]); at += 1; left = 8 }
                    left -= bits
                    let index = (byte >> left) & ((1 << bits) - 1)
                    guard index < kind else { return .bad }
                    out[origin + row * width + col] = palette[index]
                }
            }
        case 128, 130...255:
            var palette = [UInt32]()
            if kind != 128 {
                guard at + (kind - 128) * size <= end else { return .needMore }
                for _ in 0..<(kind - 128) { palette.append(color(at)); at += size }
            }
            var i = 0, col = 0
            var line = out + origin
            @inline(__always) func put(_ c: UInt32) {
                line[col] = c; col += 1; i += 1
                if col == tw { col = 0; line += width }
            }
            while i < total {
                var c: UInt32, run = 1
                if kind == 128 {
                    guard at + size <= end else { return .needMore }
                    c = color(at); at += size
                } else {
                    guard at < end else { return .needMore }
                    let v = Int(data[at]); at += 1
                    guard v & 127 < palette.count else { return .bad }
                    c = palette[v & 127]
                    if v & 128 == 0 { put(c); continue }
                }
                // A run's length is 1 plus every following byte, up to and including the first under 255.
                while true {
                    guard at < end else { return .needMore }
                    let more = Int(data[at]); at += 1
                    run += more
                    if more != 255 { break }
                }
                guard i + run <= total else { return .bad }
                for _ in 0..<run { put(c) }
            }
        default: return .bad
        }
        return .drew
    }
    // A 16-bit 5-6-5 pixel (little-endian) as the 32-bit BGRX the picture is kept in, from a table made once.
    private static let fiveSixFive: [UInt32] = (0..<65536).map { v in
        let r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31
        return UInt32((b << 3 | b >> 2) | (g << 2 | g >> 4) << 8 | (r << 3 | r >> 2) << 16) | 0xff00_0000
    }
    @inline(__always) static func wide(_ lo: UInt8, _ hi: UInt8) -> UInt32 { fiveSixFive[Int(lo) | Int(hi) << 8] }

    // The pointer's pixels (our pixel format) and a 1-bit mask, most significant bit first, into an image with real
    // transparency. An empty one (0 × 0) means the Mac hides its pointer.
    static func cursorImage(_ pixels: UnsafeRawPointer, mask: UnsafeRawPointer, w: Int, h: Int, maskRow: Int, deep: Bool = true) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let px = pixels.assumingMemoryBound(to: UInt8.self), mk = mask.assumingMemoryBound(to: UInt8.self)
        for row in 0..<h {
            for col in 0..<w {
                let shows = mk[row * maskRow + col / 8] & (0x80 >> UInt8(col % 8)) != 0
                guard shows else { continue }
                let i = (row * w + col) * 4
                if deep { out[i] = px[i + 2]; out[i + 1] = px[i + 1]; out[i + 2] = px[i] }
                else {
                    let c = wide(px[(row * w + col) * 2], px[(row * w + col) * 2 + 1])
                    out[i] = UInt8((c >> 16) & 255); out[i + 1] = UInt8((c >> 8) & 255); out[i + 2] = UInt8(c & 255)
                }
                out[i + 3] = 255
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
}
