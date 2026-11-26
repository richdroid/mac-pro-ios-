# The Last.fm app's simulator helpers, sourced by both jobs of .github/workflows/lastfm.yml (shots, then films).
# Needs: DEVICE booted with the app installed, D (devicehubctl), APP. Shots and stills land in dist/.

APP=local.macpro.LastFM

# Boot the Duo (or the first iPhone), install the app, and build Device Hub's command line for poses and touches.
sim_setup() {
  DEVICE=$(xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.name | test("^iPhone"))] | (map(select(.name | test("Duo"))) + .)[0].udid')
  xcrun simctl list devices available | grep -m1 "$DEVICE"
  xcrun simctl boot "$DEVICE"
  xcrun simctl bootstatus "$DEVICE" -b
  xcrun simctl install "$DEVICE" "$1"
  git clone -q https://github.com/ChrisThoma/devicehubctl.git /tmp/dh && (cd /tmp/dh && git checkout -q 3e58be2932794e47ee533ef2b992753bfc1c7337 && swift build -c release 2>&1 | tail -1)
  D=/tmp/dh/.build/release/devicehubctl
  open -a DeviceHub; sleep 10
}

# Turn the phone until a display's screenshot has the shape wanted. Device Hub's rotate numbers didn't land the same way
# in every pose (run 2: "rotate 1" right after closing left the outer display sideways, and open flat 1 and 3 came out
# the other way round), so the shape is checked rather than assumed.
orient() {
  local want=$1 display=$2 r w h
  for r in 1 3 2 4 1 3; do
    xcrun simctl io "$DEVICE" screenshot --display=$display /tmp/o.png > /dev/null 2>&1
    w=$(sips -g pixelWidth /tmp/o.png 2>/dev/null | awk '/pixelWidth/{print $2}'); h=$(sips -g pixelHeight /tmp/o.png 2>/dev/null | awk '/pixelHeight/{print $2}')
    if [ -n "$w" ] && { { [ $want = portrait ] && [ "$w" -lt "$h" ]; } || { [ $want = landscape ] && [ "$w" -gt "$h" ]; }; }; then echo "orient $want $display: ${w}x${h}"; return 0; fi
    $D "$DEVICE" rotate $r || true; sleep 4
  done
  echo "orient $want $display FAILED (${w}x${h})"
}

# Folded upright (display 1), open upright (display 3) or open flat (display 3).
folded() { $D "$DEVICE" pose closed || true; sleep 4; orient portrait 1; }
upright() { $D "$DEVICE" pose open || true; sleep 8; orient portrait 3; sleep 4; }
flat() { $D "$DEVICE" pose open || true; sleep 6; orient landscape 3; sleep 4; }

# One shot: name, display, wait, then the app's own arguments. A shot is checked for having rendered: a frame taken
# before the app drew (run 10's lfm-now-portrait.png was the bare ground) compresses to almost nothing, so one under
# 250 KB is taken again, up to three times, and named in the log if it never fills.
shot() {
  local name=$1 display=$2 wait=$3; shift 3
  xcrun simctl launch "$DEVICE" $APP -launchLog YES -tilesStill YES "$@"
  # TURN=landscape: turned with the app in front. The Home Screen never turns, so turning before the launch checked a
  # display that stayed upright and gave up (run 20: every -fland shot was upright).
  if [ -n "${TURN:-}" ]; then sleep 3; orient $TURN $display; fi
  sleep $wait
  local f=dist/lfm-$name.png n=0
  xcrun simctl io "$DEVICE" screenshot --display=$display $f > /dev/null 2>&1
  while [ "$(stat -f %z $f 2>/dev/null || echo 0)" -lt 250000 ] && [ $n -lt 3 ]; do
    n=$((n + 1)); echo "shot $name looked blank ($(stat -f %z $f 2>/dev/null) bytes), again ($n)"; sleep 4
    xcrun simctl io "$DEVICE" screenshot --display=$display $f > /dev/null 2>&1
  done
  [ "$(stat -f %z $f 2>/dev/null || echo 0)" -lt 250000 ] && echo "SHOT BLANK: $name"
  xcrun simctl terminate "$DEVICE" $APP || true
}

# A recording stopped, and never waited on for ever: run 35's shots step sat 90 minutes after posture-inner, where the
# old plain wait on the recorder was. Ten seconds to finish its file, then it's killed.
stop_rec() {
  kill -INT $REC 2>/dev/null
  local i=0
  while kill -0 $REC 2>/dev/null && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  if kill -0 $REC 2>/dev/null; then echo "recording $1 would not stop; killed"; kill -9 $REC 2>/dev/null; fi
  wait $REC 2>/dev/null
}

# The app's own frame times for a film (-hitchLog: a line of totals, then a line a second), copied beside it as
# dist/hitches-NAME.txt. The gate reads smoothness from these numbers, not from the runner's recording; a film with no
# hitch log is no evidence of it.
hitches() {
  local c
  c=$(xcrun simctl get_app_container "$DEVICE" $APP data 2>/dev/null) || return
  if [ "$1" = clear ]; then rm -f "$c/Library/Caches/hitches.txt" "$c/Library/Caches/stalls.txt"; return; fi
  cp "$c/Library/Caches/hitches.txt" dist/hitches-$1.txt 2>/dev/null || echo "no hitch log: $1"
  # What the main thread was doing in each stall (LFMStalls.swift), named later by ci/lfm-stall-stacks.py.
  cp "$c/Library/Caches/stalls.txt" dist/stalls-$1.txt 2>/dev/null || true
}

# One film: name, display, seconds, then the app's own arguments; steps run while it records (STEPS="cmd:wait ...").
# A step may carry a place: tap=0.4,0.6:2 taps there after 2 s. Its stills (lfm-NAME-T.png, lfm-NAME-end.png) are taken
# as it runs.
film() {
  local name=$1 display=$2 secs=$3; shift 3
  hitches clear
  xcrun simctl io "$DEVICE" recordVideo --codec=h264 --display=$display --force dist/lfm-$name.mp4 > /dev/null 2>&1 & REC=$!
  sleep 3
  xcrun simctl launch "$DEVICE" $APP -launchLog YES -hitchLog YES "$@"
  local step cmd wait arg t=0
  for step in $STEPS; do
    cmd=${step%%:*}; wait=${step##*:}
    arg=""; case $cmd in *=*) arg=${cmd#*=}; cmd=${cmd%%=*};; esac
    sleep $wait; t=$((t + wait))
    case $cmd in
      # Two swipes, the second begun a fifth of a second after the first has been let go: it must never be thrown back.
      side2) $D "$DEVICE" drag 0.8 ${Y:-0.75} 0.2 ${Y:-0.75} 0.2 || echo "drag failed"; sleep 0.2; $D "$DEVICE" drag 0.8 ${Y:-0.75} 0.2 ${Y:-0.75} 0.2 || echo "drag failed";;
      sideback2) $D "$DEVICE" drag 0.2 ${Y:-0.75} 0.8 ${Y:-0.75} 0.2 || echo "drag failed"; sleep 0.2; $D "$DEVICE" drag 0.2 ${Y:-0.75} 0.8 ${Y:-0.75} 0.2 || echo "drag failed";;
      # Back by a slow drag from the edge, held most of the way across before it's let go.
      edgeslow) $D "$DEVICE" drag ${EX:-0.01} 0.5 0.85 0.5 2.5 || echo "drag failed";;
      # Closed and opened again, as he does: the second opening is the one that must be whole in its first frame.
      relaunch) xcrun simctl terminate "$DEVICE" $APP || true; sleep 1; xcrun simctl launch "$DEVICE" $APP -launchLog YES -hitchLog YES "$@";;
      fling) $D "$DEVICE" drag ${X:-0.5} 0.8 ${X:-0.5} 0.25 0.12 || echo "drag failed";;
      flingback) $D "$DEVICE" drag ${X:-0.5} 0.25 ${X:-0.5} 0.8 0.12 || echo "drag failed";;
      pull) $D "$DEVICE" drag ${X:-0.5} 0.3 ${X:-0.5} 0.85 0.9 || echo "drag failed";;
      slow) $D "$DEVICE" drag ${X:-0.5} 0.75 ${X:-0.5} 0.35 0.9 || echo "drag failed";;
      side) $D "$DEVICE" drag 0.8 ${Y:-0.75} 0.2 ${Y:-0.75} 0.25 || echo "drag failed";;
      sideback) $D "$DEVICE" drag 0.2 ${Y:-0.75} 0.8 ${Y:-0.75} 0.25 || echo "drag failed";;
      sideslow) $D "$DEVICE" drag 0.75 ${Y:-0.75} 0.35 ${Y:-0.75} 1.2 || echo "drag failed";;
      # A short fast throw (a fifth of the width in 60 ms): turns one page by its speed alone, as WP7's flick does.
      flick) $D "$DEVICE" drag 0.7 ${Y:-0.75} 0.5 ${Y:-0.75} 0.06 || echo "drag failed";;
      # Pulled up past a list's foot and let go (after flings have reached it): WP7's compression at the end.
      push) $D "$DEVICE" drag ${X:-0.5} 0.8 ${X:-0.5} 0.3 0.9 || echo "drag failed";;
      link) xcrun simctl openurl "$DEVICE" "$LINK" || echo "link failed";;
      edge) $D "$DEVICE" drag ${EX:-0.01} 0.5 0.9 0.5 0.8 || echo "drag failed";;
      tap) if [ -n "$arg" ]; then $D "$DEVICE" touch ${arg%,*} ${arg#*,} 0.05 || echo "tap failed"; else $D "$DEVICE" touch ${TX:-0.3} ${TY:-0.3} 0.05 || echo "tap failed"; fi;;
      open|partial|closed) $D "$DEVICE" pose $cmd || echo "pose failed";;
      portrait) orient portrait $display;;
      landscape) orient landscape $display;;
      shot) xcrun simctl io "$DEVICE" screenshot --display=$display dist/lfm-$name-$t.png;;
    esac
  done
  sleep $((secs > t ? secs - t : 1))
  xcrun simctl io "$DEVICE" screenshot --display=$display dist/lfm-$name-end.png
  stop_rec $name
  hitches $name
  xcrun simctl terminate "$DEVICE" $APP || true
  if [ "$(stat -f %z dist/lfm-$name.mp4 2>/dev/null || echo 0)" -lt 20000 ]; then echo "film $name empty"; fi
}

# The release, made if it isn't there yet; an upload tried three times.
release() {
  gh release view lastfm-latest >/dev/null 2>&1 || gh release create lastfm-latest --prerelease --title "Last.fm app" --notes "The Last.fm app's own build, shots and films (branch lastfm)." --target lastfm
}
upload() {
  local f
  for f in "$@"; do
    for i in 1 2 3; do gh release upload lastfm-latest "$f" --clobber && break; echo "upload $f failed ($i)"; sleep 15; done
  done
}

# The pictures so far, published while the rest is still being taken, so a pass can be looked at before the run ends:
# ZIP is the asset (shots.zip for the shots job, film-shots.zip for the films' stills), the stage is named in stage.txt.
early() {
  (cd dist && zip -qr ../early.zip . -i '*.png') && cp early.zip "$ZIP"
  echo "$GITHUB_SHA $1 run $GITHUB_RUN_NUMBER" > stage.txt
  release
  gh release upload lastfm-latest "$ZIP" stage.txt --clobber || echo "early upload failed ($1)"
  rm -f "$ZIP"
}
