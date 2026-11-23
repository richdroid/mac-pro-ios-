// Turns a simulator film the right way up: simctl records the display as it is mounted, so a film taken open flat
// comes out a quarter turn anticlockwise and one taken open upright upside down. Re-encoded, so every player and frame
// reader sees it upright. Usage: swift ci/film-turn.swift IN.mp4 OUT.mp4 90|180, or a list of turns from given seconds
// for a film with a posture change in it ("180@0,90@12.4,180@19.1"): then drawn on a square, each part upright.
import AVFoundation
let a = CommandLine.arguments
let input = URL(fileURLWithPath: a[1]), output = URL(fileURLWithPath: a[2])
// (degrees, from second)
let turns: [(Int, Double)] = a[3].split(separator: ",").map { p in
    let f = p.split(separator: "@"); return (Int(f[0]) ?? 0, f.count > 1 ? Double(f[1]) ?? 0 : 0)
}
let turn = turns[0].0, square = turns.count > 1
let asset = AVURLAsset(url: input)
let done = DispatchSemaphore(value: 0)
var failed = false
Task {
    defer { done.signal() }
    do {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { failed = true; return }
        let size = try await track.load(.naturalSize), length = try await asset.load(.duration)
        let w = size.width, h = size.height, side = max(w, h)
        func transform(_ deg: Int) -> CGAffineTransform {
            var t: CGAffineTransform = deg == 180 ? CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
                : deg == 90 ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)      // a quarter turn clockwise
                : .identity
            if square {
                let out = deg == 90 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
                t = t.concatenating(CGAffineTransform(translationX: (side - out.width) / 2, y: (side - out.height) / 2))
            }
            return t
        }
        let t = transform(turn)
        let comp = AVMutableVideoComposition()
        comp.renderSize = square ? CGSize(width: side, height: side) : turn == 180 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        comp.frameDuration = CMTime(value: 1, timescale: 60)
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: length)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t, at: .zero)
        for (deg, from) in turns.dropFirst() { layer.setTransform(transform(deg), at: CMTime(seconds: from, preferredTimescale: 600)) }
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
