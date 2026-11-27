import SwiftUI
#if canImport(UIKit)
import UIKit

// Home's panorama in UIKit (2026-11-26, after build 80: "smoothness is still very off esp the scroll … the end of the
// scrolling horizontal list looks weird"). WP7's panorama is a ring: past its last section the first one is already
// showing at the right, and a swipe carries on round to it (study §4: "wraps last↔first"); the title, the slowest layer,
// never repeats: across the wrap it "animates out of view in the direction it was previously moving and animates back
// into the scene from the other side" [PA], and the background swings back to its start with it, never cut.
// A SwiftUI scroll can't be a ring (build 80 stopped hard at the last section with a blank stretch after it), and its
// title and background were moved by SwiftUI in every frame of a drag. Here nothing of SwiftUI runs while it moves:
// - a pan follows the finger 1:1; the sections sit in one strip moved by its layer's transform, each section placed on
//   the turn of the ring nearest the screen;
// - let go, the release velocity chooses the section (WP7's pivot rule, as WPPaging: over half a section a second turns
//   one section that way, slower lands on the nearer one, never more than one), and the landing is Core Animation's:
//   0.35 s of ExponentialEase(6) EaseOut [S4] as keyframes on the strip, the title and the background, so no frame of a
//   landing waits on the main thread;
// - a finger put down on a landing catches it where it is on screen.
// The sections, title and background are SwiftUI views hosted once each; they're drawn again only when their data does.

struct PanoGeo: Equatable {
    var sec: CGFloat, count: Int
    var W: CGFloat, H: CGFloat
    var leading: CGFloat
    var sectionsTop: CGFloat
    var titleTop: CGFloat, titleW: CGFloat, titleH: CGFloat
    var titleRate: CGFloat, bgRate: CGFloat, bgSide: CGFloat
    var ring: CGFloat { sec * CGFloat(count) }
    var travel: CGFloat { sec * CGFloat(count - 1) }
}

struct PanoramaStrip: UIViewControllerRepresentable {
    let geo: PanoGeo
    let start: Int
    let background: AnyView
    let title: AnyView
    let sections: [AnyView]
    func makeUIViewController(context: Context) -> PanoramaController {
        let c = PanoramaController()
        c.page = start
        c.update(geo: geo, background: background, title: title, sections: sections)
        return c
    }
    func updateUIViewController(_ c: PanoramaController, context: Context) {
        c.update(geo: geo, background: background, title: title, sections: sections)
    }
}

@MainActor final class PanoramaController: UIViewController, UIGestureRecognizerDelegate {
    private var geo: PanoGeo?
    // Where the panorama is, in points along the ring (unbounded: it runs on past the ring's length round a wrap).
    private var p: CGFloat = 0
    // The section at rest (its index on the ring); set before the first layout from the build's pose.
    var page = 0
    private var bgHost: UIHostingController<AnyView>?
    private var titleHost: UIHostingController<AnyView>?
    private var hosts: [UIHostingController<AnyView>] = []
    private let strip = UIView()
    private var pan: UIPanGestureRecognizer!
    private var landing: (to: CGFloat, began: CFTimeInterval, from: CGFloat)?
    private var landingID = 0
    private var startP: CGFloat = 0
    private var releasedAt: CFTimeInterval = 0
    private var caught = false
    private let tick = UISelectionFeedbackGenerator()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        strip.backgroundColor = .clear
        view.addSubview(strip)
        pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        let c = Catch()
        c.down = { [weak self] in self?.catchLanding() }
        c.up = { [weak self] in self?.letGoOfCatch() }
        view.addGestureRecognizer(c)
    }

    func update(geo g: PanoGeo, background: AnyView, title: AnyView, sections: [AnyView]) {
        loadViewIfNeeded()
        let resized = geo.map { $0 != g } ?? true
        if let old = geo, old.sec != g.sec { p = CGFloat(page) * g.sec }
        if geo == nil { p = CGFloat(page) * g.sec }
        geo = g
        if bgHost == nil {
            bgHost = newHost(background, in: view)
            titleHost = newHost(title, in: view)
            // The background, then the title, then the sections (as home's ZStack was); the two behind take no touches.
            view.sendSubviewToBack(titleHost!.view); view.sendSubviewToBack(bgHost!.view)
            bgHost?.view.isUserInteractionEnabled = false
            titleHost?.view.isUserInteractionEnabled = false
        } else {
            bgHost?.rootView = background
            titleHost?.rootView = title
        }
        while hosts.count < sections.count { hosts.append(newHost(sections[hosts.count], in: strip)) }
        for (i, s) in sections.enumerated() { hosts[i].rootView = s }
        if resized {
            stopLanding()
            // Laid out by bounds and position (anchor at the top left): a frame under a transform is undefined.
            func lay(_ v: UIView?, _ r: CGRect) { guard let v else { return }; v.layer.bounds = CGRect(origin: .zero, size: r.size); v.layer.position = r.origin }
            lay(bgHost?.view, CGRect(x: 0, y: 0, width: g.bgSide, height: g.H))
            lay(titleHost?.view, CGRect(x: g.leading + 10, y: g.titleTop, width: g.titleW + 40, height: g.titleH))
            strip.layer.anchorPoint = .zero
            lay(strip, CGRect(x: 0, y: g.sectionsTop, width: g.ring * 3, height: max(1, g.H - g.sectionsTop)))
            for h in hosts { h.view.layer.bounds = CGRect(x: 0, y: 0, width: g.sec, height: max(1, g.H - g.sectionsTop)) }
            apply(p, span: (p, p))
        }
    }

    private func newHost(_ v: AnyView, in parent: UIView) -> UIHostingController<AnyView> {
        let h = UIHostingController(rootView: v)
        h.safeAreaRegions = []
        h.sizingOptions = []
        h.view.backgroundColor = .clear
        h.view.layer.anchorPoint = .zero
        addChild(h)
        parent.addSubview(h.view)
        h.didMove(toParent: self)
        return h
    }

    // MARK: Where everything is for a position

    // The ring position in 0..<ring.
    private func q(_ x: CGFloat) -> CGFloat { guard let g = geo, g.ring > 0 else { return 0 }; let r = x.truncatingRemainder(dividingBy: g.ring); return r < 0 ? r + g.ring : r }
    // The title: the slowest layer across the sections; across the wrap it leaves in the direction it was going and comes
    // back from the other side.
    private func titleX(_ x: CGFloat) -> CGFloat {
        guard let g = geo else { return 0 }
        let q = q(x)
        if q <= g.travel { return -g.titleRate * q }
        let f = (q - g.travel) / max(g.sec, 1)
        let out = -(g.titleW + g.leading + 30)
        if f < 0.5 { let k = f / 0.5; return -g.titleRate * g.travel + (out - (-g.titleRate * g.travel)) * k }
        let k = (f - 0.5) / 0.5
        return g.W + (0 - g.W) * k
    }
    // The background: its own rate across the sections, swung back to its start across the wrap (never cut).
    private func bgX(_ x: CGFloat) -> CGFloat {
        guard let g = geo else { return 0 }
        let q = q(x)
        if q <= g.travel { return -g.bgRate * q }
        let f = (q - g.travel) / max(g.sec, 1)
        return -g.bgRate * g.travel * (1 - f)
    }
    // Each section on the turn of the ring that covers [lo − sec, lo − sec + ring): with the ring at least the screen and
    // two sections wide, every section shows at most once over a landing's whole span.
    private func place(span: (CGFloat, CGFloat)) {
        guard let g = geo else { return }
        let lo = min(span.0, span.1) - g.sec
        // The strip's own origin is a turn of the ring, so its layer moves by less than a ring.
        for (i, h) in hosts.enumerated() {
            var x = CGFloat(i) * g.sec
            let k = ((lo - x) / g.ring).rounded(.up)
            x += k * g.ring
            h.view.layer.position = CGPoint(x: x - base, y: 0)
        }
    }
    private var base: CGFloat = 0
    private func stripX(_ x: CGFloat) -> CGFloat { (geo?.leading ?? 0) - (x - base) }

    private func apply(_ x: CGFloat, span: (CGFloat, CGFloat)) {
        guard let g = geo else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Keep the strip's numbers small: its base moves by whole turns of the ring.
        base = (min(span.0, span.1) / g.ring).rounded(.down) * g.ring - g.ring
        place(span: span)
        strip.layer.setAffineTransform(CGAffineTransform(translationX: stripX(x), y: 0))
        titleHost?.view.layer.setAffineTransform(CGAffineTransform(translationX: titleX(x), y: 0))
        bgHost?.view.layer.setAffineTransform(CGAffineTransform(translationX: bgX(x), y: 0))
        CATransaction.commit()
    }

    // MARK: The finger

    @objc private func panned(_ r: UIPanGestureRecognizer) {
        guard let g = geo else { return }
        switch r.state {
        case .began:
            stopLanding()
            startP = p + r.translation(in: view).x
            moving(true)
            TouchTravel.swiped = true
        case .changed:
            p = startP - r.translation(in: view).x
            apply(p, span: (p, p))
        case .ended, .cancelled, .failed:
            p = startP - r.translation(in: view).x
            let v = -r.velocity(in: view).x
            let w = max(g.sec, 1)
            let from = (startP / w).rounded()
            let at = p / w
            var to: CGFloat = abs(v) > 0.5 * w ? (v > 0 ? at.rounded(.down) + 1 : at.rounded(.up) - 1) : at.rounded()
            to = max(from - 1, min(from + 1, to))
            releasedAt = CACurrentMediaTime()
            if to != from { tick.selectionChanged() }
            land(to * w, steps: Int(to - from), drag: (p - startP) / w, v: v / w)
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ r: UIGestureRecognizer) -> Bool {
        guard r === pan else { return true }
        let v = pan.velocity(in: view)
        return abs(v.x) > abs(v.y)
    }
    // The sections' own vertical scrolls wait for the panorama's pan to fail (it does at once on a vertical drag).
    func gestureRecognizer(_ r: UIGestureRecognizer, shouldBeRequiredToFailBy o: UIGestureRecognizer) -> Bool {
        r === pan && o.view is UIScrollView && o is UIPanGestureRecognizer && (o.view?.isDescendant(of: view) ?? false)
    }

    // MARK: Landing

    private func land(_ to: CGFloat, steps: Int = 0, drag: CGFloat = 0, v: CGFloat = 0) {
        guard let g = geo else { return }
        let from = p
        page = Int((q(to) / max(g.sec, 1)).rounded()) % g.count
        if abs(to - from) < 0.5 {
            p = to; apply(p, span: (p, p)); rested(steps: steps, drag: drag, v: v); return
        }
        let d = PageLander.duration
        let n = 30
        let ts = (0...n).map { Double($0) / Double(n) }
        let xs = ts.map { from + (to - from) * CGFloat(PageLander.ease($0)) }
        p = to
        apply(to, span: (from, to))
        landingID += 1
        let id = landingID
        landing = (to, CACurrentMediaTime(), from)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.landingID == id, self.landing != nil else { return }
                self.landing = nil
                self.rested(steps: steps, drag: drag, v: v)
            }
        }
        anim(strip.layer, xs.map(stripX), ts, d, jumps: false)
        if let t = titleHost?.view.layer { anim(t, xs.map(titleX), ts, d, jumps: true) }
        if let b = bgHost?.view.layer { anim(b, xs.map(bgX), ts, d, jumps: false) }
        CATransaction.commit()
    }
    private func anim(_ layer: CALayer, _ values: [CGFloat], _ times: [Double], _ d: Double, jumps: Bool) {
        var vs: [CGFloat] = [], ks: [Double] = []
        for (i, v) in values.enumerated() {
            // The title's leap from one side to the other across the wrap: off screen both sides, taken in no time.
            if jumps, let last = vs.last, abs(v - last) > (geo?.W ?? 400) * 0.9 { vs.append(last); ks.append(times[i]); vs.append(v); ks.append(times[i]); continue }
            vs.append(v); ks.append(times[i])
        }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = vs.map { NSNumber(value: Double($0)) }
        a.keyTimes = ks.map { NSNumber(value: $0) }
        a.calculationMode = .linear
        a.duration = d
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        layer.add(a, forKey: "land")
    }
    // Where a landing is on screen now, its animations taken off (a finger came down on it).
    private func stopLanding() {
        guard let l = landing else { return }
        landing = nil
        landingID += 1
        if let pres = strip.layer.presentation() {
            let tx = pres.affineTransform().tx
            p = (geo?.leading ?? 0) - tx + base
        } else { p = l.to }
        for layer in [strip.layer, titleHost?.view.layer, bgHost?.view.layer].compactMap({ $0 }) { layer.removeAnimation(forKey: "land") }
        apply(p, span: (p, p))
    }
    private func catchLanding() {
        guard landing != nil else { return }
        stopLanding()
        caught = true
        moving(true)
    }
    // Let go of a caught landing without a drag: it lands again from there.
    private func letGoOfCatch() {
        guard caught else { return }
        caught = false
        guard pan.state == .possible || pan.state == .failed, landing == nil, let g = geo else { return }
        land((p / max(g.sec, 1)).rounded() * g.sec)
    }
    private func rested(steps: Int, drag: CGFloat, v: CGFloat) {
        caught = false
        moving(false)
        // Back on the ring's first turn at rest, so the numbers never grow.
        if let g = geo { let r = q(p); if abs(r - p) > 0.5 { p = r; apply(p, span: (p, p)) }; page = Int((r / max(g.sec, 1)).rounded()) % g.count }
        let ms = releasedAt > 0 ? (CACurrentMediaTime() - releasedAt) * 1000 : 0
        let line = String(format: "land %d drag %.2f v %.2f settle_ms %.0f pano %d", steps, drag, v, ms, page)
        HitchLog.shared.note(line)
        MotionProbe.shared.note(line)
        releasedAt = 0
    }
    private func moving(_ on: Bool) {
        HomeSwipe.moving = on
        Store.shared.scrolling = on
    }
}

// A finger's touch-down and lift anywhere on the panorama, for catching a landing; it never recognises or delays anything.
private final class Catch: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var down: () -> Void = {}
    var up: () -> Void = {}
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent) { down() }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent) { finish(e) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent) { finish(e) }
    private func finish(_ e: UIEvent) {
        if e.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { up(); state = .failed }
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
}
#endif
