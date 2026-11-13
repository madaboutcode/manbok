# ManbokPlatform

macOS adapters: microphone, Unix socket, filesystem, process lifecycle, stderr logging.

## Jumpstart

**Updated:** 2026-06-03

### What This Module Owns

Everything that touches the OS — HAL audio, `~/.manbok/`, temp-dir WAV writes, detached daemon spawn, `open -a Audacity`.

### Mental Model

Implements Core ports (`AudioCapturing`, `DumpSink`) and provides infrastructure the app/executable wire in. `CaptureSupervisor` drives capture end-to-end (capture redesign, Waves A/B): it applies device/restart policy and owns disposable `AUHALWorker` instances behind the `PinnedAudioCapturing` waist; workers convert device-native audio to canonical PCM via `CanonicalPCMConverter` and feed chunks into Core's `SessionRegistry`. `SessionLifecycleController` polls `ProcessAudioMonitor.holderSnapshot()` and executes Core's `DemandReducer` decisions (session open/close, device candidates for the supervisor), resolving app names via `AppIdentityResolver`.

### Layout

| Folder | Role |
|--------|------|
| `Capture/` | `CaptureSupervisor` (device/restart policy, owns workers), `AUHALWorker` (device-pinned HAL capture; disposable, one start per instance), `CanonicalPCMConverter` (device-native → s16le 16 kHz mono; enforces the AVAudioConverter pull-API invariants — see ARCHITECTURE.md §Capture stack), `CaptureWaist`/`PinnedAudioCapturing` (worker boundary), `SessionLifecycleController` (poll + executor for `DemandReducer`), `CaptureDevicePolicy`, `CaptureRestartPolicy`, `SilenceRecoveryPolicy`, `AUHALEnvironmentSignals`/`EnvironmentSignals`, `AppIdentityCatalog` (bundle ID → {display name, icon bundle ID}, pure/unit-tested), `AppIdentityResolver`, `InputDeviceObserver`, `MicrophoneAuthorization` (+ `MicrophoneAuthorizing` async boundary; supervisor requests permission at first demand, never blocks the lifecycle queue), `ProcessAudioMonitor` (holder = `pdv#` input device, not `IsRunningInput`), `SilenceAlarmMonitor` (runs `SilenceAlarmPolicy`; fed by `CaptureSupervisor.onAudibleChunk` and the lifecycle's `anySessionOpen`; notifies, publishes `status`, logs), `HolderExclusion` (`appGroup`, built-in + user exclusion predicate, Settings row builder) |
| `IPC/` | `UnixSocketServer`, `UnixSocketClient` |
| `IO/` | `AppStatePaths`, `DumpPaths`, `WavFileWriter`, `PlatformDumpSink`, `ExportService` (Finder reveal + clipboard), `StatePersistenceService` (checkpoint save/restore/clear) |
| `Settings/` | `SettingsStore` (UserDefaults persistence), `LoginItemManager` (SMAppService) |
| `Runtime/` | `DaemonSession`, `DaemonPresentation`, `DaemonRuntimeEnvironment`, `MigrationService`, `AppShutdown` (stop-then-save, 2 s bound) |
| `Process/` | `DaemonProcess`, `SingleInstance` (flock launch guard) |
| `Logging/` | `AppLog`, `Diagnostics`, `DiagnosticsWriting` |
| `UI/` | `ActivityPresenting`, `TerminalCaptureMeter`, `TerminalPainter` (debug-only terminal UI) |
| `External/` | `AudacityLauncher`, `UserNotificationSilenceAlarmNotifier` (UNUserNotificationCenter; bundle-only, never constructed in tests) |

### Paths

- State: `~/.manbok/run.sock`, `~/.manbok/appa.pid`, `~/.manbok/checkpoint-<seq>/{ring.pcm,ring.json}` (generations), `~/.manbok/instance.lock` (flock held for process lifetime; `Process/SingleInstance.swift`)
- Dumps: `FileManager.default.temporaryDirectory` / `manbok-YYYYMMDD-HHMMSS.wav`

### Spike Reference

Validated prototypes: `spikes/Sources/CaptureSpike`, `IpcSpike`.

## Constraints

- Dropped converter frames: log `.warning`, continue capture.
- Presence = `pdv#` input device only. `IsRunningInput` is not a decision input (process taps set it). No gap hold: `CaptureSupervisor` releases the worker when the demand has no candidate device.
- `UnixSocketServer.stop()` closes listen fd — used when daemon exits on `STOP`.
- `stop` command must exit the daemon process — orphan pid breaks status/dump.

## Testing

```bash
swift test --filter ManbokPlatformTests
```

Capture itself is not unit-tested (needs mic); test IO/paths/IPC helpers where possible.
Mic-sharing with other apps is best-effort — manual QA, not unit-tested.