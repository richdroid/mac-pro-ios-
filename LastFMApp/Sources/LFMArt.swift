import Foundation
import SwiftUI
import ImageIO
import CoreImage
import CryptoKit

// A cover to show: Last.fm's picture when it has a real one, else the album found on Apple's store by name.
struct ArtRef: Hashable, Sendable {
    let artist: String
    let album: String
    let url: String?
    var key: String { "\(artist.lowercased())|\(album.lowercased())" }
}

// The colours a cover gives the page around it.
struct Palette: Sendable, Equatable, Codable {
    var vivid: RGB
    var deep: RGB
    var average: RGB
    struct RGB: Sendable, Equatable, Codable { var r: Double, g: Double, b: Double
        var color: Color { Color(red: r, green: g, blue: b) }
        func scaled(_ k: Double) -> RGB { RGB(r: r * k, g: g * k, b: b * k) }
    }
    // A colour made from a name, for a cover that hasn't come (or never will): the same name, the same colour.
    static func from(name: String) -> Palette {
        let h = Double(name.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % 360) / 360
        let v = RGB.hsv(h, 0.55, 0.85), d = RGB.hsv(h, 0.6, 0.28)
        return Palette(vivid: v, deep: d, average: d)
    }
}
extension Palette.RGB {
    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> Self {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6)), p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i { case 0: return .init(r: v, g: t, b: p); case 1: return .init(r: q, g: v, b: p); case 2: return .init(r: p, g: v, b: t)
        case 3: return .init(r: p, g: q, b: v); case 4: return .init(r: t, g: p, b: v); default: return .init(r: v, g: p, b: q) }
    }
}

final class ArtStore: @unchecked Sendable {
    static let shared = ArtStore()
    private let images = NSCache<NSString, CGImageBox>()
    private let lock = NSLock()
    private var palettes: [String: Palette] = [:]
    private var itunes: [String: String] = [:]   // key → artwork URL, or "" when the store has none
    private var links: [String: String] = [:]    // key → the album on Apple Music
    private var itunesNext = Date.distantPast
    private let dir: URL
    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        images.countLimit = 400
        if let d = try? Data(contentsOf: dir.appendingPathComponent("palettes.json")), let p = try? JSONDecoder().decode([String: Palette].self, from: d) { palettes = p }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("itunes.json")), let p = try? JSONDecoder().decode([String: [String]].self, from: d) {
            for (k, v) in p where v.count == 2 { itunes[k] = v[0]; links[k] = v[1].isEmpty ? nil : v[1] }
        }
    }

    // Only what's in memory: for a view's first frame, so a cover seen before is there at once, never faded in again.
    func cached(_ ref: ArtRef, px: Int) -> CGImage? { images.object(forKey: "\(ref.key)@\(px)" as NSString)?.image }
    func palette(_ ref: ArtRef) -> Palette? { lock.withLock { palettes[ref.key] } }
    func appleMusic(_ ref: ArtRef) -> URL? { lock.withLock { links[ref.key] }.flatMap(URL.init(string:)) }

    func image(_ ref: ArtRef, px: Int) async -> CGImage? {
        if let c = cached(ref, px: px) { return c }
        guard let data = await bytes(ref) else { return nil }
        // Kept under the album too, whichever source it came from, for warm() on the next launch.
        let byKey = file("album:" + ref.key)
        if !FileManager.default.fileExists(atPath: byKey.path) { try? data.write(to: byKey, options: .atomic) }
        return decode(ref, data, px: px)
    }

    // The hero's cover and backdrop, decoded now from what's on disk (a few milliseconds), for the first frame.
    func warm(_ ref: ArtRef) {
        guard cached(ref, px: 1000) == nil else { return }
        var data = try? Data(contentsOf: file("album:" + ref.key))
        if data == nil, let u = ref.url, u.hasPrefix("mock://") {
            data = Bundle.main.url(forResource: String(u.dropFirst(7)), withExtension: "jpg", subdirectory: "Mock/art").flatMap { try? Data(contentsOf: $0) }
        }
        guard let data else { return }
        _ = decode(ref, data, px: 1000)
        // The backdrop as it was blurred last time, from the disk: no Core Image before the first frame.
        if let d = try? Data(contentsOf: file("backdrop:" + ref.key)), let src = CGImageSourceCreateWithData(d as CFData, nil),
           let b = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            images.setObject(CGImageBox(b), forKey: "\(ref.key)@backdrop" as NSString)
        }
    }

    private func decode(_ ref: ArtRef, _ data: Data, px: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: px,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        images.setObject(CGImageBox(img), forKey: "\(ref.key)@\(px)" as NSString)
        if palette(ref) == nil, let p = Self.extract(img) {
            let all = lock.withLock { palettes[ref.key] = p; return palettes }
            if let d = try? JSONEncoder().encode(all) { try? d.write(to: dir.appendingPathComponent("palettes.json"), options: .atomic) }
        }
        return img
    }

    func palette(loading ref: ArtRef) async -> Palette? {
        if let p = palette(ref) { return p }
        _ = await image(ref, px: 96)
        return palette(ref)
    }

    // The bytes of a cover: from disk if fetched before, else Last.fm's largest, else Apple's store.
    private func bytes(_ ref: ArtRef) async -> Data? {
        if let u = ref.url, u.hasPrefix("mock://") {
            let name = String(u.dropFirst(7))
            return Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Mock/art").flatMap { try? Data(contentsOf: $0) }
        }
        var tries: [String] = []
        if let u = ref.url {
            // The largest Last.fm keeps, then the size it sent.
            if let r = u.range(of: #"/i/u/[^/]+/"#, options: .regularExpression) { tries.append(u.replacingCharacters(in: r, with: "/i/u/ar0/")) }
            tries.append(u)
        }
        for u in tries { if let d = await fetch(u) { return d } }
        if let u = await storeArt(ref) { return await fetch(u) }
        return nil
    }

    private func file(_ url: String) -> URL { dir.appendingPathComponent(SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40).description) }
    private func fetch(_ url: String) async -> Data? {
        let f = file(url)
        if let d = try? Data(contentsOf: f) { return d }
        guard let u = URL(string: url), let (d, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200, d.count > 512 else { return nil }
        try? d.write(to: f, options: .atomic)
        return d
    }

    // Apple's store, by artist and album, once per album ever, no more than one look every second and a half.
    private func storeArt(_ ref: ArtRef) async -> String? {
        let known = lock.withLock { itunes[ref.key] }
        if let known { return known.isEmpty ? nil : known }
        guard !LastFM.shared.mock else { return nil }
        let slot = lock.withLock { let s = max(Date(), itunesNext); itunesNext = s.addingTimeInterval(1.5); return s }
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        let term = ref.album.isEmpty ? ref.artist : "\(ref.artist) \(ref.album)"
        c.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: "album"), URLQueryItem(name: "limit", value: "5")]
        guard let (d, _) = try? await URLSession.shared.data(from: c.url!), let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        let results = J(o)["results"].array
        let want = ref.artist.lowercased()
        let hit = results.first { $0["artistName"].text.lowercased() == want } ?? results.first { $0["artistName"].text.lowercased().contains(want) || want.contains($0["artistName"].text.lowercased()) }
        let art = hit?["artworkUrl100"].string?.replacingOccurrences(of: "100x100bb", with: "1000x1000bb") ?? ""
        let link = hit?["collectionViewUrl"].string
        let all = lock.withLock {
            itunes[ref.key] = art
            if let link { links[ref.key] = link }
            return itunes.reduce(into: [String: [String]]()) { $0[$1.key] = [$1.value, links[$1.key] ?? ""] }
        }
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: dir.appendingPathComponent("itunes.json"), options: .atomic) }
        return art.isEmpty ? nil : art
    }

    // The cover's colours: the most alive one (saturated, not too dark, not white), a deep one for backgrounds, the mean.
    static func extract(_ img: CGImage) -> Palette? {
        let n = 20
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.interpolationQuality = .medium
            c.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var sum = (0.0, 0.0, 0.0), best: (Double, Palette.RGB)? = nil
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            sum.0 += r; sum.1 += g; sum.2 += b
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            let score = sat * (mx > 0.3 ? 1 : mx / 0.3) * (mx > 0.95 && sat < 0.15 ? 0.2 : 1)
            if score > (best?.0 ?? -1) { best = (score, .init(r: r, g: g, b: b)) }
        }
        let k = Double(n * n)
        let avg = Palette.RGB(r: sum.0 / k, g: sum.1 / k, b: sum.2 / k)
        var vivid = (best?.0 ?? 0) > 0.12 ? best!.1 : avg
        // Lift a dark vivid colour so it reads on the near-black ground.
        let m = max(vivid.r, vivid.g, vivid.b)
        if m < 0.55 && m > 0.01 { vivid = vivid.scaled(0.55 / m) }
        let dm = max(avg.r, avg.g, avg.b, 0.01)
        let deep = vivid.scaled(0.32 / max(vivid.r, vivid.g, vivid.b, 0.01) * min(1, dm * 1.6 + 0.4))
        return Palette(vivid: vivid, deep: deep, average: avg)
    }

    // A softly blurred, slightly richer copy of the cover, small, for the backdrop that fills the screen behind it.
    // Made the first time a cover is blurred (off the main thread), never at launch.
    private lazy var context: CIContext = CIContext(options: [.useSoftwareRenderer: false])
    func backdrop(_ ref: ArtRef) async -> CGImage? {
        if let b = cachedBackdrop(ref) { return b }
        guard let small = await image(ref, px: 160) else { return nil }
        return blurred(ref, small)
    }
    private func blurred(_ ref: ArtRef, _ small: CGImage) -> CGImage? {
        let key = "\(ref.key)@backdrop" as NSString
        let ci = CIImage(cgImage: small).clampedToExtent()
        let blurred = ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: -0.04])
            .cropped(to: CIImage(cgImage: small).extent)
        guard let out = lock.withLock({ context.createCGImage(blurred, from: blurred.extent) }) else { return nil }
        images.setObject(CGImageBox(out), forKey: key)
        // Kept small on disk for warm() on the next launch.
        let m = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(m, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(dest) { try? (m as Data).write(to: file("backdrop:" + ref.key), options: .atomic) }
        }
        return out
    }
    func cachedBackdrop(_ ref: ArtRef) -> CGImage? { images.object(forKey: "\(ref.key)@backdrop" as NSString)?.image }
}

// A cover, square, with a designed stand-in until it comes and if it never does: the album's own colour and a disc.
struct ArtView: View {
    let ref: ArtRef
    var px: Int = 300
    var corner: CGFloat = 8
    @State private var image: CGImage?
    init(_ ref: ArtRef, px: Int = 300, corner: CGFloat = 8) {
        self.ref = ref; self.px = px; self.corner = corner
        _image = State(initialValue: ArtStore.shared.cached(ref, px: px))
    }
    var body: some View {
        ZStack {
            Stand(ref: ref)
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5) }
        .task(id: ref) {
            if let c = ArtStore.shared.cached(ref, px: px) { image = c; return }
            image = nil
            if let i = await ArtStore.shared.image(ref, px: px) { withAnimation(.easeOut(duration: 0.25)) { image = i } }
        }
    }
    struct Stand: View {
        let ref: ArtRef
        var body: some View {
            let p = Palette.from(name: ref.artist + ref.album)
            ZStack {
                LinearGradient(colors: [p.vivid.color.opacity(0.85), p.deep.color], startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { g in
                    Image(systemName: "opticaldisc").resizable().scaledToFit().foregroundStyle(.white.opacity(0.16))
                        .frame(width: g.size.width * 0.42).position(x: g.size.width / 2, y: g.size.height / 2)
                }
            }
        }
    }
}
