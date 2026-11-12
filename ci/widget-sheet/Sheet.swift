import SwiftUI
import WidgetKit
import ImageIO
import UniformTypeIdentifiers

// Every widget at its real size, in each way the phone draws it, written as PNG sheets for review (the galleries'
// "-sheets YES"). Never shipped. Shared by the three galleries.
//
// What is faithful: each family's size and content margins, the rendering mode the views are told (full colour,
// accented, vibrant), the widget's own background, real-shaped data. What is approximated, since only the system can
// split a widget into its accented and plain groups: "Tinted" draws the accented render desaturated over dark glass
// (photos marked desaturated look right, colours look softer than the phone's); "Clear" flattens every colour to
// white keeping only its opacity (the harshest case, manifesto rule 24); the Lock Screen turns brightness into
// opacity, as vibrancy does; StandBy drops the widget's background, as the system does there.
enum Look: String, CaseIterable {
    case dark, light, tinted, clear
    var title: String {
        switch self {
        case .dark: return "Dark Home Screen"
        case .light: return "Light Home Screen"
        case .tinted: return "Tinted (accented, desaturated)"
        case .clear: return "Clear (accented, colours flattened)"
        }
    }
    var wallpaper: [Color] {
        switch self {
        case .dark: return [Color(red: 0.08, green: 0.1, blue: 0.2), Color(red: 0.22, green: 0.14, blue: 0.3), Color(red: 0.05, green: 0.06, blue: 0.1)]
        case .light: return [Color(red: 0.93, green: 0.9, blue: 0.85), Color(red: 0.78, green: 0.84, blue: 0.92)]
        case .tinted: return [Color(red: 0.12, green: 0.2, blue: 0.35), Color(red: 0.35, green: 0.25, blue: 0.4)]
        case .clear: return [Color(red: 0.86, green: 0.55, blue: 0.72), Color(red: 0.72, green: 0.42, blue: 0.62)]
        }
    }
}
enum Fam {
    static let small = CGSize(width: 158, height: 158)
    static let medium = CGSize(width: 338, height: 158)
    static let large = CGSize(width: 338, height: 354)
    static let circular = CGSize(width: 72, height: 72)
    static let rectangular = CGSize(width: 160, height: 72)
    static let inline = CGSize(width: 240, height: 22)
}
extension View {
    // Colours gone, opacity kept.
    func flattenedWhite() -> some View { colorMultiply(.black).colorInvert() }
    // Brightness as opacity, in white: the Lock Screen's vibrancy.
    func vibrantWhite() -> some View { luminanceToAlpha().colorMultiply(.black).colorInvert() }
}

// A Home Screen widget. `margins`: the system's 16 pt content margins (off for widgets that disable them).
struct HomeCell<C: View, B: View>: View {
    let look: Look
    let size: CGSize
    var margins = true
    let bg: B
    let content: C
    init(_ look: Look, _ size: CGSize, margins: Bool = true, bg: B, @ViewBuilder content: () -> C) {
        self.look = look; self.size = size; self.margins = margins; self.bg = bg; self.content = content()
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let inner = content.padding(margins ? 16 : 0).frame(width: size.width, height: size.height)
            .environment(\.colorScheme, look == .light ? .light : .dark)
        Group {
            switch look {
            case .dark, .light:
                inner.environment(\.widgetRenderingMode, .fullColor).background(bg)
            case .tinted:
                inner.environment(\.widgetRenderingMode, .accented).grayscale(1).background(Color.black.opacity(0.32))
            case .clear:
                inner.environment(\.widgetRenderingMode, .accented).flattenedWhite().background(Color.white.opacity(0.16))
            }
        }
        .clipShape(shape)
        .overlay { if look == .tinted || look == .clear { shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5) } }
    }
}
// A Lock Screen accessory, vibrant.
struct LockCell<C: View>: View {
    let size: CGSize
    let content: C
    init(_ size: CGSize, @ViewBuilder content: () -> C) { self.size = size; self.content = content() }
    var body: some View {
        content.frame(width: size.width, height: size.height)
            .environment(\.widgetRenderingMode, .vibrant).environment(\.colorScheme, .dark).foregroundStyle(.white)
            .vibrantWhite()
            .overlay { Rectangle().strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])) }
    }
}
// StandBy: a small widget with its background taken away, drawn large on black; at night, all of it in red.
struct StandByCell<C: View>: View {
    var night = false
    let content: C
    init(night: Bool = false, @ViewBuilder content: () -> C) { self.night = night; self.content = content() }
    var body: some View {
        Group {
            if night {
                content.padding(16).frame(width: 158, height: 158).environment(\.widgetRenderingMode, .fullColor).environment(\.colorScheme, .dark)
                    .vibrantWhite().colorMultiply(Color(red: 1, green: 0.18, blue: 0.12))
            } else {
                content.padding(16).frame(width: 158, height: 158).environment(\.widgetRenderingMode, .fullColor).environment(\.colorScheme, .dark)
            }
        }
        .scaleEffect(1.4).frame(width: 222, height: 222)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}
// One labelled row of a sheet.
struct SheetRow<C: View>: View {
    let label: String
    let content: C
    init(_ label: String, @ViewBuilder content: () -> C) { self.label = label; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.45), in: Capsule())
            HStack(alignment: .top, spacing: 16) { content }
        }
    }
}
struct Sheet<C: View>: View {
    let title: String
    var colors: [Color]
    let content: C
    init(_ title: String, colors: [Color], @ViewBuilder content: () -> C) { self.title = title; self.colors = colors; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4).background(.black.opacity(0.5), in: Capsule())
            content
        }
        .padding(20)
        .frame(width: 760, alignment: .topLeading)
        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
@MainActor func writeSheet<V: View>(_ name: String, scale: CGFloat = 2, _ view: V) {
    let r = ImageRenderer(content: view.environment(\.locale, Locale(identifier: "en_US")))
    r.scale = scale
    guard let cg = r.cgImage else { print("sheet \(name): nothing rendered"); return }
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sheets")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name + ".png")
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, cg, nil)
    print("sheet \(name): \(CGImageDestinationFinalize(d) ? "written" : "failed") \(cg.width)x\(cg.height)")
}
// What the gallery shows while (and after) it writes its sheets.
struct SheetsDone: View {
    let names: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sheets written").font(.headline)
            ForEach(names, id: \.self) { Text($0).font(.caption.monospaced()) }
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
