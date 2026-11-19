// Shrinks one simulator film for the release: H.264 at a set bitrate, its long side at most 1100 px, frame timing kept.
// The simulator's own films ran 20 to 45 Mb/s (avconvert's 1280x720 preset kept most of that), so the films came to
// 1.7 GB and never went up (films.txt Not Found, runs 27 to 32). Usage: lfm-shrink in.mp4 out.mp4
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write("usage: lfm-shrink in.mp4 out.mp4\n".data(using: .utf8)!); exit(2) }
// Written beside the target and moved into place only when whole: a shrink cut off by the step's time limit must not
// leave a broken film that looks done.
let src = URL(fileURLWithPath: args[1]), final = URL(fileURLWithPath: args[2])
let dst = final.deletingLastPathComponent().appendingPathComponent(".part-" + final.lastPathComponent)
try? FileManager.default.removeItem(at: dst)

func fail(_ s: String) -> Never { FileHandle.standardError.write("lfm-shrink: \(s)\n".data(using: .utf8)!); exit(1) }

let asset = AVURLAsset(url: src)
let sem = DispatchSemaphore(value: 0)
var track: AVAssetTrack?
var natural = CGSize.zero
var transform = CGAffineTransform.identity
Task {
    track = try? await asset.loadTracks(withMediaType: .video).first
    if let t = track {
        natural = (try? await t.load(.naturalSize)) ?? .zero
        transform = (try? await t.load(.preferredTransform)) ?? .identity
    }
    sem.signal()
}
sem.wait()
guard let track, natural.width > 0, natural.height > 0 else { fail("no video track in \(src.lastPathComponent)") }

let longest: CGFloat = 1100
let k = min(1, longest / max(natural.width, natural.height))
// Even sizes, as the encoder wants.
let w = Int((natural.width * k / 2).rounded()) * 2, h = Int((natural.height * k / 2).rounded()) * 2

guard let reader = try? AVAssetReader(asset: asset) else { fail("can't read") }
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
out.alwaysCopiesSampleData = false
guard reader.canAdd(out) else { fail("can't add reader output") }
reader.add(out)

guard let writer = try? AVAssetWriter(outputURL: dst, fileType: .mp4) else { fail("can't write") }
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: w,
    AVVideoHeightKey: h,
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 1_600_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalDurationKey: 2,
    ],
])
input.transform = transform
input.expectsMediaDataInRealTime = false
guard writer.canAdd(input) else { fail("can't add writer input") }
writer.add(input)

guard reader.startReading() else { fail("reader: \(reader.error?.localizedDescription ?? "?")") }
guard writer.startWriting() else { fail("writer: \(writer.error?.localizedDescription ?? "?")") }
var started = false
let queue = DispatchQueue(label: "shrink")
let done = DispatchSemaphore(value: 0)
input.requestMediaDataWhenReady(on: queue) {
    while input.isReadyForMoreMediaData {
        guard let buf = out.copyNextSampleBuffer() else {
            input.markAsFinished()
            done.signal()
            return
        }
        if !started { writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buf)); started = true }
        if !input.append(buf) { reader.cancelReading(); input.markAsFinished(); done.signal(); return }
    }
}
done.wait()
let fin = DispatchSemaphore(value: 0)
writer.finishWriting { fin.signal() }
fin.wait()
guard writer.status == .completed, reader.status != .failed else {
    try? FileManager.default.removeItem(at: dst)
    fail("failed: \(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "?")")
}
try? FileManager.default.removeItem(at: final)
do { try FileManager.default.moveItem(at: dst, to: final) } catch { fail("can't move into place: \(error.localizedDescription)") }
