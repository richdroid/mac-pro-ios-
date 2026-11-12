// Finds words on a screenshot and prints where they are, as fractions of its width and height ("x y"), for a tap that
// lands on them wherever the layout put them. Usage: find-text <png> <text> [nth] [minX]
// The whole recognised line must equal <text> (case-insensitive); nth (1-based) counts matches top to bottom; minX
// (a fraction) skips lines left of it. Prints nothing and exits 1 when there's no such line.
import Foundation
import Vision
import AppKit

let a = CommandLine.arguments
guard a.count >= 3, let img = NSImage(contentsOfFile: a[1]), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(2) }
let want = a[2].lowercased()
let nth = a.count > 3 ? Int(a[3]) ?? 1 : 1
let minX = a.count > 4 ? Double(a[4]) ?? 0 : 0
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = false
try? VNImageRequestHandler(cgImage: cg).perform([req])
var hits: [(Double, Double)] = []
for o in req.results ?? [] {
    guard let t = o.topCandidates(1).first?.string else { continue }
    let s = t.lowercased().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "✓◇⌃⌄"))
        .trimmingCharacters(in: .whitespaces)
    guard s == want else { continue }
    let b = o.boundingBox
    let x = Double(b.midX), y = 1 - Double(b.midY)
    if x >= minX { hits.append((x, y)) }
}
hits.sort { $0.1 < $1.1 }
guard hits.count >= nth else { exit(1) }
print(String(format: "%.4f %.4f", hits[nth - 1].0, hits[nth - 1].1))
