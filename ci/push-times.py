#!/usr/bin/env python3
# Branch-only (chumby-fix-1127): each Calendar-settings push in a swipe log, timed the same way for every build.
# For each push: asked (the pose's "push N asked", else "alarmsPage true") to the slide's start, the slide's length
# (UIKit's own is 350 ms), asked to the end, the worst late frame in it and the stalls in it.
# Usage: push-times.py LOG [LOG...]
import sys, re
for f in sys.argv[1:]:
    ev = []
    for line in open(f, errors='replace'):
        m = re.match(r'([\d.]+) (.*)', line.rstrip('\n'))
        if m: ev.append((float(m.group(1)), m.group(2)))
    name = f.split('/')[-1].replace('-swipe.log', '')
    asks = [i for i, (t, s) in enumerate(ev) if re.match(r'push \d asked', s)] or [i for i, (t, s) in enumerate(ev) if s == 'alarmsPage true']
    warm = [s for t, s in ev if 'prewarmed' in s]
    print(f'{name}: ' + (warm[0] if warm else 'no prewarm line'))
    for n, i in enumerate(asks, 1):
        t0 = ev[i][0]
        began = next(((t, s) for t, s in ev[i:] if s.startswith('move began')), None)
        if not began: print(f'  push {n}: asked at {t0:.2f}, never began'); continue
        ended = next((t for t, s in ev if t >= began[0] and s == 'move ended'), None)
        if ended is None: print(f'  push {n}: began, never ended'); continue
        late = [int(re.search(r'(\d+)', s).group(1)) for t, s in ev if t0 <= t <= ended + 0.05 and s.startswith('late frame')]
        stalls = [int(re.search(r'stall (\d+)', s).group(1)) for t, s in ev if t0 <= t <= ended + 0.3 and s.startswith('stall ')]
        print(f'  push {n} at {t0:.2f}: to slide {1000 * (began[0] - t0):.0f} ms, slide {1000 * (ended - began[0]):.0f} ms, '
              f'asked to end {1000 * (ended - t0):.0f} ms (over the 350: {1000 * (ended - t0) - 350:.0f}), worst late frame {max(late, default=0)} ms, stalls {stalls}')
