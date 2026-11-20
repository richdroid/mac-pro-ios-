# chumby-debug-1120: where the API lead stopped (2026-11-20)

Stopped on Richard's word to move back to the plan. No READY file was written: the gate has not said SHIP.

## State
- Head 956d736, pushed. CI run 44797233069 on it was still running when I stopped; its shots and films go to the
  `chumby-debug-1120` release (status.txt names the commit).
- Gate verdicts so far: HOLD (2d8381b), HOLD (99a62b4). Both in
  ~/.local/state/mac-dash/api-tasks/chumby-debug-gate-{1,2}.md.result.json.
- The third gate task is written and NOT run: ~/.local/state/mac-dash/api-tasks/chumby-debug-gate-3.md. It lists what
  was done about each blocker and what the gate should judge. Give it to a designer on the plan once status.txt says 956d736.

## Done on this branch (on main 9f42600)
- Stop/Snooze read the Chumby's own answer {ok, done, how, ring} (2d8381b).
- Home's ringing card shares the next alarm's slot; ringing page laid out before the first reading; nap handover;
  a press from the Lock Screen's door shows in the open app at once (5a7a6db).
- Widget follows a day/night change made in the app; octopus motion carried frame to frame (4033096).
- Second gate's five blockers: next alarm back after a slide to stop, knob springs back, no doubled line on Snooze,
  dropped channel row, cards cross-fade (956d736).

## Not seen in pixels yet (first films are in run 44797233069)
- Everything in 4033096 and 956d736. The channel-row fix (animations off in onMove) is a best guess.
- The widget fix has no film: CI cannot put a widget on the simulator's Home Screen.

## Not done
- "Subtle Chumby touches throughout" (Richard, 11-20).
- The nap's one empty frame; the two-frame blank on Home's card between "Snoozed until" and "Stopping…".
- Lock Screen card's ellipsis and the island's empty area (gate notes; not touched here).
- Real-device proof of Stop/Snooze from the locked phone. The bridge's half of the alarm fixes (push.js).

## Before merge
- Remove .github/workflows/chumby-debug.yml, this file, and the film-only poses if unwanted.
