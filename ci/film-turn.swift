// Turns a simulator film the right way up: simctl records the display as it is mounted, so a film taken open flat
// comes out a quarter turn anticlockwise and one taken open upright upside down. Re-encoded, so every player and frame
// reader sees it upright. Usage: swift ci/film-turn.swift IN.mp4 OUT.mp4 90|180
import AVFoundation
let a = CommandLine.arguments
let input = URL(fileURLWithPath: a[1]), output = URL(fileURLWithPath: a[2]), turn = Int(a[3]) ?? 0
let asset = AVURLAsset(url: input)
let done = DispatchSemaphore(value: 0)
var failed = false
Task {
    defer { done.signal() }
    do {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { failed = true; return }
        let size = try await track.load(.naturalSize), length = try await asset.load(.duration)
        let w = size.width, h = size.height
        let t: CGAffineTransform = turn == 180 ? CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
            : CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)      // a quarter turn clockwise
        let comp = AVMutableVideoComposition()
        comp.renderSize = turn == 180 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        comp.frameDuration = CMTime(value: 1, timescale: 60)
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: length)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t, at: .zero)
        ins.layerInstructions = [layer]
        comp.instructions = [ins]
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { failed = true; return }
        ex.videoComposition = comp
        try? FileManager.default.removeItem(at: output)
        try await ex.export(to: output, as: .mp4)
    } catch { print("film-turn: \(error)"); failed = true }
}
done.wait()
exit(failed ? 1 : 0)
