#!/usr/bin/env python3
# Each shot's title band must hold a large title: some bright pixels in rows 120–700 (below the status bar). A page that
# lost its title under a solid black band has almost none. Pure standard library: PNG decoded with zlib. Writes
# dist/FAILED-macpro-title-<shot>.txt for each failure and exits non-zero if any failed.
import os, struct, sys, zlib

def png_rows(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat, w = 8, b'', 0
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8]); body = data[pos + 8:pos + 8 + n]; pos += 12 + n
        if kind == b'IHDR': w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
        elif kind == b'IDAT': idat += body
        elif kind == b'IEND': break
    bpp = {2: 3, 6: 4}[ctype]
    raw, stride, prev, out = zlib.decompress(idat), w * bpp, bytearray(w * bpp), []
    i = 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out.append(bytes(line)); prev = line
    return w, bpp, out

failed = 0
for path in sys.argv[1:]:
    try:
        w, bpp, rows = png_rows(path)
    except Exception as e:
        print('skip', path, e); continue
    # Below the status bar, down to where content rests; the left 70 % only, so the side rail's clock never counts.
    band = rows[120:700]
    bright = total = 0
    for r in band:
        for x in range(0, int(w * 0.7) * bpp, bpp * 2):
            total += 1
            if r[x] + r[x + 1] + r[x + 2] > 600: bright += 1
    # The Mac Pro app is always dark: a white large title must leave some bright pixels in the band.
    ok = bright / max(total, 1) > 0.002
    print(('ok  ' if ok else 'FAIL'), os.path.basename(path))
    if not ok:
        failed += 1
        open(os.path.join('dist', 'FAILED-macpro-title-' + os.path.basename(path) + '.txt'), 'w').write('title band looks blank or black\n')
sys.exit(1 if failed else 0)
