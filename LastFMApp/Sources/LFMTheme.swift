import SwiftUI
import Darwin

// One scale for the whole app. Zune's spirit in Apple's grammar: very big, very thin lowercase titles that run off the
// edge, bold lowercase section heads, numbers as the graphics, the cover's colours on a near-black ground.
enum S {
    static let margin: CGFloat = 20      // a page's side margin
    static let section: CGFloat = 36     // between sections
    static let head: CGFloat = 12        // a section head to its content
    static let row: CGFloat = 12         // between rows
    static let corner: CGFloat = 22      // cards
    static let ground = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let soft = Color.white.opacity(0.66)   // second lines (an artist under a title), never a footnote
    static let accent = Color(red: 1.0, green: 0.36, blue: 0.36)
}

// The hub's title, Zune's way: huge and thin, lowercase, starting a little left of the content and running off the far
// edge. A page's first line; never in a bar, never over rows.
struct HubTitle: View {
    let text: String
    var size: CGFloat = 80
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1
    var body: some View {
        Text(text.lowercased())
            .font(.system(size: size * min(max(k, 0.9), 1.25), weight: .thin))
            .tracking(-1.5)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white.opacity(0.94))
            .padding(.leading, S.margin - 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .accessibilityAddTraits(.isHeader)
    }
}

struct SectionHead: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(.title2, weight: .bold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.system(.title3, weight: .light)).monospacedDigit().foregroundStyle(S.soft) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// A figure and what it counts: the number is the graphic.
struct Figure: View {
    let value: String
    let label: String
    var size: CGFloat = 30
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: size, weight: .light)).monospacedDigit().foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.subheadline).foregroundStyle(S.soft).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func card(_ radius: CGFloat = S.corner) -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

func number(_ n: Int) -> String { n.formatted(.number) }
func compact(_ n: Int) -> String { n >= 10_000 ? n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) : n.formatted(.number) }

// When something was played, said the way he'd say it.
func when(_ d: Date?) -> String {
    guard let d else { return "" }
    let gap = Clock.now.timeIntervalSince(d)
    if gap < 60 { return "just now" }
    if gap < 3600 { return "\(Int(gap / 60)) min ago" }
    let time = d.formatted(date: .omitted, time: .shortened)
    // Another day says which: "yesterday at 11:52 PM", "Tuesday at 9:10 PM".
    if !Calendar.current.isDate(d, inSameDayAs: Clock.now) { let n = dayName(d); return "\(n == "yesterday" ? n : n.capitalizedFirst) at \(time)" }
    return "at \(time)"
}
func dayName(_ d: Date) -> String {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Clock.now)
    let day = cal.startOfDay(for: d)
    let back = cal.dateComponents([.day], from: day, to: today).day ?? 0
    if back == 0 { return "today" }
    if back == 1 { return "yesterday" }
    if back < 7 { return d.formatted(.dateTime.weekday(.wide)).lowercased() }
    return d.formatted(.dateTime.month(.wide).day()).lowercased()
}

// The page behind everything: the cover of what's on (or last played), blurred to colour, drifting slowly while a song
// plays, over the near-black ground; darker toward the foot so lists stay easy to read. Every tab paints the same one
// from the same kept picture, so going between tabs shows the same backdrop with nothing redrawn or faded in.
struct Backdrop: View {
    let ref: ArtRef?
    var moving: Bool
    var dim: Double = 0
    var body: some View {
        ZStack {
            S.ground
            if let ref {
                Layer(ref: ref, moving: moving).id(ref.key)
                    .transition(.opacity.animation(.easeInOut(duration: 0.6)))
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.05 + dim), location: 0), .init(color: .black.opacity(0.45 + dim), location: 0.55), .init(color: .black.opacity(0.82), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
    struct Layer: View {
        let ref: ArtRef
        let moving: Bool
        @State private var image: CGImage?
        init(ref: ArtRef, moving: Bool) { self.ref = ref; self.moving = moving; _image = State(initialValue: ArtStore.shared.cachedBackdrop(ref)) }
        var body: some View {
            GeometryReader { g in
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { tl in
                    let t = moving ? tl.date.timeIntervalSinceReferenceDate : 0
                    let side = max(g.size.width, g.size.height) * 1.5
                    Group {
                        if let image {
                            Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        } else {
                            let p = Palette.from(name: ref.artist + ref.album)
                            LinearGradient(colors: [p.vivid.color, p.deep.color], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(sin(t / 11) * 7))
                    .scaleEffect(1.06 + 0.04 * sin(t / 7))
                    .offset(x: CGFloat(sin(t / 13)) * 24, y: CGFloat(cos(t / 17)) * 18)
                    .position(x: g.size.width / 2, y: g.size.height * 0.36)
                    .opacity(0.78)
                }
            }
            .task(id: ref) {
                if image == nil, let b = await ArtStore.shared.backdrop(ref) { withAnimation(.easeOut(duration: 0.5)) { image = b } }
            }
        }
    }
}

// Page content fades out under a tab bar that runs across the foot (open upright), and under the clock at the top, so no
// word reads through either; elsewhere the bars are on the side and nothing is masked.
struct BarFade: ViewModifier {
    @State private var bottom: CGFloat = 0
    @State private var top: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottom = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top = $0 }
            .mask {
                VStack(spacing: 0) {
                    if top > 30 {
                        Color.clear.frame(height: max(0, top - 18))
                        LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    }
                    Color.black
                    if bottom > 40 {
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 18)
                        Color.clear.frame(height: bottom)
                    }
                }
                .ignoresSafeArea()
            }
    }
}

// Where a cover tapped opens its page from, so the page grows out of it and shrinks back into it.
private struct ZoomSpaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
private struct OpenTrackKey: EnvironmentKey { static let defaultValue: (Scrobble) -> Void = { _ in } }
extension EnvironmentValues {
    var zoomSpace: Namespace.ID? { get { self[ZoomSpaceKey.self] } set { self[ZoomSpaceKey.self] = newValue } }
    var openTrack: (Scrobble) -> Void { get { self[OpenTrackKey.self] } set { self[OpenTrackKey.self] = newValue } }
}
struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.zoomSpace) private var space
    func body(content: Content) -> some View {
        #if os(iOS)
        if let space { content.matchedTransitionSource(id: id, in: space) } else { content }
        #else
        content
        #endif
    }
}
extension View {
    func zoomSource(_ id: String) -> some View { modifier(ZoomSource(id: id)) }
    @ViewBuilder func zoomed(_ id: String, _ space: Namespace.ID) -> some View {
        #if os(iOS)
        self.navigationTransition(.zoom(sourceID: id, in: space))
        #else
        self
        #endif
    }
    @ViewBuilder func cover<Item: Identifiable, C: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}

// A press that answers at once: the row dips a little under the finger.
struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

// The build's poses: launch arguments that put a screen in a state to be shot. Never set on the phone.
enum Pose {
    static let name = UserDefaults.standard.string(forKey: "pose") ?? ""
    static var tab: Int { UserDefaults.standard.integer(forKey: "tab") }
}

// For the build's films (-launchLog YES, never on the phone): how long after the process began each step of a launch
// came, to Caches/launch-log.txt, so a slow first frame is found in numbers.
enum LaunchLog {
    static let on = UserDefaults.standard.bool(forKey: "launchLog")
    private static let start: Date = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }()
    static func mark(_ what: String) {
        guard on else { return }
        let line = String(format: "%@ %.3f s %@\n", ProcessInfo.processInfo.processIdentifier.description, Date().timeIntervalSince(start), what)
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("launch-log.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}
