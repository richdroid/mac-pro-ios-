// The Mac Pro launch screen's glow as @2x and @3x PNGs, the same as Status's own: white at 0.18 from 4 pt out to clear at
// 96 pt, on 190 pt. Drawn here rather than kept as a vector PDF, which the launch screen didn't draw.
// Usage: swift ci/launch-glow.swift Assets.xcassets/LaunchHero.imageset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = CommandLine.arguments[1]
for scale in [2, 3] {
    let side = 190 * scale
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colors = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    let c = CGPoint(x: side / 2, y: side / 2)
    ctx.drawRadialGradient(gradient, startCenter: c, startRadius: CGFloat(4 * scale), endCenter: c,
                           endRadius: CGFloat(96 * scale), options: [.drawsBeforeStartLocation])
    let url = URL(fileURLWithPath: "\(dir)/glow@\(scale)x.png")
    guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Can't write \(url.path)")
    }
    CGImageDestinationAddImage(out, ctx.makeImage()!, nil)
    if !CGImageDestinationFinalize(out) { fatalError("Can't write \(url.path)") }
}
