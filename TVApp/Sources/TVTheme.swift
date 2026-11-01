import SwiftUI
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
    func cached(_ url: URL?) -> TVImage? { url.flatMap { cache.object(forKey: $0 as NSURL) } }
    func load(_ url: URL) async -> TVImage? {
        if let i = cached(url) { return i }
        if let t = fetching[url] { return await t.value }
        let t = Task.detached(priority: .utility) { () -> TVImage? in
            guard let (d, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200, let i = TVImage(data: d) else { return nil }
            #if canImport(UIKit)
            return i.preparingForDisplay() ?? i
            #else
            return i
            #endif
        }
        fetching[url] = t
        let i = await t.value
        fetching[url] = nil
        if let i { cache.setObject(i, forKey: url as NSURL, cost: Int(i.size.width * i.size.height) * 4) }
        return i
    }
}
struct Art<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: TVImage?
    var body: some View {
        Group {
            if let i = ImageStore.shared.cached(url) ?? loaded { content(Image(tv: i)) } else { placeholder() }
        }
        .task(id: url) { if let url { loaded = await ImageStore.shared.load(url) } }
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
            #if canImport(UIKit)
            small = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in i.draw(in: CGRect(x: 0, y: 0, width: 16, height: 16)) }
            #else
            small = i
            #endif
        }
    }
}
