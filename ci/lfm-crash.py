#!/usr/bin/env python3
# The app's crash reports (.ips, written by the runner's ReportCrash for the simulator's processes) made readable: the
# exception, the runtime's own message (a Swift fatal error, an uncaught exception's reason), and the crashed thread's
# frames, the app's own named by atos against the binary still installed in the simulator. Usage: lfm-crash.py a.ips ...
import json, subprocess, sys


def load(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    head, _, body = text.partition("\n")
    try:
        return json.loads(head), json.loads(body)
    except ValueError:
        return None, None


def atos(img, addr):
    path = img.get("path") or ""
    if not path or "base" not in img:
        return None
    try:
        out = subprocess.run(["atos", "-o", path, "-l", hex(img["base"]), hex(addr)], capture_output=True, text=True, timeout=30)
        s = out.stdout.strip()
        return s if s and not s.startswith("0x") else None
    except Exception:
        return None


def frames(th, images):
    out = []
    for i, f in enumerate(th.get("frames", [])):
        img = images[f["imageIndex"]] if 0 <= f.get("imageIndex", -1) < len(images) else {}
        name = img.get("name", "?")
        addr = img.get("base", 0) + f.get("imageOffset", 0)
        sym = f.get("symbol")
        if sym:
            sym = f"{sym} + {f.get('symbolLocation', 0)}"
        if ("LastFM" in name or not sym) and img:
            sym = atos(img, addr) or sym
        src = f" ({f['sourceFile']}:{f.get('sourceLine', '?')})" if "sourceFile" in f else ""
        out.append(f"  {i:2d} {name:28s} {sym or hex(f.get('imageOffset', 0))}{src}")
    return out


for p in sys.argv[1:]:
    head, b = load(p)
    print(f"==== {p}")
    if not b:
        print("  (not readable as .ips JSON)")
        continue
    print(f"  {head.get('app_name')} {head.get('app_version')} ({head.get('build_version')}) at {head.get('timestamp')}")
    ex = b.get("exception", {})
    print(f"  exception: {ex.get('type')} {ex.get('signal')} {ex.get('subtype', '')} {ex.get('codes', '')}")
    term = b.get("termination", {})
    if term:
        print(f"  termination: {term.get('namespace')} {term.get('indicator')} {term.get('reasons', '')}")
    for k, v in (b.get("asi") or {}).items():
        print(f"  asi {k}: {' | '.join(v) if isinstance(v, list) else v}")
    if b.get("lastExceptionBacktrace"):
        print("  last exception backtrace:")
        print("\n".join(frames({"frames": b["lastExceptionBacktrace"]}, b.get("usedImages", []))))
    for n, th in enumerate(b.get("threads", [])):
        if th.get("triggered"):
            print(f"  crashed thread {n} {th.get('name', '')} {th.get('queue', '')}:")
            print("\n".join(frames(th, b.get("usedImages", []))[:60]))
    # The main thread too, when another one crashed: what the app was doing on screen.
    ths = b.get("threads", [])
    if ths and not ths[0].get("triggered"):
        print("  main thread:")
        print("\n".join(frames(ths[0], b.get("usedImages", []))[:40]))
