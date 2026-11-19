// The phone's own Screen decoder (Sources/RemoteScreen.swift, Sources/ScreenVideo.swift) run on a Mac over a stream the
// bridge's video helper made (mac-dash's screen-video.test.js, with an out dir): every picture must decode, and the
// pictures after the screen came to rest are measured against the true picture (PSNR, in dB: 40 and up is hard to
// tell from the original, 50 is as good as lossless).
//   swiftc -O -parse-as-library Sources/RemoteScreen.swift Sources/ScreenVideo.swift ci/screen-video-check.swift -o /tmp/screen-video-check
//   /tmp/screen-video-check <out dir>
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

@main
struct ScreenVideoCheck {
    static func psnr(_ picture: CVPixelBuffer, _ truth: Data, _ w: Int, _ h: Int) -> Double {
        CVPixelBufferLockBaseAddress(picture, .readOnly); defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(picture)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(picture)
        var sum = 0.0
        truth.withUnsafeBytes { (t: UnsafeRawBufferPointer) in
            let tb = t.bindMemory(to: UInt8.self)
            for y in 0..<h { for x in 0..<w { for c in 0..<3 {
                let d = Double(Int(base[y * row + x * 4 + c]) - Int(tb[(y * w + x) * 4 + c])); sum += d * d
            } } }
        }
        let mse = sum / Double(w * h * 3)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
    // A corner of a picture (the window's top left, 420 x 260), three times its size, to look at.
    static func dump(_ picture: CVPixelBuffer?, _ truth: Data?, _ w: Int, _ h: Int, _ to: URL) {
        let cw = 420, ch = 260, x0 = 250, y0 = 130
        guard let c = CGContext(data: nil, width: cw * 3, height: ch * 3, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        c.interpolationQuality = .none
        var image: CGImage?
        if let picture { image = ScreenVideoDecoder.image(picture) }
        else if let truth, let p = CGDataProvider(data: truth as CFData) {
            image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let image, let crop = image.cropping(to: CGRect(x: x0, y: y0, width: cw, height: ch)) else { return }
        c.draw(crop, in: CGRect(x: 0, y: 0, width: cw * 3, height: ch * 3))
        guard let out = c.makeImage(), let d = CGImageDestinationCreateWithURL(to as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, out, nil); CGImageDestinationFinalize(d)
    }
    static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        guard let stream = try? Data(contentsOf: dir.appendingPathComponent("phone.rfb")),
              let meta = try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("frames.json"))) as? [String: Any],
              let w = meta["width"] as? Int, let h = meta["height"] as? Int, let rests = meta["rests"] as? [[Double]], let frames = meta["frames"] as? [[String: Any]] else {
            print("FAIL: nothing to read in \(dir.path)"); exit(1)
        }
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:9/")!)
        let decoder = ScreenDecoder(socket: task)
        decoder.useVideo()
        // The bridge's own handshake first, as the phone hears it, then the stream.
        var all = Data("RFB 003.008\n".utf8) + Data([1, 1, 0, 0, 0, 0])
        all.append(stream)
        var pictures: [CVPixelBuffer] = [], drew = 0, opened = false, cursors = 0, at = 0
        let began = CFAbsoluteTimeGetCurrent()
        while at < all.count {
            let n = min(400, all.count - at)
            for e in decoder.feed(all.subdata(in: at..<(at + n)), from: task) {
                switch e {
                case .opened(let ow, let oh): opened = ow == w && oh == h
                case .drew: drew += 1
                case .cursor: cursors += 1
                case .failed(let m): print("FAIL: \(m)"); exit(1)
                default: break
                }
            }
            at += n
            while let (p, _) = decoder.video.next(after: pictures.count, fresh: false), pictures.count < decoder.video.frames { pictures.append(p) }
            if decoder.stopped { print("FAIL: the decoder lost track of the stream at byte \(at)"); exit(1) }
        }
        let took = CFAbsoluteTimeGetCurrent() - began
        print("\(frames.count) pictures sent, \(decoder.video.frames) decoded, \(drew) drawn, opened \(opened), \(String(format: "%.1f", took / Double(max(decoder.video.frames, 1)) * 1000)) ms each to read and decode")
        var fail = decoder.video.frames != frames.count || !opened || pictures.count != frames.count
        if pictures.first.map({ ScreenVideoDecoder.image($0) == nil }) ?? true { print("FAIL: a decoded picture made no image"); fail = true }
        for (i, rest) in rests.enumerated() {
            guard let truth = try? Data(contentsOf: dir.appendingPathComponent("still-\(i).bgra")), truth.count == w * h * 4 else { continue }
            var line = "rest \(i + 1):", last = 0.0, n = 0
            for (k, f) in frames.enumerated() where k < pictures.count {
                guard let sent = f["sent"] as? Double, sent >= rest[0] - 200, sent < rest[1] else { continue }
                last = psnr(pictures[k], truth, w, h); n += 1
                if n <= 16 { line += String(format: " %+.0f ms %.1f dB (%d KB),", sent - rest[0], last, ((f["bytes"] as? Int) ?? 0) / 1024) }
            }
            if ProcessInfo.processInfo.environment["DUMP"] != nil, let k = frames.lastIndex(where: { (($0["sent"] as? Double) ?? 0) < rest[1] }), k < pictures.count {
                dump(pictures[k], nil, w, h, dir.appendingPathComponent("rest-\(i)-decoded.png")); dump(nil, truth, w, h, dir.appendingPathComponent("rest-\(i)-true.png"))
            }
            print(line, String(format: "… settled at %.1f dB after %d pictures", last, n))
            if last < 38 { print("FAIL: the picture at rest \(i + 1) is \(String(format: "%.1f", last)) dB from the true one, wanted 38 or better"); fail = true }
        }
        print(fail ? "FAIL" : "PASS")
        exit(fail ? 1 : 0)
    }
}
