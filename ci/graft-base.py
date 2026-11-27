#!/usr/bin/env python3
# Branch-only (chumby-fix-1127): gives main before mp-nav-1126 (6d22d62) this branch's stall sampler (FrameStalls) and its
# "calpushes" pose, so the Calendar-settings push is timed the same way on both builds (gate 2: "the base build had no
# sampler"). Usage: graft-base.py BASE_DIR BRANCH_DIR
import sys, re
base, branch = sys.argv[1:3]
duo = open(f'{branch}/Shared/Duo.swift').read()
start = duo.index("#if canImport(UIKit)\n// For the build's films only (-swipeLog YES from CI")
end = duo.index('\n#endif\n', duo.index('final class FrameStalls', start)) + len('\n#endif\n')
sampler = duo[start:end]
p = f'{base}/Shared/Duo.swift'; s = open(p).read()
a = '@MainActor static func frames() { if on, meter == nil { meter = FrameGaps(); busy() } }'
assert a in s, 'frames()'
s = s.replace(a, '@MainActor static func frames() { if on, meter == nil { meter = FrameGaps(); busy(); FrameStalls.shared.start() } }', 1)
b = '            last = l.timestamp\n'
assert s.count(b) == 1, 'tick'
s = s.replace(b, b + '            FrameStalls.beat = CACurrentMediaTime()\n', 1)
s += '\n' + sampler
open(p, 'w').write(s)
p = f'{base}/ChumbyApp/Sources/ChumbyAlarms.swift'; s = open(p).read()
c = '            case "calsettings": Task { try? await Task.sleep(nanoseconds: 1_200_000_000); openSettings() }\n'
assert c in s, 'calsettings'
s = s.replace(c, c + '''            case "calpushes":
                Task {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    for i in 0..<3 {
                        SwipeLog.note("push \\(i + 1) asked")
                        openSettings()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if i < 2 { SwipeLog.note("pop \\(i + 1) asked"); model.alarmsPage = false; try? await Task.sleep(nanoseconds: 2_500_000_000) }
                    }
                }
''', 1)
open(p, 'w').write(s)
print('grafted sampler and calpushes onto', base)
