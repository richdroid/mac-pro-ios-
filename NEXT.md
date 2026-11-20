# chumby-debug-1120: where the plan lead stopped (2026-11-20, usage cut)

No READY file: no gate has said SHIP. Branch pushed; head below is this file's commit on 00c6c6a.

## State
- CI run 44819758278 on 00c6c6a was still in "Shots and films" when I stopped; it publishes to the `chumby-debug-1120`
  release (status.txt names the commit). Check it before anything else; if it failed or was cancelled, push again.
- Gate task written and NOT run: ~/.local/state/mac-dash/api-tasks/chumby-debug-gate-4.md (supersedes gate-3). Give it
  to ONE visual-designer agent (model fable) once status.txt says 00c6c6a. Earlier verdicts: HOLD (2d8381b), HOLD (99a62b4).
- Open HOLD from the coordinator: Home's ring card jank (relayed 11-20; details with the coordinator). Not yet looked at.

## Verified in frames (run 44797233069, 956d736)
- Octopus at ring → snooze → stop (dbg-ringdemo.mp4 8.8–17.8 s, every frame): continuous, no jump.
- Channel drops (dbg-chdrag.mp4 ~60–63 s, ~80–83.5 s): the dropped row stays drawn and settles. Fix holds.
- Not filmable: the widget night→day fix (CI can't put a widget on the simulator Home Screen; code only).

## Done since 956d736
- 7163133: Home ring card title cross-fades in place (was two blank frames "Snoozed until" → "Stopping…"); nap
  chips/row fade to 0.12, not 0, before the rows swap (was one empty frame). Chumby touches: Home's device screen shows
  the light-blue octopus breathing on the dark glass before the first picture (WakingScreen, was a spinner); an empty
  channel shows the quiet octopus beside "Nothing in this channel yet." (as Alarms' "Sleep in").
- 4afd686: CI film dbg-tabhop.mp4 (octopus returning to Home from Alarms and Sounds) and still dbg-home-waking.png
  (poses "tabhop", "waking").
- 00c6c6a: merged main 51dea54 (ring key/Live Activity/Island in the octopus's blue; widget names). Conflict in
  SlideToStop's key glyph resolved to main's ChumbyPalette.ring. chumby + chumbywidget typecheck clean.

## Next
1. Read run 44819758278: dbg-ringdemo(-portrait) at Snoozed→Stopping, dbg-alarmsdemo nap set/cancel, dbg-tabhop,
   dbg-home-waking.png. Then the ring-card jank HOLD.
2. Gate with gate-4.md; fix; re-gate until SHIP.
3. On SHIP: delete .github/workflows/chumby-debug.yml and this file in one commit, push, write
   ~/.local/state/mac-dash/api-tasks/READY-chumby-debug-1120 with the SHA. Don't merge to main.
