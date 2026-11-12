// Added to devicehubctl in the tv-flick workflow, before its touch and drag commands: one finger held, then carried
// through segments. path x y hold [x y seconds ease]...  (fractions of the screenshot; ease 1 slows each segment to a
// stop, as a finger that eases off before it lifts). A segment to the same point is a pause.
if args[1] == "path" {
  let device = simDevice(udid)
  guard device.state == "Booted" else { fail("\(device.name) is \(device.state).") }
  let n = numbers(args[2...])
  guard n.count >= 3, (n.count - 3) % 4 == 0 else { fail("path x y hold [x y seconds ease]...") }
  let d = liveDisplay(device.udid, override: displayOverride)
  touches(device.udid, display: digitizerTarget(d)) { send in
    var at = touchPoint((n[0], n[1]), device.udid, on: d)
    send(.start, at)
    usleep(useconds_t(n[2] * 1_000_000))
    var i = 3
    while i + 3 < n.count {
      let to = touchPoint((n[i], n[i + 1]), device.udid, on: d), seconds = n[i + 2], ease = n[i + 3] > 0
      // Each injected move takes Device Hub some 25–40 ms, so the steps are coarse: their count, not their pace, is asked.
      // Each step is due at its share of the segment's time from its start, so the time the injection itself takes is
      // inside the segment, not added to it (sleeping a whole step each time made a 0.09 s flick take 0.18 s: half its
      // speed, slower than a real flick, ef52168).
      let steps = max(1, Int(seconds / 0.03))
      let from = at
      let began = Date()
      for k in 1...steps {
        let due = seconds * Double(k) / Double(steps) - Date().timeIntervalSince(began)
        if due > 0 { usleep(useconds_t(due * 1_000_000)) }
        var t = Double(k) / Double(steps)
        if ease { t = 1 - (1 - t) * (1 - t) }
        at = (from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t)
        send(.move, at)
      }
      i += 4
    }
    send(.end, at)
  }
  exit(0)
}
