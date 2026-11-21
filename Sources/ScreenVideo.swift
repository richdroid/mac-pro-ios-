import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// The Mac's screen as video. Screen Sharing itself only sends lossless pictures, 300 to 800 KB each when a page scrolls
// or a window is dragged, over a link that carries 350 to 800 KB/s: a second and more behind, one to three pictures a
// second. A bridge that says it can ({"video":true}) sends H.264 instead, in the same RFB stream, as rectangles of
// encoding "H264": about 10 KB a picture while things move, at a bitrate it fits to the link from this end's word on
// each picture (message 252), and sharpened once things are still.
//
// Decoded here by the system's own decoder, off the main thread, in the order they come; each picture then waits for a
// display refresh of its own, as the lossless ones do. The pictures are kept by this object, not by a video layer, so
// the last one stays up through a reconnect or a trip out of the app.
final class ScreenVideoDecoder: @unchecked Sendable {
    static let encoding: Int32 = 0x4832_3634
    // Three, where the lossless pictures keep two: these come 30 a second, a few at once after a hiccup on the link, and
    // each one shown is a step of the motion rather than a jump.
    static let queued = 3

    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var needsKey = true
    private var ready: [(CVPixelBuffer, Int)] = []
    private var latest: (CVPixelBuffer, Int)?
    private var count = 0
    // Pictures decoded so far, for the measuring badge.
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    // One picture as the bridge sent it: for a key picture [u16 n][SPS][u16 n][PPS] first, then the picture in AVCC.
    // False when it can't be shown and the bridge should be asked for a key picture (the first one hasn't come, or the
    // decoder was lost while the app was away).
    func take(key: Bool, _ body: UnsafeRawBufferPointer) -> Bool {
        guard let base = body.baseAddress else { return false }
        var at = 0
        if key {
            var sets: [(Int, Int)] = []
            for _ in 0..<2 {
                guard at + 2 <= body.count else { return false }
                let n = Int(body[at]) << 8 | Int(body[at + 1])
                guard at + 2 + n <= body.count else { return false }
                sets.append((at + 2, n)); at += 2 + n
            }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let pointers = [UnsafePointer(bytes + sets[0].0), UnsafePointer(bytes + sets[1].0)], sizes = [sets[0].1, sets[1].1]
            var made: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                      nalUnitHeaderLength: 4, formatDescriptionOut: &made) == 0, let made else { return false }
            if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: made) { format = made }
            else { start(made) }
            needsKey = session == nil
        }
        guard !needsKey, let session, let format, body.count > at else { return false }
        var n = body.count - at
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &block) == 0, let block,
              CMBlockBufferReplaceDataBytes(with: base + at, blockBuffer: block, offsetIntoDestination: 0, dataLength: n) == 0 else { return false }
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &n, sampleBufferOut: &sample) == 0, let sample else { return false }
        // Decoded before this returns: pictures come one at a time and in order, and this thread has nothing else to do.
        var picture: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == 0 { picture = image }
        }
        guard status == 0, let picture else {
            // The system takes its decoders back while the app is away; the next key picture starts a new one.
            forget()
            return false
        }
        lock.lock()
        count += 1
        ready.append((picture, count)); latest = (picture, count)
        if ready.count > Self.queued { ready.removeFirst(ready.count - Self.queued) }
        lock.unlock()
        return true
    }
    private func start(_ made: CMVideoFormatDescription) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil
        // Plain BGRA, as the lossless pictures are kept, so both are drawn the same way and in the same colours.
        let wanted = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: made, decoderSpecification: nil, imageBufferAttributes: wanted,
                                           outputCallback: nil, decompressionSessionOut: &s) == 0, let s else { return }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s; format = made
    }
    // Nothing more is decoded until a key picture comes. The pictures already decoded stay.
    func forget() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; needsKey = true
    }

    // The oldest picture not yet shown, or, for a layer that has shown nothing of this connection yet, the newest.
    func next(after shown: Int, fresh: Bool) -> (CVPixelBuffer, Int)? {
        lock.lock(); defer { lock.unlock() }
        if !ready.isEmpty { return ready.removeFirst() }
        if let latest, fresh || latest.1 != shown { return latest }
        return nil
    }
    // A decoded picture as an image over its own memory, which is held (and kept readable) for as long as the image is.
    static func image(_ picture: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(picture, .readOnly) == kCVReturnSuccess, let base = CVPixelBufferGetBaseAddress(picture) else { return nil }
        let w = CVPixelBufferGetWidth(picture), h = CVPixelBufferGetHeight(picture), row = CVPixelBufferGetBytesPerRow(picture)
        guard let provider = CGDataProvider(dataInfo: Unmanaged.passRetained(picture).toOpaque(), data: base, size: row * h, releaseData: { info, _, _ in
            guard let info else { return }
            let held = Unmanaged<CVPixelBuffer>.fromOpaque(info)
            CVPixelBufferUnlockBaseAddress(held.takeUnretainedValue(), .readOnly)
            held.release()
        }) else { CVPixelBufferUnlockBaseAddress(picture, .readOnly); return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    // The phone's word on a picture, for the bridge: which one it has, and whether it needs a key picture.
    static func word(seq: UInt32, needsKey: Bool) -> [UInt8] {
        [252, needsKey ? 1 : 0, 0, 0, UInt8((seq >> 24) & 255), UInt8((seq >> 16) & 255), UInt8((seq >> 8) & 255), UInt8(seq & 255)]
    }
}
