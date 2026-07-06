# ManbokPlatform

macOS adapters: microphone, Unix socket, filesystem, process lifecycle, stderr logging.

## Jumpstart

**Updated:** 2026-06-03

### What This Module Owns

Everything that touches the OS — HAL audio, `~/.manbok/`, temp-dir WAV writes, detached daemon spawn, `open -a Audacity`.

### Mental Model

Implements Core ports (`AudioCapturing`, `DumpSink`) and provides infrastructure the app/executable wire in. `CaptureOrchestrator` drives capture end-to-end — it owns the `AVAudioCapture` tap and feeds bytes into Core's `SessionRegistry`, resolving the foreground app via `AppIdentityResolver` for per-app session boundaries.

### Layout

| Folder | Role |
|--------|------|
| `Capture/` | `AVAudioCapture` (engine tap + converter), `CaptureOrchestrator` (per-app capture lifecycle + self-healing restarts on device change / byte-flow stall), `CaptureRestartPolicy` (restart rate-limit + backoff decisions, unit-tested), `AppIdentityCatalog` (bundle ID → {display name, icon bundle ID} static table + icon-candidate stemming, pure/unit-tested), `AppIdentityResolver` (bundle ID → display name; tier 1 delegates to the catalog), `InputDeviceObserver`, `MicrophoneAuthorization`, `OpportunisticCaptureController` (legacy), `ProcessAudioMonitor` |
| `IPC/` | `UnixSocketServer`, `UnixSocketClient` |
| `IO/` | `AppStatePaths`, `DumpPaths`, `WavFileWriter`, `PlatformDumpSink`, `ExportService` (Finder reveal + clipboard), `StatePersistenceService` (checkpoint save/restore/clear) |
| `Settings/` | `SettingsStore` (UserDefaults persistence), `LoginItemManager` (SMAppService) |
| `Runtime/` | `DaemonSession`, `DaemonPresentation`, `DaemonRuntimeEnvironment`, `MigrationService` |
| `Process/` | `DaemonProcess` — pid file, `posix_spawn` daemon |
| `Logging/` | `AppLog`, `Diagnostics`, `DiagnosticsWriting` |
| `UI/` | `ActivityPresenting`, `TerminalCaptureMeter`, `TerminalPainter` (debug-only terminal UI) |
| `External/` | `AudacityLauncher` |

### Paths

- State: `~/.manbok/run.sock`, `~/.manbok/appa.pid`
- Dumps: `FileManager.default.temporaryDirectory` / `manbok-YYYYMMDD-HHMMSS.wav`

### Spike Reference

Validated prototypes: `spikes/Sources/CaptureSpike`, `IpcSpike`.

## Constraints

- Dropped converter frames: log `.warning`, continue capture.
- `UnixSocketServer.stop()` closes listen fd — used when daemon exits on `STOP`.
- `stop` command must exit the daemon process — orphan pid breaks status/dump.

## Testing

```bash
swift test --filter ManbokPlatformTests
```

Capture itself is not unit-tested (needs mic); test IO/paths/IPC helpers where possible.
Mic-sharing with other apps is best-effort — manual QA, not unit-tested.