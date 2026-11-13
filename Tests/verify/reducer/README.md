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
| P4 | A non-excluded app the reducer has seen, holding while capture runs, has an open session after a poll. Includes the recheck step when capture status changes in the same tick. | `DemandReducer.swift` 19; SLC tick |
| P5 | The chosen device never favours a draining app's device over a holder's and is never a vanished device. | `DemandReducer.swift` 22, `demand()` 186-200 |
| Cold | A cold start after idle does not inherit a healthy flag: first attempt uses wasFlowing=false. Inferred rule. | `CaptureSupervisor.swift` 15-19, 148-151, 380 |
| A3 | A mic switch through a no-device poll, restarted within 4 s of the last audio byte, with no start failure, never raises the backoff. | `CaptureSupervisor.swift` 15-17; `CaptureRestartPolicy.swift` 11, 21-22 |
| Cont | A session never closes while its app really holds a mic and is not excluded. | `DemandReducer.swift` 14-16 |
| Excl | After an app is excluded, its session and capture for it alone end within 8 s. | SLC `setExcludedGroups` 139, tick |
| Idem | `step` is idempotent on an unchanged input. | `DemandReducer.swift` 126-166 |
| NoDeadlock, CanIdle | The system never gets stuck; capture can always end up stopped. | model-level |
| Slow, ExclNew, P1s, P5s | Findings rules, only with `MODEL_FINDINGS=1`. See Findings. | |

## Runs (all from this folder; Node only, no audio device, no app)

Configs: A = `MODEL_APPS=2 MODEL_DEVS=2 MODEL_TOT=1 MODEL_EXAPPS=0`; B = `APPS=1 DEVS=2 TOT=6 EXAPPS=0`; C = `APPS=2 DEVS=1 TOT=2 EXAPPS=1`; L = `TIMERS=1 APPS=2 DEVS=1 TOT=1 EXAPPS=1`. TOT is the fault budget (mic switch, list blip, mic vanish, start failure, sleep, exclusion toggle). The full command is the first line of each file. `elapsed` is in each file.

Variant `fix` (the code as it is):

| Run file | States | Exit | Result |
|---|---|---|---|
| run-fix-A.txt | 290,054 | 0 | 13 rules hold |
| run-fix-B.txt | 573,074 | 0 | 13 hold |
| run-fix-C.txt | 528,718 | 0 | 13 hold |
| run-fix-L.txt | 586,351 | 0 | 15 hold (adds P3, Plat) |

Mutants: each breaks the model the way the code could break. A mutant counts as detected only when the rule listed breaks. Runs with "capped" stopped at 600,000 states after the first break was found; the other rules were then not checked.

| Run file | Variant (the break made) | States | Exit | Rule broken |
|---|---|---|---|---|
| run-no-a3-B.txt | no-a3: forget `lastDataAt` at release (HEAD behaviour before A3) | 600,000 capped | 1 | A3 |
| run-a3-leak-B.txt | a3-leak: do not clear `lastDataAt` when demand empties | 600,000 capped | 1 | Cold |
| run-gaphold-A.txt, run-gaphold-L.txt | gaphold: an app with a device-less flag but no mic device still holds | 600,000 capped | 1 | P2a P2b P5 (A); P2a P2b P3 Plat P5 (L) |
| run-flag-A.txt, run-flag-L.txt | flag: holding decided by the device-less flag alone, mic list ignored | 600,000 capped | 1 | P2a (A); P2a Plat (L) |
| run-p5union-A.txt | p5union: candidates are the union of holders' and draining apps' devices | 302,833 | 1 | P5 |
| run-stale-A.txt | stale: draining app's kept devices not intersected with live devices | 209,564 | 1 | P5 |
| run-rowsess-A.txt | rowsess (same variant, TOT=1) | 291,670 | 0 | none: this bound is too small to catch it |
| run-rowsess-A2.txt | rowsess: only holding apps get a session, draining apps do not; TOT=2 | 600,000 capped | 1 | P4 |
| run-nostep2-A.txt | nostep2: no recheck `step` after capture status changes | 299,608 | 1 | P4 |
| run-ticks-A.txt | ticks: grace counted in polls, not by the clock | 246,546 | 1 | P2b Idem |
| run-nofallback-A.txt | nofallback: candidates from holders only, no draining app's kept device (list blip) | 600,000 capped | 1 | P1 |
| run-excl-late-C.txt | excl-late: exclusion only blocks new arrivals, not an existing session | 600,000 capped | 1 | Excl |
| run-excl-ignore-C.txt | excl-ignore: exclusion ignored for holding | 600,000 capped | 1 | Excl |
| run-timer-C.txt | timer: session closes only by a separate timer, not by the reducer | 600,000 capped | 1 | Cont Excl |
| run-excl-dropnosess-C.txt | excl-dropnosess: exclusion drops a draining app that has no open session | 519,756 | 1 | P2b Cont Idem |
| run-tight-b7-L.txt | `fix`, BSTOP tightened to 7 | 586,351 | 1 | P3 Plat |
| run-tight-bex5-C.txt | `fix`, BEX tightened to 5 | 528,718 | 1 | Excl |

Mutants with no code analogue (they show the model can detect the class of fault, not that the code has it): ticks, timer, flag, gaphold, no-a3, a3-leak, excl-dropnosess, and the tight-bound runs. Mutants that map to real code and have a replay: rowsess, p5union, stale, nofallback, nostep2, excl-ignore, excl-late.

Findings runs (`MODEL_FINDINGS=1`, exit 1 is expected):

| Run file | Config | States | Rules broken |
|---|---|---|---|
| run-findings-nosleep.txt | APPS=1 DEVS=2 TOT=3, no sleep | 138,032 | Slow, P5s |
| run-findings-edge-true.txt | same, tie at exactly 4 s counts as flowing | 137,808 | Slow, P5s |
| run-findings-edge-false.txt | same, tie counts as not flowing | 138,032 | Slow, P5s |
| run-findings-excl-C.txt | config C, `fix` | 528,718 | Slow, ExclNew |
| run-findings-excl-nosess-C.txt | config C, candidate fix `excl-nosess` (excluded app gets no new session) | 526,108 | Slow only (ExclNew fixed) |

## Question: can a mic switch slower than 4 s grow the restart backoff?

**Yes.** Model: rule Slow breaks in every findings run (`run-findings-nosleep.txt`). The path is: app records on mic 1, audio flows, mic 1 disappears, a no-device poll releases the worker (A3 keeps `lastDataAt`), 4 s or more pass, app records on mic 2, start. At that start `bytesFlowing` is false (`CaptureSupervisor.swift` 149, 359), so `recordRestart(wasFlowing: false)` counts an unhealthy restart and the next delay doubles. Rule A3 (switch within 4 s) holds in all `fix` runs. At exactly 4 s the model explores both outcomes (the real result depends on timer jitter); Slow breaks either way (edge-true, edge-false).

Real code: `ReducerModelBudgetReplayTests` runs the real `CaptureSupervisor`: gap 3 s, mic 3 starts after the base delay (healthy); gap 5 s, mic 3 is deferred (delay grew from 3 s to 6 s). So the suspicion is right: A3 keeps `lastDataAt` across the release, but the evidence expires after `watchdogThreshold` = 4 s. Impact is a longer wait before the next restart, not a failed switch. The design promises A3 only for the "one poll" case (`CaptureSupervisor.swift` 15-17), so this is a gap in the design, not a code departure.

Not shown: the reducer model uses a budget abstraction (delay capped at 8 s instead of 30 s, unhealthy count saturating at 3). The supervisor stall/silence watchdogs and the exact `mayRestart` timing are in the other agent's supervisor model.

## Findings (not fixed; the brief says report)

1. **Slow** (above).
2. **ExclNew**: after the user excludes an app that is draining without a session, `DemandReducer.step` gives it a session when capture next comes up (`DemandReducer.swift` 19). The design does not say whether that is allowed; it is probably unintended. `test_ExclNew_...` uses `XCTExpectFailure` to pin it. The candidate fix `excl-nosess` removes the break in the model (`run-findings-excl-nosess-C.txt`). This is a code-matches-design finding, not a case of the fix violating a rule.
3. **P5s** (`run-findings-*.txt`): while the restart budget defers a switch, the running worker stays on a device that vanished or that only a draining app listed. The reducer picks the right device; the supervisor is deferred. This is the HEAD deferral behaviour. P5 (reducer choice, budget ignored) holds.
4. **P1s** (P1 without the budget exemption) did **not** appear in any findings run; only Slow, P5s, ExclNew broke. P1 holds with the exemption.

## Replays (`ReducerModelReplayTests.swift`, 11 tests)

Reducer and executor tests run through the real `SessionLifecycleController` with a model-mirroring fake supervisor (capture status is observable). The 2 budget tests run the real `CaptureSupervisor`. One test (ExclNew) uses `XCTExpectFailure`.

Failing-first: for each of rowsess, p5union, stale, nofallback, nostep2, excl-ignore, excl-late I temporarily broke the real code, ran the tests, saved the output in `replay-mutant-<name>.txt` (each shows the diff, the failing test, and `AUHAL started` count 0), then restored. After the last restore `git diff` of `Sources/` is empty.

The mutants rowsess/nostep2/etc. are code mutations; they were made in the working tree only and are not committed.

## Not modelled

Supervisor stall and silence watchdogs and environment signals; start failures other than a free choice per run; restart delay above 8 s (real cap 30 s) and unbounded unhealthy count; several processes per bundle ID and app grouping; merged observations; list blips longer than one poll; the real HAL boundary and permission; user-exclusion group semantics (one flag per app); sleep details (one 6 s clock jump); more than one fault per run beyond the TOT budget; device pick tie-break (abstracted to keep-current-else-lowest-id); one device per app; apps alive from the start. Runs that hit the 600,000 cap (marked above) did not check the remaining rules on that variant. The `notModeled` text inside the run files was written before the replay path was corrected, so it names a file that does not exist; the path above is right. The checker's drift record (`.sync`) has not been created.

## Full suite

`swift test --skip AUHALWorkerIntegrationTests --skip CaptureE2ETests`: 266 tests, 0 failures (baseline 255 + 11 new); `grep -c "AUHAL started"` prints 0. Output: `run-swift-test.txt`.
