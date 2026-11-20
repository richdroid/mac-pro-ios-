#!/bin/bash
# Shrinks the films job's films for the release, after the simulator has shut down, two at a time, inside a hard
# deadline, so the publish after it can never hang (run 35 waited on shrinks until the job's limit).
# Usage: lfm-shrink-all.sh SRC OUT DEADLINE_SECONDS PARALLEL. Each film: ci/lfm-shrink.swift's tool, else avconvert's
# 960x540 preset, else kept as filmed if under 80 MB, else dropped; whatever the deadline cuts short is treated the same
# way (kept if small). The folded films go first: they're the ones the gate reads in frames.
src=$1 out=$2 deadline=${3:-900} par=${4:-2}
mkdir -p "$out"
start=$SECONDS
pids=""

one() {
  local f=$1 n
  n=$(basename "$f")
  if /tmp/lfm-shrink "$f" "$out/$n" 2> "$out/.err-$n"; then echo "shrunk: $n"; rm -f "$out/.err-$n"; return; fi
  echo "shrink failed ($(cat "$out/.err-$n" 2>/dev/null)): $n"; rm -f "$out/.err-$n"
  if avconvert -p Preset960x540 -s "$f" -o "$out/.av-$n" --replace > /dev/null 2>&1 && [ -s "$out/.av-$n" ]; then
    mv "$out/.av-$n" "$out/$n"; echo "avconvert: $n"; return
  fi
  rm -f "$out/.av-$n"
}

alive() {
  local p r=""
  for p in $pids; do kill -0 $p 2>/dev/null && r="$r $p"; done
  pids=$r
}
over() { [ $((SECONDS - start)) -ge $deadline ]; }

list=$( (ls "$src"/*.mp4 2>/dev/null | grep -v -e '-portrait' -e '-open'; ls "$src"/*-portrait*.mp4 2>/dev/null; ls "$src"/*-open*.mp4 2>/dev/null) )
for f in $list; do
  [ "$(stat -f %z "$f")" -lt 20000 ] && continue
  while :; do
    alive
    set -- $pids
    [ $# -lt $par ] && break
    over && break
    sleep 1
  done
  over && break
  one "$f" &
  pids="$pids $!"
done
# The deadline holds for the ones still running too: they and their encoders are stopped, their part files removed.
while :; do
  alive
  [ -z "$pids" ] && break
  if over; then
    for p in $pids; do pkill -9 -P $p 2>/dev/null; kill -9 $p 2>/dev/null; done
    echo "deadline reached; stopped:$pids"
    break
  fi
  sleep 1
done
rm -f "$out"/.part-* "$out"/.av-* "$out"/.err-*
for f in $list; do
  n=$(basename "$f")
  [ -s "$out/$n" ] && continue
  # Under 80 MB as filmed: run 37 dropped sync, scroll-you and both posture films at 40 MB, the ones a gate reads.
  if [ "$(stat -f %z "$f")" -lt 80000000 ]; then cp "$f" "$out/"; echo "kept as filmed: $n"; else echo "dropped (too large, not shrunk): $n"; fi
done
echo "shrinking took $((SECONDS - start)) s"
