# upil-appa (executable)

CLI surface and daemon entry. Thin — delegates to Core + Platform.

## Jumpstart

**Updated:** 2026-06-04

### Entry Points

| Invocation | Behavior |
|------------|----------|
| `upil-appa authorize\|start\|stop\|status\|dump\|sessions` | `CommandRouter` → mic TCC or `UnixSocketClient` |
| `upil-appa daemon` (hidden) | `DaemonMain.runDaemon()` — do not run manually unless debugging |
| `argv` contains `daemon` | `Main.swift` routes to `DaemonMain` (spawned child) |

### CLI I/O Contract

| Command | stdout | stderr |
|---------|--------|--------|
| `authorize` | `authorized` or `denied` (one word) | grant/deny hints |
| `dump` | WAV path; default = newest; `-1` = prior; `all` = ring; `1` = id | Audacity hint |
| `status` | `watching`, `listening`, or `stopped` (one word) | — |
| `start` | default opportunistic; `--always-on` for 24/7 capture | — |
| `dump` | absolute path to `.wav` (one line) | `AppLog` info/warnings (e.g. Audacity) |
| `start` | — | `daemon started` / `already listening` |
| `stop` | — | `stopped` or error |

Exit 0 on successful dump even if Audacity fails to open (path still on stdout).

### Files

- `Main.swift` — daemon vs CLI dispatch
- `CLI/CommandRouter.swift` — ArgumentParser subcommands
- `DaemonMain.swift` — IPC handler + `ListenerService` lifecycle

### Stale Daemon

`start` checks pid + `STATUS`: if process alive but not `listening`, sends `STOP` and respawns.

## Constraints

- Never import AVAudioEngine in this target — use `AVAudioCapture` via daemon only.
- Do not write dumps from CLI — always IPC `DUMP` to daemon.

## Design & Documentation

- `tasks/upil-appa.design.md` § L4 — Interface / flows.

## Testing

No dedicated executable tests; verify via:

```bash
swift build && .build/debug/upil-appa status
```