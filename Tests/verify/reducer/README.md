# Reducer + session machine: bounded order model

Checks the order rules of branch A (`fix/T1081-holder`): an app records while its input device list contains a microphone device. It is a **bounded check, not a proof**. The model is hand-mirrored from the code, so it is linked to the code only by the XCTest replays listed below. Where a rule holds, it holds within the bounds printed in the run file.

Rules come from the design (`ARCHITECTURE.md`, the CONTRACT blocks in the covered files, the team-lead brief), not from reading the code. Where code and design disagree, the model follows the design rule and the disagreement is listed under Findings.

Code covered (branch A head 889608f): `Sources/ManbokCore/Application/DemandReducer.swift` `step` (126-166), `demand()` (186-200); `Sources/ManbokPlatform/Capture/SessionLifecycleController.swift` `tick` (195-230), `setExcludedGroups` (139); `Sources/ManbokPlatform/Capture/CaptureSupervisor.swift` `apply` (118-267), `startWorker` (295), `restart` (345), `bytesFlowing` (356); `CaptureRestartPolicy.swift`.

## Files

- `session.model.mjs` model. `check.mjs` checker (copy of the skill checker, unchanged). `run.sh` runs everything: `./run.sh all`, or `./run.sh <tag> <variant> [ENV=value ...]`.
- `run-<tag>.txt`: first line is the exact command; then checker output; then `exit code` and `elapsed`.
- `replay-mutant-*.txt`: failing-first evidence for the XCTest replays (see Replays).
- Replays: `Tests/ManbokPlatformTests/ReducerModelReplayTests.swift` (11 tests).
- Checker exit codes: 0 all hold, 1 a rule breaks, 2 model error, 3 capped (not checked). All runs use `--max-states 600000 --max-mb 3000`.

## Rules (plain words, source)

| Rule | Plain words | Source |
|---|---|---|
| P1 | After a regular 2 s poll, while a non-excluded app holds a mic, capture runs. Excused: start failed, restart budget defers the start, no known device exists. | reducer CONTRACT (`DemandReducer.swift` 1-30); SLC tick 195-230 |
| P1b | No known device (mic switch + list blip + old mic gone): capture is off for at most one poll and the open session stays open. | `DemandReducer.swift` 14-22; `CaptureSupervisor.swift` 118-160 |
| P2a | An app that never held a mic never gets a session. | `DemandReducer.swift` 19; `step` 126-166 |
| P2b | After a poll, capture running means some app holds a mic or is draining after holding. | `DemandReducer.swift` 22; `demand()` 186-200 |
| P3 | Capture stops within 8 s (grace 5 s + 2 s poll + 1 s) of the last non-excluded holder stopping. Timers config only. | `DemandReducer.swift` 14-16; SLC 119 |
| Plat | An app's session closes within 8 s of that app stopping. Timers config only. | same |
| P4 | A non-excluded app the reducer lists as holding at that step (phase holding), while capture runs, has an open session after a poll. A holder missing from one poll's list (draining at that step) gets its session one poll later. Includes the recheck step when capture status changes in the same tick. | `DemandReducer.swift` session rule; SLC tick |
| NoSessNonHolding | No session opens for an app that does not hold at that step (a draining app never gets one). Added in FIX-A. | `DemandReducer.swift` session rule |
| ExclNew | After an app is excluded it gets no new session. Holds because the reducer input is "holds AND NOT excluded" and a session opens only for a holding entry. Reducer has no exclusion knowledge. | `DemandReducer.swift`; SLC `setExcludedGroups` |
| Carry | A start uses exactly the wasFlowing value recorded when the previous worker ended, read once. | `CaptureSupervisor.swift` `recordWorkerEnd`, `startWorker` |
| P5 | The chosen device never favours a draining app's device over a holder's and is never a vanished device. | `DemandReducer.swift` 22, `demand()` 186-200 |
| Cold | A cold start after idle does not inherit a healthy flag: first attempt uses wasFlowing=false. Inferred rule. | `CaptureSupervisor.swift` 15-19, 148-151, 380 |
| A3 | A mic switch through a no-device poll, restarted after any gap, with no start failure, never raises the backoff. | `CaptureSupervisor.swift` `recordWorkerEnd`; `CaptureRestartPolicy.swift` 11, 21-22 |
| Slow | A mic switch with no start failure never raises the restart backoff, however long the gap between the last byte and the start. Was a finding before FIX-A; now a normal rule. | same |
| Cont | A session never closes while its app really holds a mic and is not excluded. | `DemandReducer.swift` 14-16 |
| Excl | After an app is excluded, its session and capture for it alone end within 8 s. | SLC `setExcludedGroups` 139, tick |
| Idem | `step` is idempotent on an unchanged input. | `DemandReducer.swift` 126-166 |
| NoDeadlock, CanIdle | The system never gets stuck; capture can always end up stopped. | model-level |
| P1s, P5s | Findings rules, only with `MODEL_FINDINGS=1`. See Findings. | |

## Runs (all from this folder; Node only, no audio device, no app)

Configs: A = `MODEL_APPS=2 MODEL_DEVS=2 MODEL_TOT=1 MODEL_EXAPPS=0`; B = `APPS=1 DEVS=2 TOT=6 EXAPPS=0`; C = `APPS=2 DEVS=1 TOT=2 EXAPPS=1`; L = `TIMERS=1 APPS=2 DEVS=1 TOT=1 EXAPPS=1`. TOT is the fault budget (mic switch, list blip, mic vanish, start failure, sleep, exclusion toggle). The full command is the first line of each file. `elapsed` is in each file.

Variant `fix` (the code as it is). All four end by themselves (whole space explored, no cap):

| Run file | States | Exit | Result |
|---|---|---|---|
| run-fix-A.txt | 217,616 | 0 | 16 rules hold |
| run-fix-B.txt | 321,240 | 0 | 16 hold |
| run-fix-C.txt | 404,908 | 0 | 16 hold |
| run-fix-L.txt | 505,750 | 0 | 18 hold (adds P3, Plat) |

Mutants: each breaks the model the way the code could break. A mutant counts as detected only when the rule listed breaks. "capped" = stopped at 600,000 states after the first break; the other rules were then not checked.

| Run file | Variant (the break made) | States | Exit | Rules broken |
|---|---|---|---|---|
| run-no-a3-B.txt | no-a3: forget the flow evidence at release (old HEAD behaviour) | 600,000 capped | 1 | Carry A3 Slow |
| run-a3-leak-B.txt | a3-leak: do not clear the recorded value when demand empties | 600,000 capped | 1 | Carry |
| run-not-consumed-B.txt | not-consumed: a start does not clear the recorded value | 600,000 capped | 1 | Carry |
| run-drainsess-A.txt, run-drainsess-C.txt | drainsess: old session rule, a draining app also gets a session | 267,516 (A); 514,423 (C) | 1 | NoSessNonHolding (A); NoSessNonHolding ExclNew (C) |
| run-gaphold-A.txt, run-gaphold-L.txt | gaphold: an app with a device-less flag but no mic device still holds | 600,000 capped | 1 | P2a P2b P5 (A); P2a P2b P3 Plat P5 (L) |
| run-flag-A.txt, run-flag-L.txt | flag: holding decided by the device-less flag alone | 600,000 capped | 1 | P2a (A); P2a Plat (L) |
| run-p5union-A.txt | p5union: candidates are the union of holders' and draining apps' devices | 244,339 | 1 | P5 |
| run-stale-A.txt | stale: draining app's kept devices not intersected with live devices | 211,634 | 1 | P5 |
| run-rowsess-A.txt | rowsess (TOT=1; pre-FIX-A file, session rule now in drainsess) | 291,670 | 0 | none: bound too small. Obsolete |
| run-rowsess-A2.txt | rowsess, TOT=2 (pre-FIX-A file) | 600,000 capped | 1 | P4. Obsolete |
| run-nostep2-A.txt | nostep2: no recheck `step` after capture status changes | 299,940 | 1 | P4 |
| run-ticks-A.txt | ticks: grace counted in polls, not by the clock | 197,414 | 1 | P2b Idem |
| run-nofallback-A.txt | nofallback: candidates from holders only (list blip) | 215,294 | 1 | P1 |
| run-excl-late-C.txt | excl-late: exclusion only blocks new arrivals | 498,475 | 1 | ExclNew Excl |
| run-excl-ignore-C.txt | excl-ignore: exclusion ignored for holding | 600,000 capped | 1 | ExclNew Excl |
| run-timer-C.txt | timer: session closes only by a separate timer | 600,000 capped | 1 | Cont Excl |
| run-excl-dropnosess-C.txt | excl-dropnosess: exclusion drops a draining app that has no session | 396,370 | 1 | P2b Cont Idem |
| run-tight-b7-L.txt | `fix`, BSTOP tightened to 7 | 505,750 | 1 | P3 Plat |
| run-tight-bex5-C.txt | `fix`, BEX tightened to 5 | 404,908 | 1 | Excl |

Mutants with no code analogue (they show the model detects the class of fault): ticks, timer, flag, gaphold, no-a3, a3-leak, excl-dropnosess, the tight-bound runs. Mutants that map to real code and have a replay: drainsess (old session rule), p5union, stale, nofallback, nostep2, excl-ignore, excl-late, no-a3 / not-consumed (supervisor replays M1, M8, N10).

Findings runs (`MODEL_FINDINGS=1`, exit 1 is expected). Only P5s now breaks (Slow and ExclNew moved into the main rules and hold):

| Run file | Config | States | Rules broken |
|---|---|---|---|
| run-findings-nosleep.txt | APPS=1 DEVS=2 TOT=3, no sleep | 83,338 | P5s |
| run-findings-edge-true.txt | same, tie at exactly 4 s counts as flowing | 83,338 | P5s |
| run-findings-edge-false.txt | same, tie counts as not flowing | 83,338 | P5s |

Obsolete files from before FIX-A, no longer produced by `run.sh` (delete when `mc-trash` exists): run-findings-excl-C.txt, run-findings-excl-nosess-C.txt, run-rowsess-A.txt, run-rowsess-A2.txt, replay-mutant-rowsess.txt. Some runs took over 20 minutes under machine load (load average about 150); none was cut by a time bound. The flag-A file was rerun alone to remove a duplicated block.

## Question: can a mic switch slower than 4 s grow the restart backoff?

Before FIX-A: yes (rule Slow broke; a 5 s gap deferred mic 3 because the delay grew from 3 s to 6 s). After FIX-A: no. `CaptureSupervisor` records `wasFlowing` when any worker ends and a start reads it once and clears it; a start never evaluates byte age. Rule Slow holds in `run-fix-A/B/C/L.txt`; mutants no-a3 and not-consumed break Carry (and A3, Slow for no-a3). Real code: `ReducerModelBudgetReplayTests` gap 5 s now starts mic 3 after the base delay (failing-first against the old code: `replay-mutant-oldslow.txt`).

## Findings

1. **Slow**: fixed in FIX-A (above).
2. **ExclNew**: fixed in FIX-A. `DemandReducer.step` opens a session only for an entry that holds at that step; the reducer has no exclusion knowledge. The XCTExpectFailure pin is gone; the test now asserts the fixed behaviour. The model rule NoSessNonHolding holds on the new rule and breaks on the old one (`run-drainsess-A/C.txt`; old DemandReducer fails 4 assertions in 4 tests: `replay-mutant-oldsession.txt`). Guarantee changed: P4 was "every non-absent app gets a session" (design.md section 3 / design-v2 section 2 step 2); now a holder missing from one poll's list gets its session one poll (2 s) later.
3. **P5s** (`run-findings-*.txt`): while the restart budget defers a switch, the running worker stays on a device that vanished or that only a draining app listed. The reducer picks the right device; the supervisor is deferred. P5 (reducer choice, budget ignored) holds.
4. **P1s** did not appear in any findings run.

## Replays (`ReducerModelReplayTests.swift`, 11 tests)

Reducer and executor tests run through the real `SessionLifecycleController` with a model-mirroring fake supervisor (capture status is observable). The 2 budget tests run the real `CaptureSupervisor`. The ExclNew test now asserts the fixed behaviour (no `XCTExpectFailure`).

Failing-first: for each of rowsess, p5union, stale, nofallback, nostep2, excl-ignore, excl-late I temporarily broke the real code, ran the tests, saved the output in `replay-mutant-<name>.txt` (each shows the diff, the failing test, and `AUHAL started` count 0), then restored. After the last restore `git diff` of `Sources/` is empty.

The mutants rowsess/nostep2/etc. are code mutations; they were made in the working tree only and are not committed.

## Not modelled

Supervisor stall and silence watchdogs and environment signals; start failures other than a free choice per run; restart delay above 8 s (real cap 30 s) and unbounded unhealthy count; several processes per bundle ID and app grouping; merged observations; list blips longer than one poll; the real HAL boundary and permission; user-exclusion group semantics (one flag per app); sleep details (one 6 s clock jump); more than one fault per run beyond the TOT budget; device pick tie-break (abstracted to keep-current-else-lowest-id); one device per app; apps alive from the start. Runs that hit the 600,000 cap (marked above) did not check the remaining rules on that variant. The `notModeled` text inside the run files was written before the replay path was corrected, so it names a file that does not exist; the path above is right. The checker's drift record (`.sync`) has not been created.

## Full suite

`swift test --skip AUHALWorkerIntegrationTests --skip CaptureE2ETests`: 318 tests, 0 failures (FIX-A, baseline 315); `grep -c "AUHAL started"` prints 0. Output: `run-swift-test.txt` (final run).
