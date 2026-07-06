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

- **User** — uses the menu bar app; occasionally the CLI
- **CLI** — short-lived; thin IPC client (`manbok start` opens the app if not running)
- **ManbokApp** — long-lived SwiftUI menu bar app; owns mic + ring + per-app sessions + IPC server
- **Daemon (Listener) — debug/legacy** — the `--foreground` code path (`DaemonSession`); same Core/Platform underneath, no menu bar UI
- **macOS** — mic permission, AVAudio HAL, filesystem, `SMAppService` (login items)

### Invariants

1. ~~While listening, buffer length never exceeds 10 minutes of PCM at the canonical format.~~
   **Retired 2026-07-04** — capacity is now a user setting (`BufferPolicy` presets: 5/10/30/60/120
   min, default 10). See `docs/decisions/20260704-configurable-ring-buffer.md`. Replacement
   invariant: while listening, buffer length never exceeds the currently-selected preset's
   capacity.
2. No audio is written to disk until an explicit `dump` (or export).
3. Dump/export output is standard RIFF WAV, same format as the buffer.
4. At most one app/listener instance per state directory (single owner of the ring) — enforced
   by `AppDelegate.anotherInstanceRunning()` pinging the existing socket.

### Non-functional constraints (from spec)

- macOS Apple Silicon, Swift SPM, AVFoundation/CoreAudio only
- Memory scales with the chosen preset (~19 MB at 10 min default, up to ~230 MB at 120 min)
- 24/7, low CPU; must not block other mic consumers (validated manually — see assumptions)

### Out of scope (explicit)

Silence detection, segmentation UI, processing beyond capture + export. Menu bar and auto-start
at login are now **in scope** (see §3, §6) — this list reflects what's still deliberately out.

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
│ L4  Interface — SwiftUI App (ManbokApp) + CLI (manbok)       │
│     Hides: MenuBarExtra/popover/Settings UI, argv, exit codes │
│     Exports: none (edge of system)                          │
│     Does not know: AVAudioEngine, ring layout                 │
└───────────────────────────┬─────────────────────────────────┘
                            │ IPC client (CLI) / direct calls (App)
┌───────────────────────────▼─────────────────────────────────┐
│ L3  Application — session + capture orchestration            │
│     Hides: per-app session lifecycle, poll/drain timing,     │
│            dump workflow, SwiftUI state bridging              │
│     Exports: SessionRegistry, CaptureOrchestrator,            │
│              PopoverViewModel, ListenerService (legacy path) │
│     Depends on: L2 domain + L1 ports                        │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│ L2  Domain — audio memory model                             │
│     Hides: wrap arithmetic, WAV structure, time→bytes,       │
│            waveform peak math, buffer-size policy             │
│     Exports: RingBuffer, WavEncoder, AudioFormat, DumpRange, │
│              BufferPolicy, WaveformSampler                    │
│     Does not know: files, sockets, microphones              │
└───────────────────────────▲─────────────────────────────────┘
                            │ implements ports
┌───────────────────────────┴─────────────────────────────────┐
│ L1  Infrastructure — platform adapters                      │
│     Hides: AVAudioEngine, sockaddr, fork, FileManager,        │
│            process-identity lookup, UserDefaults, SMAppService│
│     Implements: AudioCapturing, IPCServing, ProcessControl,   │
│              AppIdentityResolver, SettingsStore, ExportService,│
│              LoginItemManager, MigrationService               │
└─────────────────────────────────────────────────────────────┘
```

**L2 is the center of gravity.** Everything interesting about correctness lives there; spikes already proved ring + WAV + capture feasibility at the edges. The menu bar app is a thin L4 shell over the same L2/L3 — it does not duplicate domain logic.

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

**2026-07-04 update:** Candidate A's shape gained a third target, `ManbokApp` (SwiftUI, depends on
`ManbokCore` + `ManbokPlatform`, no ArgumentParser). The long-lived process is now the menu bar
app itself, not a `manbok daemon` subcommand — see the Process model decision below and
`docs/decisions/20260704-menubar-app-process-model.md`. The `--foreground` CLI path (`DaemonSession`)
still exists for headless debugging and reuses the same libraries unchanged.

---

## 5. Key design decisions

### Process model

```
Considered:   LaunchAgent-only | separate daemon binary | dual-mode single binary
Chosen (v1):  dual-mode single binary (`manbok daemon` invoked by `start`)
Why:          one install artifact; spike-validated lifecycle; familiar macOS CLI pattern
Limitations:  no auto-respawn on crash unless user re-runs start
Fine because:  24/7 is user-initiated; crash loses buffer anyway (RAM-only)
Reversal:     login persistence / auto-restart → add LaunchAgent plist, keep same daemon entry
```

**Superseded 2026-07-04** — see `docs/decisions/20260704-menubar-app-process-model.md`:

```
Considered:   app + separate daemon (two processes) | app *is* the daemon | keep always-on
              via new IPC mode | drop `manbok start`
Chosen:       ManbokApp (menu bar app) IS the long-lived process — owns capture, ring, IPC
              server. LaunchAgent retired; start-at-login is an in-app SMAppService toggle.
              CLI becomes a thin IPC client; `manbok start` runs `open -a Manbok` if not running.
              Always-on capture dropped from v1 — opportunistic capture is the product.
Why:          one process is simpler; Core/Platform libraries drop in unchanged; login items
              are the native mechanism for menu bar apps; always-on had no traced user job
Limitations:  with the app not running, CLI ops fail (with a hint) except `start`
Fine because: `MigrationService` removes any previously-installed LaunchAgent plist so two
              processes never fight over the socket
Reversal:     real always-on need appears → add an IPC mode command (e.g. `MODE ALWAYS`)
```

### Ring representation

```
Considered:   frame/sample ring | byte ring | time-indexed segments
Chosen:       fixed-format byte ring (19_200_000 bytes at the 10-min default)
Why:          requirements fix PCM format; dump is byte slice + WAV header; spike math confirmed
Limitations:  format change requires full redesign of buffer + encoder
Fine because:  spec locks 16 kHz mono s16le for STT
Reversal:     multi-format or variable rate storage → frame-aware ring + metadata
```

**Capacity superseded 2026-07-04** — see `docs/decisions/20260704-configurable-ring-buffer.md`:

```
Considered:   fixed 10-min ring (status quo) | config-file/CLI-only setting | GUI setting with
              hard 30/60-min cap | GUI setting with large ceiling and visible memory cost
Chosen:       BufferPolicy presets 5/10/30/60/120 min (default 10), user-selected in Settings.
              Per-preset memory cost shown next to each choice. Resize preserves the newest
              audio that fits (SessionRegistry.resize); shrinking drops sessions that fall off
              entirely, same rule as ring wrap.
Why:          driving job (meeting/call recovery) runs up to an hour; beyond that, memory is
              an acceptable, user-owned trade-off
Limitations:  presets only, no arbitrary duration in v1
Reversal:     >120 min need → extend preset list (cheap)
```

### Session identity — per-app, concurrent (superseded union model)

```
Considered:   unbroken-mic-run session with union identity ("FaceTime, OBS") | per-app chop-at-
              every-change (fragments a call when another app dips in) | per-app concurrent
              sessions, overlapping views over the shared ring
Chosen:       Option 3 — one session per app; sessions from different apps overlap in time and
              share ring bytes (SessionRegistry: one open session per bundle ID, not one global
              session). See docs/decisions/20260704-session-per-app.md.
Why:          the app is the user's recognition handle for recovery ("the Zoom call" as one row);
              union identity made rows ambiguous, chop-at-change fragmented long calls
Limitations:  more than one session open at once; overlapping sessions dumped separately
              duplicate shared audio in their WAVs (by design)
Reversal:     per-app tracking proves noisy (helper-process churn) → fall back to union-identity
              unbroken-run sessions, which remains the proven behavior underneath
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

**App path (2026-07-04):** the menu bar app does not shell out to Audacity. `ExportService`
writes the session WAV to temp and either reveals it in Finder (`NSWorkspace
.activateFileViewerSelecting`) or puts the file URL on the pasteboard — the user picks the
export action per-session from the popover. `AudacityLauncher` remains CLI-only, exercised on
the `--foreground` debug path.

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
    AudioFormat.swift        # constants: sampleRate, channels, bytesPerSample
    BufferPolicy.swift       # ring-size presets (5/10/30/60/120 min) + resize-loss math
    ByteRingBuffer.swift     # capacity now a construction param, not a constant
    DumpRange.swift          # minutes → byte offsets in ring
    WaveformSampler.swift    # PCM → amplitude peaks (batch + incremental)
    AppEvent.swift           # arrived/departed value type for orchestrator poll-diff
    SessionSummary.swift, SessionSummary+Display.swift, RingBufferSummary.swift, DumpSessionSelector.swift
    WavPCMEncoder.swift
  Application/
    SessionRegistry.swift    # per-app open/closed sessions over the shared ring — replaces RecordingSession
    ListenerService.swift    # legacy/debug: CLI --foreground start/stop/status/dump use cases
  Ports/
    AudioCapturing.swift, DumpSink.swift
  IPC/
    IPCCommand.swift         # bare-verb request parsing
    IPCResponse.swift        # NDJSON response serialization

ManbokPlatform/
  Capture/
    AVAudioCapture.swift          # implements AudioCapturing
    CaptureOrchestrator.swift     # per-app poll/drain lifecycle — drives SessionRegistry (the app's capture path)
    AppIdentityResolver.swift     # bundle ID/pid → display name (curated table → PPID walk → cosmetic fallback)
    ProcessAudioMonitor.swift     # enumerates other processes holding the mic
    OpportunisticCaptureController.swift  # legacy/debug: union-identity capture for --foreground
    InputDeviceObserver.swift, MicrophoneAuthorization.swift
  IO/
    WavFileWriter.swift, DumpPaths.swift, AppStatePaths.swift, PlatformDumpSink.swift
    ExportService.swift      # session WAV → Finder reveal or clipboard (the app's export path)
  Settings/
    SettingsStore.swift      # UserDefaults-backed bufferPreset + startAtLogin
    LoginItemManager.swift   # SMAppService.mainApp wrapper
  Runtime/
    DaemonSession.swift, DaemonPresentation.swift, DaemonRuntimeEnvironment.swift  # legacy/debug --foreground path
    MigrationService.swift   # removes legacy LaunchAgent + stale socket/pid on app launch
  External/
    AudacityLauncher.swift   # NSWorkspace / open(1) wrapper (CLI-only, legacy/debug)
  Logging/
    AppLog.swift, Diagnostics.swift, DiagnosticsWriting.swift
  Process/
    DaemonProcess.swift      # pid file + stale-socket cleanup (used by both app and --foreground)
  IPC/
    UnixSocketServer.swift, UnixSocketClient.swift
  UI/
    ActivityPresenting.swift, TerminalCaptureMeter.swift, TerminalPainter.swift  # --foreground live meter

ManbokApp/                  # SwiftUI app target — no ArgumentParser
  ManbokApp.swift            # @main; MenuBarExtra + Settings scene; wires SessionRegistry →
                              # CaptureOrchestrator → PopoverViewModel; hosts the IPC server inline
  ViewModels/
    PopoverViewModel.swift    # polls SessionRegistry at ~1 Hz while popover visible; ExportService wrapper
  Views/
    PopoverContentView, HeaderView, SessionListView, SessionRowView, WaveformView,
    EmptyStateView, PermissionDeniedView, FooterView, SettingsView

manbok/                     # CLI executable — thin IPC client
  CLI/
    CommandRouter.swift      # ArgumentParser → IPC calls; `start` opens the .app if not running
  DaemonMain.swift           # legacy/debug: `--foreground` entry point (DaemonSession)
  Main.swift
```

### L2 — Domain

#### `AudioFormat`

**Responsibility:** Single source of truth for canonical PCM constants.

**GUARANTEES**

- `bytesPerMinute`/`bytesPerSecond` derive every duration↔byte conversion (buffer capacity is no
  longer a fixed constant here — see `BufferPolicy`).
- All domain math uses these constants.

**DOES NOT:** Read hardware formats.

---

#### `BufferPolicy`

**Responsibility:** Ring-size presets and the pure math to reason about resizing.

**GUARANTEES**

- `Preset` is `min5|min10|min30|min60|min120`, default `min10` (matches the historical fixed ring).
- `capacityBytes(for:)` derives every byte count from `AudioFormat.bytesPerMinute`.
- `memoryCost(for:)` — human string (`"~19 MB"`), decimal megabytes, rounded.
- `sessionsLost(currentSessions:targetPreset:ringTotalWritten:)` — dry-run count of sessions that
  would have zero surviving bytes if resized now; a session with even one surviving byte is not
  counted as lost.

**DOES NOT:** Persist the selected preset (`SettingsStore`) or perform the resize/copy (`SessionRegistry.resize`).

---

#### `ByteRingBuffer`

**Responsibility:** O(1) append of PCM chunks; logical read of last *N* bytes (possibly two segments).

**GUARANTEES**

- Capacity is a construction parameter (`BufferPolicy.capacityBytes(for:)`), not a fixed constant.
- After `write(_:)`, total stored length ≤ `capacityBytes`; oldest bytes overwritten.
- `slice(lastBytes:)` returns 1 or 2 `Data` segments that concatenate to exactly `min(requested, filled)` bytes, in chronological order.
- A seeded initializer (capacity, `seededTotalBytesWritten`, `initialData`) supports preserve-newest-that-fits resize (`SessionRegistry.resize`) without losing the absolute-offset namespace sessions are anchored to.
- Thread-safety: documented — either internal lock or "external serial queue" (choose one in implementation; **`SessionRegistry`** owns the queue, replacing `RecordingSession`).

**EXPECTS**

- Writes are multiples of `bytesPerFrame` (2 bytes for s16le mono) or implementation rounds/truncates consistently.

**FAILURE BEHAVIOR**

- `write` larger than capacity → only the trailing `capacityBytes` of the chunk are kept.

**DOES NOT:** Know WAV, files, or time in minutes (see `DumpRange`).

---

#### `WaveformSampler`

**Responsibility:** Pure PCM → amplitude-peak computation for waveform rendering.

**GUARANTEES**

- `peaks(from:buckets:)` always returns exactly `buckets` values in `0.0...1.0` (batch mode, used once at session close).
- `IncrementalSampler` accumulates peaks as PCM chunks arrive (used while a session is open, for the live waveform); `currentPeaks(buckets:)` and `finalize(buckets:)` both return exactly `buckets` values — `finalize` is just the last observation, no distinct closing computation.
- 16-bit little-endian mono; a trailing odd byte is dropped, not an error.

**DOES NOT:** Render UI or store peaks (`SessionRegistry` owns storage of finalized peaks).

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

#### `SessionRegistry` (replaces `RecordingSession`)

**Responsibility:** Owns the shared byte ring, all per-app sessions, stable ids, and waveform peaks. The registry, not a single global session, is the app's model of "what's been recorded."

**GUARANTEES**

- One open session per bundle ID; multiple concurrent open sessions across different apps (see `docs/decisions/20260704-session-per-app.md`) — sessions are overlapping **views** over one ring (byte-range + id), not disjoint owners of bytes.
- `append(_:)` writes once to the shared ring, then feeds every open session's incremental waveform sampler with the same chunk.
- Stable ids are monotonic `UInt64`, assigned at open, never reused; re-opening an already-open bundle ID returns the same id.
- `listSessions()` returns newest-start-first; a closed session with any surviving bytes is clamped to its surviving range rather than dropped entirely (deliberate change from the old `RecordingSession`, which discarded on any overwrite).
- `resize(to:)` does a preserve-newest-that-fits copy and expires closed sessions that fully fell off; open sessions keep shrinking from the front dynamically, same mechanism as ring wrap.
- All mutation serialized on a private queue (same pattern as `RecordingSession` had).

**EXPECTS:** `bundleID` non-empty; `append(_:)` called only while capture is active.

**FAILURE BEHAVIOR:** `snapshotForSession` for an unknown/fully-expired id → `nil`.

**DOES NOT:** Start/stop capture, write files, or import AppKit/AVFoundation.

---

#### `CaptureOrchestrator` (the app's capture path; replaces `OpportunisticCaptureController` there)

**Responsibility:** Per-app start/stop derived from set-diff of consecutive polls against `ProcessAudioMonitor`, driving `SessionRegistry` open/close directly.

**GUARANTEES**

- App appears → `registry.openSession(bundleID:displayName:)` using `AppIdentityResolver`. App disappears → starts a per-app drain timer; expiry → `registry.closeSession(bundleID:)`; reclaimed before expiry → timer cancelled, no session churn.
- Publishes `anySessionOpen: Bool` (true through drain — one-signal rule) and `micPermission: MicPermissionState`, both updated on the main thread for SwiftUI.
- Capture engine starts on first arrival, stops once every session is closed and no drain timers remain.
- Capture self-heals while sessions are open (spike-validated 2026-07-06, see `tasks/decisions-20260706-device-change-robustness.md`): restarts on default-input change (`InputDeviceObserver`), on `AVAudioEngineConfigurationChange`, and on byte-flow stall detected by a watchdog on the poll tick — `engine.isRunning` is untrustworthy, byte flow is ground truth. Sessions stay open across restarts (short ring gap only). Restarts are rate-limited with exponential backoff (`CaptureRestartPolicy`, health = byte flow, not elapsed time) so a device that can't hold capture converges to one attempt per 30s — never a flap loop. Input-device identity logged at notice level on every (re)start.

**EXPECTS:** `AudioCapturing`, `SessionRegistry`, `ProcessAudioMonitor`, `AppIdentityResolver` injected. `start()`/`stop()` idempotent, callable from any thread.

**FAILURE BEHAVIOR:** `capture.start` throws → retried on subsequent polls at the policy backoff; sessions not opened for an arrival until capture is actually running. Device-change signals inside the backoff window are suppressed (the watchdog is the backstop — a debounce alone can swallow the terminal stop event).

**DOES NOT:** Own the ring or session storage; route IPC; touch UI; run VAD (stays in `ListenerService`, used only for the `--foreground` meter).

---

#### `PopoverViewModel`

**Responsibility:** Bridges `SessionRegistry` + `CaptureOrchestrator` to SwiftUI popover views.

**GUARANTEES**

- Polls the registry at ~1 Hz only between `startPolling()`/`stopPolling()` (popover visible/not visible) — no background polling.
- `dumpSession`/`copySession` are thin wrappers over `ExportService`, deriving `appSlug` from the session's display name.

**FAILURE BEHAVIOR:** `ExportService` throwing or returning nil (expired session) → `dumpSession` returns nil / `copySession` returns false; no error surfaced beyond that.

**DOES NOT:** Republish `anySessionOpen`/`micPermission` — views observe the orchestrator directly.

---

#### `ListenerService` (legacy/debug — `--foreground` path only)

**Responsibility:** Use cases for the old dual-mode-binary daemon: `startCapture`, `stopCapture`, `isListening`, `dump(minutes:to:)`, `listSessions()`/`dump(sessionId:)` via its own internal `SessionRegistry`.

**GUARANTEES**

- `dump` while not listening → structured error (not empty file).
- `stop` idempotent; `start` when already listening → no-op success.

**EXPECTS:** Platform adapters injected at construction.

**DOES NOT:** Parse CLI flags; launch GUI apps. Not used by the menu bar app — kept for headless debugging (`manbok start --foreground`).

---

#### `DumpPaths`

**Responsibility:** Deterministic temp filenames for dumps.

**GUARANTEES**

- Path is under `FileManager.default.temporaryDirectory`.
- Pattern: `manbok-YYYYMMDD-HHMMSS.wav` (local timezone).
- Parent directory exists before write.

**DOES NOT:** Open applications or delete old dumps.

---

#### `AudacityLauncher` (CLI / L4, legacy/debug — not used by the app)

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

**GUARANTEES:** One request per connection; bare-verb command line in, NDJSON response line out (`v:1` + `type` discriminator — see `docs/decisions/20260705-ndjson-ipc.md`).

**Commands (current):**

```text
PING                    → PONG
STATUS                  → LISTENING | WATCHING (ring summary)
SESSIONS                → session list (stable ids, per-app)
DUMP [minutes]          → OK path=<absolute-path> | ERR <message>
DUMP SESSION <id>       → OK path=<absolute-path> | ERR session_not_found
STOP                    → OK (app exits)
```

**Server (the app):** `ManbokApp.swift` binds this against the shared `SessionRegistry` +
`CaptureOrchestrator` — there is no separate daemon-side handler class; the switch over
`IPCCommand` lives inline in `ManbokApp.init()`.

**DOES NOT:** Stream audio over socket.

---

#### `DaemonProcess`

**GUARANTEES:** Writes/reads pid file, exclusive lock via pid + stale socket cleanup. Used by both the app (at launch) and the `--foreground` path.

**FAILURE BEHAVIOR:** Stale pid → detect dead process, reclaim state dir.

---

#### `AppIdentityResolver`

**Responsibility:** Resolve a mic-holding process's bundle ID/pid to a display name (e.g. `us.zoom.xos` → "Zoom") for session labels.

**GUARANTEES**

- Chain: (1) curated table (case-insensitive, ~50 common apps); (2) PPID walk (`libproc`/`sysctl`) to parent + `NSRunningApplication.localizedName`; (3) cosmetic fallback (strip helper/extension suffixes, titlecase last path component).
- Thread-safe; caches runtime resolutions per process lifetime (not persisted).

**FAILURE BEHAVIOR:** PPID walk or `NSRunningApplication` lookup fails → falls through to the next tier; never throws.

**DOES NOT:** Resolve content inside an app (no tab/site names).

---

#### `ExportService`

**Responsibility:** Turns a session's PCM into a WAV and hands it to Finder or the pasteboard — the app's replacement for the CLI's Audacity hand-off.

**GUARANTEES**

- `dumpToFinder`/`copyToClipboard(stableId:registry:appSlug:startTime:)` → `URL?`; nil if the session has fully expired.
- Filename: `manbok-<slug>-YYYYMMDD-HHMMSS.wav` (slug = sanitized app display name, timestamp = session start); collisions get `-2`, `-3` suffixes, never a silent overwrite.
- Raw-span CLI dumps (no app identity) keep the existing `manbok-YYYYMMDD-HHMMSS.wav` pattern via `DumpPaths` — not this service's job.

**FAILURE BEHAVIOR:** Expired session → nil. WAV write failure → throws.

**DOES NOT:** Render UI feedback or open Audacity.

---

#### `SettingsStore`

**Responsibility:** Thin `UserDefaults`-backed store for user-configurable settings (buffer preset, start-at-login), published for SwiftUI binding.

**GUARANTEES:** An unreadable/unrecognized stored preset falls back to `BufferPolicy.Preset.default` rather than crashing.

**DOES NOT:** Resize the ring when `bufferPreset` changes (`SessionRegistry.resize`), or register/unregister login items when `startAtLogin` changes (`ManbokApp` wires that).

---

#### `LoginItemManager`

**Responsibility:** Thin wrapper around `SMAppService.mainApp` for start-at-login.

**GUARANTEES:** `register()`/`unregister()` throw on macOS refusal (e.g. `.requiresApproval`); `status` exposes current registration for UI.

**DOES NOT:** Persist the user's preference (`SettingsStore`) or show UI beyond what macOS itself triggers.

---

#### `MigrationService`

**Responsibility:** One-time cleanup for installs upgrading from the old LaunchAgent daemon, run at app launch before the socket binds.

**GUARANTEES**

- Detects a legacy LaunchAgent plist (`~/Library/LaunchAgents/com.manbok.app.plist`); if found, `launchctl bootout`s it and deletes the file.
- Cleans a stale `run.sock`/pid file when the recorded pid is dead, or an orphaned socket with no pid file.
- Safe to call multiple times (no-op once clean); all filesystem/process errors swallowed — best-effort, never throws.

**DOES NOT:** Start the app, bind sockets, or manage `LoginItemManager`.

---

### L4 — Interface

#### `CommandRouter` (CLI)

**Responsibility:** Map `authorize|start|stop|status|sessions|dump` to IPC calls or an app launch.

**GUARANTEES**

- Exit code 0 on success; non-zero on user-fixable errors.
- **stdout** carries only scriptable primary output (one line): dump → absolute path; `status` → `listening` | `stopped`.
- **stderr** carries human diagnostics (start/stop messages, warnings, errors).
- `start` runs `open -a Manbok` if the app isn't already running (checked via `PING`); `start --foreground` runs the legacy in-process daemon instead (debug only).
- Connection failure → "manbok isn't running" hint rather than a raw socket error.

**DOES NOT:** Touch `AVAudioEngine` directly; write log files.

---

#### `ManbokApp` (SwiftUI app)

**Responsibility:** `@main` entry point; owns the app's object graph and the `MenuBarExtra`/`Settings` scenes.

**GUARANTEES**

- `init()` runs `MigrationService.runIfNeeded()`, builds `SettingsStore` → `SessionRegistry` (sized from the persisted preset) → `AVAudioCapture` → `CaptureOrchestrator` → `PopoverViewModel`, starts the IPC server against that same registry/orchestrator, then calls `orchestrator.start()`.
- `AppDelegate.anotherInstanceRunning()` pings the existing socket at launch; if another instance answers, this one terminates instead of fighting over the ring/socket.
- Menu bar icon reflects `micPermission`/`anySessionOpen` state (denied / recording / watching).

**DOES NOT:** Implement domain logic — it wires L2/L3 components together and hosts the IPC dispatch.

---

## 7. End-to-end flows

### App launch (normal path)

```text
ManbokApp.init() → MigrationService.runIfNeeded()   (bootout legacy LaunchAgent, clean stale socket/pid)
                 → SettingsStore()                    (reads persisted bufferPreset/startAtLogin)
                 → SessionRegistry(ringCapacity: BufferPolicy.capacityBytes(for: preset))
                 → AVAudioCapture() + CaptureOrchestrator(capture:registry:)
                 → PopoverViewModel(registry:orchestrator:)
                 → bind ~/.manbok/run.sock, serve IPCCommand inline against registry/orchestrator
                 → orchestrator.start()                (begins polling for mic-holding processes)
AppDelegate.applicationDidFinishLaunching → PING existing socket; if answered, terminate self
                                          → request mic permission if not yet determined
```

### App session lifecycle (per mic-holding app)

```text
CaptureOrchestrator poll (every 2s) → set-diff vs previous poll
  app arrives  → start capture engine if idle → AppIdentityResolver.resolve → registry.openSession
  app departs  → start 5s drain timer → (reclaimed: cancel) | (expires: registry.closeSession)
registry.append(pcm) on every capture callback → shared ring write → feed each open session's
  incremental waveform sampler
PopoverViewModel (only while popover visible) polls registry at ~1 Hz → sessions/ringFilled/ringCapacity
```

### Export from the popover (dump or copy)

```text
User taps "Save" or "Copy" on a session row
PopoverViewModel.dumpSession/copySession → ExportService.dumpToFinder/copyToClipboard
  → registry.snapshotForSession(stableId:) → WavPCMEncoder.encode → write to temp
  → NSWorkspace reveal in Finder, or NSPasteboard write
  → nil/false if the session's bytes have fully expired (dropped off the ring)
```

### `manbok dump 3` (CLI, thin IPC client)

```text
CLI → connect socket → send "DUMP 3\n"
App → registry.snapshotForDump(minutes: 3) → WavPCMEncoder → PlatformDumpSink.write
    → reply NDJSON {"type":"ok_path", path:"/var/folders/.../T/manbok-20260603-160000.wav"}
CLI → write path to stdout (single line, no prefix); diagnostics to stderr
    → not opened in Audacity in this path (that's --foreground/legacy only)
```

### `manbok start` (app not running)

```text
CLI → PING socket → no reply → `open -a Manbok`
App launches per "App launch" flow above
```

### `manbok status`

```text
CLI → STATUS → NDJSON {"type":"listening"|"watching", ring:{...}}
```

---

## 8. Assumptions and fallbacks

| Assumption | Invalidated if | Fallback |
|------------|----------------|----------|
| AVAudioEngine + converter can run alongside other mic apps | Manual mic-share test fails | Document limitation; investigate aggregate device / lower buffer size |
| Single app instance per user is enough | Multi-user Mac shared | State dir includes `$UID` |
| ~~10 min fixed is fine~~ **Resolved:** `BufferPolicy` presets (5/10/30/60/120 min), user-chosen | User wants >120 min | Extend the preset list |
| Line IPC is sufficient | Need structured errors | ~~Version prefix~~ **Resolved:** NDJSON responses (`v:1` + `type`), see `docs/decisions/20260705-ndjson-ipc.md` |
| ~~Forked daemon survives terminal close~~ **Resolved:** app is the long-lived process; login item (`LoginItemManager`) replaces the LaunchAgent | User wants always-on capture | Add an IPC mode command (e.g. `MODE ALWAYS`) — deliberately dropped from v1 |
| Per-app session tracking (poll set-diff) doesn't produce noisy junk rows from helper-process churn | Manual QA shows flapping helper sessions | Fall back to union-identity unbroken-run sessions (the model it replaced) |

---

## 9. Validation scenarios

| Scenario | Expected |
|----------|----------|
| Happy: Zoom call → popover → Save | Session row appears while open; "Save" reveals WAV in Finder |
| Two apps overlap (Zoom + OBS) | Two separate session rows, each spanning only its own app's mic use |
| Export after ring resize dropped a session's tail | Export clamped to surviving bytes, not nil, unless fully expired |
| `manbok dump \| wc -l` | stdout is exactly one path line; logs don't pollute pipe |
| Dump 0 min / empty ring | ERR, no file |
| Second app launch while one is running | Second instance PINGs, sees a reply, terminates itself |
| `manbok stop` then `manbok dump` | ERR — app not running (CLI hint) |
| Capture while Zoom uses mic | WAV has audio; Zoom still works (manual) |
| App force-quit (`kill -9`) | `manbok status` → not-running hint; `manbok start` relaunches it |
| Buffer preset changed in Settings | Ring resizes preserving newest audio; `sessionsLost` preview matches actual result |
| Unit: ring wrap | preset-minutes + 1 min write → last preset-minutes only in slice |
| Unit: WAV header | byte lengths match `spikes` golden |
| Unit: session-per-app | overlapping opens/closes produce independent, correctly-clamped `SessionSnapshot`s |

---

## 10. Resolved product decisions

| Decision | Choice |
|----------|--------|
| **Dump path** | System temp dir (`FileManager.default.temporaryDirectory`), file `manbok-<timestamp>.wav` (raw span) or `manbok-<app-slug>-<timestamp>.wav` (per-session export) |
| **Who writes dump** | App (returns absolute path over IPC for CLI dumps; writes directly for popover exports) |
| **After export (app)** | `ExportService` reveals in Finder or copies to clipboard — no Audacity dependency |
| **After dump (CLI `--foreground` legacy)** | `AudacityLauncher` opens the WAV in Audacity |
| **Buffer capacity** | User-selected `BufferPolicy` preset (5/10/30/60/120 min), default 10 — see §5 |
| **Process model** | Menu bar app is the long-lived process; CLI is a thin IPC client — see §5 |
| **Session identity** | Per-app, concurrent, overlapping sessions — see §5 |
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

**v1 (dual-mode binary, historical):**

1. L2 `ByteRingBuffer` + `WavPCMEncoder` + tests
2. L2 `DumpRange` + tests
3. L1 `AVAudioCapture` (port spike code)
4. L3 `RecordingSession` + `ListenerService`
5. L1 IPC server + `DaemonProcess`
6. L4 CLI commands
7. Manual mic-sharing gate

**Menu bar app evolution (2026-07-04 cycle):**

1. L2 `BufferPolicy`, `WaveformSampler`, `AppEvent` + tests
2. L3 `SessionRegistry` (replaces `RecordingSession`) + tests
3. L1 `AppIdentityResolver`, `CaptureOrchestrator` (replaces `OpportunisticCaptureController` for the app path) + tests
4. L1 `ExportService`, `SettingsStore`, `LoginItemManager`, `MigrationService` + tests
5. `ManbokApp` target: SwiftUI views, `PopoverViewModel`, inline IPC handler
6. `CommandRouter` updated to thin IPC client + `open -a Manbok`
7. Manual: resize while sessions open, overlapping-app sessions, login-item toggle, upgrade-from-LaunchAgent migration

---

## 12. One-breath summary

**Building:** a macOS menu bar app (+ thin CLI) that keeps a user-chosen window (5–120 min) of speech-grade PCM in a byte ring, tracks it per mic-holding app as overlapping sessions, and exports any session's WAV to Finder or the clipboard on demand.
**Why:** STT sometimes drops audio; user needs a silent safety net, recognizable by "which app was I on."
**Path:** layered core (testable ring + WAV + waveform math) with thin AVFoundation/socket/process/UserDefaults adapters; the app itself is the long-lived process, CLI is a thin IPC client, `--foreground` remains for headless debugging.
**Doesn't handle:** segmentation, always-on capture (deliberately dropped from v1), disk persistence of the buffer beyond an explicit export.
**Reversal:** mic-sharing fails, buffer format changes, or per-app session tracking proves noisy → revisit capture adapter, storage model, or fall back to union-identity sessions (see `docs/decisions/`) before piling on features.
