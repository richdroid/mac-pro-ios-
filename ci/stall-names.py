#!/usr/bin/env python3
# Stalls from FrameStalls (Shared/Duo.swift; Caches/stalls.txt, copied as dist/NAME-stalls.txt) made readable: the app's
# frames named with atos against the build, then for every stall its length and what filled it (the app's functions
# and the frameworks' by how many samples they were on the stack, and the leaf frames).
# Usage: stall-names.py APP_DIR stalls-NAME.txt [more...]   (prints to stdout)
import sys, re, subprocess
from collections import Counter
app = sys.argv[1]
files = sys.argv[2:]
stalls = []
for f in files:
    cur = None
    for line in open(f, errors='replace'):
        line = line.rstrip('\n')
        if line.startswith('stall '):
            m = re.match(r'stall t (-?[\d.]+) ms (\d+)', line)
            cur = {'file': f, 't': float(m.group(1)), 'ms': int(m.group(2)), 'samples': []}
            stalls.append(cur)
        elif cur is not None and line.startswith('  '):
            cur['samples'].append(line.strip().split(' | '))
# The app's frames, image by image, through atos.
want = {}
for s in stalls:
    for fr in s['samples']:
        for x in fr:
            m = re.match(r'@(.+)\+0x([0-9a-f]+)$', x)
            if m: want.setdefault(m.group(1), set()).add(int(m.group(2), 16))
names = {}
for img, offs in want.items():
    offs = sorted(offs)
    for i in range(0, len(offs), 400):
        chunk = offs[i:i + 400]
        try:
            out = subprocess.run(['xcrun', 'atos', '-o', f'{app}/{img}', '-l', '0x100000000'] + [hex(0x100000000 + o) for o in chunk],
                                 capture_output=True, text=True, timeout=120).stdout.splitlines()
        except Exception as e:
            out = []
        for o, n in zip(chunk, out):
            n = re.sub(r' \(in [^)]+\)', '', n)
            n = re.sub(r'\s*\([^)]*\.swift:\d+\)$', lambda m: m.group(0), n)
            names[f'@{img}+0x{o:x}'] = n[:220]
def nm(x): return names.get(x, x)
def isapp(x): return x.startswith('@')
total = sum(s['ms'] for s in stalls)
print(f'{len(stalls)} stalls over 40 ms, {total} ms in all')
print('timeline (t s: ms): ' + '  '.join(f"{s['t']:.1f}:{s['ms']}" for s in stalls))
# Across every stall, the app's functions by samples.
allc = Counter()
for s in stalls:
    for fr in s['samples']:
        for x in set(fr):
            if isapp(x): allc[nm(x)] += 1
print('\n-- the app, every stall (samples on stack)')
for n, c in allc.most_common(40): print(f'{c:6d}  {n}')
for s in sorted(stalls, key=lambda s: -s['ms'])[:12]:
    print(f"\n== stall at {s['t']:.2f} s, {s['ms']} ms, {len(s['samples'])} samples ({s['file'].split('/')[-1]})")
    a, fw, leaf = Counter(), Counter(), Counter()
    for fr in s['samples']:
        for x in set(fr):
            (a if isapp(x) else fw)[nm(x)] += 1
        if fr: leaf[nm(fr[0])] += 1
    print('-- app'); [print(f'{c:6d}  {n}') for n, c in a.most_common(22)]
    print('-- frameworks'); [print(f'{c:6d}  {n[:160]}') for n, c in fw.most_common(18)]
    print('-- leaf'); [print(f'{c:6d}  {n[:160]}') for n, c in leaf.most_common(8)]
