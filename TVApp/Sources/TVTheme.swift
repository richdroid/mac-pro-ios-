import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

// An iPhone app first. A few things carry over from the TV's launcher: its cyan, its banner shape, and the soft wall of colour from the art.
enum TVLook {
    static let accent = Color(hex: 0x3FE3E8)
    static let bannerTile = Color(hex: 0x3A4A52)
    static let bannerSize = CGSize(width: 142, height: 80)
    static let card: CGFloat = 22, banner: CGFloat = 12, gap: CGFloat = 12
    static let press = Animation.spring(duration: 0.25, bounce: 0.25)
    // The side bar's glass and its margin from the display's edge, folded and open alike.
    static let railRoom: CGFloat = 76
    // A form row in the same glass as the cards, never the system's opaque grey over the living background.
    static var glassRow: some View { Rectangle().fill(.ultraThinMaterial) }
}
extension Color { init(hex: UInt32) { self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) } }
extension View {
    func tvCard(_ radius: CGFloat = TVLook.card) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// Pictures stay in memory, so scrolling back never flashes a placeholder.
@MainActor
final class ImageStore {
    static let shared = ImageStore()
    private let cache: NSCache<NSURL, TVImage> = {
        let c = NSCache<NSURL, TVImage>()
        c.totalCostLimit = 120 << 20
        return c
    }()
    // The wall, the cover and the band often ask for the same picture at once; fetch it once.
    private var fetching: [URL: Task<TVImage?, Never>] = [:]
    // A cover's band colour, as Mint tints its items: the picture's average, muted and darkened so white text reads.
    private var bands: [URL: Color] = [:]
    func band(_ url: URL) async -> Color? {
        if let b = bands[url] { return b }
        guard let image = await load(url) else { return nil }
        #if canImport(UIKit)
        let rgb: (Double, Double, Double)? = await Task.detached(priority: .utility) {
            guard let cg = image.cgImage else { return nil }
            var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
            guard let c = CGContext(data: &px, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            var r = 0.0, g = 0.0, b = 0.0
            for i in stride(from: 0, to: px.count, by: 4) { r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]) }
            return (r / 64 / 255, g / 64 / 255, b / 64 / 255)
        }.value
        guard let rgb else { return nil }
        let top = max(rgb.0, rgb.1, rgb.2, 0.01), k = 0.42 / top
        let color = Color(red: rgb.0 * k, green: rgb.1 * k, blue: rgb.2 * k)
        bands[url] = color
        return color
        #else
        return nil
        #endif
    }
    func cachedBand(_ url: URL?) -> Color? { url.flatMap { bands[$0] } }
    // Memory only: never a disk read or a decode on the main thread, which is what drawing calls this from (r21: banners
    // read and decoded here, six at a time on the open Remote, froze the throw). The disk copies come in through warm().
    func cached(_ url: URL?) -> TVImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }
    // The apps' banners kept on disk between launches, read and decoded off the main thread at launch, so a cold launch
    // still draws them from its first frames rather than as empty tiles (r20).
    func warm(_ urls: [URL]) {
        let todo = urls.filter { cache.object(forKey: $0 as NSURL) == nil }
        guard !todo.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            var got: [(URL, TVImage, Bool)] = []
            for u in todo {
                guard let file = Self.bannerFile(u), let d = try? Data(contentsOf: file), let i = Self.decode(d, maxPixels: 1400) else { continue }
                got.append((u, i, FileManager.default.fileExists(atPath: file.path + ".flat")))
            }
            let ready = got
            await MainActor.run {
                for (u, i, flat) in ready where self.cache.object(forKey: u as NSURL) == nil {
                    self.cache.setObject(i, forKey: u as NSURL)
                    if flat { self.flats.insert(u) }
                }
            }
        }
    }
    // Where an app's banner is kept between launches; nil for anything that isn't a banner. The folder is made once.
    nonisolated static let bannerDir: URL? = {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tv-banners", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    nonisolated static func bannerFile(_ url: URL) -> URL? {
        guard url.path.hasSuffix("/icon"), let q = url.query, let dir = bannerDir else { return nil }
        let name = q.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return dir.appendingPathComponent(name)
    }
    // Pictures with nothing in them, like a white logo flattened onto white: known as soon as the picture is, so a
    // banner never draws the blank first.
    private var flats: Set<URL> = []
    func isFlat(_ url: URL?) -> Bool { url.map { flats.contains($0) } ?? false }
    // The tiny versions the backdrops stretch (the wall's 16 by 16, the pages' 6 by 6), made with the picture.
    private var smalls: [URL: [Int: TVImage]] = [:]
    func small(_ url: URL, _ side: Int) -> TVImage? { smalls[url]?[side] }
    // Everything a picture needs is done off the main thread, as it arrives: decoded straight to a size no screen here
    // shows bigger (1400 px, the Remote's picture open at 3x), its tiny versions drawn, and a banner checked for blank.
    // Before, full-size art was kept and shrunk or checked on the main thread while a page waited.
    struct Ready: @unchecked Sendable { let image: TVImage; let six: TVImage?; let sixteen: TVImage?; let flat: Bool }
    func load(_ url: URL) async -> TVImage? {
        if let i = cached(url) { return i }
        // A banner kept on disk: read and decoded off the main thread, before going to the network.
        if let file = Self.bannerFile(url) {
            let kept = await Task.detached(priority: .userInitiated) { () -> (TVImage, Bool)? in
                guard let d = try? Data(contentsOf: file), let i = Self.decode(d, maxPixels: 1400) else { return nil }
                return (i, FileManager.default.fileExists(atPath: file.path + ".flat"))
            }.value
            if let k = kept {
                cache.setObject(k.0, forKey: url as NSURL)
                if k.1 { flats.insert(url) }
                return k.0
            }
        }
        if let t = fetching[url] { return await t.value }
        let icon = url.path.hasSuffix("/icon")
        let job = Task.detached(priority: .utility) { () -> Ready? in
            // Tried three times: one failed fetch left a cover waiting, its light running, for good (r29: open Watch).
            var got: Data?
            for wait in [0.0, 0.6, 1.8] {
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                if let (d, resp) = try? await Self.session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 { got = d; break }
            }
            guard let d = got, let i = Self.decode(d, maxPixels: 1400) else { return nil }
            if icon, let file = Self.bannerFile(url) { try? d.write(to: file, options: .atomic) }
            #if canImport(UIKit)
            // The same renderer the pages used before, at the screen's own scale, so the stretched blur looks the same.
            func shrink(_ side: Int) -> TVImage {
                UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in i.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
            }
            return Ready(image: i, six: shrink(6), sixteen: shrink(16), flat: icon && flatPicture(i))
            #else
            return Ready(image: i, six: i, sixteen: i, flat: false)
            #endif
        }
        let t = Task { await job.value?.image }
        fetching[url] = t
        let r = await job.value
        fetching[url] = nil
        guard let r else { return nil }
        // Only the apps' banners are ever blank like that, and checking every poster would cost scrolling.
        if r.flat {
            flats.insert(url)
            if let file = Self.bannerFile(url) { FileManager.default.createFile(atPath: file.path + ".flat", contents: Data()) }
        }
        var s: [Int: TVImage] = [:]; s[6] = r.six; s[16] = r.sixteen
        if smalls.count > 400 { smalls.removeAll(keepingCapacity: true) }
        smalls[url] = s
        #if canImport(UIKit)
        let scale = r.image.scale
        #else
        let scale: CGFloat = 1
        #endif
        cache.setObject(r.image, forKey: url as NSURL, cost: Int(r.image.size.width * r.image.size.height * scale * scale) * 4)
        return r.image
    }
    // Pictures on a session of their own: on the shared one they queued behind the app's long requests to the same Mac
    // (a start followed line by line, status), and a row of covers could sit waiting (r29: open Watch, grey for 7 s).
    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()
    // A picture shrunk to a few pixels a side, off the main thread, for a soft background with no live blur.
    nonisolated static func shrunk(_ i: TVImage, _ side: Int) async -> TVImage? {
        #if canImport(UIKit)
        struct Box: @unchecked Sendable { let i: TVImage }
        let box = Box(i: i)
        return await Task.detached(priority: .userInitiated) { () -> Box in
            Box(i: UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in box.i.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) })
        }.value.i
        #else
        return i
        #endif
    }
    // Decoded at no more than `maxPixels` on its longer side, and ready to draw, so the first frame that shows it doesn't
    // decode it on the main thread.
    nonisolated static func decode(_ d: Data, maxPixels: Int) -> TVImage? {
        #if canImport(UIKit)
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return TVImage(data: d) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return TVImage(data: d) }
        return TVImage(cgImage: cg)
        #else
        return TVImage(data: d)
        #endif
    }
}

// Whether a picture shows nothing: its brightness hardly varies across a 16 by 16 grid. See-through parts count as the
// black a wide banner sits on. A real logo, however plain, varies by far more than 4 %.
func flatPicture(_ image: TVImage) -> Bool {
    #if canImport(UIKit)
    guard let cg = image.cgImage else { return false }
    let side = 16
    var px = [UInt8](repeating: 0, count: side * side * 4)
    let drawn: Bool = px.withUnsafeMutableBytes { raw in
        guard let c = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        c.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: side, height: side))
        c.interpolationQuality = .medium
        c.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return true
    }
    guard drawn else { return false }
    var sum = 0.0, squares = 0.0
    for i in stride(from: 0, to: px.count, by: 4) {
        let l = (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
        sum += l; squares += l * l
    }
    let n = Double(side * side), mean = sum / n
    return (squares / n - mean * mean).squareRoot() < 0.04
    #else
    return false
    #endif
}
struct Art<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: TVImage?
    @State private var fading = false
    var body: some View {
        // The stand-in stays underneath, never faded away, and only the art fades in over it: a stand-in fading out as
        // the art fades in showed the page behind for a few frames.
        let shown = ImageStore.shared.cached(url) ?? loaded
        ZStack {
            if shown == nil || fading { placeholder() }
            if let i = shown { content(Image(tv: i)).transition(.opacity) }
        }
        // Art that arrives after the first frame fades in over its stand-in, which goes only once the fade is done; art
        // already kept is there from the start.
        .task(id: url) {
            guard let url, ImageStore.shared.cached(url) == nil else { return }
            let i = await ImageStore.shared.load(url)
            fading = true
            withAnimation(.easeOut(duration: 0.25)) { loaded = i }
            try? await Task.sleep(nanoseconds: 300_000_000)
            fading = false
        }
    }
}

// The soft wall behind the rows: art really shrunk to a few pixels, then stretched. Cheap, with no live blur.
struct Wall: View {
    let art: String?
    @State private var small: TVImage?
    var body: some View {
        ZStack {
            Color.black
            if let small {
                Color.clear
                    .overlay { Image(tv: small).resizable().interpolation(.high).scaledToFill().opacity(0.55) }
                    .clipped().transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.26), value: small)
        .task(id: art) {
            guard let art, let u = URL(string: art), let i = await ImageStore.shared.load(u) else { small = nil; return }
            small = ImageStore.shared.small(u, 16) ?? i
        }
    }
}

#if os(iOS)
// A pushed page hides the navigation bar (its title is drawn on the page, Back is the side bar's), and UIKit turns the
// swipe from the left edge off with the bar. Back on, for any page with one under it (Richard, 2026-11-07: "the back
// button behavior is awful rn"; a swipe from the edge is the other way back every iPhone page has).
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        g === interactivePopGestureRecognizer ? viewControllers.count > 1 : true
    }
}
#endif
