# ManbokPlatform

macOS adapters: microphone, Unix socket, filesystem, process lifecycle, stderr logging.

## Jumpstart

**Updated:** 2026-06-03

### What This Module Owns

Everything that touches the OS — HAL audio, `~/.manbok/`, temp-dir WAV writes, detached daemon spawn, `open -a Audacity`.

### Mental Model

Implements Core ports (`AudioCapturing`, `DumpSink`) and provides infrastructure the executable wires in `DaemonMain`.

### Layout

| Folder | Role |
|--------|------|
| `Capture/` | `AVAudioCapture` — engine tap + converter → 16 kHz mono `Data` |
| `IPC/` | `UnixSocketServer`, `UnixSocketClient` |
| `IO/` | `AppStatePaths`, `DumpPaths`, `WavFileWriter`, `PlatformDumpSink` |
| `Process/` | `DaemonProcess` — pid file, `posix_spawn` daemon |
| `Logging/` | `AppLog` — `os.Logger` + stderr mirror |
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