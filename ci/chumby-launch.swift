// The Chumby launch screen's sea and wordmark as PNGs, drawn from the SVGs kept in their imagesets. The launch screen drew
// nothing but black from the SVGs themselves, so it gets plain pictures, and the SVGs are taken out of the build once drawn.
// Only what those files use is read: one rect, radial gradients, circles, and paths of M, L, Q and Z with translate and scale.
// Usage: swift ci/chumby-launch.swift ChumbyApp/Assets.xcassets
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func attrs(_ tag: String) -> [String: String] {
    let re = try! NSRegularExpression(pattern: #"([a-zA-Z-]+)="([^"]*)""#)
    var out: [String: String] = [:]
    for m in re.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
        out[String(tag[Range(m.range(at: 1), in: tag)!])] = String(tag[Range(m.range(at: 2), in: tag)!])
    }
    return out
}
func find(_ pattern: String, in s: String) -> [String] {
    let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
}
func num(_ s: String?) -> CGFloat { CGFloat(Double(s ?? "") ?? 0) }
func color(_ hex: String, _ alpha: CGFloat) -> CGColor {
    let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: alpha)
}

func draw(_ svg: String, scale: CGFloat, opaque: Bool, to url: URL) {
    let root = attrs(find(#"<svg\b[^>]*>"#, in: svg)[0])
    let box = (root["viewBox"] ?? "").split(separator: " ").map { num(String($0)) }
    let w = Int((num(root["width"]) * scale).rounded()), h = Int((num(root["height"]) * scale).rounded())
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
    // SVG runs down from the top left; flip, then fit the view box to the picture.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: CGFloat(w) / box[2], y: -CGFloat(h) / box[3])
    ctx.translateBy(x: -box[0], y: -box[1])

    var gradients: [String: (CGPoint, CGFloat, CGGradient)] = [:]
    for g in find(#"<radialGradient\b.*?</radialGradient>"#, in: svg) {
        let a = attrs(find(#"<radialGradient\b[^>]*>"#, in: g)[0])
        let stops = find(#"<stop\b[^>]*>"#, in: g).map(attrs)
        let colors = stops.map { color($0["stop-color"] ?? "#000000", $0["stop-opacity"].map { num($0) } ?? 1) }
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops.map { num($0["offset"]) })!
        gradients[a["id"] ?? ""] = (CGPoint(x: num(a["cx"]), y: num(a["cy"])), num(a["r"]), gradient)
    }
    for tag in find(#"<(rect|circle|path)\b[^>]*>"#, in: svg) {
        let a = attrs(tag)
        let fill = a["fill"] ?? "#000000"
        ctx.saveGState()
        if let t = a["transform"] {
            for op in find(#"(translate|scale)\([^)]*\)"#, in: t) {
                let n = find(#"-?[0-9]*\.?[0-9]+"#, in: op).map { num($0) }
                if op.hasPrefix("translate") { ctx.translateBy(x: n[0], y: n.count > 1 ? n[1] : 0) }
                else { ctx.scaleBy(x: n[0], y: n.count > 1 ? n[1] : n[0]) }
            }
        }
        let path = CGMutablePath()
        if tag.hasPrefix("<rect") {
            path.addRect(CGRect(x: num(a["x"]), y: num(a["y"]), width: num(a["width"]), height: num(a["height"])))
        } else if tag.hasPrefix("<circle") {
            let r = num(a["r"])
            path.addEllipse(in: CGRect(x: num(a["cx"]) - r, y: num(a["cy"]) - r, width: 2 * r, height: 2 * r))
        } else {
            var cmd = "", n: [CGFloat] = []
            func flush() {
                switch cmd {
                case "M": path.move(to: CGPoint(x: n[0], y: n[1]))
                case "L": path.addLine(to: CGPoint(x: n[0], y: n[1]))
                case "Q": path.addQuadCurve(to: CGPoint(x: n[2], y: n[3]), control: CGPoint(x: n[0], y: n[1]))
                default: break
                }
                n = []
            }
            for token in find(#"[MLQZ]|-?[0-9]*\.?[0-9]+"#, in: a["d"] ?? "") {
                if let c = token.first, c.isLetter {
                    if c == "Z" { path.closeSubpath(); cmd = "" } else { cmd = token }
                    continue
                }
                n.append(num(token))
                if n.count == (cmd == "Q" ? 4 : 2) { flush(); if cmd == "M" { cmd = "L" } }
            }
        }
        let evenOdd = a["fill-rule"] == "evenodd"
        if fill.hasPrefix("url(#"), let g = gradients[String(fill.dropFirst(5).dropLast())] {
            ctx.addPath(path)
            if evenOdd { ctx.clip(using: .evenOdd) } else { ctx.clip() }
            ctx.drawRadialGradient(g.2, startCenter: g.0, startRadius: 0, endCenter: g.0, endRadius: g.1, options: [])
        } else {
            ctx.setFillColor(color(fill, a["fill-opacity"].map { num($0) } ?? 1))
            ctx.addPath(path)
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        }
        ctx.restoreGState()
    }
    guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Can't write \(url.path)") }
    CGImageDestinationAddImage(out, ctx.makeImage()!, nil)
    if !CGImageDestinationFinalize(out) { fatalError("Can't write \(url.path)") }
}

let assets = CommandLine.arguments[1]
// The sea is soft all over, so @2x serves every phone and keeps the launch picture small; the wordmark gets both.
for (set, scales, opaque) in [("LaunchSea", [2], true), ("LaunchWord", [2, 3], false)] {
    let dir = URL(fileURLWithPath: "\(assets)/\(set).imageset")
    for name in [set, set + "-dark"] {
        let src = dir.appendingPathComponent(name + ".svg")
        guard let svg = try? String(contentsOf: src, encoding: .utf8) else { fatalError("Can't read \(src.path)") }
        for s in scales { draw(svg, scale: CGFloat(s), opaque: opaque, to: dir.appendingPathComponent("\(name)@\(s)x.png")) }
    }
    for name in [set, set + "-dark"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name + ".svg")) }
}
