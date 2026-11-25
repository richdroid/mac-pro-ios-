#!/usr/bin/env python3
# Rotation's main-thread stalls from an `xctrace export` of a Time Profiler run: the busiest stretches of the main
# thread (samples back to back), each with the app's own frames and the SwiftUI/UIKit/Core Animation frames that filled
# it, so a dropped frame is named from its stack. Usage: lfm-stalls.py EXPORT.xml [TOP]
import sys, xml.etree.ElementTree as ET
from collections import Counter
root = ET.parse(sys.argv[1]).getroot()
top = int(sys.argv[2]) if len(sys.argv) > 2 else 5
ids = {}
def res(e):
    r = e.get('ref')
    if r is not None: return ids.get(r, e)
    if e.get('id') is not None: ids[e.get('id')] = e
    for c in e: res(c)
    return e
samples = []
for row in root.iter('row'):
    t = th = bt = None
    for c in row:
        c = res(c)
        if c.tag == 'sample-time': t = int(c.text)
        elif c.tag == 'thread': th = c.get('fmt', '')
        elif c.tag == 'backtrace': bt = c
    if t is None or bt is None or 'main' not in (th or '').lower(): continue
    fr = []
    for f in bt.iter('frame'):
        f = res(f)
        n = f.get('name')
        if n: fr.append(n)
    samples.append((t, fr))
samples.sort()
if not samples: print('no main-thread samples'); sys.exit()
t0 = samples[0][0]
print(f'main-thread samples {len(samples)} over {(samples[-1][0]-t0)/1e9:.1f} s')
runs, cur = [], [samples[0]]
for a, b in zip(samples, samples[1:]):
    if b[0] - a[0] <= 3_000_000: cur.append(b)
    else: runs.append(cur); cur = [b]
runs.append(cur)
# Every stretch over 25 ms in time order (the timeline), then the longest ones in detail.
print('-- busy stretches over 25 ms (start s, ms)')
print('  '.join(f'{(r[0][0]-t0)/1e9:.2f}:{(r[-1][0]-r[0][0])/1e6:.0f}' for r in runs if (r[-1][0]-r[0][0]) > 25e6))
app = lambda n: 'LastFM' in n or 'LFM' in n
ui = lambda n: any(k in n for k in ('SwiftUI', 'AttributeGraph', 'UIKit', 'CoreAnimation', 'CA::', 'ImageIO', 'CoreText', 'TextKit', 'CoreGraphics', 'decode', 'Decode', 'JSON', 'sqlite', 'Foundation'))
for r in sorted(runs, key=lambda r: r[-1][0] - r[0][0], reverse=True)[:top]:
    ms = (r[-1][0] - r[0][0]) / 1e6
    print(f'\n== busy {ms:.0f} ms from {(r[0][0]-t0)/1e9:.2f} s, {len(r)} samples')
    incl = Counter(); leaf = Counter()
    for _, fr in r:
        for n in set(fr): incl[n] += 1
        if fr: leaf[fr[0]] += 1
    print('-- app frames (inclusive)')
    for n, c in [x for x in incl.most_common() if app(x[0])][:40]: print(f'{c:6d}  {n[:200]}')
    print('-- framework frames (inclusive)')
    for n, c in [x for x in incl.most_common() if ui(x[0]) and not app(x[0])][:30]: print(f'{c:6d}  {n[:200]}')
    print('-- leaf')
    for n, c in leaf.most_common(15): print(f'{c:6d}  {n[:200]}')
