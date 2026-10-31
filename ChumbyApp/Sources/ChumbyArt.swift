import SwiftUI
import WidgetKit

// The Chumby's own octopus and wordmark, parsed from the device's Flash files.
enum ChumbyArt {
    static let octBox = CGRect(x: -87.75, y: -62.5, width: 165.75, height: 127.25)
    static let wordBox = CGRect(x: 0.0, y: 0.0, width: 1937.25, height: 554.25)
    static let octBody = parse("M32 -62 Q44 -62 48 -57 L51 -52 L53 -46 L54 -40 L54 -34 L54 -32 L53 -25 L52 -16 L51 -9 Q51 -6 52 -4 L52 -2 L55 0 L58 2 L64 7 L72 16 L76 26 L78 31 L76 31 L70 30 L64 26 L58 23 L54 20 L48 15 Q44 13 41 12 L38 12 L38 14 L40 20 L43 28 L45 40 Q45 46 44 50 L42 55 L38 52 L32 44 L27 36 L24 30 L22 25 L20 20 L19 23 L16 28 Q15 32 14 41 Q12 51 8 58 L4 63 L1 65 L0 63 L-2 58 L-4 50 L-4 43 L-3 36 L-2 31 L-1 26 L0 23 L-4 25 Q-8 30 -12 37 L-17 45 L-23 52 L-29 58 L-32 60 L-33 54 Q-34 48 -32 42 L-29 36 L-27 30 L-23 24 L-21 19 L-24 21 L-30 25 L-36 29 L-42 36 L-48 43 L-54 49 L-56 52 L-57 47 L-57 38 L-55 30 L-52 25 L-47 19 L-43 14 L-47 14 L-52 14 L-57 14 L-63 15 L-71 16 L-79 17 L-84 17 L-88 17 L-87 16 L-82 12 L-73 6 L-64 2 L-57 0 L-44 -2 L-37 -2 L-36 -7 L-36 -13 L-37 -18 L-38 -24 L-39 -33 L-37 -43 L-34 -48 L-32 -50 L-28 -53 L-16 -58 L-5 -60 L6 -61 L20 -62 L32 -62 Z")
    static let octEyes = parse("M-10 -40 Q-4 -40 -1 -36 Q2 -33 2 -28 Q2 -23 -1 -20 Q-4 -16 -10 -16 Q-15 -16 -18 -20 Q-21 -23 -22 -28 Q-21 -33 -18 -36 Q-14 -40 -10 -40 Z M-4 -22 Q-2 -25 -2 -28 Q-2 -31 -4 -33 Q-6 -35 -10 -35 Q-13 -35 -15 -33 Q-17 -31 -17 -28 Q-17 -25 -15 -22 Q-13 -20 -10 -20 Q-6 -20 -4 -22 Z M26 -40 Q30 -40 33 -38 Q36 -35 36 -30 Q36 -26 33 -23 Q30 -20 26 -20 Q21 -20 18 -23 Q16 -26 16 -30 Q16 -35 18 -38 Q21 -40 26 -40 Z M26 -35 Q22 -34 21 -30 Q22 -26 26 -26 Q30 -26 30 -30 Q30 -34 26 -35 Z")
    static let word = parse("M212 236 Q199 228 185 224 Q171 219 156 219 Q142 219 129 224 Q117 228 108 237 Q99 246 94 258 Q88 270 88 284 Q88 298 94 310 Q99 322 108 331 Q118 340 130 345 Q143 350 157 350 L188 346 Q201 343 215 336 L208 409 Q180 422 143 422 Q115 422 89 412 Q64 402 44 384 Q24 367 12 341 Q0 316 0 284 Q0 252 12 226 Q24 200 44 182 Q64 164 89 154 Q114 145 141 145 Q167 145 189 150 Q210 155 228 165 L212 236 Z M531 232 L531 416 L445 416 L445 254 Q445 239 435 228 Q425 217 405 217 Q385 217 374 228 Q363 239 363 254 L363 416 L278 416 L278 0 L362 0 L362 176 L363 176 Q373 161 392 152 Q410 143 438 143 Q482 143 506 166 Q531 190 531 232 Z M668 152 L668 314 Q668 328 678 339 Q688 350 707 350 Q726 350 737 338 Q748 328 748 312 L748 152 L835 152 L835 416 L756 416 L756 380 L756 380 Q747 401 727 412 Q706 424 674 424 Q630 424 606 400 Q581 378 581 336 L581 152 L668 152 Z M1304 416 L1218 416 L1218 253 Q1218 238 1210 228 Q1202 217 1181 217 Q1160 217 1151 228 Q1141 239 1141 254 L1141 416 L1054 416 L1054 253 Q1054 238 1046 228 Q1038 217 1017 217 Q997 217 987 228 Q978 239 978 254 L978 416 L891 416 L891 151 L971 151 L971 187 L972 187 Q980 166 999 154 Q1019 143 1050 143 Q1079 143 1100 154 Q1120 165 1129 186 Q1137 167 1159 155 Q1181 143 1211 143 Q1256 143 1280 166 Q1304 190 1304 232 L1304 416 Z M1630 222 Q1641 247 1641 279 Q1641 310 1631 336 Q1622 362 1602 382 Q1582 402 1553 412 Q1524 424 1485 424 Q1443 424 1410 412 Q1377 400 1358 384 L1358 0 L1440 0 L1440 160 Q1448 154 1468 149 Q1486 143 1507 143 Q1535 143 1559 152 Q1583 162 1602 180 Q1620 197 1630 222 Z M1492 218 Q1473 218 1460 225 Q1446 232 1440 238 L1440 340 Q1446 344 1459 348 Q1471 352 1484 352 Q1517 352 1536 333 Q1556 314 1556 284 Q1555 270 1551 258 Q1546 246 1538 238 Q1530 228 1518 223 Q1506 218 1492 218 Z M1858 152 L1937 152 L1847 390 Q1832 430 1817 458 Q1801 486 1785 505 Q1768 524 1751 536 Q1734 547 1715 554 L1663 502 Q1695 490 1719 465 Q1743 440 1760 398 L1664 152 L1748 152 L1786 254 L1795 280 L1802 306 L1803 306 L1811 280 Q1815 266 1820 254 L1858 152 Z")

    static func parse(_ d: String) -> Path {
        var p = Path()
        let t = d.replacingOccurrences(of: "([MLQZ])", with: " $1 ", options: .regularExpression).split(separator: " ").map(String.init)
        var i = 0, cmd = ""
        func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(t[i]) ?? 0) }
        while i < t.count {
            if Double(t[i]) == nil { cmd = t[i]; i += 1; if cmd == "Z" { p.closeSubpath() }; continue }
            switch cmd {
            case "M": let x = n(), y = n(); p.move(to: CGPoint(x: x, y: y))
            case "L": let x = n(), y = n(); p.addLine(to: CGPoint(x: x, y: y))
            case "Q": let a = n(), b = n(), x = n(), y = n(); p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: a, y: b))
            default: i += 1
            }
        }
        return p
    }
}

struct ArtShape: Shape {
    let art: Path, box: CGRect
    func path(in r: CGRect) -> Path {
        let k = min(r.width / box.width, r.height / box.height)
        let t = CGAffineTransform(translationX: r.midX, y: r.midY).scaledBy(x: k, y: k).translatedBy(x: -box.midX, y: -box.midY)
        return art.applying(t)
    }
}

// The still octopus, for widgets and small places.
struct OctopusMark: View {
    var color: Color = Color(red: 0.17, green: 0.36, blue: 0.68)
    var eyes: Color = .white
    var blink: CGFloat = 1
    @Environment(\.widgetRenderingMode) private var mode
    var body: some View {
        ZStack {
            // A clear or tinted Home Screen flattens colours to one tone, so cut the eyes out of the body.
            if mode != .fullColor {
                var both = ChumbyArt.octBody
                let _ = both.addPath(ChumbyArt.octEyes)
                ArtShape(art: both, box: ChumbyArt.octBox).fill(color, style: FillStyle(eoFill: true))
            } else {
            ArtShape(art: ChumbyArt.octBody, box: ChumbyArt.octBox).fill(color, style: FillStyle(eoFill: true))
            ArtShape(art: ChumbyArt.octEyes, box: ChumbyArt.octBox).fill(eyes, style: FillStyle(eoFill: true))
                .scaleEffect(x: 1, y: blink, anchor: ChumbyPalette.eyeAnchor)
            }
        }
        .aspectRatio(ChumbyArt.octBox.width / ChumbyArt.octBox.height, contentMode: .fit)
    }
}

enum ChumbyPalette {
    static var eyeAnchor: UnitPoint {
        let b = ChumbyArt.octEyes.boundingRect
        return UnitPoint(x: (b.midX - ChumbyArt.octBox.minX) / ChumbyArt.octBox.width, y: (b.midY - ChumbyArt.octBox.minY) / ChumbyArt.octBox.height)
    }
    static func hex(_ h: UInt32) -> Color { Color(red: Double(h >> 16 & 255) / 255, green: Double(h >> 8 & 255) / 255, blue: Double(h & 255) / 255) }
    static func sea(_ dark: Bool) -> [Color] { dark ? [0x061a3f, 0x0a4a9c, 0x7a3a2a, 0x0b5f58, 0x3b2470].map(hex) : [0xdbe9fb, 0xa9cdf8, 0xffc477, 0x7be8bd, 0xfc8a63].map(hex) }
    static let orange = hex(0xfc5825), on = hex(0x29c77e)
    static func ink(_ dark: Bool) -> Color { dark ? hex(0xeef4ff) : hex(0x0b2a5c) }
    static func sub(_ dark: Bool) -> Color { dark ? hex(0xa4b7d6) : hex(0x54688c) }
    static func acc(_ dark: Bool) -> Color { dark ? hex(0x79bbff) : hex(0x0051bd) }
    static func oct(_ dark: Bool) -> Color { dark ? hex(0x79bbff) : hex(0x2c5bae) }
    static func word(_ dark: Bool) -> Color { dark ? hex(0xeaf3ff) : hex(0x0a57b4) }
}

// A still version of the web app's sea: soft colour blobs.
struct StillSea: View {
    let dark: Bool
    var body: some View {
        let c = ChumbyPalette.sea(dark)
        GeometryReader { g in
            let m = max(g.size.width, g.size.height)
            ZStack {
                c[0]
                Circle().fill(c[1]).frame(width: m * 0.9).offset(x: -m * 0.35, y: -m * 0.3)
                Circle().fill(c[2]).frame(width: m * 0.6).offset(x: m * 0.4, y: -m * 0.1)
                Circle().fill(c[3]).frame(width: m * 0.65).offset(x: -m * 0.2, y: m * 0.4)
                Circle().fill(c[4]).frame(width: m * 0.42).offset(x: m * 0.32, y: m * 0.36)
            }
            .frame(width: g.size.width, height: g.size.height)
            .blur(radius: m * 0.09)
        }
    }
}
