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
      // Driven by the clock, not by a count of steps: each move is sent at the place the finger is at the moment it's
      // sent, about every 10 ms (or as fast as Device Hub takes them, 25–40 ms each), and the last one exactly at the
      // segment's end. A count of coarse steps made a 0.09 s flick three moves, which read as no speed at all folded.
      let from = at
      let began = Date()
      while true {
        let e = Date().timeIntervalSince(began)
        var t = seconds > 0 ? min(1, e / seconds) : 1
        if ease { t = 1 - (1 - t) * (1 - t) }
        at = (from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t)
        send(.move, at)
        if e >= seconds { break }
        let wait = min(0.01, seconds - Date().timeIntervalSince(began))
        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
      }
      i += 4
    }
    send(.end, at)
  }
  exit(0)
}
