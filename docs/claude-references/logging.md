# Logging & Diagnostics

## How It Works

All logging goes through `AppLog` → `Diagnostics` sink → `os.Logger` (subsystem `ai.manbok.app`).

- App target: `OSLogOnlyDiagnostics` (Console.app / `log show`)
- CLI target: `OSLogAndStderrDiagnostics` (Console.app + stderr)

## macOS Unified Logging Persistence

| Log Level | Persistence | Use For |
|-----------|------------|---------|
| `.debug` | **Not stored.** Stream-only (`log stream`) | Verbose tracing, IPC received commands |
| `.info` | **Memory ring buffer.** Dropped within ~5 min | Operational detail (bytes written, file paths) |
| `.notice` | **Persisted to disk.** Survives reboot | Session opens/closes, state changes, errors worth diagnosing later |
| `.error` | **Always persisted** | Failures |
| `.fault` | **Always persisted** | System-level issues |

**Rule:** Anything you'd need to diagnose a user-reported issue must be `.notice` or above.

## Querying Logs

```bash
# Persisted logs (notice and above) — use a wide enough time window
/usr/bin/log show --last 30m --predicate 'subsystem == "ai.manbok.app"'

# Include info-level (memory buffer, may already be gone)
/usr/bin/log show --last 5m --predicate 'subsystem == "ai.manbok.app"' --info

# Live stream from the running app (all levels including debug)
/usr/bin/log stream --process $(pgrep -f Manbok) --level debug

# Filter by category
/usr/bin/log show --last 30m --predicate 'subsystem == "ai.manbok.app" AND category == "capture"'
```

**Important:** Use `/usr/bin/log` (full path) — shell aliases or zsh globbing can break the predicate quoting.

## Gotcha: Time Window

`log show --last 1m` only searches the last minute. If the event happened 10 minutes ago, you won't find it. Use `--last 30m` or `--last 1h` when investigating.

## Ad-hoc Signing

Unified logging works fine for ad-hoc signed apps. TTL=0 in stream output reflects the log *level* (debug/info are ephemeral by design), not a signing issue. Notice-level logs persist normally.

## False Mic Sessions

macOS system processes that briefly touch the mic (e.g., System Settings → Sound showing the input level meter) are filtered out in `ProcessAudioMonitor.ignoredBundleIDPrefixes`. Known:

- `com.apple.Sound-Settings.extension` — Sound settings input meter
- `com.apple.systempreferences.*` — System Settings panels
- `com.apple.audio.*` — Audio system helpers

Infrastructure helpers that can hold `IsRunningInput=true` permanently are filtered by exact bundle ID in `ProcessAudioMonitor.alwaysOnProcesses` (Siri/CoreSpeech, Continuity Camera, and Rogue Amoeba's ARK agent). These never open sessions or demand capture.

- `com.rogueamoeba.arkaudiod` — ARK (Audio Routing Kit). It performs system-audio routing for Loopback/Audio Hijack and can report `IsRunningInput=true` with **no input device** indefinitely. Before this exclusion it kept Manbok's capture alive after the real recording app stopped (`pdv# gap — holding current capture` with no bound).
- **Attribution limitation:** HAL exposes no link from ARK's IO to the client app, so excluding it is all-or-nothing. An app whose microphone capture is performed *only* by ARK, without setting its own process's `IsRunningInput`, will not be tracked as a mic holder. Observed real apps (e.g. Pipit, `com.pxkan.pipit2`) set their own flag and remain tracked. Do not broaden this to a `com.rogueamoeba.*` prefix — that would also hide real Rogue Amoeba apps.
