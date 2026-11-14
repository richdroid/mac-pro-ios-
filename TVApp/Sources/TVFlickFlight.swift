import SwiftUI
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

// What's in his hand and what's in the air, as one thing, drawn by Core Animation over the window.
//
// A card held on a shelf is lifted as its own picture (made from the card itself, before the lift: no screen capture, no
// second copy, nothing fetched). From then on the finger moves that one layer directly, point for point, with no view
// redrawn; let go upward, the same layer is the flight: it leaves at the finger's own speed on a spring worked out ahead
// (FlickSpring) and handed whole to the render server, so it runs however long the main thread is busy bringing the
// Remote up under it, and its cover lands exactly on the Remote's own picture of it. Let go anywhere else, it goes home
// on the same kind of spring, from the speed it was let go at. (Richard, 2026-11-14: "flicking suxks … everything is so
// janky": before, the hand was a SwiftUI copy redrawn per touch, swapped at the release for a smaller screen capture of
// itself that started again from rest.)
//
// A stream row or the flick page's card keeps its own SwiftUI look in the hand; let go, a still of it flies here the
// same way, at the finger's speed, with the poster coming up over it.
@MainActor enum RenderFlight {
    #if os(iOS) || FLIGHTCHECK
    // The Remote's soft ground, opening under whatever flies.
    private static var ground: UIView?
    // A row's flight: the poster that comes up over the row's still.
    private static var poster: UIView?
    // A row's flight: the still of the row. A shelf card: the card itself (its place and its lean).
    private static var card: UIView?
    // A shelf card only. `size`: how big it is (the swell in the hand, the flight's scale). `body`: the pop as it lifts.
    // `pic`: the whole card (cover, name band, shadow). `face`: the cover alone, which is what lands. `edge`: lit as it rises.
    private static var size: CALayer?
    private static var body: CALayer?
    private static var pic: CALayer?
    private static var face: CALayer?
    private static var edge: CAShapeLayer?
    private static var wide = false
    private static var hasImage = false
    private static var cardSize = CGSize.zero
    private static var faceHeight: CGFloat = 0
    private static var rest = CGPoint.zero
    // The still's own size, which a row's flight is scaled against.
    private static var base = CGSize.zero
    // How the finger left it, used by the first aim.
    private static var velocity = CGVector.zero
    // Where it's going, each number on its own spring: the lead's centre (x, y) and its size or scale (a, b); the ground's
    // centre and size.
    private static var lead: [FlickTravel] = []
    private static var under: [FlickTravel] = []
    // The fades that go with the first aim at the Remote, done once.
    private static var opened = false
    static var views: [UIView] { [ground, card, poster].compactMap { $0 } }
    private static var window: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first
    }
    #endif
    // In his hand, not yet let go.
    static private(set) var inHand = false
    // Which flight is in the air: a throw that lets go of its own checks it's still the one flying.
    static private(set) var serial = 0
    static var windowSize: CGSize {
        #if os(iOS) || FLIGHTCHECK
        return window?.bounds.size ?? .zero
        #else
        return .zero
        #endif
    }
    static var screenScale: CGFloat {
        #if os(iOS) || FLIGHTCHECK
        return window?.traitCollection.displayScale ?? 3
        #else
        return 2
        #endif
    }
    static var flying: Bool {
        #if os(iOS) || FLIGHTCHECK
        return ground != nil
        #else
        return false
        #endif
    }
    // Where the thing is right now as the screen shows it (window points), mid-spring included: the hand's picture or
    // the flight's. For the release (the flight starts exactly there) and for the build's meter.
    static func seen() -> CGRect? {
        #if os(iOS) || FLIGHTCHECK
        if let c = card, let s = size {
            let p = (c.layer.presentation() ?? c.layer).position, t = (s.presentation() ?? s).transform
            let w = cardSize.width * t.m11, h = cardSize.height * t.m22
            return CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        }
        if let v = card ?? poster { return (v.layer.presentation() ?? v.layer).frame }
        #endif
        return nil
    }

    // MARK: The card in the hand

    // Lifted off its shelf: `image` is the card as it's drawn at rest, `rect` where it is (window points), `cover` the
    // height of its picture (the rest is its name band). It comes up from the squeeze of the press it was under.
    static func pick(_ image: CGImage, at rect: CGRect, cover: CGFloat, corner: CGFloat, wide isWide: Bool) {
        #if os(iOS) || FLIGHTCHECK
        cancel()
        serial += 1
        guard let w = window, rect.width > 4, rect.height > 4 else { return }
        wide = isWide; hasImage = true; inHand = true
        cardSize = rect.size; faceHeight = min(max(4, cover), rect.height)
        rest = CGPoint(x: rect.midX, y: rect.midY)
        velocity = .zero
        let holder = UIView(frame: rect)
        holder.isUserInteractionEnabled = false
        let s = CALayer(), b = CALayer(), p = CALayer(), f = CALayer(), e = CAShapeLayer()
        let whole = CGRect(origin: .zero, size: rect.size)
        s.frame = whole; b.frame = whole; p.frame = whole
        p.contents = image; p.contentsGravity = .resize
        p.shadowColor = UIColor.black.cgColor; p.shadowOpacity = 0.55; p.shadowRadius = 26; p.shadowOffset = CGSize(width: 0, height: 18)
        p.shadowPath = CGPath(roundedRect: whole, cornerWidth: corner, cornerHeight: corner, transform: nil)
        // The cover alone, cut from the same picture, exactly over the card's own: what's left when the name band goes.
        f.frame = CGRect(x: 0, y: 0, width: rect.width, height: faceHeight)
        f.contents = image; f.contentsGravity = .resize
        f.contentsRect = CGRect(x: 0, y: 0, width: 1, height: faceHeight / rect.height)
        f.cornerRadius = corner; f.cornerCurve = .continuous; f.masksToBounds = true
        e.frame = f.frame
        e.path = CGPath(roundedRect: f.bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: corner, cornerHeight: corner, transform: nil)
        e.fillColor = nil; e.strokeColor = UIColor(TVLook.accent).cgColor; e.lineWidth = 1.5; e.opacity = 0
        b.addSublayer(p); b.addSublayer(f); b.addSublayer(e)
        s.addSublayer(b)
        holder.layer.addSublayer(s)
        s.transform = CATransform3DMakeScale(1.06, 1.06, 1)
        w.addSubview(holder)
        card = holder; size = s; body = b; pic = p; face = f; edge = e
        // The lift itself: up from the press's squeeze onto its shadow, with a little bounce, in the render server.
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.965 / 1.06; pop.toValue = 1
        pop.mass = 1; pop.stiffness = 500; pop.damping = 31; pop.initialVelocity = 0
        pop.duration = min(0.6, pop.settlingDuration)
        b.add(pop, forKey: "lift")
        let shade = CABasicAnimation(keyPath: "shadowOpacity")
        shade.fromValue = 0; shade.toValue = 0.55; shade.duration = 0.2
        shade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        p.add(shade, forKey: "lift")
        #endif
    }
    // The finger moved: the card is exactly that far from where it lifted, leaning the way it's going, a little bigger
    // as it rises, its edge lit once letting go would send it. Set straight on the layer: nothing is laid out or redrawn.
    static func carry(by d: CGSize, lean: Double, armed: Bool) {
        #if os(iOS) || FLIGHTCHECK
        guard inHand, let c = card, let s = size, let e = edge else { return }
        let rise = max(0, -d.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        c.layer.position = CGPoint(x: rest.x + d.width, y: rest.y + d.height)
        c.layer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(lean) * .pi / 180))
        let k = 1.06 + 0.06 * min(1, rise / 240)
        s.transform = CATransform3DMakeScale(k, k, 1)
        e.opacity = Float(armed ? 1 : 0.45 * min(1, rise / 80))
        e.lineWidth = armed ? 2 : 1.5
        CATransaction.commit()
        #endif
    }
    // Let go short of a throw: home on a spring, from the speed it was let go at; `done` once it's there (the shelf's own
    // card shows again in the same frame this one goes).
    static func putBack(velocity v: CGVector, done: @escaping () -> Void) {
        #if os(iOS) || FLIGHTCHECK
        guard inHand, let c = card, let s = size else { inHand = false; done(); return }
        inHand = false
        let now = CACurrentMediaTime(), tv = FlickSpring.tamed(v, most: 1800)
        let spring = FlickSpring(response: 0.32, damping: 0.8)
        let p = c.layer.position, k = Double(s.transform.m11)
        move(c.layer, FlickTravel(from: p.x, to: rest.x, speed: tv.dx, began: now, spring: spring),
             FlickTravel(from: p.y, to: rest.y, speed: tv.dy, began: now, spring: spring))
        scale(s, FlickTravel(from: k, to: 1, speed: 0, began: now, spring: spring), FlickTravel(from: k, to: 1, speed: 0, began: now, spring: spring))
        settle(c, quick: 0.2)
        if let p = pic { fade(p, "shadowOpacity", to: 0, 0.3) }
        CATransaction.flush()
        let mine = serial
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            done()
            if serial == mine { cancel() }
        }
        #else
        done()
        #endif
    }
    // Thrown: the same picture is the flight from here. The Remote's soft ground is laid under it, unseen until it's
    // aimed. Returns where it was let go, as drawn.
    @discardableResult static func throwCard(velocity v: CGVector, soft: TVImage?, tint: Color?) -> CGRect {
        #if os(iOS) || FLIGHTCHECK
        guard inHand, let w = window, let c = card else { return .zero }
        inHand = false
        velocity = FlickSpring.tamed(v)
        lead = []; under = []; opened = false
        let at = seen() ?? c.frame
        let g = makeGround(at, soft: soft, tint: tint)
        w.insertSubview(g, belowSubview: c)
        ground = g
        return at
        #else
        return .zero
        #endif
    }

    // MARK: A row's flight

    // Up at `from` (window points): a still of the row or card as it is on screen, the poster over it, the ground under.
    // `velocity`: how the finger left it (zero for a tap).
    static func launch(from: CGRect, image: TVImage?, soft: TVImage?, tint: Color?, wide isWide: Bool, velocity v: CGVector = .zero) {
        #if os(iOS) || FLIGHTCHECK
        cancel()
        serial += 1
        guard let w = window, from.width > 4, from.height > 4 else { return }
        wide = isWide
        velocity = FlickSpring.tamed(v)
        base = from.size
        let g = makeGround(from, soft: soft, tint: tint)
        // The row or card itself, as it is on screen, so the very first frame of the flight is what was under the finger.
        let c = w.resizableSnapshotView(from: from, afterScreenUpdates: false, withCapInsets: .zero)
        c?.frame = from
        c?.isUserInteractionEnabled = false
        let p = UIView(frame: from)
        p.layer.contents = image?.cgImage
        p.layer.contentsGravity = .resizeAspectFill
        p.layer.cornerRadius = 14; p.layer.cornerCurve = .continuous; p.clipsToBounds = true
        // The poster comes up over the row's still as the shape opens (not cut in over the row in the first frame).
        p.alpha = 0
        p.isUserInteractionEnabled = false
        w.addSubview(g)
        if let c { w.addSubview(c) }
        w.addSubview(p)
        ground = g; poster = p; card = c
        hasImage = image != nil
        #endif
    }
    // The picture, arrived after it left (not in memory at the pick): it comes up over the still wherever the flight is.
    static func picture(_ image: TVImage) {
        #if os(iOS) || FLIGHTCHECK
        guard let p = poster, !hasImage else { return }
        p.layer.contents = image.cgImage; hasImage = true
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            p.alpha = 1; if size == nil { card?.alpha = 0 }
        }
        CATransaction.flush()
        #endif
    }

    // MARK: The flight

    // Toward the Remote's picture, `to` in window points; again later, from wherever it is and however fast it's going,
    // if that place moves. The first aim leaves at the finger's speed.
    static func aim(_ to: CGRect, first: Bool = false, flush: Bool = true) {
        #if os(iOS) || FLIGHTCHECK
        guard let g = ground, to.width > 20 else { return }
        let now = CACurrentMediaTime()
        if let c = card, let s = size {
            // A shelf card: its cover lands on the Remote's own, the card scaled as one so the cover fits it.
            let land = landing(in: to)
            let sx = land.width / max(1, cardSize.width), sy = land.height / max(1, faceHeight)
            go(&lead, from: [c.layer.position.x, c.layer.position.y, s.transform.m11, s.transform.m22],
               to: [land.midX, land.midY + (cardSize.height - faceHeight) / 2 * sy, sx, sy], now: now)
            move(c.layer, lead[0], lead[1])
            scale(s, lead[2], lead[3])
            // Its corner as the Remote's poster has it, at the size it lands.
            face?.cornerRadius = (wide ? TVLook.card : 8) / max(0.2, sx)
        } else if let p = poster {
            // A row: the poster opens from the row's shape into the Remote's framed poster, the row's still under it.
            let end = inner(to)
            go(&lead, from: [p.layer.position.x, p.layer.position.y, p.layer.bounds.width, p.layer.bounds.height],
               to: [end.midX, end.midY, end.width, end.height], now: now)
            move(p.layer, lead[0], lead[1])
            resize(p.layer, lead[2], lead[3])
            if let c = card, base.width > 0, base.height > 0 {
                move(c.layer, lead[0], lead[1])
                scale(c.layer, shrunk(lead[2], by: base.width), shrunk(lead[3], by: base.height))
            }
        }
        go(&under, from: [g.layer.position.x, g.layer.position.y, g.layer.bounds.width, g.layer.bounds.height],
           to: [to.midX, to.midY, to.width, to.height], now: now)
        move(g.layer, under[0], under[1])
        resize(g.layer, under[2], under[3])
        if !opened {
            opened = true
            let shelf = size != nil
            if let c = card, shelf { settle(c, quick: 0.2) }
            if let p = pic { fade(p, "opacity", to: 0, 0.2) }
            UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                g.alpha = 1; g.layer.cornerRadius = TVLook.card
                if let p = poster {
                    p.layer.cornerRadius = wide ? TVLook.card : 8
                    // With no picture yet, the Remote's own stand-in (the app's purple) rather than the row squeezed into
                    // a poster's shape.
                    if !hasImage { p.backgroundColor = UIColor(red: 0x35 / 255, green: 0x2B / 255, blue: 0x4E / 255, alpha: 1) }
                    p.alpha = 1
                    card?.alpha = 0
                }
            }
        }
        // Sent to the render server now, not at the end of this turn: the turn that brings the Remote up is the long one.
        if flush { CATransaction.flush() }
        #endif
    }
    // On its way at once, toward where the Remote's picture is (or, not known yet, on up the way it was thrown), for a
    // thing thrown before its pick is made: it never sits still where it was let go. The pick re-aims it from wherever
    // it is.
    static func rise(toward slot: CGRect?) {
        #if os(iOS) || FLIGHTCHECK
        guard let g = ground, let w = window else { return }
        if let slot, slot.width > 20, w.bounds.contains(CGPoint(x: slot.midX, y: slot.midY)) { aim(slot, first: true, flush: true); return }
        // Not known: only moved, as it is, on up and kept whole on the screen.
        guard let v = card ?? poster else { return }
        let now = CACurrentMediaTime()
        let at = seen() ?? v.frame
        let top = w.safeAreaInsets.top + 16
        let dy = max(top, at.minY - 140) - at.minY
        let p = v.layer.position
        if let s = size {
            go(&lead, from: [p.x, p.y, s.transform.m11, s.transform.m22], to: [p.x, p.y + dy, s.transform.m11, s.transform.m22], now: now)
            move(v.layer, lead[0], lead[1])
            settle(v, quick: 0.2)
        } else {
            go(&lead, from: [p.x, p.y, v.layer.bounds.width, v.layer.bounds.height], to: [p.x, p.y + dy, v.layer.bounds.width, v.layer.bounds.height], now: now)
            for l in [poster?.layer, card?.layer].compactMap({ $0 }) { move(l, lead[0], lead[1]) }
        }
        let q = g.layer.position
        go(&under, from: [q.x, q.y, g.layer.bounds.width, g.layer.bounds.height], to: [q.x, q.y + dy, g.layer.bounds.width, g.layer.bounds.height], now: now)
        move(g.layer, under[0], under[1])
        CATransaction.flush()
        #endif
    }
    // Landed: the Remote's own picture is coming up under it; it goes as that one arrives.
    static func land(after delay: Double = 0.1) {
        #if os(iOS) || FLIGHTCHECK
        let all = views
        forget()
        UIView.animate(withDuration: 0.15, delay: delay, options: [.curveEaseOut]) { all.forEach { $0.alpha = 0 } } completion: { _ in all.forEach { $0.removeFromSuperview() } }
        #endif
    }
    static func cancel() {
        #if os(iOS) || FLIGHTCHECK
        views.forEach { $0.removeFromSuperview() }
        forget()
        #endif
    }

    #if os(iOS) || FLIGHTCHECK
    private static func forget() {
        ground = nil; poster = nil; card = nil
        size = nil; body = nil; pic = nil; face = nil; edge = nil
        inHand = false; lead = []; under = []; opened = false; velocity = .zero
    }
    // Where the framed poster sits in the Remote's picture: its height less 14 pt each side, 2:3, centred.
    private static func inner(_ to: CGRect) -> CGRect {
        if wide { return to }
        let h = max(0, to.height - 28), w = (h * 2 / 3).rounded()
        return CGRect(x: to.midX - w / 2, y: to.minY + 14, width: w, height: h)
    }
    // Where a shelf card's cover lands: as the Remote draws it, fitted inside its picture 14 pt in, in the cover's own
    // shape (a poster, a square sleeve); a wide still fills the picture.
    private static func landing(in to: CGRect) -> CGRect {
        if wide { return to }
        let shape = faceHeight > 0 ? cardSize.width / faceHeight : 2.0 / 3
        var h = max(0, to.height - 28), w = (h * shape).rounded()
        if w > to.width - 28 { w = max(0, to.width - 28); h = w / max(0.01, shape) }
        return CGRect(x: to.midX - w / 2, y: to.midY - h / 2, width: w, height: h)
    }
    // The Remote's soft ground as it starts: the poster at 16 px on black (or the title's colour), unseen, at `frame`.
    private static func makeGround(_ frame: CGRect, soft: TVImage?, tint: Color?) -> UIView {
        let g = UIView(frame: frame)
        g.backgroundColor = .black
        g.layer.cornerRadius = 14; g.layer.cornerCurve = .continuous; g.clipsToBounds = true
        g.alpha = 0
        g.isUserInteractionEnabled = false
        if let dim = soft?.cgImage.flatMap({ dimmed($0) }) {
            g.layer.contents = dim
            g.layer.contentsGravity = .resizeAspectFill
        } else {
            g.backgroundColor = UIColor(tint ?? Color(white: 0.15)).withAlphaComponent(0.7)
        }
        return g
    }
    // The tiny soft picture at 70 % on black, as one picture, so the ground is a single layer the render server can
    // stretch as it opens.
    private static func dimmed(_ image: CGImage) -> CGImage? {
        let w = max(1, image.width), h = max(1, image.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let all = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(all)
        ctx.setAlpha(0.7)
        ctx.draw(image, in: all)
        return ctx.makeImage()
    }
    // Each number set going toward its target: from where it stands with the finger's speed on the first aim, from its
    // true place and speed on any later one.
    private static func go(_ travels: inout [FlickTravel], from: [CGFloat], to: [CGFloat], now: Double) {
        if travels.count == to.count {
            travels = zip(travels, to).map { $0.aimed(at: Double($1), now: now) }
        } else {
            let speeds = [Double(velocity.dx), Double(velocity.dy), 0, 0]
            travels = to.indices.map { FlickTravel(from: Double(from[$0]), to: Double(to[$0]), speed: speeds[$0], began: now) }
        }
    }
    // The same travel as a share of `by` (a still scaled, where a picture is resized).
    private static func shrunk(_ t: FlickTravel, by: CGFloat) -> FlickTravel {
        let k = Double(max(1, by))
        return FlickTravel(from: t.from / k, to: t.to / k, speed: t.speed / k, began: t.began, spring: t.spring)
    }
    private static func keyframes(_ layer: CALayer, _ path: String, _ values: [Any]) {
        let a = CAKeyframeAnimation(keyPath: path)
        a.values = values
        a.duration = FlickSpring.time
        a.calculationMode = .linear
        layer.add(a, forKey: "fly-" + path)
    }
    private static func move(_ layer: CALayer, _ x: FlickTravel, _ y: FlickTravel) {
        let xs = x.frames(), ys = y.frames()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: x.to, y: y.to)
        CATransaction.commit()
        keyframes(layer, "position", zip(xs, ys).map { NSValue(cgPoint: CGPoint(x: $0, y: $1)) })
    }
    private static func resize(_ layer: CALayer, _ w: FlickTravel, _ h: FlickTravel) {
        let ws = w.frames(), hs = h.frames()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(x: 0, y: 0, width: max(0, w.to), height: max(0, h.to))
        CATransaction.commit()
        keyframes(layer, "bounds.size", zip(ws, hs).map { NSValue(cgSize: CGSize(width: max(0, $0), height: max(0, $1))) })
    }
    private static func scale(_ layer: CALayer, _ x: FlickTravel, _ y: FlickTravel) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(CGFloat(x.to), CGFloat(y.to), 1)
        CATransaction.commit()
        keyframes(layer, "transform.scale.x", x.frames().map { NSNumber(value: $0) })
        keyframes(layer, "transform.scale.y", y.frames().map { NSNumber(value: $0) })
    }
    private static func fade(_ layer: CALayer, _ path: String, to: Float, _ duration: Double) {
        let a = CABasicAnimation(keyPath: path)
        a.fromValue = (layer.presentation() ?? layer).value(forKeyPath: path)
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(to, forKeyPath: path)
        CATransaction.commit()
        layer.add(a, forKey: "fade-" + path)
    }
    // A shelf card out of the hand: upright again, its lit edge out.
    private static func settle(_ c: UIView, quick: Double) {
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = (c.layer.presentation() ?? c.layer).value(forKeyPath: "transform.rotation.z")
        turn.toValue = 0
        turn.duration = quick
        turn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        c.layer.setAffineTransform(.identity)
        CATransaction.commit()
        c.layer.add(turn, forKey: "upright")
        if let e = edge { fade(e, "opacity", to: 0, quick) }
    }
    #endif
}
