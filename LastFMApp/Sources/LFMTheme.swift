import SwiftUI
import Darwin
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// One scale for the whole app, from real Zune and Windows Phone 7 (rotation-zune-2026-11-20): a near-black ground with
// the colour in the covers; a type ramp of big steps where size and weight are the hierarchy (large light lowercase
// names and heads, thin figures, small bold capitals for labels); everything hung from one left edge with no boxes
// round it; square covers with tight gaps. Glass is kept for what iOS 26 puts in it and what he touches.
enum S {
    // Spacing: one system, and nothing else anywhere (Richard, 2026-11-13: "spacing is bad rn").
    // WP7's grid (lastfm.md §27.1, Richard 2026-11-25 "make this work as a zune windows phone app"): content hung 24
    // from the left (12 + 12); folded, the outer display is about WP7's 480 px across, so a WP7 pixel is about a point.
    static let margin: CGFloat = 24      // a page's side inset
    static let section: CGFloat = 36     // between sections
    static let head: CGFloat = 12        // a section head (or a hub title) to its content
    static let gap: CGFloat = 12         // between rows, tiles, chips and cards side by side
    static let inner: CGFloat = 16       // a card's padding, and between the blocks inside it
    static let pair: CGFloat = 4         // a figure and its label; a title and its second line
    static let figures: CGFloat = 24     // between figures side by side
    static let row: CGFloat = 12         // between rows (the same as gap: rows are 52 pt art, 6 above and below)
    static let corner: CGFloat = 22      // cards
    static let art: CGFloat = 52         // a row's cover
    static let tile: CGFloat = 136       // a panorama's cover
    static let square: CGFloat = 0       // a cover's corner: square, as Zune's and WP7's are
    static let mosaic: CGFloat = 4       // between the covers of a mosaic
    // WP7's dark theme: the ground is flat black, nothing behind it (Richard, 2026-11-25: "nor do the colors and blur").
    static let ground = Color.black
    static let soft = Color.white.opacity(0.66)   // second lines (an artist under a title), never a footnote
    // Zune's magenta (the gradient's start, Z.accent): love, the streak, the history bars. Marks only.
    static let accent = Color(red: 0.85, green: 0.0, blue: 0.45)
}

// The hub's title, Zune's way: huge and thin, lowercase, starting a little left of the content. It fits the page when
// it can, shrinking to no less than 70 %; a name too long even for that runs on under the side bar and off the display
// on purpose, never stopped at the bar's edge (Richard's phone, 2026-11-14: his name cut mid-word at the bar).
struct HubTitle: View {
    let text: String
    var size: CGFloat = 80
    // How far it may shrink to fit. His own name is always whole (0.3); other titles keep their size past 70 %.
    var least: CGFloat = 0.7
    @ScaledMetric(relativeTo: .largeTitle) private var k: CGFloat = 1
    var body: some View {
        let base = size * min(max(k, 0.9), 1.25)
        // The size chosen in the same layout pass that draws it, from the width offered: it was measured after the first
        // frame, so a long title drew at full size for a frame, then shrank (run 39 review, fault 9). Steps of 5 %
        // down to the least; past that a title keeps its size (runs off), his own name stays at its least.
        let steps = stride(from: 1.0, through: Double(least) - 0.001, by: -0.05).map { CGFloat($0) }
        ViewThatFits(in: .horizontal) {
            ForEach(steps, id: \.self) { s in line(base, s).padding(.trailing, S.margin) }
            line(base, least < 0.7 ? least : 1)
        }
        // Both bounds, so the frame is the page's width however long the name: with only a maximum it took the text's
        // own width, and a long album's title pushed the whole page off the left edge (run 11).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        // Zune's parallax: as the page goes up, the huge title slides off to the left at a quarter of the scroll, a layer
        // of its own (drawn, never laid out again).
        .visualEffect { c, p in c.offset(x: min(0, p.frame(in: .scrollView).minY) * 0.25) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }
    private func line(_ base: CGFloat, _ scale: CGFloat) -> some View {
        Text(text.lowercased())
            .font(.zuneLower(size: base * scale))
            .tracking(-1.5 * scale)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white.opacity(0.94))
            .padding(.leading, S.margin - 3)
    }
    // How much a title shrinks to fit the room it's given (its own inset and the page's margin at the far side): to
    // 70 % at the least; past that it keeps its size and runs off the edge.
    static func scale(_ text: String, base: CGFloat, room: CGFloat, least: CGFloat = 0.7) -> CGFloat {
        let natural = textWidth(text.lowercased(), size: base, tracking: -1.5, face: Z.lower())
        let avail = room - (S.margin - 6) - S.margin
        guard natural > 0, avail > 0 else { return 1 }
        let fit = min(1, avail / natural)
        return fit >= least ? fit : 1
    }
}

// A line's width in the thin system face, worked out before it's drawn, so a title is the right size in its first frame.
func textWidth(_ s: String, size: CGFloat, tracking: CGFloat = 0, weight: CGFloat? = nil, face: String? = nil) -> CGFloat {
    #if canImport(UIKit)
    let f = face.flatMap { UIFont(name: $0, size: size) } ?? Z.uiFont(size, weight: weight ?? -0.4)
    #else
    let f = NSFont.systemFont(ofSize: size, weight: weight.map { NSFont.Weight(rawValue: $0) } ?? .thin)
    #endif
    return ceil((s as NSString).size(withAttributes: [.font: f, .kern: tracking]).width)
}

// A figure, shown at its value at once. It used to count up the first time it was shown and roll when it changed;
// Richard, 2026-11-18: "i hate the running total scrobble thing how the number goes up". A new value simply replaces
// the old one. (The key is kept so every call site reads the same.)
struct Counting: View {
    let value: Int
    let key: String
    var format: (Int) -> String = number
    init(_ value: Int, key: String, format: @escaping (Int) -> String = number) {
        self.value = value; self.key = key; self.format = format
    }
    var body: some View {
        Text(format(value)).transaction { $0.animation = nil }
    }
}

// The app's haptics: the six words every one of his iPhone apps shares (manifesto, 2026-11-14), each only ever in answer
// to his own touch. SwiftUI's sensoryFeedback follows the system's haptics switch by itself.
extension SensoryFeedback {
    static let tick = SensoryFeedback.selection
    static let snap = SensoryFeedback.impact(flexibility: .soft, intensity: 0.5)
    static let tap = SensoryFeedback.impact(weight: .light)
    static let thunk = SensoryFeedback.impact(weight: .medium)
    static let done = SensoryFeedback.success
    static let warn = SensoryFeedback.warning
}

struct SectionHead: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // Zune's section name: large, light, lowercase, hung from the page's left edge.
            Text(text.lowercased()).font(.zuneLower(.title)).foregroundStyle(.white.opacity(0.96)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.zune(.subheadline)).monospacedDigit().foregroundStyle(S.soft).lineLimit(1) }
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
        VStack(alignment: .leading, spacing: S.pair) {
            Text(value).font(.zune(size: size, .light)).monospacedDigit().foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                // One height whatever the shrink, so labels in a row of figures share a line.
                .frame(height: ceil(size * 1.2), alignment: .bottom)
            // What it counts, as Zune labels a figure: small bold capitals.
            Text(label).textCase(.uppercase).font(.zuneCaps(.caption, .semibold)).tracking(0.8).foregroundStyle(S.soft).lineLimit(1).minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    // What was a glass card is a plain block hung from the page's left edge, under its head: Zune boxes nothing, and
    // some forty panes of glass each sampling the ground were the app's heaviest drawing (run 39 review, fault 8).
    func card(_ radius: CGFloat = S.corner) -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension String { var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() } }

func number(_ n: Int) -> String { n.formatted(.number) }
func compact(_ n: Int) -> String { n >= 10_000 ? n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) : n.formatted(.number) }

// When something was played, said the way he'd say it.
func when(_ d: Date?) -> String {
    guard let d else { return "" }
    let gap = Clock.now.timeIntervalSince(d)
    if gap < 60 { return "just now" }
    if gap < 3600 { return "\(Int(gap / 60)) min ago" }
    let time = d.formatted(date: .omitted, time: .shortened).plainSpaces
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

// The page behind everything: the cover of what's on (or last played), blurred to colour, over the near-black ground;
// darker toward the foot so lists stay easy to read. Every tab paints the same one from the same kept picture, so going
// between tabs shows the same backdrop with nothing redrawn or faded in.
// It holds still. It drifted at 30 frames a second under every glass card, which redrew the whole screen while a song
// played and moved the ground on every fourth frame of a scroll (run 39 review, fault 8). A new cover crossfades over
// the old one, which stays under it until the new one is in: never black between (fault 2).
struct Backdrop: View {
    // Zune HD's and WP7's music hub (Richard, 2026-11-25: "there should be more imagery and color"): the picture of what's
    // on (or the page's own album) big and sharp behind the page, larger than the screen and running off its right edge,
    // under a black wash so white type reads (WP7: "dark and low contrast, a black overlay"). Never blurred.
    let ref: ArtRef?
    var moving: Bool = false
    var dim: Double = 0
    var body: some View {
        // Laid out in an overlay of a colour that already covers the safe areas: inside a background the reader was given
        // the page's safe frame and the picture stopped short of the side strip and the foot (run 60).
        ScreenBleed { g in
            ZStack(alignment: .topLeading) {
                Color.black
                if let ref {
                    let side = max(g.height, g.width) * 1.08
                    // Dim and desaturated, as WP7.5's artist pages set their photo behind the pivot.
                    // The desaturation baked into the picture (no filter on a screen-sized layer). A new picture is a new
                    // layer faded over the old (Ground's slow cross-fade), never swapped in one frame.
                    TreatedArt(ref, .muted)
                        .frame(width: side, height: side)
                        .clipped()
                        // Never short of the left edge: open flat the screen is wider than tall (gate on build 78: a
                        // black strip down the left behind ROTATION).
                        .offset(x: min(0, g.width - side * 0.82), y: -side * 0.06)
                        .id(ref.key)
                        .transition(.opacity)
                    // Darkest across the top, where the small capitals and names sit over the cover's own lettering.
                    // The top tenth nearly black: a cover's own title, cropped by the screen's top edge, read as stray
                    // letters over the capitals ("…rizons", run 63 gate).
                    LinearGradient(stops: [.init(color: .black.opacity(0.92 + dim), location: 0),
                                           .init(color: .black.opacity(0.8 + dim), location: 0.09),
                                           .init(color: .black.opacity(0.55 + dim), location: 0.2),
                                           .init(color: .black.opacity(0.62 + dim), location: 0.45),
                                           .init(color: .black.opacity(0.86), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// One ground per visit (WP7 study §2; Richard, 11-26: "i dont like how background cover changes so quickly"). WP7's hub
// set ONE picture behind the panorama, the photo of the artist last played, and kept it for the whole visit ("only one
// image displayed at any given time"; "the Panorama is not designed to have a dynamic background", its author). So home,
// every hub and the pages that borrow it paint `Ground.hubs`: the artist's photo (Deezer, ArtistPhotos), else the cover,
// chosen once; it moves only for a new artist, never sooner than 30 s after the last change, and only once the new picture
// is baked, by a slow 1.2 s cross-fade. Now playing paints `Ground.now`: the same rule per artist with no hold, as WP7 held
// one photo per artist and faded the next in once it had loaded.
@MainActor @Observable final class Ground {
    static let hubs = Ground(now: false)
    static let now = Ground(now: true)
    struct Pick: Equatable { let ref: ArtRef; let treat: ArtStore.Treat; let artist: String }
    private(set) var pick: Pick?
    @ObservationIgnored private let forNow: Bool
    @ObservationIgnored private var since = Date.distantPast
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var aim: String?
    static let fade = 1.2
    private var hold: Double { forNow ? 0 : 30 }
    private init(now: Bool) { forNow = now }
    func follow(_ s: Scrobble?) {
        guard let s else { return }
        let a = ArtistPhotos.norm(s.artist)
        if aim == a { return }
        // This artist's photo already: nothing changes (his next song by the same artist keeps the same ground).
        if let p = pick, ArtistPhotos.norm(p.artist) == a, p.ref.isPhoto { return }
        job?.cancel()
        aim = a
        // The very first: at once, from what's ready now (the cover stands in for a photo not yet found).
        if pick == nil {
            let lp = look(s, photo: true)
            if let r = ArtistPhotos.shared.photo(s.artist, lp) { pick = Pick(ref: r, treat: lp, artist: s.artist); since = Date(); aim = nil; return }
            pick = Pick(ref: s.art, treat: look(s, photo: false), artist: s.artist); since = Date()
        }
        job = Task { [weak self] in
            guard let self else { return }
            let lp = self.look(s, photo: true)
            await ArtistPhotos.shared.prepare(s.artist, looks: [lp])
            guard !Task.isCancelled else { return }
            var next: Pick
            if let r = ArtistPhotos.shared.photo(s.artist, lp) { next = Pick(ref: r, treat: lp, artist: s.artist) }
            else {
                // No photo: a cover already showing for this artist stays; else the cover, baked first.
                if let p = self.pick, ArtistPhotos.norm(p.artist) == a { self.aim = nil; return }
                let t = self.look(s, photo: false)
                _ = await ArtStore.shared.treated(s.art, t)
                next = Pick(ref: s.art, treat: t, artist: s.artist)
            }
            let wait = self.hold - Date().timeIntervalSince(self.since)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled, self.aim == a else { return }
            self.aim = nil
            guard next != self.pick else { return }
            self.since = Date()
            withAnimation(.easeInOut(duration: Self.fade)) { self.pick = next }
        }
    }
    private func look(_ s: Scrobble, photo: Bool) -> ArtStore.Treat { forNow ? (photo ? .tinted(Store.tint(s.art)) : .duotone) : .muted }
}

// Zune desktop's Now Playing: the picture of what's on across the whole screen in one colour (a duotone in the cover's
// own colour, no blur), and over it the artist and album in giant capitals running off the right edge.
struct NowBackdrop: View {
    let song: Scrobble?
    var body: some View {
        ScreenBleed { g in
            ZStack(alignment: .topLeading) {
                Color.black
                if let s = song {
                    // The duotone in the cover's own vivid colour, bright (Zune desktop's is a saturated single colour).
                    let vivid = (ArtStore.shared.palette(s.art) ?? Palette.from(name: s.art.artist + s.art.album)).vivid.color
                    let side = max(g.height, g.width) * 1.05
                    // WP7's now playing (study §2): the artist's photo, one per artist, held while his songs play and
                    // faded to the next artist's once it's ready (Ground.now), never a cover per song. Baked look, no filter.
                    if let pick = Ground.now.pick {
                        TreatedArt(pick.ref, pick.treat)
                            .frame(width: side, height: side)
                            .clipped()
                            // Never short of the left edge: open flat the screen is wider than tall and 0.85 of the side
                            // left a black strip down the left pane.
                            .offset(x: min(0, g.width - side * 0.85), y: g.height - side)
                            .id(pick.ref.key + pick.treat.tag)
                            .transition(.opacity)
                    }
                    // Darker down the lower half, where the page's figures sit over the giant capitals and the cover's
                    // own lettering (run 64 shots: "Friday" over "ENDLESS" over the cover's title).
                    // Darker again under the body text (build 76 notes: hard to read over the capitals folded).
                    LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .black.opacity(0.25), location: 0.38),
                                           .init(color: .black.opacity(0.62), location: 0.6), .init(color: .black.opacity(0.8), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    // The giant capitals in a band at the foot, clear of the cover above (run 61 gate).
                    VStack(alignment: .leading, spacing: -24) {
                        Text(s.artist).font(.zuneCaps(size: 96, .bold))
                        if !s.album.isEmpty { Text(s.album).font(.zuneCaps(size: 96, .bold)) }
                    }
                    .textCase(.uppercase).lineLimit(1).fixedSize()
                    // Quieter than the type over it: open upright the page's "about" lay over them and was hard to read (run 63 gate).
                    .foregroundStyle(vivid.mix(with: .white, by: 0.5).opacity(0.11))
                    .padding(.leading, S.margin - 4)
                    .offset(y: g.height - (s.album.isEmpty ? 1 : 2) * 92 - 60)
                }
            }
            // Pinned to the top left: the picture is larger than the screen, so the stack grew to it and was centred,
            // which pulled everything up and left (a black column under the side strip folded, a black band at the foot,
            // the artist's name starting off screen: "DIA SOREL").
            .frame(width: g.width, height: g.height, alignment: .topLeading)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// Page content fades out under the clock at the top, so no word reads through it: the ground's colour drawn over the
// content there, not a mask (two full-page masks were an off-screen pass each, every frame; run 39 review, fault 8).
// At the foot the system's own glass tab bar floats over the page, as in every iOS 26 app.
struct BarFade: ViewModifier {
    // WP7's system tray is solid: what scrolls up passes under a flat black band as tall as the bars, no fade or blur.
    // Only once something has scrolled under it: at rest the page's picture runs to the top as a hub's does, the small
    // capitals on Back's row (run 63 gate: a black bar holding Back, the page "artificially lowered").
    var on = true
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            GeometryReader { g in
                let top = max(g.safeAreaInsets.top, g.frame(in: .global).minY)
                if top > 30 {
                    Color.black.frame(height: TopBar.across()?.maxY ?? top).offset(y: -g.frame(in: .global).minY)
                        .opacity(on ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: on)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
// Where a cover tapped opens its page from, so the page grows out of it and shrinks back into it.
private struct ZoomSpaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var zoomSpace: Namespace.ID? { get { self[ZoomSpaceKey.self] } set { self[ZoomSpaceKey.self] = newValue } }
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
    @ViewBuilder func cover<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
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

// Zune's tilt: what's under the finger tips back in three dimensions and sinks a little, and springs back with a small
// overshoot when let go. The answer to a press is the tilt, never a change of colour; the weight is in the press, none
// in the drag.
struct Press: ButtonStyle {
    var depth: CGFloat = 0.955
    func makeBody(configuration: Configuration) -> some View {
        // WP7's TiltEffect [S4]: the sink and a thumb's tip, no colour change; back 200 ms after release, over 100 ms.
        Tilt(depth: depth).makeBody(configuration: configuration)
    }
}

// The build's poses: launch arguments that put a screen in a state to be shot. Never set on the phone.
enum Pose {
    static let name = UserDefaults.standard.string(forKey: "pose") ?? ""
    static var tab: Int { UserDefaults.standard.integer(forKey: "tab") }
    static var panel: Int { UserDefaults.standard.integer(forKey: "panel") }
    // Where on the page a pose's state is: scrolled to, so the shot shows it (-pose scrub held an hour off the screen).
    static var anchor: String? { name == "scrub" ? "day" : name == "sync" ? "reading" : name == "collage" ? "collage" : name == "ask" ? "ask" : name == "portrait" ? "portrait" : nil }
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

// For the build's films (-hitchLog YES, never on the phone): the frame times, so a film's smoothness is read in numbers
// rather than from the runner's own recording (run 39 review, F-B). A display link counts every frame later than one
// and a half refresh intervals. Caches/hitches.txt gets one line a second (that second's frames, late frames, frames
// missed and longest gap, so a hitch can be matched to the moment of the film it fell in) under a first line of totals.
// The build's films can switch one moving thing off (-off wave,wall,drift,shadow), so the hitch log can say which of
// them costs frames rather than a guess (run 41: his page held 15 frames a second at rest with a song on).
enum Diag {
    private static let offs = Set((UserDefaults.standard.string(forKey: "off") ?? "").split(separator: ",").map(String.init))
    static func off(_ s: String) -> Bool { offs.contains(s) }
}
#if canImport(UIKit)
@MainActor final class HitchLog: NSObject {
    static let shared = HitchLog()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0, began: CFTimeInterval = 0, mark: CFTimeInterval = 0
    private var total = (frames: 0, late: 0, missed: 0, longest: 0.0)
    private var second = (frames: 0, late: 0, missed: 0, longest: 0.0)
    private var lines: [String] = []
    func start() {
        guard UserDefaults.standard.bool(forKey: "hitchLog"), link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        // And what the main thread was doing in each stall (LFMStalls.swift).
        StallSampler.shared.start()
    }
    // Where a horizontal swipe came to rest, relative to where it began ("land 1" a page on, "land 0" sprung back), for
    // the films' check that a swipe turned the page it should (ci/lfm-sim.sh lands).
    func note(_ s: String) {
        guard link != nil else { return }
        lines.append(String(format: "t %5.1f ", last - began) + s)
    }
    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let interval = max(l.targetTimestamp - l.timestamp, 1.0 / 120)
        StallSampler.beat = now
        guard last > 0 else { last = now; began = now; mark = now; StallSampler.origin = now; return }
        let gap = now - last
        last = now
        let late = gap > interval * 1.5, missed = late ? Int((gap / interval).rounded()) - 1 : 0
        total.frames += 1; second.frames += 1
        if late { total.late += 1; second.late += 1; total.missed += missed; second.missed += missed }
        total.longest = max(total.longest, gap); second.longest = max(second.longest, gap)
        guard now - mark >= 1 else { return }
        // (pager: how many times a pivot told its names where it is in this second; in a drag it should match the frames.)
        lines.append(String(format: "t %5.1f frames %3d late %2d missed %3d longest_ms %4.0f pager %3d", now - began, second.frames, second.late, second.missed, second.longest * 1000, PagerMotion.moves))
        PagerMotion.moves = 0
        second = (0, 0, 0, 0); mark = now
        let head = String(format: "total seconds %.1f frames %d late %d missed %d longest_ms %.0f interval_ms %.1f", now - began, total.frames, total.late, total.missed, total.longest * 1000, interval * 1000)
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("hitches.txt")
        try? Data(([head] + lines).joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }
}
#endif
