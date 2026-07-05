# manbok (executable)

CLI surface and daemon entry. Thin — delegates to Core + Platform.

## Jumpstart

**Updated:** 2026-07-05

### Entry Points

| Invocation | Behavior |
|------------|----------|
| `manbok start` | PING socket → "already running"; else `open -a Manbok` |
| `manbok start --foreground` | In-process debug daemon (`DaemonMain`, meter on TTY) |
| `manbok stop\|status\|dump\|sessions` | `CommandRouter` → `UnixSocketClient` IPC to the app |
| `manbok authorize` | Mic TCC request (for debug/foreground use) |
| `manbok daemon` (hidden) | `DaemonMain.runDaemon()` — debug only |
| `argv` contains `daemon` | `Main.swift` routes to `DaemonMain` (backward compat) |

### CLI I/O Contract

| Command | stdout | stderr |
|---------|--------|--------|
| `authorize` | `authorized` or `denied` (one word) | grant/deny hints |
| `status` | `watching`, `listening`, or `stopped` + ring summary | — |
| `start` | — | `manbok.app launched` or `manbok is already running` |
| `dump` | absolute path to `.wav`; default = newest; `-1` = prior; `all` = ring; `1` = id | `AppLog` info/warnings (e.g. Audacity) |
| `stop` | — | `stopped` or error |

Connection failure → "manbok isn't running — run 'manbok start' or open Manbok.app"

### Files

- `Main.swift` — daemon vs CLI dispatch (backward compat for in-flight LaunchAgents)
- `CLI/CommandRouter.swift` — ArgumentParser subcommands
- `DaemonMain.swift` — IPC handler + `ListenerService` lifecycle (debug/--foreground only)

## Constraints

- Never import AVAudioEngine in this target — use `AVAudioCapture` via daemon only.
- Do not write dumps from CLI — always IPC `DUMP` to the app.

## Testing

No dedicated executable tests; verify via:

```bash
swift build && .build/debug/manbok status
```
