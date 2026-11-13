# CaptureSupervisor order model

A bounded check of every order of events for the capture supervisor on branch `fix/T1081-holder` (head 889608f). It is not a proof. Every "holds" below is true only inside the bounds printed in the run file.

Files: `supervisor.model.mjs` (the model, mirrored by hand from the code), `check.mjs` (checker, copied from the formal-verification skill), `run.sh` (runs), `run-*.txt` (one saved run each), `replay.mjs` (scenarios; prints expected rows), `supervisor.sync.json` (drift record), `mutation-replay-results.txt` (failing-first evidence for the XCTests).
Real-code replays: `Tests/ManbokPlatformTests/CaptureSupervisorReplayTests.swift` and the generated `CaptureSupervisorReplayExpected.swift`.

Rerun: `cd Tests/verify/supervisor && ./run.sh all` (about 15 minutes; each run is cut at 1200 s, exit 124 = bound reached = gap). One run: `./run.sh base MODEL_VARIANT=base`. Regenerate expected rows: `node replay.mjs --swift > ../../ManbokPlatformTests/CaptureSupervisorReplayExpected.swift`. Drift: `node check.mjs drift .`. All runs are node only; no audio device is opened.

## What the model contains

One app in demand (two ids, so an id change can occur), two mics, a fake worker. Each 2 s poll the environment picks: app list (empty / app with no device / app with mic 1 or 2), chunk mode (flowing / digital silence / none / flowing then stops), a `captureDisturbed` signal, a start that throws. The model mirrors `apply`, `restart`, `startWorker`, `bytesFlowing`, `releaseWorkerKeepingFlowEvidence`, `abandonWorker`, `stop`, `CaptureRestartPolicy` and `SilenceRecoveryPolicy`.
Units: poll 2 s, watchdogThreshold 4 s, baseDelay 1 s, maxDelay 30 s, silence 10 s, maxSilentRestarts 2 (the code defaults). Ages are capped at the largest value the code compares them with, so the state space is finite and the search ends by itself (base: 380,358 states, whole space explored).

Model-vs-code check (done in this task): each action was read against `CaptureSupervisor.swift` at 889608f, and 19 scenarios were replayed on the real code (below). One defect was found in the model and fixed: the A3 mutant `clear-on-release` was not caught, because rule R2m read the byte age from the field the mutant clears. The rule now reads a history copy (`rla`). Dead history fields were removed.

## Rules

Source column: design = `.mc/tasks/T1081-mic-vs-monitor/design-v2.md`; CS = `Sources/ManbokPlatform/Capture/CaptureSupervisor.swift`; RP = `CaptureRestartPolicy.swift`; SP = `SilenceRecoveryPolicy.swift`. "Assumption" = no written rule; inferred, marked so.

| Rule | In plain words | Source | Result on current code |
|---|---|---|---|
| R1_run | After a poll the worker runs only if demand has a candidate device. With a candidate device it runs, unless the start failed or the restart budget blocked the attempt. No candidate device (or empty demand) means no worker. | design section 2 "Supervisor changes" (gap hold removed); CS:7-9, 146-154, 235-245 | holds |
| R2_healthyRestart | A start or restart made while bytes flowed within 4 s does not grow the backoff. | RP:10-12, 72-80; CS:149-151, 345, 324 | holds |
| R2m_micSwitch (assumption) | A mic released for "no device" and started again no more than K polls after the poll that saw its last byte does not grow the backoff. K=1 means at most about 4 s after the last byte. | design section 6 A3 ("a healthy mic switch resets backoff"); CS:14-17, 149-150, 356-360, 362-371 | holds for K=1; breaks for K=2 (see "The 4 s question") |
| R3_bounded | The restart delay never exceeds maxDelay. | RP:10, 53-55 | holds |
| R3e_sustained (assumption, off unless MODEL_SUSTAIN=1) | After a worker flowed for maxDelay without a break, a later stall or signal restart starts from base delay (count at most 1). | none written; inferred from RP:10-14 | breaks (run sustain-scaled): the count is not reset by a long healthy run; only a restart of a flowing worker resets it. See finding F3. |
| R4_stall | The stall watchdog never restarts a worker before 4 s have passed since its start and since its last byte. | RP:6-8, 59-62; CS:172-183 | holds |
| R5_ladderOrder | The silence ladder moves one step at a time (armed, re-resolving, retrying, holding) or back to armed. A ladder restart starts only from armed or re-resolving. Holding is entered only from retrying. | SP:5-16, 47-108; CS:186-216 | holds |
| R5_ladderReset | A poll that sees real signal, or a demand/target change from outside the ladder, leaves the ladder armed. | SP:111-114, 49-53; CS:247-249 | holds |
| R5_holdHealth | Health is "holding silent" only while a worker is capturing. | CaptureWaist.swift:40 ("holdingSilent: capturing, silence ladder exhausted") | BREAKS (finding F1) |
| R5_holdFlag (assumption) | The hold flag is set only while the ladder is in holding. | sm-inventory H7 | BREAKS (finding F2, already listed as H7) |
| R6_lifetime | Empty demand and `stop()` clear the carried byte evidence, the restart budget, the ladder and the hold flag. | CS:14-17, 106-128, 373-384 | holds in the model; see "leak-empty" below: no behaviour depends on it |
| R6b_noLeak | Byte evidence without a worker exists only between a release for no device and the next start attempt. | CS:14-17 | holds |
| Rdefer (assumption) | With a candidate device and no start failure, the worker waits at most N polls for the restart budget. N is a bound, not a rule from the design. | design section 6 A3 | restricted to mic switches only: holds for N=13, breaks for N=12 (max wait 13 polls = 26 s). See finding F4. |
| R8_noStorm (assumption) | Recovery restarts (stall, signal, silence) do not happen in more than N polls in a row. | RP:14-16 ("no flap loop") | N=99 holds; N=4 breaks: a `captureDisturbed` signal on every poll restarts a flowing worker on every poll. See finding F5. |
| NoDeadlock, CanIdle | No stuck state; from any point the worker can end up stopped. | checker built-ins | hold |

## Runs

Each row: command (`env <vars> node check.mjs supervisor.model.mjs --max-states 6000000 --max-mb 3000`, run by `run.sh`), states, exit code. Exit 0 = every rule holds; 1 = a rule breaks; 124 = time bound reached. No run hit a bound, no run hit the state cap (exit 3 never occurred).

| Run file | Env | Result | States | Depth | Exit |
|---|---|---|---|---|---|
| run-base.txt | MODEL_VARIANT=base | 2 of 16 break: R5_holdHealth, R5_holdFlag | 380,358 | 63 | 1 |
| run-switch-only.txt | base, MODEL_RESTRICT=switch (only app-list changes, chunks always flow, no start failure, no signals) | 16 hold | 7,510 | 68 | 0 |
| run-switch-only-k2.txt | switch-only, MODEL_SWITCH_MAX=2 | R2m_micSwitch breaks | 7,510 | 68 | 1 |
| run-switch-only-defer12.txt | switch-only, MODEL_DEFER_MAX=12 | Rdefer breaks | 7,510 | 68 | 1 |
| run-switch-only-defer13.txt | switch-only, MODEL_DEFER_MAX=13 | 16 hold | 7,510 | 68 | 0 |
| run-switch-only-defer14.txt | switch-only, MODEL_DEFER_MAX=14 | 16 hold | 7,510 | 68 | 0 |
| run-storm4.txt | base, MODEL_RECOV_MAX=4 | + R8_noStorm breaks | 380,358 | 63 | 1 |
| run-sustain-scaled.txt | base, MODEL_SUSTAIN=1, MODEL_MAX=60 (maxDelay scaled to 12 s to keep the space small) | + R3e_sustained breaks | 114,772 | 40 | 1 |
| run-m-clear-on-release.txt | MODEL_VARIANT=m-clear-on-release | + R2m_micSwitch | 380,358 | 63 | 1 |
| run-m-never-reset.txt | m-never-reset | + R2_healthyRestart, R2m_micSwitch | 367,990 | 59 | 1 |
| run-m-stall-lastdata-only.txt | m-stall-lastdata-only | + R4_stall | 383,678 | 63 | 1 |
| run-m-ladder-skip.txt | m-ladder-skip | + R5_ladderOrder | 359,772 | 58 | 1 |
| run-m-leak-empty.txt | m-leak-empty | + R6_lifetime, R6b_noLeak | 382,152 | 63 | 1 |
| run-m-gaphold.txt | m-gaphold | + R1_run | 418,707 | 63 | 1 |
| run-m-uncapped-delay.txt | m-uncapped-delay | + R3_bounded | 681,046 | 81 | 1 |

The earlier partial run files (unknown revision, one killed by SIGTERM after 13 s) were replaced. The earlier "6M states did not finish" came from that kill; the base space is 380,358 states and finishes in about 80 s.

## Mutant to broken rule to replay

A mutant is the model with one fix removed. "Replay" is the XCTest that runs the same kind of trace on the real code and fails when the fix is removed from production code (temporary edit; output in `mutation-replay-results.txt`; code restored afterwards).

| Mutant (fix removed) | Rule it breaks | Production edit used | Replay test | Fails with the edit |
|---|---|---|---|---|
| clear-on-release (A3: keep lastDataAt on release) | R2m_micSwitch | CS releaseWorkerKeepingFlowEvidence clears lastDataAt | M1 | M1 |
| never-reset (reset count on healthy restart) | R2_healthyRestart, R2m | RP recordRestart grows on every restart | M2 | M1, M2, B2 |
| stall-lastdata-only (fresh worker gets 4 s grace) | R4_stall | RP isStalled ignores captureStartedAt | M3 | M3, N4, B3 |
| ladder-skip (armed goes to re-resolving) | R5_ladderOrder | SP noteRestart armed -> retrying | M4 | M4, N5, B2 |
| gaphold (no candidate device releases the worker) | R1_run | CS target-nil branch keeps the worker | M5, M6 | M5, M6, N7, M1, B1 |
| uncapped-delay (cap at maxDelay) | R3_bounded | RP currentDelay without min(maxDelay) | M7 | M7 |
| leak-empty (empty demand clears byte evidence) | R6_lifetime, R6b_noLeak | CS abandonWorker keeps lastDataAt | none possible | survives all 19 replays and the 15 existing CaptureSupervisorTests |

leak-empty: the model rule breaks, but no observable behaviour changes. After empty demand the restart policy is reset, so the next start is the first attempt and ignores `wasFlowing`; the start then sets `lastDataAt = nil` anyway. The line `lastDataAt = nil` in `abandonWorker` is redundant for restart behaviour today. R6 guards state hygiene only. Not a bug; recorded so nobody expects a test to fail for it.

Counterexample traces from the checker are short (for example clear-on-release: list mic 1, poll, no mic listed, poll, mic 1 listed, poll). The XCTest scenarios M1..M7 are longer versions of the same trace, repeated until the changed count shows up as a late start (the count itself is not visible; the effect is).

## XCTest replays

`CaptureSupervisorReplayTests` (19 tests) drives the real `CaptureSupervisor` with a fake worker and a fake clock (existing seams only: `makeWorker`, `clock`, `EnvironmentSignaling`). After each poll it compares (capturing, target, start attempts, health == holdingSilent, health == deferredNoDevice) to the model's row.
- N1..N9: one normal path through each mirrored action. All equal to the model.
- B1..B3: break paths on the current code (findings below). The expected rows are today's behaviour, so these pass; they pin the finding and must be changed when it is fixed.
- M1..M7: mutant discriminators.

Result on unmutated code: `swift test --skip AUHALWorkerIntegrationTests --skip CaptureE2ETests` = 274 tests, 0 failures (255 baseline + 19); `grep -c "AUHAL started"` = 0.

## The 4 s question

Can a mic switch longer than 4 s (watchdogThreshold) from the last audio byte grow the restart backoff? Yes. Run `switch-only-k2` (R2m with K=2 polls) breaks. Shortest trace:
1. app lists mic 1; 2. poll (worker starts); 3. app lists no device; 4. poll (bytes flowed during the interval, then the worker is released; last byte about 0.1 s old); 5. poll (still no device, byte 2 s old); 6. app lists mic 1; 7. poll (last byte now 4.1 s old).
At step 7 `bytesFlowing` is false (CS:359: age less than 4 s), so the start is recorded as unhealthy (RP:72-77): the unhealthy count goes 0 to 1 and the next restart must wait 2 s (then 4, 8, 16, 30 s with each further slow switch). The new mic starts at step 7 itself (the gate is checked before the count grows); the cost shows later.
Replay B1 on the real code: four such switches in a row (about 3 polls each); at the fifth, the mic is listed again at poll 12 but capture only resumes at poll 14: 2 polls = 4 s late. In switch-only mode the longest wait the model finds is 13 polls = 26 s (Rdefer: holds at 13, breaks at 12). The user sees a gap in the recording after the mic returns, only after repeated slow switches within seconds of each other; one slow switch shows nothing. The count is cleared only by a restart of a flowing worker, empty demand, or `stop()`.
Design check: design-v2 section 6 A3 promises "a healthy mic switch resets backoff". The code keeps the evidence for 4 s only (CS:359). The design does not state the 4 s limit. Mismatch reported, not fixed.

## Findings (not fixed; outside this task's ownership)

- F1 (R5_holdHealth, replay B2 row 20): after the silence ladder gives up (holding), a restart whose start throws leaves `isHolding` true with no worker; `apply` returns health `.holdingSilent` while `isCapturing` is false (CS:256-257, flag cleared only at CS:315 or CS:194). CaptureWaist.swift:40 says holdingSilent means capturing. No code outside the supervisor reads `health` today (grep over Sources), so nothing visible to the user; any future consumer would see a wrong state.
- F2 (R5_holdFlag): same flag: `noteExternalChange` re-arms the ladder but not `isHolding` (known as H7 in sm-inventory).
- F3 (R3e, replay B3): the unhealthy count survives a long healthy run. Two stalls 40 s apart give count 2 (delay 4 s), not 1. Effect: a later stall restart may wait up to 30 s after enough unrelated stalls. RP:12-14 says health is byte flow, not elapsed time, on purpose; this is the cost of that choice.
- F4 (Rdefer): see "The 4 s question".
- F5 (R8, run storm4): a `captureDisturbed` signal on every poll while bytes flow restarts the worker on every poll (a restart of a flowing worker is healthy, so no backoff). RP:14-16 promises "no flap loop" for devices that cannot hold capture; a flowing engine with a signal storm is outside that promise, but is a flap loop to the user (mic indicator strobing every 2 s).
Escalation: F1 and F2 are rule violations on real code paths (replayed). They are pre-existing (the lines are unchanged since d7a0c6b) and no production change is made here.

## Not modelled

- Device choice (CaptureDevicePolicy tie-break): the resolved target is a free input each poll; 2 mics.
- Demand reducer and sessions (other model); one app in demand.
- Real chunk timing inside a 2 s interval: four modes only; a chunk just before a poll has age 0.1 s; silence starts 1.9 s before the poll.
- Poll jitter: polls are exactly 2.0 s apart. A restart delay of exactly 2 s (count 1) is allowed at the next poll only because 2.0 >= 2.0; a poll 1 ms early would defer one poll.
- Stale chunks from a stopped worker (H4); signal observer on a failed start (H6); the tick between a ladder restart and the first silent chunk (H5, partly: mode changes cover the re-arm).
- Sleep/wake and wall-clock jumps (`Date()` is wall clock); thread interleaving of `stop()` on the socket thread.
- Health values other than holdingSilent and deferredNoDevice; log lines; `defaultInputChanged` (inert); `restartInPlace` (never returned).
- Restart count saturates at 6 in the model (delay is already at maxDelay from 5); real code counts without bound.
- Bounds: one app, two mics, one pending signal, one start failure kind. Larger populations are not checked.

## Gaps

- `leak-empty` has no behavioural replay (equivalent mutant).
- Rdefer, R8 and R3e are assumption rules with a chosen bound; the bound is part of each run.
- Rdefer was only run in switch-only mode, not in the full model.
- The model is hand-mirrored. Its link to the code is the 19 replays (all rows equal, 7 mutants killed by them); logic not on those paths is "not linked to the code".
