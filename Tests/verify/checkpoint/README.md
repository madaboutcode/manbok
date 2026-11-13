# Checkpoint, single instance and shutdown order check

Question: after any crash, kill, power loss, second launch or hung shutdown, does the next launch restore the newest complete checkpoint, and do two launches ever fight over the state directory?

Model: `checkpoint.model.mjs` (hand-copied from `StatePersistenceService.swift`, `SingleInstance.swift`, `AppShutdown.swift`).
`check.mjs` is a copy of the formal-verification skill script, so the check runs without the skill installed.
Method: order check (bounded search over every order of events). It is not a proof; "holds" is true only inside the bounds below.

Actors: up to 2 processes (P0 first instance, P1 a second launch at any time), a state directory of generations (`checkpoint-<seq>`) and temp dirs, one lock, one socket.
Steps include each step of save (snapshot, mkdir, write PCM, write manifest, fsync files, rename, fsync directory, delete older), restore (pick, delete stale), shutdown (stop returns or the 2 s budget expires, then save), kill -9, and one power loss (names persist or revert; unsynced data persists, is lost, or the PCM is garbage while the manifest survives).

## Rules

| Rule | In plain words | Source |
|---|---|---|
| OneSave | After any crash the next launch restores nothing or a checkpoint whose PCM and manifest come from one save and whose bytes are intact. Never a mismatched pair, never damaged audio. (= restore never picks an incomplete generation) | `StatePersistenceService.swift:122-140` (`stage` fsyncs both files and the dir before anything is published), `:58-63` (rename, then fsync dir), `:153-179` (`load` checks) |
| Newest | The checkpoint a launch restores is the newest complete one on disk at that moment. | `:77-95` (candidates newest first, skip invalid) |
| NoRegress | A launch never restores older than the newest save that had fully finished, unless a stored generation was damaged by outside means. (= a crash at any step of save never loses the newest complete checkpoint) | `:54-66` (older generations deleted only after the new one is renamed and the directory fsynced) |
| Q4Keep | If the app was stopped or lost power after launch with no save started since the previous restore, the next launch restores the same checkpoint again. (= Q4=A: a launch never deletes the only complete checkpoint) | `:91-104` (restore keeps the restored generation; deletes only older ones and temp dirs), `:92-97` (directory fsync after the pick) |
| SecondInstance | A process that does not hold the instance lock never changes the state directory or the socket; the running instance's socket stays in place. | `SingleInstance.swift:37-47` (`acquire`, non-blocking flock), `:60-74` (`claim` unlinks nothing), `ManbokApp.swift:22-28` (claim before migration, restore, socket), `UnixSocketServer.swift:160` (only the lock holder reaches `unlink` before bind) |
| NoDeadlock | The system never gets stuck with nothing left to do. | whole model |
| ShutdownSaves (reachability) | A shutdown whose `stop()` hangs still reaches its save without any crash: no process stays waiting for `stop()`. | `AppShutdown.swift:26,39-46` (2 s budget, then `checkpoint()` anyway) |

## Runs

From the worktree root: `MODEL_VARIANT=<v> MODEL_LAUNCHES=<L> MODEL_SAVES=<S> node Tests/verify/checkpoint/check.mjs Tests/verify/checkpoint/checkpoint.model.mjs --max-mb 1500`
Exit codes: 0 every rule holds, 1 a rule breaks, 2 model error, 3 stopped at a cap. L = process launches over the whole run, S = saves started. Other bounds: 1 power loss, 1 outside damage, 2 shutdown requests per process.

| Variant | L | S | Result | States | Time | Exit |
|---|---|---|---|---|---|---|
| `current` (fixed code, incl. restore fsync from commit 19bc2c8) | 3 | 2 | 7 rules hold | 972,123, depth 94 | 3749 s (machine under heavy load) | 0 |
| `current-pre-fix` (restore without the directory fsync) | 3 | 1 | Q4Keep breaks (finding F1, fixed in 19bc2c8) | 1,152,160, depth 94 | 346 s | 1 |

Earlier on the pre-final model revision (before the fsync fix and the PCM-garbage power outcome), `current` also held at L3/S2 and L2/S3.

### Finding F1 (fixed)

Path (variant `current-pre-fix`): P0 starts, restores, a shutdown begins a save and is killed after the rename but before the directory fsync; P0 starts again and restores that generation; power loss reverts the unsynced rename (the directory goes back to its temp name); P0 starts and finds no checkpoint.
Needs a first-ever checkpoint: with an older generation present, the revert brings it back. Fix: `fsyncDirectory(state)` in `restore()` after the pick (19bc2c8). No unit test: there is no seam to observe fsync, and XCTest cannot cause a power loss. The evidence is this model: `current` holds, `current-pre-fix` breaks.

## Mutants (one per rule, each breaking it)

| Mutant (`MODEL_VARIANT=`) | What it changes | Broken rule(s) | L/S | States | Exit | Replay against real code (production line changed temporarily, test seen to fail, line restored) |
|---|---|---|---|---|---|---|
| `m-rename-first` | rename before fsync of the files | OneSave, Newest (power loss leaves the PCM garbage under a valid manifest) | 2/1 | 78,843 | 1 | none: needs a power loss, XCTest cannot produce one |
| `m-clear-after-restore` | launch deletes the restored generation (pre-Q4) | NoRegress, Q4Keep | 3/1 | 801,085 | 1 | `restore` deleting `seq <= restored.seq` fails `CheckpointReliabilityReplayTests.test_previousRunAudioSurvivesCrashRightAfterNextLaunch`, `StatePersistenceTests.test_restore_twiceWithoutSaveInBetween_returnsSameAudio`, `test_restore_crashAfterStagingBeforeRename_returnsPreviousGenerationAndRemovesTemp` |
| `m-nolock` | a process that fails the lock carries on | SecondInstance (and Newest: the second process restores and deletes generations while the first one is saving) | 2/1 | 1,563,428 (stopped at the 1500 MB cap after the two breaks were found; the other rules are "not checked" in this run) | 1 | `acquire` returning a lock although held fails `SingleInstanceTests.test_acquire_whileHeld_returnsNil` and two `claim` tests |
| `m-sock-unlink` | a process that fails the lock unlinks the socket | SecondInstance | 2/2 | see gaps | 1 | `claim` calling `unlink(socketURL.path)` fails `IPCReliabilityReplayTests.test_secondLaunchDoesNotMakeRunningInstanceUnreachable` |
| `m-cleanup-first` | restore deletes all but the newest generation before it validates | Newest | 2/2 | see gaps | 1 | deleting before the pick fails `StatePersistenceTests.test_restore_newestTruncated_fallsBackToOlderComplete` |
| `m-inplace` | save replaces ring.pcm / ring.json in place (pre-B1) | OneSave | 2/2 | see gaps | 1 | none: the pre-B1 layout is not a one-line mutation; the generation tests (`StatePersistenceTests`) cover the fixed behaviour |
| `m-stop-unbounded` | shutdown waits for `stop()` without a budget | ShutdownSaves (reachability) | 2/2 | see gaps | 1 | `stopBudget = 20` fails `AppShutdownTests.test_perform_stopHangs_checkpointStillRunsWithinBound` |

## Gaps

- `m-sock-unlink`, `m-cleanup-first`, `m-inplace`, `m-stop-unbounded` were seen to break their rule on an earlier revision of this model (L2/S2: 61,856 / 68,828 / 17,969 / 24,759 states, exit 1 each). They were not rerun on the final revision (the run was stopped to limit machine load). The model edits since then: power-loss "garbage" now keeps the manifest, a save whose temp dir was removed aborts, restore fsyncs the directory.
- Deeper bounds than L3/S2 were not run. With L3/S3 the search exceeds 200,000 states and the 256 MB default; not tried at 1500 MB.
- F1 has no code replay (see above).

## Not modelled

- Legacy root files (`ring.pcm` / `ring.json` at the state root): unit tests only (`StatePersistenceTests.test_restore_legacyRootLayout_readOnceThenRemoved`).
- File sizes: every non-empty PCM has the size its manifest states (ring full). The size check cannot tell two saves apart (worst case). Real sizes differ when the ring is not full, which only helps detection.
- Fine-grained power-loss outcomes: one data outcome (persist / lose both files / PCM garbage with intact manifest) and one name outcome (persist / revert) for all unsynced items together. APFS ordering of rename before unlink is assumed.
- Garbage manifest content (it fails to decode and is detected).
- SessionRegistry, the ring and capture (data is a tag per save); `ManbokApp` wiring beyond the order claim, restore and bind.
- IPC (see `../ipc`): the PING answer of a holder is abstracted away; a process that fails the lock exits either way.
- The 0.1 s delay before `exit(0)` after STOP: modelled as exit at any time after a shutdown finished (a crash is possible at every step anyway).
- Clocks, directory mtime, disk full beyond one "write fails" step, permission errors, migration between claim and restore.
