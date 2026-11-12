import Foundation
import CoreGraphics

// The flick, as one hand on one thing that can go to the TV: every row and card that sends reads the finger through this,
// so the lift, the throw, the put-back and the tap are the same everywhere (Richard, 2026-11-11: "flicking isnt working
// consistently it should be the basis of everything"). Plain values in, plain answers out, no views: the scripted hands
// at the foot drive it exactly as a finger does, and the build and this Mac run them.
//
// In a list the thing is lifted after a hold (a plain swipe scrolls, never a throw: the 2026-11-10 ruling); a card with
// nothing under it to scroll is in the hand from the first touch. From the lift on it follows the finger; let go upward,
// carried far enough or thrown fast enough, it goes to the TV; let go where it was lifted, it was a press that ran long,
// and a press is the pick; let go anywhere else, it goes back.
struct FlickHand {
    struct Rules: Equatable {
        // How long the finger rests before the thing is in the hand. 0: at once.
        var hold: Double
        // Moved this far before the hold is done: a scroll, and the hand lets go of it.
        var slop: CGFloat = 10
        // Let go within this of where it was lifted: a press that ran long, so a tap.
        var still: CGFloat = 10
        // Carried up this far and let go, at any speed: thrown.
        var carry: CGFloat = 66
        // Once lit, brought back down this far under the line before it goes out.
        var unarm: CGFloat = 24
        // Or flung up this fast (points a second, the fastest stretch of the last tenth of a second, so a finger that
        // slows as it leaves still counts) having risen at least `flingRise`.
        var fling: CGFloat = 280
        var flingRise: CGFloat = 30
        // Up, not sideways: the rise is at least this share of the sideways travel (about 60° either side of straight up).
        var steep: CGFloat = 0.6
        // In a list, a throw is only meant when the thing was in the hand first: still for this long after the lift, or
        // carried at least `carried` in all. A thumb resting on a row and then swiping the list up lifts the row just as
        // the swipe begins; that's a scroll that came late, and it never sends anything.
        var beat: Double = 0.08
        // By the finger's own clock: the least time after the lift for a move to be an answer to it (seeing or feeling
        // the row come up and then moving takes a person longer than this).
        var react: Double = 0.15
        var carried: Double = 0.25
        static let list = Rules(hold: 0.3)
        static let card = Rules(hold: 0, beat: 0, carried: 0)
    }
    enum Phase: Equatable { case idle, pressing, lifted, yielded, done }
    // What the thing does while the finger is on it.
    enum Event: Equatable {
        case lifted
        // Let go now and it goes (true), or it no longer would (false): felt as a detent, seen as its edge lit.
        case armed(Bool)
        // The finger moved before the hold: the list's.
        case yielded
    }
    // How it ended.
    enum Outcome: Equatable {
        // Let go before the hold: an ordinary tap, the button's own.
        case quickTap
        // Lifted and let go where it was: a tap that ran long, the pick.
        case longTap
        case thrown
        case putBack
        // Taken away by the system (a call, the scroll view, the view gone): back to rest, silently.
        case cancelled
        // Nothing of this hand's: it was a scroll, or it had already ended.
        case none
    }
    let rules: Rules
    private(set) var phase = Phase.idle
    private var downAt = 0.0, downPoint = CGPoint.zero
    private(set) var liftedAt = 0.0
    private var liftPoint = CGPoint.zero
    private var movedAt: Double?
    private var samples: [(t: Double, p: CGPoint)] = []
    private(set) var armed = false
    // The finger as the screen itself timed it (each touch's own timestamp, in seconds from the touch-down), when there
    // is such a reading. The callbacks above come when the main thread gets to them: a lift that holds it for 0.4 s makes
    // a swipe that began the instant the row lifted look like a carry begun later (CI c1a69a9: tv-finger-latescroll sent
    // in all three postures), and bunches a quick flick's moves so it reads slow. The finger's own clock settles both:
    // moving already as the row lifted is a scroll come late, never a throw; and its own speed as it left is the fling.
    var real: [(t: Double, p: CGPoint)]?
    // When the row lifted, by the same clock (seconds from the touch-down).
    var realLift: Double?
    init(_ rules: Rules) { self.rules = rules }
    // Already on its way before he could have seen the lift and answered it, by the finger's own clock: it began as a
    // scroll. Any reported position more than twice `still` from where it came down, before the lift (`lift`, as the
    // screen's clock read it when the row lifted; the hold at the earliest) plus `react`. Never interpolated: a finger
    // that reports no moves is resting (interpolating across a rest read a flick begun after one as already moving).
    static func rushed(_ real: [(t: Double, p: CGPoint)], _ rules: Rules, lift: Double? = nil) -> Bool {
        guard rules.hold > 0, let first = real.first else { return false }
        let until = max(rules.hold, lift ?? 0) + rules.react
        return real.contains { $0.t < until && hypot($0.p.x - first.p.x, $0.p.y - first.p.y) > rules.still * 2 }
    }
    // The fastest upward stretch of at least 30 ms ending in the last quarter second, in points a second (negative is
    // up): a flick that eases to a stop and rests a moment before the finger leaves the glass is still the flick (a
    // finger at rest reports no moves, so the rest itself has no samples to read).
    static func speed(_ samples: [(t: Double, p: CGPoint)]) -> CGVector {
        guard let last = samples.last else { return .zero }
        var best = CGVector.zero
        for i in samples.indices.reversed() {
            let end = samples[i]
            if last.t - end.t > 0.25 { break }
            guard let j = samples[..<i].lastIndex(where: { end.t - $0.t >= 0.03 }) else { continue }
            let dt = end.t - samples[j].t
            let v = CGVector(dx: (end.p.x - samples[j].p.x) / dt, dy: (end.p.y - samples[j].p.y) / dt)
            if v.dy < best.dy { best = v }
        }
        return best
    }
    // How it left, for the flight: the finger's own speed when that's the faster reading.
    var leaving: CGVector {
        if let r = real { let v = Self.speed(r); if v.dy < velocity.dy { return v } }
        return velocity
    }
    // For the build's logs: what the finger's own clock said.
    var realNote: String {
        guard let r = real, let f = r.first, let l = r.last else { return "real none" }
        let moved = r.first { hypot($0.p.x - f.p.x, $0.p.y - f.p.y) > rules.still }?.t ?? -1
        let v = Self.speed(r)
        return String(format: "real n=%d moved=%.2f up=%.2f rise=%.0f rv=%.0f rushed=%d", r.count, moved, l.t, f.p.y - l.p.y, v.dy, isRushed ? 1 : 0) + String(format: " lift=%.2f", realLift ?? -1)
    }
    private var isRushed: Bool { real.map { Self.rushed($0, rules, lift: realLift) } ?? false }

    // Where the finger has it, from where it was lifted.
    var offset: CGSize {
        guard let last = samples.last, phase == .lifted || phase == .done else { return .zero }
        return CGSize(width: last.p.x - liftPoint.x, height: last.p.y - liftPoint.y)
    }
    // How the finger was moving as it left: the fastest upward stretch over the last tenth of a second, in points a
    // second (negative is up), with its sideways part.
    var velocity: CGVector {
        guard let last = samples.last else { return .zero }
        var best = CGVector.zero
        // Every stretch of at least 30 ms that ends in the last 150 ms, the fastest upward one.
        for i in samples.indices.reversed() {
            let end = samples[i]
            if last.t - end.t > 0.15 { break }
            guard let j = samples[..<i].lastIndex(where: { end.t - $0.t >= 0.03 }) else { continue }
            let dt = end.t - samples[j].t
            let v = CGVector(dx: (end.p.x - samples[j].p.x) / dt, dy: (end.p.y - samples[j].p.y) / dt)
            if v.dy < best.dy { best = v }
        }
        // Over the last two samples too, and the whole tenth, so a slow steady carry still has its speed.
        if best == .zero, let first = samples.last(where: { last.t - $0.t > 0.012 }) {
            let dt = last.t - first.t
            best = CGVector(dx: (last.p.x - first.p.x) / dt, dy: (last.p.y - first.p.y) / dt)
        }
        return best
    }

    mutating func down(_ p: CGPoint, at t: Double) -> [Event] {
        self = FlickHand(rules)
        phase = .pressing; downAt = t; downPoint = p
        samples = [(t, p)]
        return rules.hold <= 0 ? lift(at: t) : []
    }
    // The hold's own clock: the finger has rested long enough without moving away.
    mutating func held(at t: Double) -> [Event] {
        guard phase == .pressing, t - downAt >= rules.hold - 0.001 else { return [] }
        return lift(at: t)
    }
    mutating func move(_ p: CGPoint, at t: Double) -> [Event] {
        switch phase {
        case .pressing:
            if hypot(p.x - downPoint.x, p.y - downPoint.y) > rules.slop { phase = .yielded; return [.yielded] }
            samples.append((t, p))
            // The hold's clock may have been missed (a busy frame): the finger's own time says it's done.
            return t - downAt >= rules.hold ? lift(at: t) : []
        case .lifted:
            samples.append((t, p))
            if samples.count > 40 { samples.removeFirst(samples.count - 40) }
            if movedAt == nil, hypot(p.x - liftPoint.x, p.y - liftPoint.y) > rules.still { movedAt = t }
            // Lit at the line, and kept lit until it's brought well back under it (`unarm` below), so a finger resting on
            // the line doesn't flicker the edge on and off.
            let now = wouldThrow(at: t) || (armed && keepsArm(at: t))
            if now != armed { armed = now; return [.armed(now)] }
            return []
        default: return []
        }
    }
    // `fling`: the system's own reading of the finger's speed as it left, when there is one; either reading counts.
    mutating func up(_ p: CGPoint, at t: Double, fling: CGVector? = nil) -> Outcome {
        switch phase {
        case .pressing:
            phase = .done
            return .quickTap
        case .lifted:
            _ = move(p, at: t)
            phase = .done
            // Lit as he let go: it goes, as the edge said it would.
            if armed || wouldThrow(at: t) { return .thrown }
            if let f = fling, flung(f, rise: -offset.height), meant(at: t), steepEnough { return .thrown }
            if let r = real, flung(Self.speed(r), rise: -offset.height), meant(at: t), steepEnough { return .thrown }
            let o = offset
            if abs(o.width) < rules.still && abs(o.height) < rules.still && movedAt == nil { return .longTap }
            return .putBack
        default:
            return .none
        }
    }
    mutating func cancel() -> Outcome {
        let was = phase
        phase = .done
        return was == .lifted ? .cancelled : .none
    }

    private mutating func lift(at t: Double) -> [Event] {
        phase = .lifted; liftedAt = t
        liftPoint = samples.last?.p ?? downPoint
        samples = [(t, liftPoint)]
        movedAt = nil; armed = false
        return [.lifted]
    }
    // Let go now: would it go?
    func wouldThrow(at t: Double) -> Bool {
        guard phase == .lifted || phase == .done else { return false }
        let o = offset
        let rise = -o.height
        guard rise > 0, rise >= rules.steep * abs(o.width) else { return false }
        guard rise >= rules.carry || flung(velocity, rise: rise) else { return false }
        return meant(at: t)
    }
    private func flung(_ v: CGVector, rise: CGFloat) -> Bool {
        -v.dy >= rules.fling && rise >= rules.flingRise && -v.dy >= rules.steep * abs(v.dx)
    }
    // Already lit: stays lit while it's still up, steeply enough, within `unarm` of the line.
    private func keepsArm(at t: Double) -> Bool {
        let rise = -offset.height
        return rise >= rules.carry - rules.unarm && rise >= rules.steep * abs(offset.width) && meant(at: t)
    }
    private var steepEnough: Bool { let o = offset; return -o.height > 0 && -o.height >= rules.steep * abs(o.width) }
    private func meant(at t: Double) -> Bool {
        if rules.hold <= 0 { return true }
        // The finger's own clock, when there is one, is the only word on it.
        // Until it reads past the beat, it can't yet say: not meant (never lit early by a scroll's first moves).
        if let r = real { return (r.last?.t ?? 0) >= max(rules.hold, realLift ?? 0) + rules.react && !isRushed }
        guard let movedAt else { return false }
        return movedAt - liftedAt >= rules.beat || t - liftedAt >= rules.carried
    }
}

// MARK: - Scripted hands
// Each is a finger's whole touch, sample by sample, and what the flick must make of it. A line with "pass":false is a
// failure the build reports; ci/flick-hands/main.swift runs the same scripts on the Mac.
extension FlickHand {
    enum Step { case down(CGFloat, CGFloat), move(CGFloat, CGFloat), held, up(CGFloat, CGFloat), upFling(CGFloat, CGFloat, CGFloat), cancel }
    struct Script { let name: String; let rules: Rules; let steps: [(Double, Step)]; let want: Outcome; let what: String; var events: [Event]? = nil
        // The screen's own timing of the same finger, when the callbacks came late (see `real`).
        var real: [(t: Double, p: CGPoint)]? = nil }
    // A real finger's samples: down at (x, y), still until `from`, then by (dx, dy) over `ms` in 30 ms steps (as the
    // build's injected fingers move), eased out if asked, and resting `rest` seconds before it lifts.
    static func feel(_ x: CGFloat, _ y: CGFloat, from: Double, by dx: CGFloat, _ dy: CGFloat, ms: Double, ease: Bool = false, rest: Double = 0) -> [(t: Double, p: CGPoint)] {
        var r: [(t: Double, p: CGPoint)] = [(0, CGPoint(x: x, y: y)), (from, CGPoint(x: x, y: y))]
        let n = max(1, Int(ms / 30))
        for i in 1...n {
            var f = CGFloat(i) / CGFloat(n)
            if ease { f = 1 - (1 - f) * (1 - f) }
            r.append((from + Double(i) * ms / 1000 / Double(n), CGPoint(x: x + dx * f, y: y + dy * f)))
        }
        if rest > 0, let l = r.last { r.append((l.t + rest, l.p)) }
        return r
    }
    // A straight stroke from (x0, y0) by (dx, dy) over `ms`, at 120 samples a second.
    static func stroke(from t0: Double, _ x0: CGFloat, _ y0: CGFloat, by dx: CGFloat, _ dy: CGFloat, ms: Double, ease: Bool = false) -> [(Double, Step)] {
        let n = max(1, Int(ms / 8.33))
        return (1...n).map { i in
            var f = CGFloat(i) / CGFloat(n)
            // Easing out: fast at first, slowing to a stop as it leaves.
            if ease { f = 1 - (1 - f) * (1 - f) }
            return (t0 + Double(i) * ms / 1000 / Double(n), .move(x0 + dx * f, y0 + dy * f))
        }
    }
    static let scripts: [Script] = {
        let L = Rules.list, C = Rules.card
        var s: [Script] = []
        // Lists: the hold, then the throw.
        s.append(Script(name: "hold-then-carry-up", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.45, 200, 400, by: 6, -140, ms: 300) + [(0.76, .up(206, 260))],
                        want: .thrown, what: "held, then carried 140 pt up: sent", events: [.lifted, .armed(true)]))
        s.append(Script(name: "hold-then-short-fast-flick", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.42, 200, 400, by: 4, -45, ms: 80) + [(0.51, .up(204, 355))],
                        want: .thrown, what: "held, then a short sharp flick of 45 pt in 80 ms: sent (was put back: under 90 pt)"))
        s.append(Script(name: "flick-that-slows-as-it-leaves", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.42, 200, 400, by: 0, -60, ms: 130, ease: true) + [(0.58, .up(200, 340))],
                        want: .thrown, what: "a flick that eases to a stop before the finger lifts: its fastest stretch counts, sent"))
        s.append(Script(name: "carry-up-then-pause", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.4, 200, 400, by: 0, -120, ms: 300) + [(1.2, .up(200, 280))],
                        want: .thrown, what: "carried well up, held there, then let go: sent"))
        s.append(Script(name: "diagonal-throw", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.45, 200, 400, by: 90, -120, ms: 200) + [(0.66, .up(290, 280))],
                        want: .thrown, what: "thrown up and to the side (37° off upright): sent"))
        // Lists: never steal a scroll.
        s.append(Script(name: "plain-swipe-up", rules: L,
                        steps: [(0, .down(200, 400))] + stroke(from: 0.02, 200, 400, by: 0, -200, ms: 150) + [(0.18, .up(200, 200))],
                        want: .none, what: "a plain swipe up the list: a scroll, nothing lifted, nothing sent", events: [.yielded]))
        s.append(Script(name: "slow-drag-starting-early", rules: L,
                        steps: [(0, .down(200, 400))] + stroke(from: 0.05, 200, 400, by: 0, -60, ms: 400) + [(0.46, .up(200, 340))],
                        want: .none, what: "a slow scroll that starts before the hold: the list's"))
        s.append(Script(name: "late-scroll-after-resting-thumb", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.31, 200, 400, by: 0, -160, ms: 120) + [(0.44, .up(200, 240))],
                        want: .putBack, what: "a resting thumb that swipes the moment the row lifts: a scroll come late, never sent"))
        s.append(Script(name: "jitter-under-slop", rules: L,
                        steps: [(0, .down(200, 400)), (0.1, .move(203, 404)), (0.2, .move(198, 397)), (0.3, .held), (0.5, .up(201, 402))],
                        want: .longTap, what: "a press that wobbles a little and runs long: a tap, the pick"))
        // The moves came bunched (the main thread busy as the row lifted), so the hand's own speed reads low; the system's
        // reading of the release says it was flung.
        s.append(Script(name: "bunched-moves-system-fling", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held), (0.55, .move(200, 395)), (0.56, .move(200, 380)), (0.57, .move(200, 362)), (0.75, .upFling(200, 355, -900))],
                        want: .thrown, what: "a flick whose moves arrived bunched: the system's own speed at the release counts, sent"))
        s.append(Script(name: "system-fling-sideways", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.45, 200, 400, by: 120, -30, ms: 150) + [(0.62, .upFling(320, 370, -900))],
                        want: .putBack, what: "flung, but carried sideways: back, nothing sent"))
        // The callbacks came late (a 0.4 s busy frame as the row lifted): by them, every move came well after the lift.
        // By the finger's own clock, one swipe began as the row lifted (a scroll: never sent) and one flick came after a
        // rest (sent, at its own speed, not the bunched callbacks').
        s.append(Script(name: "late-scroll-busy-frame", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held), (0.72, .move(200, 300)), (0.73, .move(200, 250)), (0.74, .up(200, 240))],
                        want: .putBack, what: "a swipe the instant the row lifted, its moves handled 0.4 s late: by the finger's clock a scroll, never sent",
                        real: feel(200, 400, from: 0.31, by: 0, -160, ms: 120)))
        s.append(Script(name: "late-scroll-carried-far", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held), (0.72, .move(200, 200)), (1.1, .up(200, 100))],
                        want: .putBack, what: "a long scroll begun as the row lifted, carried 300 pt: still a scroll, never sent",
                        real: feel(200, 400, from: 0.32, by: 0, -300, ms: 400)))
        s.append(Script(name: "short-flick-busy-frame", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held), (0.80, .move(200, 380)), (0.81, .move(200, 356)), (0.82, .up(200, 355))],
                        want: .thrown, what: "held, then a 45 pt flick in 90 ms, its moves bunched by a busy frame: sent at the finger's own speed",
                        real: feel(200, 400, from: 0.45, by: 0, -45, ms: 90)))
        s.append(Script(name: "ease-flick-busy-frame", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held), (0.85, .move(200, 345)), (0.86, .up(200, 336))],
                        want: .thrown, what: "held, then a flick easing to a stop, handled late: sent",
                        real: feel(200, 400, from: 0.45, by: 0, -64, ms: 150, ease: true, rest: 0.03)))
        s.append(Script(name: "rest-then-flick-no-samples-at-rest", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held), (0.8, .move(200, 370)), (0.81, .move(200, 330)), (0.82, .up(200, 309))],
                        want: .thrown, what: "still for 0.45 s with no moves reported, then a 91 pt flick: sent (a rest is never read as a slow move)",
                        real: [(0, CGPoint(x: 200, y: 400)), (0.48, CGPoint(x: 200, y: 370)), (0.51, CGPoint(x: 200, y: 330)), (0.54, CGPoint(x: 200, y: 309))]))
        s.append(Script(name: "carry-busy-frame", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held), (0.8, .move(200, 300)), (1.0, .move(200, 160)), (1.5, .up(200, 160))],
                        want: .thrown, what: "held, carried 240 pt up and rested: sent",
                        real: feel(200, 400, from: 0.45, by: 0, -240, ms: 600, rest: 0.3)))
        s.append(Script(name: "back-down-busy-frame", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held), (0.8, .move(200, 160)), (1.6, .up(200, 395))],
                        want: .putBack, what: "carried up then all the way back down: not sent",
                        real: feel(200, 400, from: 0.45, by: 0, -240, ms: 400) + feel(200, 160, from: 0, by: 0, 235, ms: 400).dropFirst(2).map { (t: $0.t + 0.85, p: $0.p) }))
        // Put back.
        s.append(Script(name: "hold-then-drag-down", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.45, 200, 400, by: 0, 90, ms: 250) + [(0.72, .up(200, 490))],
                        want: .putBack, what: "lifted and pulled down: back where it was, nothing sent"))
        s.append(Script(name: "hold-then-sideways", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.45, 200, 400, by: 140, -30, ms: 250) + [(0.72, .up(340, 370))],
                        want: .putBack, what: "lifted and carried sideways: back, nothing sent"))
        s.append(Script(name: "up-then-back-down", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.45, 200, 400, by: 0, -120, ms: 200)
                            + stroke(from: 0.65, 200, 280, by: 0, 115, ms: 250) + [(0.95, .up(200, 395))],
                        want: .putBack, what: "carried up past the line, then brought back down: changed his mind, not sent",
                        events: [.lifted, .armed(true), .armed(false)]))
        s.append(Script(name: "resting-on-the-line", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.45, 200, 400, by: 0, -86, ms: 400)
                            + stroke(from: 0.85, 200, 314, by: 0, 20, ms: 300) + [(1.4, .up(200, 334))],
                        want: .thrown, what: "carried just past the line, then sagging 20 pt under it: the edge stays lit, and it goes",
                        events: [.lifted, .armed(true)]))
        s.append(Script(name: "cancelled-while-lifted", rules: L,
                        steps: [(0, .down(200, 400)), (0.3, .held)] + stroke(from: 0.4, 200, 400, by: 0, -50, ms: 100) + [(0.55, .cancel)],
                        want: .cancelled, what: "the system takes the touch while it's in the hand: put back, never left floating"))
        s.append(Script(name: "quick-tap", rules: L,
                        steps: [(0, .down(200, 400)), (0.09, .up(200, 400))],
                        want: .quickTap, what: "a quick tap: the row's own button, the pick"))
        // The card: in the hand from the first touch, the same throw.
        s.append(Script(name: "card-tap", rules: C,
                        steps: [(0, .down(200, 500)), (0.1, .up(201, 500))],
                        want: .longTap, what: "a tap on the card: sent"))
        s.append(Script(name: "card-flick", rules: C,
                        steps: [(0, .down(200, 500))] + stroke(from: 0.02, 200, 500, by: 0, -50, ms: 90) + [(0.12, .up(200, 450))],
                        want: .thrown, what: "the card flicked up at once, no hold: sent"))
        s.append(Script(name: "card-pull-down", rules: C,
                        steps: [(0, .down(200, 500))] + stroke(from: 0.02, 200, 500, by: 0, 80, ms: 200) + [(0.25, .up(200, 580))],
                        want: .putBack, what: "the card pulled down: back"))
        s.append(Script(name: "card-slow-small-lift", rules: C,
                        steps: [(0, .down(200, 500))] + stroke(from: 0.02, 200, 500, by: 0, -40, ms: 600) + [(0.64, .up(200, 460))],
                        want: .putBack, what: "the card nudged up 40 pt, slowly: back, not sent"))
        return s
    }()
    // Each script through a fresh hand: one line of what it did, one of whether that was right.
    static func runScripts() -> [String] {
        var lines: [String] = []
        for script in scripts {
            var h = FlickHand(script.rules)
            var events: [Event] = []
            var real = false
            var outcome = Outcome.none
            for (t, step) in script.steps {
                switch step {
                case .down(let x, let y): events += h.down(CGPoint(x: x, y: y), at: t)
                case .move(let x, let y): events += h.move(CGPoint(x: x, y: y), at: t)
                case .held: events += h.held(at: t)
                case .up(let x, let y): if !real, let r = script.real { h.real = r; real = true }; outcome = h.up(CGPoint(x: x, y: y), at: t)
                case .upFling(let x, let y, let vy): outcome = h.up(CGPoint(x: x, y: y), at: t, fling: CGVector(dx: 0, dy: vy))
                case .cancel: outcome = h.cancel()
                }
            }
            let v = h.velocity
            let pass = outcome == script.want && (script.events == nil || script.events == events)
            lines.append(#"{"case":"\#(script.name)","out":"\#(outcome)","events":"\#(events.map { "\($0)" }.joined(separator: " "))","vy":\#(Int(v.dy)),"assert":"\#(script.what)","pass":\#(pass)}"#)
        }
        return lines
    }
}
