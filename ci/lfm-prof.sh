# Rotation's motions profiled (Time Profiler on the main thread) beside the app's own hitch log, so each dropped frame
# is named from its stack, not guessed. Sourced after ci/lfm-sim.sh (DEVICE, D, APP, hitches).
steps() {
  local step cmd wait arg
  for step in $STEPS; do
    cmd=${step%%:*}; wait=${step##*:}
    arg=""; case $cmd in *=*) arg=${cmd#*=}; cmd=${cmd%%=*};; esac
    sleep $wait
    case $cmd in
      side) $D "$DEVICE" drag 0.8 ${Y:-0.75} 0.2 ${Y:-0.75} 0.25 || echo "drag failed";;
      sideback) $D "$DEVICE" drag 0.2 ${Y:-0.75} 0.8 ${Y:-0.75} 0.25 || echo "drag failed";;
      sideslow) $D "$DEVICE" drag 0.75 ${Y:-0.75} 0.35 ${Y:-0.75} 1.2 || echo "drag failed";;
      edgeslow) $D "$DEVICE" drag ${EX:-0.01} 0.5 0.85 0.5 2.5 || echo "drag failed";;
      edge) $D "$DEVICE" drag ${EX:-0.01} 0.5 0.9 0.5 0.8 || echo "drag failed";;
      fling) $D "$DEVICE" drag ${X:-0.5} 0.8 ${X:-0.5} 0.25 0.12 || echo "drag failed";;
      flingback) $D "$DEVICE" drag ${X:-0.5} 0.25 ${X:-0.5} 0.8 0.12 || echo "drag failed";;
      slow) $D "$DEVICE" drag ${X:-0.5} 0.75 ${X:-0.5} 0.35 0.9 || echo "drag failed";;
      tap) $D "$DEVICE" touch ${arg%,*} ${arg#*,} 0.05 || echo "tap failed";;
      shot) xcrun simctl io "$DEVICE" screenshot --display=$PDISP dist/prof-$PNAME-$SECONDS.png > /dev/null 2>&1;;
    esac
  done
}
# prof NAME DISPLAY SECONDS app-args...: launched, profiled from about a second in for SECONDS, STEPS run meanwhile.
prof() {
  PNAME=$1 PDISP=$2; local secs=$3; shift 3
  hitches clear
  local c; c=$(xcrun simctl get_app_container "$DEVICE" $APP data 2>/dev/null) && rm -f "$c/Library/Caches/launch-log.txt"
  local L; L=$(xcrun simctl launch "$DEVICE" $APP -launchLog YES -hitchLog YES "$@"); local PID=${L##*: }
  ( xcrun xctrace record --template 'Time Profiler' --device "$DEVICE" --attach "$PID" --time-limit ${secs}s --output /tmp/p-$PNAME.trace > /tmp/p-$PNAME.log 2>&1 ) & local PROF=$!
  SECONDS=0
  steps
  for _ in $(seq 1 $((secs + 40))); do kill -0 $PROF 2>/dev/null || break; sleep 1; done
  kill $PROF 2>/dev/null; wait $PROF 2>/dev/null
  ( xcrun xctrace export --input /tmp/p-$PNAME.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > /tmp/p-$PNAME.xml 2>/dev/null ) & local EXP=$!
  for _ in $(seq 1 90); do kill -0 $EXP 2>/dev/null || break; sleep 1; done
  kill $EXP 2>/dev/null
  { [ -s /tmp/p-$PNAME.xml ] && python3 ci/lfm-stalls.py /tmp/p-$PNAME.xml 6 > dist/stalls-$PNAME.txt 2>&1; } || { echo "profile failed"; tail -8 /tmp/p-$PNAME.log; } > dist/stalls-$PNAME.txt
  rm -rf /tmp/p-$PNAME.trace /tmp/p-$PNAME.xml
  hitches $PNAME
  c=$(xcrun simctl get_app_container "$DEVICE" $APP data 2>/dev/null) && cp "$c/Library/Caches/launch-log.txt" dist/launch-$PNAME.txt 2>/dev/null
  xcrun simctl terminate "$DEVICE" $APP || true
  echo "== $PNAME: $(head -1 dist/hitches-$PNAME.txt 2>/dev/null)"; head -40 dist/stalls-$PNAME.txt
  sleep 2
}
# Everything profiled in one posture (suffix, display).
profile_all() {
  local x=$1 d=$2
  # Launch on home and left: the first seconds (the rest films' 1-3 s freezes).
  STEPS="shot:6 shot:6" prof p-launch-home$x $d 14 -hub home
  STEPS="shot:6 shot:6" prof p-launch-you$x $d 14 -tab 0
  # Home: a tile tapped (turnstile out, hub in), Back by its button, then the now-playing tile and Back by the edge.
  STEPS="shot:5 tap=0.25,0.70:1 shot:3 tap=${BACKAT:-0.895,0.29}:1 shot:3 tap=0.3,0.45:1 shot:3 edgeslow:1 shot:3" prof p-home-tap$x $d 24 -hub home
  # The panorama swiped through and back.
  Y=0.6 STEPS="side:5 side:2 side:2 sideback:2 sideback:2 sideback:2 shot:1" prof p-home-pan$x $d 20 -hub home
  # Pivots: now playing through and round, the profile hub round (the wrap).
  Y=0.6 STEPS="side:5 side:2 side:2 side:2 sideback:2 sideback:2 shot:1" prof p-pivot-now$x $d 20 -hub nowPlaying
  Y=0.6 STEPS="side:5 side:2 side:2 side:2 side:2 sideback:2 shot:1" prof p-pivot-profile$x $d 20 -hub profile
  # A row's page pushed and popped (charts), and a long list scrolled (history).
  STEPS="tap=0.4,0.62:6 shot:3 tap=${BACKAT:-0.895,0.29}:1 shot:2 tap=0.4,0.62:2 shot:3 edgeslow:1 shot:2" prof p-tap-artist$x $d 22 -tab 1 -kind 0
  STEPS="slow:5 fling:2 fling:2 fling:2 flingback:2 flingback:2" prof p-scroll-history$x $d 18 -hub history
}

# The motions filmed (Release build), for the gate to read frame by frame beside each film's hitch log.
films_all() {
  local x=$1 d=$2
  STEPS="shot:4 tap=0.25,0.70:2 shot:1 shot:2 tap=${BACKAT:-0.895,0.29}:2 shot:1 shot:2" film home-tap$x $d 18 -hub home
  STEPS="tap=0.25,0.70:6 shot:2 edgeslow:1 shot:1 shot:3" film home-swipe$x $d 18 -hub home
  STEPS="tap=0.3,0.45:6 shot:2 tap=${BACKAT:-0.895,0.29}:2 shot:2" film home-now$x $d 16 -hub home
  Y=0.6 STEPS="side:6 shot:2 side:2 shot:2 side:2 shot:2 sideback:2 shot:1 sideback:2 sideback:2 shot:2" film home-pan$x $d 26 -hub home
  STEPS="shot:8 shot:8" film home-tiles$x $d 20 -hub home
  Y=0.6 STEPS="side:6 shot:2 side:2 shot:2 side:2 shot:2 sideback:2 shot:2" film pivot-wrap$x $d 22 -hub profile
  Y=0.6 STEPS="side:6 shot:2 side:2 shot:2 side:2 shot:2 sideback:2 sideback:2 sideback:2 shot:2" film pivot-now$x $d 26 -hub nowPlaying
  Y=0.6 STEPS="side:6 shot:2 side:2 shot:2 sideback:2 shot:2" film pivot-charts$x $d 20 -tab 1
  Y=0.6 STEPS="side:6 shot:2 edgeslow:2 shot:1 shot:3" film edge-back-pivot$x $d 18 -hub discover
  STEPS="tap=0.4,0.62:7 shot:1 shot:2 tap=${BACKAT:-0.895,0.29}:1 shot:1 shot:2" film tap-artist$x $d 18 -tab 1 -kind 0
  STEPS="slow:6 shot:2 fling:2 shot:2 fling:2 shot:2 flingback:2" film scroll-history$x $d 18 -hub history
  STEPS="shot:8 relaunch:2 shot:1 shot:2 shot:4" film launch-warm$x $d 20 -hub home
  # The detail pages' tops, opened from the charts and left at rest (the tray band only once scrolled).
  STEPS="tap=0.4,0.62:7 shot:3 slow:2 shot:2" film tap-album$x $d 16 -tab 1 -kind 1
}
# Scrolling as Richard named it (2026-11-25: "the side scrolling and scrolling in general is wayyy off"): a pivot and the
# panorama dragged slowly and thrown short, and a long list scrolled, flung to its foot, pulled past both ends.
films_scroll() {
  local x=$1 d=$2
  Y=0.6 STEPS="side:6 shot:2 sideslow:2 shot:2 flick:2 shot:2 flick:2 shot:2" film swipe-pivot$x $d 22 -hub profile
  Y=0.6 STEPS="sideslow:6 shot:2 flick:2 shot:2 sideback:2 shot:2" film swipe-home$x $d 20 -hub home
  STEPS="pull:6 shot:1 slow:2 fling:1 fling:1 fling:1 fling:1 push:2 shot:1 flingback:2 flingback:1 shot:2" film scroll-long$x $d 26 -hub history
}
# The folded wrap-back swipe that sprang back once (run 63 gate, blocker 1), three more times.
films_wrap() {
  for r in 1 2 3; do
    Y=0.6 STEPS="side:6 shot:2 side:2 shot:2 side:2 shot:2 sideback:2 shot:2 sideback:2 shot:2" film pivot-wrap-again$r 1 24 -hub profile
  done
}

# Build 62's motions, the ones Richard named (taps, Back, pans, pivots, pushes, launch), for the before numbers.
films_before() {
  local x=$1 d=$2
  STEPS="shot:4 tap=0.25,0.70:2 shot:1 shot:2 tap=${BACKAT:-0.895,0.29}:2 shot:1 shot:2" film home-tap$x $d 18 -hub home
  STEPS="tap=0.25,0.70:6 shot:2 edgeslow:1 shot:1 shot:3" film home-swipe$x $d 18 -hub home
  Y=0.6 STEPS="side:6 shot:2 side:2 shot:2 side:2 shot:2 sideback:2 shot:1 sideback:2 sideback:2 shot:2" film home-pan$x $d 26 -hub home
  Y=0.6 STEPS="side:6 shot:2 side:2 shot:2 side:2 shot:2 sideback:2 shot:2" film pivot-wrap$x $d 22 -hub profile
  Y=0.6 STEPS="side:6 shot:2 side:2 shot:2 side:2 shot:2 sideback:2 sideback:2 sideback:2 shot:2" film pivot-now$x $d 26 -hub nowPlaying
  STEPS="tap=0.4,0.62:7 shot:1 shot:2 tap=${BACKAT:-0.895,0.29}:1 shot:1 shot:2" film tap-artist$x $d 18 -tab 1 -kind 0
  STEPS="shot:8 relaunch:2 shot:1 shot:2 shot:4" film launch-warm$x $d 20 -hub home
}
