#!/usr/bin/env python3
# Reads an `xctrace export` of a Time Profiler run (the time-profile table) and prints, for the app's main thread, the
# longest busy stretch (samples back to back) and the code that filled it, so a stall in a film can be named, not guessed.
import sys, re, xml.etree.ElementTree as ET
from collections import Counter
root = ET.parse(sys.argv[1]).getroot()
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
    # The main thread's name varies by Instruments version ("Main Thread 0x…", "… main-thread …"); r31's filter matched
    # nothing. Any thread whose name says main.
    if t is None or bt is None or 'main' not in (th or '').lower(): continue
    frames = []
    for f in bt.iter('frame'):
        f = res(f)
        n = f.get('name')
        if n: frames.append(n)
    samples.append((t, frames))
samples.sort()
if not samples: print('no main-thread samples'); sys.exit()
# Busy stretches: samples about 1 ms apart. The longest one is the stall.
runs, cur = [], [samples[0]]
for a, b in zip(samples, samples[1:]):
    if b[0] - a[0] <= 3_000_000: cur.append(b)
    else: runs.append(cur); cur = [b]
runs.append(cur)
runs.sort(key=lambda r: r[-1][0] - r[0][0], reverse=True)
for r in runs[:3]:
    ms = (r[-1][0] - r[0][0]) / 1e6
    print(f'== busy {ms:.0f} ms from {r[0][0]/1e9:.3f} s, {len(r)} samples')
    incl = Counter(); leaf = Counter()
    for _, fr in r:
        for n in set(fr): incl[n] += 1
        if fr: leaf[fr[0]] += 1
    print('-- inclusive (app and SwiftUI frames first)')
    for n, c in sorted(incl.items(), key=lambda x: -x[1])[:70]:
        if any(k in n for k in ('TV', 'SwiftUI', 'AttributeGraph', 'UIKit', 'CoreAnimation', 'Image', 'Text', 'View', 'body', 'layout', 'Layout')):
            print(f'{c:6d}  {n[:180]}')
    print('-- leaf')
    for n, c in leaf.most_common(25): print(f'{c:6d}  {n[:180]}')
