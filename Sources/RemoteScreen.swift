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
final class FrameBuffer {
    let bytes: UnsafeMutableRawPointer
    let size: Int
    init(size: Int) { self.size = size; bytes = calloc(max(size, 1), 1) }
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
    @Published var image: CGImage?
    @Published var size = CGSize.zero
    // Where the Mac's pointer should be, kept here so the picture can follow it.
    @Published var cursor = CGPoint.zero

    private var socket: URLSessionWebSocketTask?
    private var buffer = Data()
    private var inflater = ZRLEInflater()
    private var frame = FrameBuffer(size: 0)
    private var trailingPublish: Task<Void, Never>?
    // Nothing is drawn while the screen is closed, so nothing is built either.
    var paused = false { didSet { if !paused { publish() } } }
    private var width = 0, height = 0
    private var buttons: UInt8 = 0
    private var lastPublish = Date.distantPast
    private var running = false
    private enum Stage { case version, security, result, serverInit, messages }
    private var stage = Stage.version
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
    func enteredBackground() {
        #if canImport(UIKit)
        // iOS gives a little time before it suspends the network.
        background = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackground() }
        #endif
    }
    private func endBackground() {
        #if canImport(UIKit)
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
        #endif
    }
    func enteredForeground() {
        endBackground()
        guard wanted, let base else { return }
        attempts = 0
        retry?.cancel()
        if !running || socket == nil { connect(base: base) }
        else { request(incremental: false) }   // a stale socket shows up as a failed send, which reconnects
    }
    func dropConnection() { socket?.cancel(with: .abnormalClosure, reason: nil) }

    private func scheduleRetry() {
        guard wanted, let base else { return }
        attempts += 1
        let wait = min(Double(attempts), 5)
        phase = .reconnecting
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if !Task.isCancelled, self?.wanted == true { self?.connect(base: base) }
        }
    }

    func connect(base: URL) {
        retry?.cancel()
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
        buffer = Data(); inflater = ZRLEInflater(); stage = .version; running = true; phase = image == nil ? .connecting : .reconnecting
        task.resume()
        Task { await receiveLoop(task, base: base) }
    }

    func disconnect() {
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if phase != .needsLogin { phase = .idle }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, base: URL) async {
        while running, socket === task {
            do {
                switch try await task.receive() {
                case .data(let d): buffer.append(d)
                case .string(let s): buffer.append(Data(s.utf8))
                @unknown default: break
                }
                try parse()
            } catch {
                guard running, socket === task else { return }
                let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                running = false
                socket = nil
                if code == 409 { phase = .needsLogin; return }
                // Dropped: try again quietly. Only say so if it keeps failing.
                if attempts >= 8 && image == nil { phase = .failed("Can’t reach the Mac’s screen."); return }
                scheduleRetry()
                return
            }
        }
    }

    private func take(_ n: Int) -> Data? {
        guard buffer.count >= n else { return nil }
        let out = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return out
    }
    private func send(_ bytes: [UInt8]) {
        let task = socket
        task?.send(.data(Data(bytes))) { [weak self] error in
            // A send on a socket iOS already killed fails here; the receive loop reconnects, but nudge it.
            if error != nil { Task { @MainActor in if self?.socket === task { self?.dropConnection() } } }
        }
    }
    private func be16(_ d: Data, _ i: Int) -> Int { Int(d[d.startIndex + i]) << 8 | Int(d[d.startIndex + i + 1]) }
    private func be32(_ d: Data, _ i: Int) -> Int { be16(d, i) << 16 | be16(d, i + 2) }

    private func parse() throws {
        while true {
            switch stage {
            case .version:
                guard take(12) != nil else { return }
                socket?.send(.data(Data("RFB 003.008\n".utf8))) { _ in }
                stage = .security
            case .security:
                guard let head = buffer.first, buffer.count >= 1 + Int(head), take(1 + Int(head)) != nil else { return }
                send([1])
                stage = .result
            case .result:
                guard let r = take(4) else { return }
                if be32(r, 0) != 0 { phase = .failed("Screen Sharing refused the connection."); running = false; return }
                send([1])
                stage = .serverInit
            case .serverInit:
                guard buffer.count >= 24 else { return }
                let nameLength = be32(buffer, 20)
                guard let head = take(24 + nameLength) else { return }
                width = be16(head, 0); height = be16(head, 2)
                frame = FrameBuffer(size: width * height * 4)
                size = CGSize(width: width, height: height)
                cursor = CGPoint(x: width / 2, y: height / 2)
                // 32-bit little-endian BGRA. ZRLE first, moved areas next, raw as the fallback, and being told of a resize.
                send([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
                send([2, 0, 0, 4,  0, 0, 0, 16,  0, 0, 0, 1,  0, 0, 0, 0,  255, 255, 255, 33])
                request(incremental: false)
                stage = .messages
                phase = .connected
                attempts = 0
            case .messages:
                guard let type = buffer.first else { return }
                switch type {
                case 0: if try !readUpdate() { return }
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

    private func readUpdate() throws -> Bool {
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
            default: phase = .failed("Unexpected screen data."); running = false; return false
            }
            guard buffer.count >= at else { return false }
        }
        var read = 4
        for _ in 0..<count {
            let x = be16(buffer, read), y = be16(buffer, read + 2), w = be16(buffer, read + 4), h = be16(buffer, read + 6)
            let encoding = Int32(truncatingIfNeeded: be32(buffer, read + 8))
            read += 12
            switch encoding {
            case 0:
                let offset = read
                buffer.withUnsafeBytes { src in
                    for row in 0..<h where y + row < height && x + w <= width {
                        memcpy(frame.bytes + ((y + row) * width + x) * 4, src.baseAddress! + offset + row * w * 4, w * 4)
                    }
                }
                read += w * h * 4
            case 1:
                copyRect(fromX: be16(buffer, read), fromY: be16(buffer, read + 2), x: x, y: y, w: w, h: h)
                read += 4
            case 16:
                let length = be32(buffer, read)
                let offset = read + 4
                let ok = buffer.withUnsafeBytes { src -> Bool in
                    guard let pixels = inflater.inflate(src.baseAddress! + offset, count: length) else { return false }
                    return drawZRLE(pixels, x: x, y: y, w: w, h: h)
                }
                guard ok else { phase = .failed("Unexpected screen data."); running = false; return false }
                read = offset + length
            default:
                // The Mac changed resolution: a new picture follows.
                width = w; height = h
                frame = FrameBuffer(size: width * height * 4)
                size = CGSize(width: width, height: height)
            }
        }
        buffer = Data(buffer.dropFirst(read))
        publish()
        request(incremental: true)
        return true
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
                    for i in 0..<total { guard let c = pixel() else { return false }; put(i, c) }
                case 1:
                    guard let c = pixel() else { return false }
                    for i in 0..<total { put(i, c) }
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

    private func publish() {
        guard !paused, width > 0 else { return }
        let since = Date().timeIntervalSince(lastPublish)
        // Too soon: come back once, so the last change of a burst is never left undrawn.
        guard since > 0.033 else {
            if trailingPublish == nil {
                trailingPublish = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((0.036 - since) * 1e9))
                    self?.trailingPublish = nil
                    self?.publish()
                }
            }
            return
        }
        guard let provider = frame.provider() else { return }
        lastPublish = Date()
        image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func request(incremental: Bool) {
        send([3, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)])
    }

    // MARK: Input
    func pointer(x: Int, y: Int, buttons mask: UInt8) {
        buttons = mask
        send([5, mask, UInt8((x >> 8) & 255), UInt8(x & 255), UInt8((y >> 8) & 255), UInt8(y & 255)])
    }
    func click(x: Int, y: Int, right: Bool = false) {
        let mask: UInt8 = right ? 4 : 1
        cursor = CGPoint(x: x, y: y)
        pointer(x: x, y: y, buttons: 0); pointer(x: x, y: y, buttons: mask); pointer(x: x, y: y, buttons: 0)
    }
    // Moves the pointer, keeping whatever button is held.
    func move(to p: CGPoint) {
        cursor = CGPoint(x: max(0, min(size.width - 1, p.x)), y: max(0, min(size.height - 1, p.y)))
        pointer(x: Int(cursor.x), y: Int(cursor.y), buttons: buttons)
    }
    func hold(_ down: Bool) { pointer(x: Int(cursor.x), y: Int(cursor.y), buttons: down ? 1 : 0) }
    func clickHere(right: Bool = false) { click(x: Int(cursor.x), y: Int(cursor.y), right: right) }
    private func wheel(_ mask: UInt8) {
        pointer(x: Int(cursor.x), y: Int(cursor.y), buttons: mask); pointer(x: Int(cursor.x), y: Int(cursor.y), buttons: 0)
    }
    func scroll(up: Bool) { wheel(up ? 8 : 16) }
    func scroll(left: Bool) { wheel(left ? 32 : 64) }
    func keyEvent(_ sym: UInt32, down: Bool) {
        send([4, down ? 1 : 0, 0, 0, UInt8((sym >> 24) & 255), UInt8((sym >> 16) & 255), UInt8((sym >> 8) & 255), UInt8(sym & 255)])
    }
    func key(_ sym: UInt32) { keyEvent(sym, down: true); keyEvent(sym, down: false) }
    // A key with modifiers held around it.
    func key(_ sym: UInt32, with modifiers: [UInt32]) {
        for m in modifiers { keyEvent(m, down: true) }
        key(sym)
        for m in modifiers.reversed() { keyEvent(m, down: false) }
    }
    // A stand-in picture, for the build's simulator shots, which have no Mac to connect to.
    func showSample() {
        wanted = false
        let w = 1680, h = 1050
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        c.setFillColor(CGColor(red: 0.12, green: 0.2, blue: 0.42, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)); c.fill(CGRect(x: 240, y: 200, width: 900, height: 620))
        c.setFillColor(CGColor(red: 0.78, green: 0.78, blue: 0.82, alpha: 1)); c.fill(CGRect(x: 240, y: 780, width: 900, height: 40))
        c.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.24, alpha: 0.9)); c.fill(CGRect(x: 0, y: 1020, width: w, height: 30))
        image = c.makeImage(); size = CGSize(width: w, height: h); cursor = CGPoint(x: 700, y: 500); phase = .connected
    }
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
