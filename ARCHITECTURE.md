# manbok — architecture

**Sources:** `requirements.md`, `spikes/README.md` (2026-06-03)

---

## 1. Problem model

### Job to be done

When speech-to-text (or another recorder) drops audio, the user hires **manbok** to keep a rolling copy of what they said so they can export it without repeating themselves.

### Nouns and verbs (essential complexity)

| Essential | Meaning |
|-----------|---------|
| **PCM stream** | Mono 16 kHz, 16-bit samples — the canonical stored form |
| **Ring buffer** | Fixed-capacity in-memory store of the last 10 minutes of PCM bytes |
| **Listener** | Long-lived process that continuously fills the ring |
| **Dump** | On-demand export of the last *N* minutes (or all) to a WAV file |
| **Commands** | `start`, `stop`, `status`, `dump` — user-facing control |

### Actors

- **User** — runs CLI in a terminal
- **CLI** — short-lived; sends control commands
- **Daemon (Listener)** — long-lived; owns mic + ring buffer
- **macOS** — mic permission, AVAudio HAL, filesystem

### Invariants

1. While listening, buffer length never exceeds 10 minutes of PCM at the canonical format.
2. No audio is written to disk until an explicit `dump`.
3. Dump output is standard RIFF WAV, same format as the buffer.
4. At most one listener instance per state directory (single owner of the ring).

### Non-functional constraints (from spec)

- macOS Apple Silicon, Swift SPM, AVFoundation/CoreAudio only
- ~19.2 MB RAM for buffer
- 24/7, low CPU; must not block other mic consumers (validated manually — see assumptions)

### Out of scope (explicit)

Menu bar, silence detection, segmentation UI, processing beyond capture + export, auto-start at login (unless added later).

---

## 2. Discovery memo

### Volatility map

| Likely to change | Contain behind |
|------------------|----------------|
| Buffer duration (10 min) | `BufferPolicy` / constants in domain |
| Dump path conventions | `DumpPaths` (system temp + timestamp); Audacity launch in CLI |
| IPC message shape | `IPC` module only |
| Capture API (AVAudioEngine details) | `PlatformCapture` adapter |
| Device native sample rate | Inside converter in capture adapter |

Ring math and WAV layout should not change when IPC changes.

### Core vs shell

| Core (pure, test with `Data`) | Shell (I/O) |
|-------------------------------|-------------|
| `ByteRingBuffer` write/read/slice | `AVAudioCapture` tap + converter |
| `WavPCMEncoder` header + body | Writing `.wav` to URL |
| `DumpSlice` (minutes → byte range) | Unix socket listen/accept |
| | Process detach, pid file |
| | Mic permission prompts |

### Failure domains

| Failure | Blast radius | Behavior |
|---------|--------------|----------|
| Mic denied | Cannot listen | `start` fails with actionable message; no daemon |
| Capture glitch / converter error | One buffer chunk | Drop chunk; log at `.error` to stderr/OSLog; keep listening |
| Daemon crash | Lost buffer | Acceptable — RAM-only by design |
| Dump disk full | Dump only | Return error; listener keeps running |
| Second `start` | CLI only | Idempotent: report already listening |
| CLI while daemon down | CLI only | Clear "not listening" / connection error |

### Data lifecycle

```text
HAL mic (variable rate)
  → convert (adapter)
  → PCM bytes (fixed format)
  → ring write (overwrite oldest)
  → [on dump] contiguous logical slice (may be two physical segments)
  → WAV bytes
  → file on disk
```

### State ownership

| State | Owner | Persisted? |
|-------|-------|------------|
| Ring buffer contents | Daemon only | No |
| Listening / not listening | Daemon | No (reconstructed: process alive?) |
| pid, socket path | Daemon writes on start; CLI reads | Yes — `~/.manbok/` |
| Dump files | CLI or daemon (see open questions) | Yes — user path |

---

## 3. Layer stack

Each layer hides one kind of mess. Dependencies point **inward** (interface → application → domain; infrastructure implements domain ports).

```text
┌─────────────────────────────────────────────────────────────┐
│ L4  Interface — CLI (manbok executable)                  │
│     Hides: argv, exit codes, human messages                 │
│     Exports: none (edge of system)                          │
│     Does not know: AVAudioEngine, ring layout                 │
└───────────────────────────┬─────────────────────────────────┘
                            │ IPC client
┌───────────────────────────▼─────────────────────────────────┐
│ L3  Application — Daemon use cases                          │
│     Hides: command routing, session lifecycle, dump workflow  │
│     Exports: start/stop/status/dump orchestration             │
│     Depends on: L2 domain + L1 ports                        │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│ L2  Domain — audio memory model                             │
│     Hides: wrap arithmetic, WAV structure, time→bytes       │
│     Exports: RingBuffer, WavEncoder, AudioFormat, DumpRange │
│     Does not know: files, sockets, microphones              │
└───────────────────────────▲─────────────────────────────────┘
                            │ implements ports
┌───────────────────────────┴─────────────────────────────────┐
│ L1  Infrastructure — platform adapters                      │
│     Hides: AVAudioEngine, sockaddr, fork, FileManager       │
│     Implements: AudioCapturing, IPCServing, ProcessControl    │
└─────────────────────────────────────────────────────────────┘
```

**L2 is the center of gravity.** Everything interesting about correctness lives there; spikes already proved ring + WAV + capture feasibility at the edges.

---

## 4. Candidate decompositions

### A — Layered library + dual-mode binary (recommended)

**Pattern:** Hexagonal / ports-and-adapters (lightweight — one capture port, no generic DI framework).

**Shape:**

- SPM library `ManbokCore` — L2 + L3 + IPC message types
- SPM library `ManbokPlatform` — L1 adapters
- Executable `manbok` — CLI + `manbok daemon` (or `--daemon`) entry

**Dependency:** `manbok` → `ManbokPlatform` → `ManbokCore`

| Pros | Cons |
|------|------|
| Domain fully unit-testable | Two library targets (still small) |
| Spike code maps cleanly | Slightly more scaffolding than one file |
| Clear place for CONTRACT blocks | |

### B — Single target monolith

**Pattern:** Modular folders inside one executable target.

| Pros | Cons |
|------|------|
| Fewest moving parts | Temptation to import AVFoundation in "domain" files |
| Fast to scaffold | Harder to enforce dependency rules in SPM |

**Loses when:** first requirement change (e.g. test capture without mic) forces refactor.

### C — Separate `manbok` + `manbok-daemon` binaries

**Pattern:** Two executables, shared library.

| Pros | Cons |
|------|------|
| Obvious process boundary | Two products to install/sign |
| | `start` must locate daemon binary |

**Loses when:** dual-mode single binary (`start` re-execs self) is simpler and standard on macOS CLI tools.

### Comparison (engineering quality vs simplicity)

| Candidate | Engineering | Simplicity | Verdict |
|-----------|-------------|------------|---------|
| A | Strong boundaries, testable core | Moderate | **Choose** |
| B | Weak boundary enforcement | Highest now | Reject — boundary debt |
| C | Clear but redundant | Lower | Reject — unnecessary split |

### Recommendation

**Candidate A** — layered library + single binary with daemon subcommand.

**Trade-off:** Two SPM targets instead of one file. Pays for itself on the first `dump` boundary test and any capture refactor.

**Would reconsider if:** the entire tool stays under ~400 lines forever with zero tests — then B might win. That is unlikely once IPC + daemon lifecycle land.

---

## 5. Key design decisions

### Process model

```
Considered:   LaunchAgent-only | separate daemon binary | dual-mode single binary
Chosen:       dual-mode single binary (`manbok daemon` invoked by `start`)
Why:          one install artifact; spike-validated lifecycle; familiar macOS CLI pattern
Limitations:  no auto-respawn on crash unless user re-runs start
Fine because:  24/7 is user-initiated; crash loses buffer anyway (RAM-only)
Reversal:     login persistence / auto-restart → add LaunchAgent plist, keep same daemon entry
```

### Ring representation

```
Considered:   frame/sample ring | byte ring | time-indexed segments
Chosen:       fixed-format byte ring (19_200_000 bytes)
Why:          requirements fix PCM format; dump is byte slice + WAV header; spike math confirmed
Limitations:  format change requires full redesign of buffer + encoder
Fine because:  spec locks 16 kHz mono s16le for STT
Reversal:     multi-format or variable rate storage → frame-aware ring + metadata
```

### IPC

```
Considered:   shared memory | HTTP localhost | Unix domain socket + line protocol
Chosen:       Unix socket at ~/.manbok/run.sock, newline commands
Why:          spike passed; debuggable with nc; no extra deps
Limitations:  local machine only; no large binary payloads over socket
Fine because:  dump writes file path in reply, not audio over wire
Reversal:     remote control → add auth + different transport; keep domain commands
```

### Dump destination and trim workflow

```
Considered:   cwd | ~/Downloads | system temp dir
Chosen:       FileManager.default.temporaryDirectory + manbok-<timestamp>.wav
Why:          ephemeral recovery files; avoids cluttering project dirs; matches "quick trim" workflow
Limitations:  OS may purge temp; user must save from Audacity if keeping long-term
Fine because:  job is recover-then-trim, not archive
Reversal:     user wants durable dumps → --output flag or ~/Downloads default
```

```
Considered:   daemon opens app | CLI opens app | print path only
Chosen:       CLI runs `open -a Audacity <path>` after successful DUMP
Why:          CLI runs in user GUI session; daemon stays headless; dump still succeeds if Audacity missing
Limitations:  requires Audacity installed at /Applications/Audacity.app (standard macOS install)
Fine because:  explicit trim step in requirements conversation
Reversal:     CI/automation → --no-open flag (not v1 unless needed)
```

### Capture stack

```
Considered:   AudioQueue | AVAudioRecorder | AVAudioEngine tap + converter
Chosen:       AVAudioEngine input tap + AVAudioConverter → s16le 16 kHz mono
Why:          spike showed device at 48 kHz → stable conversion; continuous tap fits ring
Limitations:  converter errors drop frames; mic-sharing is OS-dependent
Fine because:  matches "no processing" scope; spike proved throughput
Reversal:     mic-sharing manual test fails → spike HAL/aggregate device path before coding more
```

---

## 6. Components and contracts

### Package / module map

```text
ManbokCore/
  Domain/
    AudioFormat.swift      # constants: sampleRate, channels, bytesPerSample, capacity
    ByteRingBuffer.swift
    DumpRange.swift          # minutes → byte offsets in ring
    WavPCMEncoder.swift
  Application/
    RecordingSession.swift   # wires capture sink → ring; thread-safe
    ListenerService.swift    # start/stop/status/dump use cases
  IPC/
    IPCCommand.swift         # parse/serialize line protocol
    IPCResponse.swift

ManbokPlatform/
  Capture/
    AVAudioCapture.swift     # implements AudioCapturing
  IO/
    WavFileWriter.swift      # URL + Data → disk
    DumpPaths.swift          # temp dir + timestamped filename
    AppStatePaths.swift      # ~/.manbok/{run.sock, appa.pid}
  External/
    AudacityLauncher.swift   # NSWorkspace / open(1) wrapper (CLI-only)
  Logging/
    AppLog.swift             # os.Logger + stderr mirror for CLI
  Process/
    DaemonProcess.swift      # fork/detach, pid file
  IPC/
    UnixSocketServer.swift
    UnixSocketClient.swift

manbok/                   # executable
  CLI/
    CommandRouter.swift      # ArgumentParser → IPC or daemon main
  DaemonMain.swift
  Main.swift
```

### L2 — Domain

#### `AudioFormat`

**Responsibility:** Single source of truth for canonical PCM and buffer capacity.

**GUARANTEES**

- `capacityBytes == 19_200_000` for 10 minutes at defined rate.
- All domain math uses these constants.

**DOES NOT:** Read hardware formats.

---

#### `ByteRingBuffer`

**Responsibility:** O(1) append of PCM chunks; logical read of last *N* bytes (possibly two segments).

**GUARANTEES**

- After `write(_:)`, total stored length ≤ `capacityBytes`; oldest bytes overwritten.
- `slice(lastBytes:)` returns 1 or 2 `Data` segments that concatenate to exactly `min(requested, filled)` bytes, in chronological order.
- Thread-safety: documented — either internal lock or "external serial queue" (choose one in implementation; **RecordingSession** owns the queue).

**EXPECTS**

- Writes are multiples of `bytesPerFrame` (2 bytes for s16le mono) or implementation rounds/truncates consistently.

**FAILURE BEHAVIOR**

- `write` larger than capacity → only the trailing `capacityBytes` of the chunk are kept.

**DOES NOT:** Know WAV, files, or time in minutes (see `DumpRange`).

---

#### `DumpRange`

**Responsibility:** Map `minutes?` and current `filledBytes` → byte count for slice.

**GUARANTEES**

- `nil` minutes → all filled content.
- `minutes` clamped to ≤ 10 and ≤ filled duration.
- Returns 0 only when ring is empty.

**DOES NOT:** Perform I/O.

---

#### `WavPCMEncoder`

**Responsibility:** Pure encoding of PCM `Data` → WAV file bytes (RIFF + fmt + data).

**GUARANTEES**

- Output passes `file(1)` as PCM mono 16 kHz for given input length (spike-validated layout).
- Header `data` chunk size matches PCM count.

**EXPECTS:** PCM already in canonical format.

**DOES NOT:** Write files (platform writer does).

---

### L3 — Application

#### `RecordingSession`

**Responsibility:** Own the ring; receive PCM from capture port; expose `append` / `snapshotForDump`.

**GUARANTEES**

- Only mutates ring on capture callback path (serialized).
- `snapshotForDump(minutes:)` is consistent — no partial write visible.

**EXPECTS:** `AudioCapturing` delivers converted PCM only.

**FAILURE BEHAVIOR:** Capture stop → session quiescent; ring contents preserved until process exit.

---

#### `ListenerService`

**Responsibility:** Use cases for daemon: `startCapture`, `stopCapture`, `isListening`, `dump(minutes:to:)`.

**GUARANTEES**

- `dump` while not listening → structured error (not empty file).
- `dump(minutes:)` writes to `DumpPaths.nextURL()` under system temp (never cwd).
- `stop` idempotent.
- `start` when already listening → no-op success.

**EXPECTS:** Platform adapters injected at construction.

**DOES NOT:** Parse CLI flags; launch GUI apps.

---

#### `DumpPaths`

**Responsibility:** Deterministic temp filenames for dumps.

**GUARANTEES**

- Path is under `FileManager.default.temporaryDirectory`.
- Pattern: `manbok-YYYYMMDD-HHMMSS.wav` (local timezone).
- Parent directory exists before write.

**DOES NOT:** Open applications or delete old dumps.

---

#### `AudacityLauncher` (CLI / L4, not daemon)

**Responsibility:** Open a WAV in Audacity after dump.

**GUARANTEES**

- Uses `/usr/bin/open -a Audacity <path>` (or `NSWorkspace` equivalent).
- If Audacity is missing, returns failure **without** deleting the WAV.

**FAILURE BEHAVIOR**

- App not found → log warning on stderr; dump path still on stdout — **v1: exit 0 if dump OK, warn on open fail**.

**DOES NOT:** Block on user saving in Audacity.

---

### L1 — Infrastructure (ports)

#### `AudioCapturing` (protocol)

```swift
protocol AudioCapturing: AnyObject {
    func start(sink: @escaping (Data) -> Void) throws
    func stop()
}
```

**GUARANTEES (AVAudioCapture):** Delivers s16le 16 kHz mono; calls sink on audio thread.

**FAILURE BEHAVIOR:** `start` throws if permission denied or engine fails; no sink calls after `stop`.

**DOES NOT:** Buffer more than one chunk internally.

---

#### `UnixSocketServer` / `UnixSocketClient`

**GUARANTEES:** One request per connection; UTF-8 line commands; response line + optional body path for dump.

**Commands (v1):**

```text
PING          → PONG
STATUS        → LISTENING | STOPPED
DUMP [minutes] → OK path=<absolute-path>  | ERR <message>
STOP          → OK
```

**DOES NOT:** Stream audio over socket.

---

#### `DaemonProcess`

**GUARANTEES:** `start` detaches child, writes pid file, exclusive lock via pid + stale socket cleanup.

**FAILURE BEHAVIOR:** Stale pid → detect dead process, reclaim state dir.

---

### L4 — CLI

#### `CommandRouter`

**Responsibility:** Map `start|stop|status|dump` to IPC client or local daemon launch.

**GUARANTEES**

- Exit code 0 on success; non-zero on user-fixable errors.
- **stdout** carries only scriptable primary output (one line): dump → absolute path; `status` → `listening` | `stopped`.
- **stderr** carries human diagnostics (start/stop messages, warnings, errors).
- `start` launches daemon only if not already listening.

**DOES NOT:** Touch `AVAudioEngine` directly; write log files.

**FLAGS (v1 minimum):** none required; future `--no-open` skips `AudacityLauncher`; future `--verbose` raises log level.

---

## 7. End-to-end flows

### `manbok start`

```text
CLI → check pid/socket → if alive: stderr "already listening", exit 0
     → else fork exec same binary `daemon`
Daemon → write pid, bind ~/.manbok/run.sock
       → ListenerService.startCapture()
       → block in socket accept loop
```

### `manbok dump 3`

```text
CLI → connect socket → send "DUMP 3\n"
Daemon → DumpPaths.nextURL() under system temp
       → DumpRange(3) → ring.slice → WavPCMEncoder → WavFileWriter
       → reply "OK path=/var/folders/.../T/manbok-20260603-160000.wav"
CLI → write path to stdout (single line, no prefix)
    → diagnostics to stderr (e.g. "opened in Audacity")
    → AudacityLauncher.open(path)
    → on open fail: stderr warning; stdout path unchanged; exit 0
```

### `manbok status`

```text
CLI → STATUS → LISTENING | STOPPED
```

---

## 8. Assumptions and fallbacks

| Assumption | Invalidated if | Fallback |
|------------|----------------|----------|
| AVAudioEngine + converter can run alongside other mic apps | Manual mic-share test fails | Document limitation; investigate aggregate device / lower buffer size |
| Single daemon per user is enough | Multi-user Mac shared | State dir includes `$UID` |
| 10 min fixed is fine | User wants 30 min | `BufferPolicy` constant + memory doc |
| Line IPC is sufficient | Need structured errors | Version prefix `v1 STATUS` without changing domain |
| Forked daemon survives terminal close | Child dies with session | `launchd` plist (out of scope v1) |

---

## 9. Validation scenarios

| Scenario | Expected |
|----------|----------|
| Happy: start → wait → dump | WAV in temp dir, Audacity opens with audio |
| Dump OK, Audacity missing | path on stdout; warning on stderr; exit 0 |
| `manbok dump \| wc -l` | stdout is exactly one path line; logs don't pollute pipe |
| Dump 0 min / empty ring | ERR, no file |
| Double start | "already listening", one process |
| stop then dump | ERR not listening |
| dump while Zoom uses mic | WAV has audio; Zoom still works (manual) |
| Daemon kill -9 | status STOPPED; start works again |
| Unit: ring wrap | 11 min write → last 10 min only in slice |
| Unit: WAV header | byte lengths match `spikes` golden |

---

## 10. Resolved product decisions

| Decision | Choice |
|----------|--------|
| **Dump path** | System temp dir (`FileManager.default.temporaryDirectory`), file `manbok-<timestamp>.wav` |
| **Who writes dump** | Daemon (returns absolute path over IPC); CLI opens Audacity |
| **After dump** | CLI launches **Audacity** with the WAV for trim/export |
| **Logging** | `os.Logger` + stderr diagnostics; stdout = primary output only; no log files |

### Logging (resolved)

**Decision:** All diagnostic output to **stderr** only. **No log files** in v1.

**Idiomatic Swift / macOS CLI practice:**

| Practice | Application |
|----------|-------------|
| **stdout vs stderr** | stdout = machine-friendly result (one line per command); stderr = everything else |
| **`os.Logger`** | Shared `Logger(subsystem: "ai.manbok.app", category: "cli" \| "daemon" \| "capture")` — Apple-standard, zero deps, works in Console.app |
| **No `print()` in Core** | Domain/application use `Logger` or callbacks; only L4/L1 edges emit to stderr |
| **Levels** | `.error` failures, `.warning` recoverable (dropped frame, Audacity missing), `.info` lifecycle (started/stopped), `.debug` verbose (behind `--verbose` later) |
| **Detached daemon** | stderr may be discarded after fork; **OSLog still records** — operators use Console.app filter `subsystem:ai.manbok.app` |
| **ArgumentParser** | CLI parsing (ecosystem standard for Swift executables) |
| **Exit codes** | 0 success; 1 general error; optional 2 usage (ArgumentParser) |

**`AppLog` helper (L1 or small Core utility):**

- Wraps `Logger` + mirrors `.info`/`.warning`/`.error` to `FileHandle.standardError` when `isatty(STDERR_FILENO)` or always for errors (so terminal users see feedback without opening Console).
- Debug logs: Logger only unless `--verbose` (then also stderr).

**DOES NOT:** Rotate files, syslog forwarding, structured JSON logs (YAGNI).

---

## 11. Implementation order (aligned to layers)

1. L2 `ByteRingBuffer` + `WavPCMEncoder` + tests
2. L2 `DumpRange` + tests
3. L1 `AVAudioCapture` (port spike code)
4. L3 `RecordingSession` + `ListenerService`
5. L1 IPC server + `DaemonProcess`
6. L4 CLI commands
7. Manual mic-sharing gate

---

## 12. One-breath summary

**Building:** a macOS CLI + background daemon that keeps 10 minutes of speech-grade PCM in a byte ring and exports WAV on demand.
**Why:** STT sometimes drops audio; user needs a silent safety net.
**Path:** layered core (testable ring + WAV) with thin AVFoundation/socket/process adapters and a dual-mode binary.
**Doesn't handle:** segmentation, in-app trim UI, login items, disk persistence of the buffer (user saves from Audacity if keeping).
**Reversal:** mic-sharing fails or buffer duration/format changes → revisit capture adapter or storage model before piling on features.
